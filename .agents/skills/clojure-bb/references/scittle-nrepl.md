# Browser scittle REPL (sci.nrepl)

Babashka can host a REPL for ClojureScript running *in a browser page*, so you
can evaluate against the live page — its DOM, its state, its loaded functions —
instead of guessing from the source or reloading to test a theory. One bb
process serves two ports: an nREPL for REPL clients (`bb repl --connect <port>`),
and a websocket that the page connects back on.

## Start the server

Nothing project-specific is needed — no bb.edn, no deps:

```bash
bb -Sdeps '{:deps {io.github.babashka/sci.nrepl {:mvn/version "0.0.2"}}}' \
   -e "(require '[sci.nrepl.browser-server :as browser])
        (browser/start! {:nrepl-port 3339 :websocket-port 3340})
        @(promise)"
```

- **`@(promise)` is load-bearing.** `start!` spawns the servers on their own
  threads and returns immediately, so without a blocker the bb process exits and
  the ports close. In a REPL or a long-lived task it isn't needed; in `bb -e` it is.
- `-Sdeps` merges as the *last* deps file, so run this from a directory whose
  `bb.edn` you don't mind merging, or from `$HOME`.
- For a project that already has the dep (`io.github.babashka/sci.nrepl`, on
  Clojars; scittle's own docs pin a git sha instead), just call
  `(browser/start! {...})` from a task or REPL that stays alive.
- A second server on the same ports fails to bind — use another pair (e.g.
  1339/1340) when something already holds 3339/3340.

## Point the page at it

In the page's `<head>`, *after* the scittle.js tag, and with a matching version:

```html
<script>var SCITTLE_NREPL_WEBSOCKET_PORT = 3340;</script>
<script src="https://cdn.jsdelivr.net/npm/scittle@0.8.33/dist/scittle.nrepl.js" type="application/javascript"></script>
```

The client reads the port global **when the script executes** and connects right
away — that's why the port var is its own tag above it. There's nothing to call
and no `DOMContentLoaded` wait.

- `SCITTLE_NREPL_WEBSOCKET_HOST` overrides the host; the default is
  `location.hostname`, which is right whenever the websocket server runs on the
  machine serving the page.
- The client hardcodes `ws://`, so an `https://` page blocks it as mixed content.

## Evaluate into the page

With a tab open on the page:

```bash
bb repl --connect 3339 <<'EOF'
(js/console.log "hi from the page")
EOF
```

The form runs in the page's SCI env, so it can read the DOM and call what the
page defined:

```clojure
{:title (.-title js/document)
 :items (.. js/document (querySelectorAll ".item") -length)
 :socket-open? (= 1 (.-readyState (.-ws_nrepl js/window)))}
```

- **A tab must be open.** The nREPL forwards into whichever page is connected;
  with none, forms have nowhere to go.
- Reloading the page is fine — the socket reconnects; the page just has to be
  the one you mean, and a stale tab keeps the old code.
- Pass the port explicitly when the directory has its own `.nrepl-port` (a
  different bb nREPL): `bb repl --connect 3339`. Without it the client
  auto-detects that file and lands on the wrong server, where `js/...` fails with
  `Unable to resolve symbol`.

## Load a whole file: heredoc or stdin, always

A REPL client's *file argument* does not reach the page, so pipe the code in
instead — one path that works with every client, and the way to re-evaluate an
edited file in the live page without restarting anything:

```bash
bb repl --connect 3339 < client.cljs
bb repl --connect 3339 <<'EOF'
(js/console.log "just a form")
EOF
```

The text streams to the nREPL, so the browser evaluates it as written: the file's
own `(ns ...)` runs first (the prompt switches to that namespace), then every form
in order, including whatever it ends with — a re-render, a `console.log`. That is
also a fast way to verify a file *is* live: load it, then read the page state back
out.

Measured against a scittle nREPL:

| Attempt | Result |
|---|---|
| `bb repl --connect 3339 client.cljs` | file argument ignored — connects, prompts, evaluates nothing |
| `bb repl --connect 3339 -f client.cljs` | `-f` read as a filename: `File does not exist: -f` |
| any client's `-f client.cljs` | it sends `(load-file "…")`, which the browser's SCI has no idea how to run: `Unable to resolve symbol: load-file` |
| `bb repl --connect 3339 -e '(…)'` | ignored — the REPL never evaluates it |

`bb repl --connect` takes the port alone (`3339` → `127.0.0.1:3339`), prints the
connection banner on stderr and a `user=> ` / `your-ns=> ` prompt interleaved into
stdout, so strip it when parsing.

## Develop a file, not an inline tag

An inline `<script type="application/x-scittle">` is fine for a spike, but you
can't edit it from an editor. Serve the source as a file and load it by URL, so
the buffer you edit and the code in the page are the same thing:

```html
<script src="/client.cljs" type="application/x-scittle"></script>
```

Start the file with its own `(ns client)`: the nREPL session then lands in that
namespace, and the REPL can call the file's functions by name.

Serve it with `babashka.http-server`, or from the app's own routes — send
`application/x-scittle`, and disable caching while iterating so a reload always
fetches the current file.

## Gotchas

| Symptom | Cause and fix |
|---|---|
| `Unable to resolve symbol: doseq` (or `map`, `filter`, `vec`, `println`) in a script that looks fine | scittle evaluates each `x-scittle` script in the ns the previous one left current, so an earlier script's `(:refer-clojure :exclude [...])` applies to yours. Start every x-scittle file with its own `(ns ...)`. |
| `(.classList el)` blows up with "Function.prototype.apply was called on [object DOMTokenList]" | In SCI, `.-prop` reads a property and `(.method obj ...)` calls a method. Write `(.-classList el)`. |
| `^:export` on a `defn` doesn't create a global | `^:export` is scittle's own API, not user code. Export with `(aset js/window "name" f)` and call it qualified. |
| `goog/typeOf`, `goog.object/*` unresolved | A browser SCI env has no Closure library — use plain interop (`js/Object.keys`, `(.-x obj)`). |
| Evals return nothing / hang | No page connected, or the tab is on a different host than the websocket server. |
