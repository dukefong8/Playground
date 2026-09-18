/**
 * .pigit.ts — a single-tool pi extension: `git`.
 *
 * Built for non-interactive use (`pi -p --tools read,edit,find,git`, e.g. from pighcid.sh).
 * It lives at .pi/extensions/pigit.ts inside the project, which pi discovers relative to
 * the working directory, so sessions started in that project load it too. That is why it
 * registers exactly one tool and overrides no built-in: a `grep`/`find`/`ls` override here
 * would replace the real ones, and would fail outside a git repository.
 *
 * It never prompts, never registers a command, and never waits on a human: the hook
 * hangs if it does.
 *
 * The tool takes a fixed operation enum plus an optional path/ref. It can never
 * run an arbitrary command string, and it cannot mutate anything except the
 * working-tree file named by `revert_file` (`git checkout -- <path>`). No network.
 *
 * Output is capped (120 lines / 6 KB, whichever comes first) and ends with a
 * marker that says exactly how much was cut, because the hook's cost is dominated
 * by re-reading context on every turn.
 */

import { realpathSync, statSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Output cap: bytes and lines, whichever is hit first. */
const MAX_OUTPUT_BYTES = 6 * 1024;
const MAX_OUTPUT_LINES = 120;

/** `log` bounds. */
const DEFAULT_LOG_ENTRIES = 10;
const MAX_LOG_ENTRIES = 25;

/** Any single git invocation we run is short-lived; a hook must not hang on it. */
const GIT_TIMEOUT_MS = 20_000;

/** Bounds on a `grep` pattern, checked in one place by checkPattern below. */
const MAX_PATTERN_CHARS = 500;

/** How much of a model-supplied string an error message may quote back (see echo). */
const MAX_ECHO_CHARS = 200;

const OPS = ["status", "diff", "diff_staged", "log", "show", "grep", "revert_file"] as const;
type Op = (typeof OPS)[number];
const ALLOWED_OPS = new Set<string>(OPS);

const PARAMETERS = Type.Object({
  op: Type.String({
    description:
      'Operation, one of: "status" | "diff" | "diff_staged" | "log" | "show" | "grep" | "revert_file". Any other value is refused without running anything.',
  }),
  path: Type.Optional(
    Type.String({
      description:
        'Repository-relative path. Required by "revert_file" (a directory path reverts everything under it). Used as a narrowing pathspec by the other operations, including "grep". Absolute paths, "~", and ".." are refused.',
    }),
  ),
  pattern: Type.Optional(
    Type.String({
      description:
        'Required by "grep": the search pattern (an extended regular expression, passed as `git grep -e <pattern>`, so it can never be read as an option). Searches only files in this repository — it cannot reach outside it. Ignored by the other operations.',
    }),
  ),
  ref: Type.Optional(
    Type.String({
      description: 'Commit-ish for "show" (default "HEAD"), e.g. "HEAD", "HEAD~1", "main", "abc1234". Ignored by the other operations.',
    }),
  ),
  lines: Type.Optional(
    Type.Number({
      description: `For "log": how many commits to list, 1-${MAX_LOG_ENTRIES} (default ${DEFAULT_LOG_ENTRIES}). Ignored by the other operations.`,
    }),
  ),
});

const DESCRIPTION = [
  "Run a fixed, non-interactive git query, or undo one bad file edit.",
  'Operations (op): "status" = git status --short --branch (where am I); "diff" = git diff (see what you just changed); "diff_staged" = git diff --staged; "log" = git log --oneline -n <lines>; "show" = git show --stat <ref> (one commit); "grep" = git grep --line-number -e <pattern> -- <path>, which sees only this repository — outside it there is nothing to find, so searching elsewhere is wasted turns; "revert_file" = git checkout -- <path>, the undo for a bad edit, requires path.',
  "Every other operation is refused, including add, commit, push, pull, fetch, merge, reset, clean, restore, switch, rebase, stash, config, remote, worktree, submodule and index/object plumbing. This tool never accepts an arbitrary command string and never touches the network.",
  `Output is capped at ${MAX_OUTPUT_LINES} lines or ${MAX_OUTPUT_BYTES / 1024} KB, whichever comes first, and ends with a truncation marker stating how much was cut; narrow it with path or a smaller lines value instead of re-reading the whole thing.`,
  "It never prompts and never blocks waiting for input.",
].join(" ");

interface CapResult {
  text: string;
  truncated: boolean;
  totalLines: number;
  totalBytes: number;
  keptLines: number;
  keptBytes: number;
  omittedLines: number;
  omittedBytes: number;
}

interface ExecResult {
  stdout?: string;
  stderr?: string;
  code?: number;
  killed?: boolean;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function byteLength(text: string): number {
  return encoder.encode(text).length;
}

function humanBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
}

/** Split into lines without a phantom trailing empty line. */
function splitLines(raw: string): string[] {
  const lines = raw.split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

/** Cap to MAX_OUTPUT_LINES / MAX_OUTPUT_BYTES, appending a marker saying what was cut. */
function capOutput(raw: string): CapResult {
  const totalBytes = byteLength(raw);
  const lines = splitLines(raw);
  const totalLines = lines.length;

  if (totalBytes <= MAX_OUTPUT_BYTES && totalLines <= MAX_OUTPUT_LINES) {
    return {
      text: lines.join("\n"),
      truncated: false,
      totalLines,
      totalBytes,
      keptLines: totalLines,
      keptBytes: totalBytes,
      omittedLines: 0,
      omittedBytes: 0,
    };
  }

  const kept: string[] = [];
  let keptBytes = 0;
  for (const line of lines) {
    if (kept.length >= MAX_OUTPUT_LINES) break;
    const cost = byteLength(line) + (kept.length > 0 ? 1 : 0);
    if (keptBytes + cost > MAX_OUTPUT_BYTES) break;
    kept.push(line);
    keptBytes += cost;
  }

  // A single line longer than the whole budget: hard-cut it on a byte boundary.
  if (kept.length === 0) {
    const first = lines[0] ?? "";
    const cut = decoder.decode(encoder.encode(first).slice(0, MAX_OUTPUT_BYTES));
    kept.push(cut);
    keptBytes = byteLength(cut);
  }

  const omittedLines = Math.max(0, totalLines - kept.length);
  const omittedBytes = Math.max(0, totalBytes - keptBytes);
  const marker =
    `\n[truncated: kept ${kept.length} of ${totalLines} lines ` +
    `(${humanBytes(keptBytes)} of ${humanBytes(totalBytes)}); ` +
    `${omittedLines} lines and ${humanBytes(omittedBytes)} cut — ` +
    `narrow with path, or use a smaller lines value or "show" instead]`;

  return {
    text: kept.join("\n") + marker,
    truncated: true,
    totalLines,
    totalBytes,
    keptLines: kept.length,
    keptBytes,
    omittedLines: omittedLines,
    omittedBytes: omittedBytes,
  };
}

function firstLines(text: string, maxLines: number, maxBytes: number): string {
  const joined = splitLines(text).slice(0, maxLines).join("\n");
  if (byteLength(joined) <= maxBytes) return joined;
  return decoder.decode(encoder.encode(joined).slice(0, maxBytes));
}

/**
 * Quote model-supplied text back into an error message, bounded. Every other return path
 * goes through capOutput or firstLines; the refusals that echo the caller's own input are
 * the only place a model string reached the result uncapped.
 */
function echo(text: string): string {
  return JSON.stringify(text.length > MAX_ECHO_CHARS ? `${text.slice(0, MAX_ECHO_CHARS)}…` : text);
}

type PathCheck = { ok: true; path: string } | { ok: false; reason: string };

/**
 * Path safety: relative only, no "..", must stay inside the repo root — including
 * through symlinks in the deepest existing ancestor of the path.
 */
function checkPath(raw: unknown, repoRoot: string, cwd: string): PathCheck {
  if (typeof raw !== "string" || raw.trim() === "") {
    return { ok: false, reason: "missing path (this operation needs a repository-relative file or directory path)" };
  }

  let candidate = raw.trim();
  if (candidate.startsWith("@")) candidate = candidate.slice(1); // models sometimes prepend @
  if (candidate === "") return { ok: false, reason: "missing path" };
  if (candidate.includes("\0") || candidate.includes("\n") || candidate.includes("\r")) {
    return { ok: false, reason: "path contains control characters" };
  }
  if (candidate.startsWith("~") || isAbsolute(candidate) || /^[A-Za-z]:[\\/]/.test(candidate) || candidate.startsWith("\\\\")) {
    return { ok: false, reason: `absolute paths are refused: ${echo(candidate)}` };
  }
  if (candidate.split("/").includes("..")) {
    return { ok: false, reason: `".." escapes are refused: ${echo(candidate)}` };
  }

  const absolute = resolve(cwd, candidate);
  const fromRoot = relative(repoRoot, absolute);
  if (fromRoot !== "" && (fromRoot.startsWith("..") || isAbsolute(fromRoot))) {
    return { ok: false, reason: `path is outside the repository root (${repoRoot}): ${echo(candidate)}` };
  }

  // Lexical checks already passed; also refuse if a symlink in the existing part of
  // the path points outside the repository.
  let realRoot: string;
  try {
    realRoot = realpathSync(repoRoot);
  } catch {
    return { ok: true, path: candidate }; // nothing to compare against; git will still refuse nonsense
  }
  let probe = absolute;
  for (;;) {
    try {
      const real = realpathSync(probe);
      const rel = relative(realRoot, real);
      if (rel !== "" && (rel.startsWith("..") || isAbsolute(rel))) {
        return { ok: false, reason: `path escapes the repository root through a symlink: ${echo(candidate)}` };
      }
      break;
    } catch {
      const parent = dirname(probe);
      if (parent === probe) break;
      probe = parent;
    }
  }

  return { ok: true, path: candidate };
}

type RefCheck = { ok: true; ref: string } | { ok: false; reason: string };

/** Commit-ish safety: allow only plain revision names that cannot look like an option. */
function checkRef(raw: unknown): RefCheck {
  if (raw === undefined || raw === null || raw === "") return { ok: true, ref: "HEAD" };
  if (typeof raw !== "string") return { ok: false, reason: "ref must be a string" };
  const ref = raw.trim();
  if (ref === "") return { ok: true, ref: "HEAD" };
  if (ref.length > 200) return { ok: false, reason: "ref is too long" };
  if (!/^[A-Za-z0-9_][A-Za-z0-9._/~^{}@-]*$/.test(ref)) {
    return { ok: false, reason: `refused ref ${echo(ref)}: only plain commit-ish names are accepted` };
  }
  if (ref.includes("..")) return { ok: false, reason: `refused ref containing "..": ${echo(ref)}` };
  return { ok: true, ref };
}

function clampLogLines(raw: unknown): number {
  if (typeof raw !== "number" || !Number.isFinite(raw)) return DEFAULT_LOG_ENTRIES;
  return Math.min(MAX_LOG_ENTRIES, Math.max(1, Math.trunc(raw)));
}

type PatternCheck = { ok: true; pattern: string } | { ok: false; reason: string };

/**
 * One place for the pattern rules used by op="grep". The wording here is what the model
 * reads on a bad call, so it names the op that needs the pattern.
 */
function checkPattern(raw: unknown): PatternCheck {
  const pattern = typeof raw === "string" ? raw : "";
  if (pattern.trim() === "") {
    return { ok: false, reason: 'missing pattern (op="grep" searches this repository with git grep and needs a pattern)' };
  }
  if (pattern.length > MAX_PATTERN_CHARS) return { ok: false, reason: `pattern is too long (max ${MAX_PATTERN_CHARS} characters)` };
  if (pattern.includes("\0") || /[\n\r]/.test(pattern)) return { ok: false, reason: "pattern contains control characters" };
  return { ok: true, pattern };
}

function failure(text: string) {
  return { content: [{ type: "text" as const, text: `git: ${text}` }], details: { ok: false } };
}

export default function gitToolExtension(pi: ExtensionAPI) {
  async function git(args: string[], cwd: string, signal: AbortSignal | undefined): Promise<ExecResult> {
    return (await pi.exec("git", args, { signal, cwd, timeout: GIT_TIMEOUT_MS })) as ExecResult;
  }

  async function resolveRepoRoot(cwd: string, signal: AbortSignal | undefined): Promise<{ ok: true; root: string } | { ok: false; reason: string }> {
    let result: ExecResult;
    try {
      result = await git(["rev-parse", "--show-toplevel"], cwd, signal);
    } catch (error) {
      return { ok: false, reason: `could not run git (${errorText(error)})` };
    }
    if (result.killed) return { ok: false, reason: `git timed out after ${GIT_TIMEOUT_MS}ms` };
    const stderr = (result.stderr ?? "").trim();
    if (result.code !== 0) {
      if (!stderr && !(result.stdout ?? "").trim()) return { ok: false, reason: `git is not available (or not executable) in ${cwd}` };
      if (/not a git repository/i.test(stderr)) return { ok: false, reason: `not a git repository: ${cwd}` };
      return { ok: false, reason: `git rev-parse failed (exit ${result.code}): ${firstLines(stderr, 4, 400)}` };
    }
    const root = (result.stdout ?? "").trim();
    if (root === "") return { ok: false, reason: `could not determine the git repository root for ${cwd}` };
    return { ok: true, root };
  }

  pi.registerTool({
    name: "git",
    label: "Git",
    description: DESCRIPTION,
    promptSnippet: "Inspect the repository and undo a bad edit with a fixed set of read-only git operations",
    promptGuidelines: [
      'Use git with op="diff" to see exactly what you just changed before editing again.',
      'Use git with op="grep" and a pattern to search this repository. There is no other search tool: a file that is not in this repository cannot be found by searching for it, so do not spend turns looking outside the repo.',
      'Use git with op="revert_file" and the file path to undo a bad edit instead of re-editing the same lines.',
      'The git tool accepts only the ops status, diff, diff_staged, log, show, grep and revert_file; it never runs arbitrary or mutative git commands and never prompts.',
    ],
    parameters: PARAMETERS,

    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      try {
        const op = typeof params.op === "string" ? params.op.trim() : "";
        if (!ALLOWED_OPS.has(op)) {
          return failure(
            `refused op ${echo(op)}. Allowed ops: ${OPS.join(", ")}. ` +
              "This tool never runs mutative or arbitrary git commands (no add, commit, push, pull, fetch, merge, reset, clean, restore, switch, rebase, stash, config, remote, worktree, submodule or plumbing).",
          );
        }
        const selected = op as Op;
        const cwd = ctx.cwd;

        const repo = await resolveRepoRoot(cwd, signal);
        if (!repo.ok) return failure(repo.reason);

        const wantsPath = selected === "revert_file";
        let pathArg: string | undefined;
        if (wantsPath || (typeof params.path === "string" && params.path.trim() !== "")) {
          const checked = checkPath(params.path, repo.root, cwd);
          if (!checked.ok) return failure(checked.reason);
          pathArg = checked.path;
        }

        if (selected === "revert_file") {
          // `checkPath` accepts "." and directories, and `git checkout -- .` (or -- <dir>)
          // discards every uncommitted change underneath it. Nothing is staged in this
          // workflow, so that is unrecoverable. Comparing against the repo root is not
          // enough — the hook's cwd is a subdirectory of it, so "." resolves to a subdir
          // that holds all the work. This tool exists to undo one bad edit: require a file.
          let isDir = false;
          try {
            isDir = statSync(resolve(cwd, pathArg as string)).isDirectory();
          } catch {
            // Missing path; git will report it.
          }
          if (isDir) {
            return failure(
              "refusing revert_file on a directory: `git checkout -- <dir>` discards every uncommitted change under it. Pass a single file.",
            );
          }
        }

        let argv: string[];
        switch (selected) {
          case "status":
            argv = ["status", "--short", "--branch"];
            break;
          case "diff":
            argv = ["diff"];
            break;
          case "diff_staged":
            argv = ["diff", "--staged"];
            break;
          case "log":
            argv = ["log", "--oneline", "-n", String(clampLogLines(params.lines))];
            break;
          case "show": {
            const checked = checkRef(params.ref);
            if (!checked.ok) return failure(checked.reason);
            argv = ["show", "--stat", checked.ref];
            break;
          }
          case "grep": {
            const checked = checkPattern(params.pattern);
            if (!checked.ok) return failure(checked.reason);
            // `--untracked` covers files not yet added. Ignored ones stay out because git
            // applies the repository's own .gitignore rules here — no path list is hardcoded
            // in this file; what is searched is exactly what `git status` would show.
            argv = ["grep", "--line-number", "--color=never", "-I", "--untracked", "-e", checked.pattern];
            break;
          }
          case "revert_file":
            argv = ["checkout", "--", pathArg as string];
            break;
        }
        if (pathArg !== undefined && selected !== "revert_file") argv.push("--", pathArg);

        const result = await git(argv, cwd, signal);
        if (result.killed) return failure(`git ${selected} timed out after ${GIT_TIMEOUT_MS}ms`);
        const stderr = (result.stderr ?? "").trim();
        const stdout = result.stdout ?? "";
        if (result.code !== 0) {
          // `git grep` exits 1 to mean "no matches", which is a normal answer, not a
          // failure — reporting it as one would push pi into re-running the search.
          if (selected === "grep" && result.code === 1 && stdout.trim() === "") {
            return {
              content: [{ type: "text" as const, text: "(no matches in this repository)" }],
              details: { ok: true, op: selected, argv, path: pathArg, exitCode: 1, matches: 0 },
            };
          }
          if (!stderr && stdout.trim() === "") return failure(`git is not available (or not executable) in ${cwd}`);
          return failure(`git ${selected} failed (exit ${result.code}): ${firstLines(stderr || stdout.trim(), 6, 600)}`);
        }

        if (selected === "revert_file") {
          const after = await git(["diff", "--stat", "--", pathArg as string], cwd, signal);
          const remaining = (after.stdout ?? "").trim();
          const state =
            after.code === 0 && remaining === ""
              ? "no unstaged changes left in that path"
              : `unstaged changes still present in that path: ${firstLines(remaining || (after.stderr ?? "").trim(), 4, 300)}`;
          return {
            content: [{ type: "text" as const, text: `reverted ${pathArg} (git checkout -- ${pathArg})\n${pathArg}: ${state}` }],
            details: { ok: true, op: selected, argv, path: pathArg, exitCode: result.code },
          };
        }

        const capped = capOutput(stdout);
        let text = capped.text;
        if (text.trim() === "") {
          text =
            selected === "status"
              ? "(clean working tree)"
              : selected === "diff"
                ? "(no unstaged changes)"
                : selected === "diff_staged"
                  ? "(no staged changes)"
                  : selected === "log"
                    ? "(no commits)"
                    : selected === "grep"
                      ? "(no matches in this repository)"
                      : "(no output)";
        }

        return {
          content: [{ type: "text" as const, text }],
          details: {
            ok: true,
            op: selected,
            argv,
            path: pathArg,
            exitCode: result.code,
            truncated: capped.truncated,
            totalLines: capped.totalLines,
            keptLines: capped.keptLines,
            totalBytes: capped.totalBytes,
            omittedLines: capped.omittedLines,
          },
        };
      } catch (error) {
        // Never throw: an exception here must not be able to disturb the pi run.
        return failure(`unexpected failure: ${errorText(error)}`);
      }
    },
  });

}

function errorText(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}
