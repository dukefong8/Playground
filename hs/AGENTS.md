# Haskell Project — Agent Guide

Workflow first (below); module structure, layering rules and recipes are at the bottom — read
`## Layering Rules` before adding a module, a route, or an asset.

## Hard Rules

- **DO NOT run `cabal`, `stack`** — the project uses `ghciwatch` (via `make dev`) for REPL-driven development. Dependencies are pre-installed through `make env` (which internally uses `cabal install`).
- **DO NOT send commands to the ghciwatch tmux pane** — `make dev` runs ghciwatch, not an interactive GHCi REPL. Commands typed there hit a dead shell. Use eval comments (`-- $>`) in source files instead; ghciwatch auto-evaluates them on reload.
- **Prefer Prelude first** — check `ghci -e ':browse Prelude'` and `ghci -e':hoogle <name>|<type>'` before adding any import from other modules. The project Prelude re-exports Relude, Optics, MonadThrow, MonadAsync, and Data.Strict.Wrapper. Only add an explicit import when Prelude genuinely lacks what you need.

## Build & Error Feedback

ghciwatch (via `make dev`) runs in the background and writes live errors to `ghcid.txt`. When nvim-mcp LSP is connected, use `mcp__nvim_buffer_diagnostics` for HLS diagnostics.

Always consult BOTH sources before concluding code is clean:

```bash
cat ghcid.txt          # check compile errors
# ghciwatch's pane: locate the ghciwatch process, then the pane on its tty. Keyed
# on the process rather than the pane's foreground command — that reads `make`,
# since ghciwatch is its child — and not on an index, which moves with the layout.
GHCW_PANE=$(tmux list-panes -a -F '#{pane_id} #{pane_tty}' | \
  awk -v t="$(ps -o tty= -p "$(pgrep -x ghciwatch | head -1)" 2>/dev/null | tr -d ' ')" \
    '$2 ~ t {print $1; exit}')
tmux capture-pane -t "$GHCW_PANE" -p -S -30   # check auto-run test output
```

GHC error codes → <https://errors.haskell.org/index.html>

## Eval Comments (ghciwatch auto-run)

`-- $> expr` comments in source files are auto-evaluated by ghciwatch on reload. Test results appear in the tmux pane buffer. To trigger tests:

```bash
touch src/Todo/Test.hs    # triggers auto-eval of the tasty suites
```

Then check the pane:

```bash
tmux capture-pane -t "$GHCW_PANE" -p -S -30 | grep -E "(OK|passed|failed|All)"
```

## Testing

Five suites, each with its own eval comment in `src/Todo/Test.hs`:

```haskell
-- $> tasty testDB              -- :49   persistence CRUD (1 case)
-- $> tasty testGeneratedTitles -- :95   insertableGeneratedTitles (1)
-- $> tasty testCheckedInt64    -- :105  Int64 range guards (3)
-- $> tasty testRoute           -- :125  ihp-router behaviour (9)
-- $> tasty testRouteServant    -- :129  the same 9 assertions, over /servant
```

`testRoute` and `testRouteServant` are one body of assertions parameterized by mount prefix
(`webBehaviorTests … "/app"` / `"/servant"`) and built through `appWithPool`, so the two stacks
are proven identical rather than assumed to be. The title generator is stubbed per suite with
`setGenerateTodoTitles` (`Todo.Generate` keeps its backend in a process-global `IORef`) — no test
ever calls Grace. Isolation is by truncation, not transactions, and ghciwatch re-runs the suites
on every reload: browser state does not survive one.

Browser smoke tests use chrome-devtools MCP — the app is at `/app/todos`, the servant twin at
`/servant/todos`:

```bash
# navigate, then drive the page and assert on the DOM from evaluate_script
mcp__plugin_chrome-devtools-mcp_chrome-devtools__navigate_page pageId: 1, type: "url", url: "http://localhost:8000/app/todos"
mcp__plugin_chrome-devtools-mcp_chrome-devtools__evaluate_script pageId: 1, function: "async () => { ... }"
```

## ihp-typed-sql tests (cabal exception)

The `DO NOT run cabal` rule above does NOT apply here. Run from this dir (`hs/`, whose `cabal.project` includes `ihp-typed-sql`):

```bash
cabal test ihp-typed-sql:spec --test-show-details=direct   # suite is named `spec`, not `tests`
```

- Requires `PGHOST`/`DATABASE_URL` in env (already set in this shell).
- Never run two suites concurrently against the same DB: `setupSchema` DDL on shared `typed_sql_test_*` tables races (dropped-table / dropped-type / FK errors). Serial runs are reproducible.
- Slow: ~119 examples, each ghci case takes ~10s (10+ min total). Run in background and poll:
```bash
rm -f /tmp/ihp-test.log /tmp/ihp-test.done
nohup bash -c 'cabal test ihp-typed-sql:spec --test-show-details=direct > /tmp/ihp-test.log 2>&1; echo $? > /tmp/ihp-test.done' >/dev/null 2>&1 &
tail -n 30 /tmp/ihp-test.log   # poll; done when /tmp/ihp-test.done exists
```
- Fast single-test path (hspec match, ~15s):
```bash
cabal test ihp-typed-sql:spec --test-show-details=direct --test-options='--match "/<test name substring>/"'
```

## Hole-Driven Development

Write type signatures first; use `_` for unknowns. Check typed-hole suggestions in `ghcid.txt` immediately on save. Fill holes incrementally.

## Module Structure

```
src/
  Main.hs           entry: brackets the pool + logger, serves Site.app on :8000
  Site.hs           root dispatcher: first path segment -> sub-app
  Site/Static.hs    the one embedded-asset app, mounted at /static
  Prelude.hs        project prelude; must keep this name
  Service/          infrastructure the features share
    Hasql.hs          pool + session runner (Pool, Session, runDb)
    Http.hs           RouteHandler, error mapping, body parsing — no HTML
    Logger.hs         colog actions (logInfo, logError, closeLogger)
  Htmx/             view plumbing
    Prelude.hs        the single view import surface, and the only module that renders
    QQ.hs             hsx, with the htmx v4 attribute allowlist
    Type.hs           parsed htmx header types (parse, don't validate)
  Home/             landing page + the shared 404
    Route.hs          homeRouteTrie, homeApp, notFoundResponse
    View.hs           index, page404
  Todo/             one feature, served by two transports
    Type.hs           domain types, view records, boundary helpers
    Db.hs             the SQL: one *Session per query
    Handler.hs        effects only — RouteHandler <view record>, shared verbatim
    View.hs           Html () producers only, parameterized over TodoLinks
    Static.hs         the feature's embedded asset (contributed, never routed)
    Route.hs          ihp-router trie at /app
    Servant.hs        servant record API at /servant
    Generate.hs       title-generator backend (process-global; stubbed in tests)
    Test.hs           the tasty suites, run by its -- $> comments
```

## Layering Rules

- **Views render nothing.** A `*View` module exports `Html ()` producers only — no `LBS.ByteString`,
  no `Lucid` import. `Htmx.Prelude` is the only renderer: `htmlResponse` (Status → Html → Response),
  `viewResponse`, and `htmlBody` for the one caller that cannot take a response (servant's
  `ServerError`). `renderBS` is deliberately not re-exported, so the coupling cannot leak back.
- **Handlers know no HTTP and no HTML.** `Todo.Handler` takes a `Pool` and returns a view record
  (`TodosView`, `TodoMutationView`, …) inside `RouteHandler`; the route modules decide status and
  body. Both stacks call the same nine functions unchanged — that is what keeps them identical.
- **Infrastructure lives in `Service/`.** `Service.*` never imports a feature or `Htmx.*`, and
  features never touch hasql-pool or colog directly.
- **Routing owns paths, methods and the shared 404.** The trie answers a method mismatch with
  `405` + `Allow` and falls through to `Home.Route.notFoundResponse`; a handler must not hand-roll
  either one.
- **Boundary parsing is one chain, applied identically in both stacks:** `checkedInt64` → `toTodoId`
  → `toRowId` → `unTodoId`, reached via `Todo.Route.routeTodoIdOr404` and `Todo.Servant.withTodoId`.
- **One of each shared thing, imported rather than respelled:** the 404 body
  (`Home.Route.notFoundResponse`, `Home.View.page404`), todo URLs (`Todo.View.todoLinks`), the
  swap constant (`listSwap`), asset URLs (`Site.Static.staticUrl`).
- **Assets are contributed, not routed.** A feature exports `assetEntries` + `assetSources`
  (`Todo.Static`); `Site.Static` embeds them once for the whole site. Never add a route for a file.
- **Two accepted exceptions — do not extend them.** `Todo.Type` imports `Service.Http` (the
  `GenerateTodoTitles` seam and `checkedInt64`), and the asset URL crosses namespaces:
  `Todo.View` → `Site.Static` → `Todo.Static`, key declared by the feature, URL built by the site.

## Recipes

- **A route** — a constructor on the route ADT, a line in the `[routes|…|]` block, a `dispatchTodo`
  clause, the twin in `Todo.Servant`, and a case in `webBehaviorTests` (which runs it against both
  prefixes).
- **A view** — an `Html ()` producer in `Todo/View.hs` taking `TodoLinks` first; serve it with
  `viewResponse` from the route.
- **A query** — a `…Session :: Session a` in `Todo/Db.hs` built with `typedSql`, called through
  `runDbOr500 pool …` so a failed session becomes a 500. Decoder order must equal SELECT order —
  `Todo/Type.hs` records why a mismatch fails at runtime, not at compile time.
- **An embedded asset** — a key constant, `assetSources`, and `assetEntries` in the feature's
  `Static.hs`, plus its names in the `Site.Static` splice lists; the URL comes from `staticUrl`.
- **A sub-app** — a `Foo/` namespace (Type, Db, Handler, View, Route), one branch in `Site.app`,
  and `staticUrl` for anything it ships.

## Why It Is Shaped This Way

- **Template Haskell's stage restriction decides where splices live.** A splice may reference
  imported names only, so assets are declared in feature modules and the single `mkSettings` splice
  sits in `Site.Static`. That is what retired the old `Todo.Asset`/`Todo.Filter` split and the
  inline literals it needed.
- **There is no per-package cabal file.** The package is `-isrc` plus `make env` (the one sanctioned
  `cabal install`) and `hie.yaml`'s direct cradle; `make exe` builds the binary.
- **`.ghci` sets `-fdefer-type-errors`.** A type error inside a TH splice therefore surfaces as a
  runtime splice exception rather than a compile error — read the exception, not just its location.
- **Sequence a move for the reload loop.** ghciwatch reloads on every save and `Makefile:22` hands a
  failing build to pi, so move as new module → repoint importers → delete the old file, and never
  leave the tree non-compiling between saves.
