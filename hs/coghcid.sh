#!/usr/bin/env bash
# coghcid.sh — hand a failed build to codex, non-interactively.
#
# Runs as a ghciwatch --after-reload-shell hook, so it only ever fires when a
# reload failed. ghciwatch discards hook output, so each run reports itself on the
# status line of the tmux window running ghciwatch.
set -euo pipefail

GHCID=${GHCID:-ghcid.txt}
LOG=$PWD/.coghcid.log # stdout+stderr of the codex run; outside WORK so the trap
# cannot remove it
WORK=$PWD/.coghcid # lock dir, removed on exit

# Where to report: the pane this runs in, which is the ghciwatch pane — ghciwatch
# starts hooks in the pane it itself runs in. Empty outside tmux, so reporting is
# skipped.
TARGET=${COGHCID_TMUX_TARGET:-${TMUX_PANE:-}}

# ghcid.txt reads "All good (10 modules)" when the build is clean.
if [[ ! -f $GHCID ]] || grep -q 'All good' "$GHCID"; then
  exit 0
fi

# Take a lock: codex edits source -> reload -> this hook runs again, so without one
# every edit would spawn another codex. mkdir is atomic and portable — macOS ships no
# flock(1).
if ! mkdir "$WORK" 2>/dev/null; then
  owner=$(cat "$WORK/pid" 2>/dev/null || true)
  # `kill -0` first: it is the portable probe. BusyBox ps has no -p, so there it
  # reports a live pid as dead and every lock would read as stale. `ps -p` stays as
  # the backstop for a process we do not own, which `kill -0` cannot signal.
  if [[ -n $owner ]] && { kill -0 "$owner" 2>/dev/null || ps -p "$owner" >/dev/null 2>&1; }; then
    echo "coghcid: codex already running (pid $owner), skipping" >&2
    exit 0
  fi
  # Stale lock from a killed run. Steal it with `mv`, which only one process can win —
  # claiming it in place would let two hooks that both read the same dead pid fall through
  # together and start two codexes, and the loser's exit trap would then delete the winner's
  # lock, admitting a third. `async:` hooks are never serialised by ghciwatch, so the
  # overlap this guards against is real.
  mv -- "$WORK" "$WORK.stale.$$" 2>/dev/null || exit 0
  rm -rf -- "$WORK.stale.$$"
  mkdir "$WORK" 2>/dev/null || exit 0
fi
trap 'rm -rf -- "${WORK:?}"' EXIT
echo $$ >"$WORK/pid"

PROMPT="Fix GHC errors with minimal correct edits; read ghcid.txt until it outputs 'All good'. Choose the fix from 'Valid hole fits' first, then try other fixes as needed. CRITICAL DIRECTIVE: once two consecutive edit commands leave errors on the exact same line number, do not run any further tools or commands. End with exactly one line: 'FIXED: <one-line summary of what you changed>' on success, or 'STOPPED: <reason>' if you stopped early."

# --disable plugins/hooks drops the harness: ~10k of the ~23k input tokens, none of
# it useful for a compile error.
#
# Reasoning effort is deliberately left to config, which is `medium`. Pinning it to
# `low` cut turns 30->21 and tokens by 23%, but broke correctness: on the scenario
# whose bounds check had been deleted, codex then "restored" checkedInt64 *without*
# its range guards. That compiles, and nothing in the test suite covers it — only
# the byte-identical check caught it. Cheap reasoning is a false economy here.
FLAGS=(--disable plugins --disable hooks -m gpt-6-luna)

# Status goes on the status line, and nothing is typed into any pane: the
# ghciwatch pane is a TUI, so text arriving there is read as keystrokes and could
# act on the live build. This is display only.
report() { # $1 = lifetime in ms, $2 = message, $3 = overlay colour, $4 = "clear" to retire after $1
  [[ -n $TARGET ]] || return 0
  # Overlay: right-aligned and coloured; -C keeps the pane redrawing, and no -N so
  # keys still work (a key just clears it).
  tmux display-message -C -t "$TARGET" -d "$1" "#[align=right,fg=${3:-white}]$2" 2>/dev/null || true
  # Persistent copy in status-right, which a key press cannot dismiss.
  tmux set-option -w -t "$TARGET" @ghcid_status "$2" 2>/dev/null || true
  # Only the final report retires it: the "working" line is meant to be replaced by
  # the summary, so a timer armed for it would just clear that summary early.
  [[ -n ${4:-} ]] || return 0
  tmux run-shell -b -d "$(($1 / 1000))" -t "$TARGET" -C \
    "set-option -w -t $TARGET -u @ghcid_status" 2>/dev/null || true
}
# Show "working" the moment codex starts; the result below replaces it. This call arms
# no timer, so a run that dies leaves the line up until the next report.
report 30000 'coghcid: fixing the build error...'

# --ephemeral leaves no session file, so there is no thread to pin and no earlier
# conversation to re-read. The errors and the prompt ride in together on stdin,
# errors first; `-` is codex's "read the prompt from stdin".
#
# --json makes codex report the run as JSONL on stdout, so the final reply is read
# from the run's own output rather than guessed at afterwards. `|& tee` merges
# stderr into stdout and logs the whole stream to .coghcid.log, so a hard failure
# is in the log rather than lost. That merge is why the parse below reads with -R +
# fromjson?: given a mixed stream, plain jq aborts on the first stderr line and
# prints nothing at all, which would leave the raw JSONL as the status line.
rc=0
out=$(printf '%s\n\n%s\n' "$(<"$GHCID")" "$PROMPT" | codex exec "${FLAGS[@]}" --json --ephemeral -C "$PWD" -s workspace-write - |& tee "$LOG") || rc=$?

# Relay one line into the ghciwatch window, which would otherwise show nothing of
# the run. Prefer codex's own FIXED:/STOPPED: line (the prompt asks for one), then
# its last non-empty line, then the exit code. The `|| true`s below are
# load-bearing: under `set -e` with pipefail, a grep that matches nothing exits 1
# and would take the whole script with it.
final=$(jq -Rr 'fromjson? | select(.item.type == "agent_message") | .item.text' <<<"$out" 2>/dev/null | tail -1 || true)
[[ -n $final ]] || final=$out
summary=$(grep -aoE '^(FIXED|STOPPED):.*' <<<"$final" 2>/dev/null | tail -1 || true)
if [[ -z ${summary:-} ]]; then
  summary=$(grep -av '^[[:space:]]*$' <<<"$final" 2>/dev/null | tail -1 || true)
fi
# Cap the length for the status line: codex's last line is not guaranteed short.
# cut -c counts characters, so it cannot split a multi-byte one.
# Cap the whole status text, prefix included — capping the summary alone leaves the
# stored value 9 chars longer than the status line's budget.
summary=$(printf '%s' "coghcid: ${summary:-codex exited $rc}" | tr -d '\r' | tr '\n' ' ' | cut -c1-160)
report "${COGHCID_STATUS_MS:-60000}" "$summary" yellow clear

exit "$rc"
