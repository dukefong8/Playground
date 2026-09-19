---
name: clojure-bb
description: "Write idiomatic Babashka (bb) scripts, modules and bb.edn tasks. Covers task conventions (thin wrappers, report/strict pairs, offline gates, exit codes), babashka.fs, babashka.process, babashka.cli, babashka.http-client, REPL-loadable scripts, and hosting a browser scittle/ClojureScript REPL over sci.nrepl. Use whenever: writing or editing a bb script or module, adding or changing a bb.edn task, editing .clj files in a directory that has bb.edn or scripts/, automating a build/dev/release workflow with bb, or evaluating ClojureScript against a live browser page."
---

# Babashka (bb)

Babashka is a fast-starting Clojure interpreter for scripting, powered by SCI. It has the full Clojure macro system (`defmacro`, syntax-quote, gensyms, `binding`, `try/finally`) — identical to Clojure, no limitations. Where it differs from Clojure is in what is *available* (libraries, classes, some stdlib fns), and the REPL is the fastest way to find out: `(resolve 'foo)` or `(doc foo)` settles it in one call.

**What this skill is for.** The API surface is not the hard part — a REPL answers `(doc fs/glob)` instantly and the answer is always current. This skill is for the things a REPL cannot tell you: the conventions a project's bb code follows, the invariants that break silently, and the reasoning behind both. When you need an API signature, go to the REPL rather than looking for it here.

## Principles

- Pure functions at the core, side effects at the edges
- Define functions before use — no forward declares
- Never shadow built-in names (`count`, `name`, `filter`, `run!`, …)
- Prefer a babashka built-in namespace over shelling out, and don't reimplement what babashka already ships: `babashka.fs` over `rm`/`cp`/`find`, `babashka.http-client` over curl/wget, `babashka.http-server` over `python -m http.server`. The REPL and `bb` docs will tell you what exists; the principle is the part worth remembering.

## REPL gate

Before writing or planning Babashka code, get a live bb REPL. It is the difference between verifying and guessing, and it applies to planning and reviewing too — probing `fs/glob` semantics, a `diff` exit code, or JSON shapes while you plan is cheaper than discovering the answer in the implementer's third iteration.

Drive a bb nREPL with `bb repl --connect`, feeding code on **stdin** — a heredoc, so quoting never bites:

```bash
bb nrepl-server 7888 &          # or a project task: bb nrepl [port]

bb repl --connect 7888 <<'EOF'
(require '[babashka.fs :as fs] :reload)
(fs/glob "." "**.clj")
EOF
```

Each form evaluates in turn and prints its value. A file argument does not work — `bb repl --connect 7888 probe.clj` connects, prompts and evaluates nothing — and neither does `-e`, which is silently ignored. Stdin is the only reliable channel.

Worth having as a task in any project of size, so nobody has to remember the port:

```clojure
nrepl {:doc "Start a bb nREPL server: bb nrepl [port] (default 7888)"
       :task (shell "bb" "nrepl-server" (or (first *command-line-args*) "7888"))}
```

**Check what you actually connected to.** Make `(System/getProperty "user.dir")` your first form: connecting to a port someone else owns is easy, and the failure is silent — every probe then reports that project's directory and you draw conclusions about the wrong codebase. A project running a *browser* scittle nREPL (`sci.nrepl.browser-server`, see below) and a plain bb nREPL at once will have two ports, and picking the wrong one is how `js/…` and `fs/…` both end up unresolved.

One more trap: a server started **before** you changed `:paths` will not see the new module — the classpath is fixed at startup, and the symptom (`Unable to resolve symbol`) reads like a broken module rather than a stale server. Restart it.

If you genuinely cannot get a REPL, say so and keep going — but treat every API assumption as unverified, and prefer code whose correctness you can check by running the task end-to-end.

## Writing modules

A module a task calls has three obligations, and the first is what makes the other two
checkable:

1. **It must be REPL-loadable.** No top-level I/O, no top-level `System/exit`, no top-level
   `def` with side effects — all behaviour inside functions. A module you cannot
   `(require ... :reload)` cannot be explored, and a top-level side effect turns every
   reload into a repeated one.
2. **Side effects at the edges.** Gather (read the world) → transform (pure, iterate in the
   REPL) → act (destructive, takes a plan). The plan *is* the dry run.
3. **Destructive work is previewable.** A task that deletes or writes should be able to
   show its plan without acting on it.

A module that also runs as a standalone command keeps its REPL-loadability with the `*file*`
gate — babashka's `if __name__ == "__main__"`, via the `babashka.file` system property:

```clojure
(ns my-script
  (:require [babashka.fs :as fs]))

(defn main! [args] (println "Running with" args))

;; Fires only when run as a script, not when loaded via require
(when (= *file* (System/getProperty "babashka.file"))
  (main! *command-line-args*))
```

When exploring destructive code, point it at a temp tree — `fs/with-temp-dir` — rather than
at real data, and never evaluate `System/exit` in the REPL. Lifecycle wrappers (`with-*`)
compose; `System/exit` does not, so return the exit code out of the wrappers and exit once,
after cleanup.

## Running commands

| Need | Use |
|---|---|
| Run command, inherit I/O, fail on error | `(p/shell "cmd" "arg1" "arg2")` |
| Capture output for parsing | `(p/shell {:out :string} "cmd")` |
| Long-running background process | `(p/process ["cmd" "args"])` |
| Suppress the throw on a non-zero exit | `(p/shell {:continue true} "cmd")` |

`shell` inherits I/O and **throws on non-zero exit**; `process` captures to buffers, never throws, returns immediately.

Two things the table above does not tell you:

- **`:continue true` does not cover a missing executable.** It only handles a non-zero exit. A binary that isn't on `PATH` (or isn't executable) throws `java.io.IOException: Cannot run program …` regardless — the exact "blows up" a wrapper task is usually written to prevent. Guard with `fs/which` before shelling out, and catch anyway for the race.
- **`shell` does not take an argv vector.** `(p/shell opts ["cmd" "arg"])` stringifies the vector and dies with `Cannot run program "[cmd"`. Vector argv is a `process` habit; with `shell`, either use varargs or `(apply p/shell opts argv)`.

**Tokenization**: only the FIRST string argument to `shell` is tokenized.

```clojure
(p/shell "npm install" "-g" "nbb")     ;; correct: 3 args
(p/shell "npm install" "-g nbb")       ;; WRONG: "-g nbb" is one arg
```

**`$` macro**: `(-> (p/$ ls -la) :out slurp)`

**Deadlock warning**: with large inputs and `check`, use `:out :string`.

## CLI argument parsing

`babashka.cli` is the one namespace worth knowing the shape of before you touch it, because two of its behaviours bite:

- `parse-opts` **ignores bare positional args**; `parse-args` returns `{:opts {...} :args [...]}`.
- **Without `:restrict`, unknown flags are silently swallowed.** `--dyas 3` (a typo) parses as no option at all and the task runs on its defaults — looking like success. `cli/parse-opts args {:restrict true}` turns that into an error, and `{:restrict-args true}` rejects stray positionals too. For anything destructive or gating, restrict.

Auto-coercion is on by default (`"true"`→boolean, `"123"`→number), `:coerce []` collects repeated flags, and `(cli/format-opts {:spec spec})` renders help. For the spec shape itself and the one-definition pattern that feeds parsing, help and completions, see [One CLI spec per module](#one-cli-spec-per-module).

## bb.edn tasks

Tasks are the project's CLI. Treat the task file as a designed interface, not a scratchpad: someone should be able to run `bb tasks`, read the list, and find what they need without opening the file.

### bb.edn is read as EDN, not Clojure

Task bodies are data until babashka evaluates them, and the EDN reader is stricter than the Clojure reader. Verified on bb v1.13.223 — each of these fails while *loading* bb.edn, so the whole file is dead, not just one task:

| You want | Don't write | Write |
|---|---|---|
| a regex | `#"..."` → *Invalid regex literal found in EDN config, use re-pattern instead* | `(re-pattern "...")` |
| a deref | `@a` → *Invalid leading character: @* | `(deref a)` |
| an anonymous fn | `#(...)` → *No dispatch macro for: (* | `(fn [x] ...)` |

The same applies to `:init` bodies. The error messages name the fix, so this costs one iteration rather than a hunt — but it's cheaper to write it right.

### Namespaces must arrive before analysis

A task body is analyzed as a whole before any of it evaluates, so a `require` **inside** the body is too late — the alias is unresolved at analysis time:

```clojure
;; Fails: "Unable to resolve symbol: fs/exists? ... :phase analysis"
{:task (do (require '[babashka.fs :as fs]) (println (fs/exists? ".")))}
```

Bring namespaces in where they are visible *before* the body is compiled. `:requires` is the lighter form when you only need aliases; `:init` is for that plus `def`/`defn`:

```clojure
{:tasks
 {:requires ([babashka.fs :as fs])

  build {:doc "Now the alias resolves" :task (println (fs/exists? "."))}}}
```

This is also why a helper defined in `:init` is callable from every task, and why a module required only *inside* a task body fails at load rather than at the call.

### How tasks are listed

`bb tasks` prints tasks **in bb.edn order**, not alphabetically, and aligns the doc column to the widest task name. Two consequences worth designing around:

- The `:doc` string's only surface is this listing — there is no `bb <task> --help`. Write it for a stranger, and include argument syntax: `"Demo reel: every example N seconds each (default 15): bb run-all [secs]"`.
- Because the list is flat and ordered, **grouping has to be written down**. In a task file of any size, the opening comment is the primary map of the surface — grouped by area, and kept in the same order as the tasks below it so the two can be diffed by eye. An `info` task that prints the same map is a good companion.

`:init` does not run for `bb tasks`, so listing stays fast and dependency-free.

### Thin wrapper, module holds logic

```
bb.edn                          scripts/*.clj
  :paths ["scripts"]              (ns my-module (:require ...))
  :init (require '[my-module])    (defn start! [opts] ...)
  my-task                         pure helpers first,
    {:doc "..."                   side effects at the edge
     :task (my-module/start! ...)}
```

The `:task` body should read as a wiring diagram. If you can't tell what a task does from its one-line body, the logic belongs in a module. Signals it's time to delegate: validation, branching, error handling, anything two tasks share, anything you would want to unit-test, anything past about three lines.

Put the module in the project's **existing** source root. `scripts/` is the convention in the example above, but a project already using `src/` should get `src/my_module.clj` and no change to `:paths` — adding a second root beside `src/` splits the codebase for no reason.

```clojure
;; scripts/my_module.clj — validation is pure, so it is testable in the REPL
(defn- validate-args [opts]
  (let [errors (cond-> []
                 (not (:port opts)) (conj "Missing --port")
                 (not (fs/exists? (:dir opts "."))) (conj "Directory not found"))]
    {:valid? (empty? errors) :errors errors :config (merge {:port 8080} opts)}))

(defn start! [opts]
  (let [{:keys [valid? errors config]} (validate-args opts)]
    (if valid?
      (p/shell "my-server" "--port" (str (:port config)))
      (do (doseq [e errors] (binding [*out* *err*] (println "Error:" e)))
          (System/exit 1)))))
```

### `:init` for shared helpers

```clojure
{:paths ["scripts"]
 :tasks
 {:init (do
          (require '[babashka.fs :as fs]
                   '[clojure.string :as str]
                   '[examples-registry :as reg])
          (def kondo-dep "{:deps {clj-kondo/clj-kondo {:mvn/version \"2025.02.20\"}}}")
          (defn kondo-argv []
            (if (fs/which "clj-kondo")
              ["clj-kondo"]
              ["clojure" "-Sdeps" kondo-dep "-M" "-m" "clj-kondo.main"])))

  ;; ...the tasks themselves, each now a one-liner over kondo-argv
  lint {:doc "clj-kondo over src (report only)" :task (run-kondo (kondo-argv) false)}}}
```

`:init` runs in a fresh process before every task invocation — but not for `bb tasks`. That makes it the right home for loading modules, resolving external commands, and defining helpers shared across tasks.

**`bb tasks` succeeding proves nothing about whether your modules load.** It lists without evaluating `:init` or `:requires`, so a task file can look healthy while the first real invocation dies on a missing namespace. Run the task.

Keep it cheap and quiet. It must not print: anything on stdout lands in the output of every task, including tasks whose output another program parses.

**Don't `:init`-require what a gate audits.** If `:init` loads the namespaces a checker inspects, then deleting one of them makes bb.edn itself unloadable — no task runs at all, so the gate cannot report the very drift it exists to catch. That is the same "a check cannot guard what it never loaded" failure as above, one level up. `:init` may require the *checker* and the *registry*; the audited artifacts must be read as data from disk. A gate that reads files as text survives a file going missing; a gate that requires them does not.

`{:tasks {:requires ([babashka.cli :as cli]) …}}` is the lighter-weight built-in for plain namespace accessibility; reach for `:init` when you also need `def`/`defn`. Placement is load-bearing — `:requires` goes at the **top of the `:tasks` map**, not at bb.edn's top level, and `:paths` alone is not enough: it puts a module on the classpath without loading it, so a task body calling `my-module/fn` still fails with `Unable to resolve symbol`.

### Naming and grouping

- **`group:action`** — the colon reads as a namespace (`lsp:format`, `lib:check`, `hooks:install`) and keeps related tasks adjacent when the file is laid out in groups.
- **`-private-task`** — a leading dash hides it from `bb tasks` while leaving it runnable. Use it for helpers other tasks `run` or `depends` on.
- **`:override-builtin true`** — required when you deliberately shadow a built-in task name such as `run`, `test` or `help`.

### Report-only and strict: the pair pattern

The most common shape in a mature task file is one check under two policies:

```clojure
lint        {:doc "clj-kondo over src (report only, always exits 0); strict: bb lint:strict"
             :task (run-kondo false)}
lint:strict {:doc "bb lint, but exit non-zero if clj-kondo reports findings"
             :task (run-kondo true)}
```

The reason for two is a mismatch of audiences. A developer mid-edit wants the findings, not a wall of red and a non-zero exit that breaks the `&&` chain they're working in; a hook or CI job wants nothing *but* the exit code. So the default is friendly and always exits 0, and the `:strict` twin is what gates call.

There are two distinct pairings, and they are named differently:

| pair | what differs | naming |
|---|---|---|
| mutation vs dry run | one writes, the other doesn't | `lsp:format` / `lsp:format-check` |
| report-only vs gating | both read; only one fails | `lint` / `lint:strict` |

In both cases the second name must keep the first as its stem, so the relationship is visible in the `bb tasks` listing.

**Name the twin in the `:doc`.** This is the most-skipped part of the pattern, and it is the part that decides whether anyone discovers the twin exists — `bb tasks` is the only surface a reader has, and nothing else will tell them. Write it literally:

```clojure
lint {:doc "clj-kondo over src (report only, always exits 0); CI gates with: bb lint:strict"
      :task (run-kondo false)}
```

Say the exit code out loud, too. "Report only, always exits 0" is a promise the task has to keep in *every* branch, including the tool-missing one — tasks that claimed it while exiting 3 when the linter was absent cost a reviewer a real investigation.

### Exit codes

The exit code is the contract that makes tasks composable in hooks, CI and `&&` chains. Four rules:

- **A task's return value is discarded.** `{:task 3}` exits 0. If a task is supposed to carry a code, it has to say so: `(System/exit code)`, or `throw (ex-info "…" {:babashka/exit code})`.
- **Propagate the real code** — `(System/exit (:exit res))`, not a hand-rolled `{:clean 0 :findings 1}` table. clj-kondo distinguishes warnings (2) from errors (3), and flattening both to 1 throws away the only thing a CI script can key on.
- `(p/shell {:continue true} ...)` **before** inspecting `:exit`; without `:continue`, `shell` throws on non-zero and you never see the code.
- Never `System/exit` inside a cleanup wrapper — return the code and exit after cleanup.

### Arguments: parse or forward, not both

```clojure
;; You own the CLI: parse with a spec
my-task {:task (my/start! (cli/parse-opts *command-line-args*
                                         {:coerce {:port :int} :alias {:p :port}}))}

;; The wrapped tool owns the CLI: forward verbatim
record {:task (let [{:keys [exit]} (apply shell {:continue true}
                                           "screen-grab" "record"
                                           "--manifest" "scripts/demo_manifest.edn"
                                           *command-line-args*)]
                 (System/exit exit))}
```

Forwarding beats re-declaring a tool's flags: the wrapped tool's own `--help` stays true and you stop maintaining a parallel copy of its option list. Pass configuration to a subprocess through the environment rather than argv when it is an implementation detail: `(shell {:extra-env {"RAYLIB_APP_AUTO_QUIT_MS" ms}} ...)`.

Three details decide whether forwarding actually works:

- **Order matters: operands first, forwarded args last.** Greedy flags swallow everything after them, so `tool --disable A B file.md` feeds `file.md` to `--disable` — and can print usage and *exit 0*, a green run that linted nothing. Build the argv as `(concat cmd files args)`.
- **`--` arrives literally.** `bb my-task --fix -- file.md` hands the task `("--fix" "--" "file.md")`. If you forward `*command-line-args*` verbatim, drop a leading `--` rather than passing it to the tool.
- **Prove the passthrough against a known-bad input.** Flags that reach the tool only when the tool actually runs are the ones that matter; a wrapper verified with `--help` alone may still swallow its operands.

### One CLI spec per module

When you own the CLI, define the spec **in the module** and let bb.edn reference it:

```clojure
;; scripts/my_module.clj — the flat per-option style
(def cli-spec
  {:download {:coerce :string :desc "Download a ref"}
   :use      {:coerce :string :desc "Switch to a ref"}
   :status   {:coerce :boolean :alias :s}})

(defn exec! [opts] ...)

;; bb.edn — one line, and the spec stays where the behaviour is
my-task {:doc "Manage versions [--download <ref> | --use <ref> | --status]"
         :task (my-module/exec! (cli/parse-opts *command-line-args* {:spec my-module/cli-spec}))}
```

One definition then drives argument parsing, `cli/format-opts` help text, and shell completions — instead of three copies that drift. Keep the `:doc` argument summary in sync with the spec.

Use the **flat per-option** style, not the `{:coerce {…} :alias {…}}` form. Both work with `parse-opts`, but `format-opts` only generates help from the flat style — passed a coerce-map spec it prints nothing, quietly breaking the one-definition promise above.

### Results an agent can read

When a task produces a report, a diff or a large result, also write it to a file under `.tmp/` and say so in the `:doc` and in stdout. A human reads the summary in the terminal; an agent reads the file without re-running the task or parsing the human-readable form. The convention is what makes a task usable from both sides.

### Resolving external commands

```clojure
(def jolt-cmd (if (fs/which "jolt") "jolt" "joltc"))

(defn kondo-argv []
  (if (fs/which "clj-kondo")
    ["clj-kondo"]
    ["clojure" "-Sdeps" kondo-dep "-M" "-m" "clj-kondo.main"]))
```

Two failures this prevents. Tools get renamed, and a machine that has used the tool since before the rename keeps a stale shim — so hardcoding the old spelling looks fine locally and dies on a fresh install. And not every contributor has the fast native binary; a self-contained fallback keeps the task runnable on a bare checkout. `clojure -Sdeps … -M -m clj-kondo.main` above is the good kind: a pinned version, resolved from the local Maven cache, offline.

**Not every fallback is the good kind.** A chain ending in `npx --yes something` resolves a version from the network at task-run time. As a *gate* that is a bad trade: the verdict drifts with whatever the registry serves, an offline runner degrades badly, and the "not installed" branch you carefully wrote never fires because `npx` exists on most machines. Prefer refusing with install instructions over silently fetching; if you do fetch, say so in the `:doc`.

When neither route exists, refuse with the reason and the fix rather than a stack trace:

```clojure
(when-not (fs/which "screen-grab")
  (binding [*out* *err*]
    (println "bb record needs the `screen-grab` capture CLI on your PATH.")
    (println "You don't need it to view the demos: every GIF is committed under docs/demos/."))
  (System/exit 1))
```

### Offline gates for registration drift

The highest-value and most-often-missing pattern. Every project has facts that must agree across N places and that no compiler checks: a new example needs a source namespace, a `deps.edn` alias, a require in the compile-check list, and a task. Add one and forget the require, and `bb check` still prints *all namespaces compiled OK* and exits 0 — because the compile gate can only compile what its own require list names. **A check cannot guard the thing it never loaded.**

So write a separate gate that reads the registration points as data and compares them. It needs nothing but bb and the files, so it runs on a bare checkout and in CI:

```clojure
check:registration
{:doc "Source, deps.edn alias, check require and bb.edn task all agree"
 :task (let [probs (regi/problems root reg/examples)]
         (if (seq probs)
           (do (binding [*out* *err*]
                 (doseq [[n what] probs] (println (str "  " n ": " what))))
               (System/exit 1))
           (println (str "registration ok, " (count reg/examples) " examples"))))}
```

Rules that make gates survive contact:

- **Derive every expected value** from a source of truth or from the files themselves, never from a literal. A gate holding a hardcoded `171` becomes a second thing to update, and then a thing to distrust.
- **Put the mapping in one place.** In the raylib-jlt suite, `deps.edn` is the source of truth for which namespace a row means — the alias is not the display name and the namespace is derivable from neither — so everything else is checked *against* it rather than against string surgery.
- **Check the binding, not just the membership.** Membership is the easy half. A task listed as `gamma` whose body actually calls `beta/run!` passes every presence check while being exactly the bug you set out to catch — a thing that silently never runs. Compare what each entry *points at*.
- **A hand-maintained exemption list is a regression.** If the gate needs `:ignore #{"init" "requires" "check" …}` to stop reporting false positives, it has reintroduced the same class of forgetting it was built to catch. Tighten what counts as an entry instead of listing what doesn't.
- **`.gitignore` whatever the gate writes.** A checker that leaves a cache or report in the tree makes people distrust it. Same change, same commit.

Prose that states a count is a gate waiting to be written: a doc once claimed "All 151 recordings are here" while the suite had grown to 171. If a number matters, derive it or gate it.

### Give the tool a project-local config dir

A gate is only worth having if the developer and CI see the same verdict. Tools that resolve config or cache by walking up from the working directory break that: an ancestor project's `.clj-kondo` (or any tool's equivalent) silently changes the analysis, so the same bytes lint differently in two checkouts — four phantom `Unresolved var` warnings on one machine and none on another is how a gate earns a reputation for lying.

The idiomatic fix is to give the project its own config dir. For clj-kondo that also imports library-exported configs — hooks and `:lint-as` from your dependencies — which you want anyway:

```bash
mkdir -p .clj-kondo                     # required; the import refuses without it
CP=$(clojure -Spath)
clj-kondo --copy-configs --dependencies --lint "$CP"
# Configs copied:
# - .clj-kondo/imports/rewrite-clj/rewrite-clj
```

`--skip-lint` copies without the linting pass when you only want the import. Once `.clj-kondo/` exists in the project, its cache lives at `.clj-kondo/.cache` and the upward search stops there — the shadowing problem and the missing config both go away, with no `--cache-dir` flag to remember. Prefer this over the `--cache-dir` workaround; if you do pin a cache dir, create it first, because clj-kondo throws on a `--cache-dir` that does not exist.

### Git hooks

```clojure
hooks:install
{:doc "Install FAST pre-commit hook (lint + format dry-run, ~2s)"
 :task (let [hook ".git/hooks/pre-commit"]
         (spit hook (str "#!/bin/bash\n" ...))
         (shell "chmod" "+x" hook)
         (println "✓ pre-commit hook installed")
         (println ">> skip once with: git commit --no-verify"))}
```

Offering a fast variant and a `hooks:install:full` respects the developer's time budget, which is the only reason a hook survives. Print the `--no-verify` escape hatch so nobody learns to fear it, and ship an `hooks:uninstall`.

Long-running and server tasks (`bb nrepl`) block forever on purpose — say so in the `:doc`, because the reader's only warning is that line.

### Changing what an existing task does

Renaming or re-pointing a task is a breaking change to the project's CLI. A git hook, a script or someone's fingers already call it, and if the old name now does nothing, it does *nothing silently* — the worst outcome, and the same failure mode as a gate that passes on a broken tree.

So when a destructive task becomes safe-by-default (a good instinct), the old spelling must still fail loudly: keep `prune` erroring with "use `prune:dry-run`, deletion moved to `prune:apply`", rather than letting it quietly stop deleting. Additive is fine; a silent no-op is not.

### Output vocabulary

Pick a small set of markers and reuse them: `▶` for what is starting, `✓`/`✗` for outcomes, `·` for something checked and absent. Send diagnostics to stderr with `(binding [*out* *err*] ...)` so a task's stdout stays parseable — a human reading a terminal and a program reading a pipe want different things from the same run.

### Comments carry the why

The comment worth writing says what the code cannot: that `jolt` replaced `joltc` in 0.5.0 and the fallback exists because CI failed with *Cannot run program "joltc"*; that only one formatter may own formatting because cljfmt and clojure-lsp disagree on compact literal tables; that a gate exists because a check passed on a broken tree. Include the date when you measured something, and the symptom you saw. This is what separates a task file a colleague can safely change from one they can only cargo-cult.

## Script dependencies

For a script that needs libraries, use a **script-adjacent** `bb.edn` (bb 1.3.177+):

```clojure
;; ~/bin/my-script.clj  ← the script
;; ~/bin/bb.edn         ← picked up automatically, from any cwd
{:deps {medley/medley {:mvn/version "1.3.0"}}}
```

## Browser scittle REPL (sci.nrepl)

Babashka can host a REPL for ClojureScript running *in a browser page* — the right tool when the code you're working on **is** the page (its DOM, its state, the functions it has loaded):

```bash
bb -Sdeps '{:deps {io.github.babashka/sci.nrepl {:mvn/version "0.0.2"}}}' \
   -e "(require '[sci.nrepl.browser-server :as b]) (b/start! {:nrepl-port 3339 :websocket-port 3340}) @(promise)"
```

Then `bb repl --connect 3339` puts you in the page's SCI env; the page needs a port var plus `scittle.nrepl.js` loaded after `scittle.js`.

Pass the port explicitly. The browser env and the project's own bb nREPL are different targets, and `js/…` only resolves in the former. Same stdin discipline as above; note that `-f` sends `load-file`, which browser SCI cannot resolve.

See [references/scittle-nrepl.md](references/scittle-nrepl.md) for the page snippet, the file-serving pattern that lets an editor buffer and the page share one source, and the SCI interop gotchas.

## Common mistakes

| Mistake | Correction |
|---|---|
| Shelling out for file ops (`rm`, `cp`, `find`) | Use `babashka.fs` |
| `curl`/`wget` for HTTP | `babashka.http-client` |
| `python -m http.server` | `babashka.http-server` |
| `#"regex"`, `@deref` or `#(...)` in bb.edn | `re-pattern`, `deref`, `(fn [x] …)` — EDN reader |
| Logic inside a `:task` body | Delegate to a `scripts/*.clj` module |
| Task with no `:doc` | Always add one — `bb tasks` is the only surface |
| Printing from `:init` | It runs before every task; keep it silent |
| Missing `:continue true` before checking `:exit` | Without it, `shell` throws on non-zero |
| Trusting `:continue true` for a missing binary | It only covers non-zero exit; `fs/which` first |
| `(shell opts ["cmd" "arg"])` | `shell` stringifies the vector; use varargs or `apply` |
| Expecting a task's return value to set the exit code | `{:task 3}` exits 0; call `System/exit` |
| Hand-rolling exit codes (`{:findings 1}`) | Propagate the tool's real code |
| Forwarding args before the operands | Greedy flags swallow paths, can exit 0 |
| Passing a leading `--` through to the tool | It arrives literally; strip it |
| `(shell "cmd -flag value")` for multi-arg | `(shell "cmd" "-flag" "value")` |
| A `require` inside a task body | Too late — put it in `:init`/`:requires` |
| `:requires` at bb.edn top level | It goes at the top of the `:tasks` map |
| Relying on `:paths` to load a module | It only adds it to the classpath |
| `:init`-requiring what a gate audits | The gate dies when the artifact goes missing |
| A gate that checks membership but not the target | Catches "never registered" but not "points elsewhere" |
| A gate needing a hand-maintained `:ignore` list | Tighten what counts as an entry instead |
| Forward declaring functions | Define before use — rearrange the file |
| `System/exit` inside a `with-*` wrapper | Return the code, exit after cleanup |
| Top-level side effects in a module | Wrap in functions; use the `*file*` gate |
| A gate holding a hardcoded count | Derive it from the source of truth |
| A fallback that fetches from the network at run time | A gate's verdict then depends on the registry |
| Assuming `**` and `*` are the same in globs | `**` is recursive, `*` is one level |
| `**/*.ext` expecting root-level matches | `**/*.ext` skips root; use `**.ext` |
| Expecting `fs/glob` to see dotfiles | It skips them by default; `{:hidden true}`, and `fs/list-dir` disagrees |

## Source material

- **Babashka Book**: https://book.babashka.org/ · **Tasks**: https://book.babashka.org/#tasks
- **babashka.fs**: [README](https://github.com/babashka/fs/blob/master/README.md) · [API](https://github.com/babashka/fs/blob/master/API.md)
- **babashka.process**: [README](https://github.com/babashka/process) · [API](https://github.com/babashka/process/blob/master/API.md)
- **babashka.cli**: [README](https://github.com/babashka/cli) · [API](https://github.com/babashka/cli/blob/main/API.md)
- **babashka.http-client**: [README](https://github.com/babashka/http-client) · [API](https://github.com/babashka/http-client/blob/main/API.md)
- **Pods**: [docs](https://github.com/babashka/pods) · [registry](https://github.com/babashka/pod-registry)
- **Examples**: [README](https://github.com/babashka/babashka/blob/master/examples/README.md)
