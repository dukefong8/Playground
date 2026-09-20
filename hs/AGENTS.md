# Haskell Project — Agent Guide

Workflow first (below); module structure, layering rules and recipes are at the bottom — read
`## Layering Rules` before adding a module, a route, or an asset.

Design language: **module / interface / seam / adapter / depth → leverage + locality**
(see `.agents/skills/codebase-design/SKILL.md`). Directory names like `Service/` stay;
the prose below names their roles: `Service.Hasql` is a **module**, `Pool/Session/runDb`
is its **interface**, `Todo.Route` + `Todo.Servant` are two **adapters** at one **seam**.

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

`-- $> expr` comments in source files are auto-evaluated by ghciwatch on reload — but only for the
modules `:add`ed in `.ghci` (`Main`, plus `Todo.Test` while its `:add` line is uncommented there;
without it the tasty suites never run). Results appear in the pane:

```bash
touch src/Todo/Test.hs    # re-runs its suites, once Todo.Test is added
```

Then check the pane:

```bash
tmux capture-pane -t "$GHCW_PANE" -p -S -30 | grep -E "(OK|passed|failed|All)"
```

## Testing

Four suites, each with its own eval comment in `src/Todo/Test.hs`:

```haskell
-- $> tasty testDB              -- persistence CRUD (1 case)
-- $> tasty testGeneratedTitles -- insertableGeneratedTitles (1)
-- $> tasty testRoute           -- ihp-router behaviour (7)
-- $> tasty testRouteServant    -- the same 7 assertions, over /servant
```

(Their line numbers move with every edit above them — `grep -n '-- \$>' src/Todo/Test.hs` for where they are now.)

`testRoute` and `testRouteServant` are one body of assertions parameterized by mount prefix
(`webBehaviorTests … "/app"` / `"/servant"`), each stack built directly (`appWithStatic ihpApp`,
`appWithStatic servantApp`) so the feature is tested without the site. The one site-owned prefix the
page needs, `/static`, comes from a wai-app-static filesystem mock over `static/` (`mockStatic`).
Assertions are on status and body — headers are deliberately not asserted. The generator's runner is stubbed per suite with
`Service.Grace.setRunner` (one process-global runner lives there) — no test ever calls Grace. Isolation is by truncation, not transactions, and ghciwatch re-runs the suites
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

A feature is one vertical slice of one spec — `Todo/` is the TodoMVC spec — so its model, view,
controller and tests all live in its own subdir, and the slice names below are the vocabulary the
rules use.

```
src/
  Main.hs           entry: brackets the pool + logger, serves Site.app on :8000
  Site.hs           composes the features: every controller entry point, and the one
                    embedded-asset app, behind the /static, /app and /servant mounts
  Prelude.hs        project prelude; must keep this name
  Service/          shared modules — any feature may import these
    Grace.hs          the LLM-runner module: one runner per process, stubbed in tests
    Hasql.hs          the persistence module; its interface is (Pool, Session, runDb)
    Http.hs           RouteHandler, error mapping, body parsing — no HTML
    Logger.hs         colog actions (logInfo, logError, closeLogger)
  Htmx/             shared view modules — any view may import these
    Prelude.hs        the deep view module: the single import surface, and the only renderer
    QQ.hs             hsx, with the htmx v4 attribute allowlist
    Type.hs           parsed htmx header types (parse, don't validate)
  Home/             the landing page and the shared 404; a shared module other features import
    Route.hs          Controller — homeRouteTrie, homeApp, notFoundResponse
    View.hs           View — index, page404
  Todo/             one feature, served by two controller mounts
    Type.hs           Model — domain types, the view records, identity + title helpers
    Db.hs             Model — the SQL: one *Session per query
    View.hs           View — Html () producers only, parameterized over TodoLinks
    Static.hs         View — the feature's embedded asset (contributed, never routed)
    Handler.hs        Controller — effects plus form parsing: RouteHandler <view record>;
                      owns AddTodoRequest/GenerateTodosRequest/UpdateTodoRequest
    Generate.hs       Controller — the todo-title prompt, run through Service.Grace
    Route.hs          Controller — ihp-router trie at /app, serving the HTML
    Servant.hs        Controller — servant record adapter at /servant
    Test.hs           Test — the tasty suites, run by its -- $> comments
```

## Layering Rules

Dependencies point one way: Model and View at the bottom, Controller above them, `Site` on top.
They constrain *module imports*, not values: a link that spells another subdir's URL is coupling by
value — allowed, and worth a test — while importing that subdir's module is not.

Allowed directions (importer → imported):

```
Controller → Model, View, Service.*, Htmx.*, Home.*   (Handler → Db, Type; Route/Servant → Handler, View, Type)
View       → Model (own subdir), Htmx.*, Static (own feature)
Model      → Service.Hasql, Type (own subdir)          (Db → Type; nothing in Model touches Handler/View)
Service.*  → Service.* only
Site       → Home.Route, */Route, */Servant, */Static
Test       → own subdir, Service.*
```

Forbidden: Model/View → Controller; any feature → another feature; anything → `Site`
(except `Main`); `Service.*` → feature or `Htmx.*`.

- **Model and View never import Controller.** `Type.hs`, `Db.hs`, `View.hs` and `Static.hs` must
  still build with `Handler.hs`, `Route.hs` and `Servant.hs` deleted. Controllers read the model
  and render the views; never the reverse.
- **A feature imports its own subdir, `Service.*`, and the utility modules (`Htmx`, `Home`) — and
  nothing else.** No `Todo.* → Foo.*`: another feature's model, view or handler is off limits. The
  way to share something is to make it a `Service` (infrastructure) or a utility module, not to
  reach across subdirs.
- **`Site` is the only composer.** It imports the features to mount them — every controller entry
  point (`*/Route`, `*/Servant`), plus their embedded assets — and nothing else does. A view must
  not import `Site` (that inverts the seam and closes a cycle), which is why an asset's URL is derived
  in its own feature (`Todo.Static.todoFilterUrl`).
- **A feature's `Test.hs` builds its own stack, not the site** — `appWithPool ihpApp` for `/app`,
  `appWithStatic servantApp` for `/servant` — so the slice is tested in isolation, with a
  filesystem mock standing in for the site's `/static`. What is left to the composer (the home
  page, `/404`, a method mismatch on `/`) has no test module yet.
- **Views render nothing.** A `View` module exports `Html ()` producers only — no `LBS.ByteString`,
  no `Lucid` import. `Htmx.Prelude` is the only renderer, through `htmlResponse` (Status → Html →
  Response) and `viewResponse`; nothing else turns a view into bytes, and no byte-level renderer is
  exported at all. The view records controllers hand back are Model's (`Todo/Type.hs`).
- **Handlers are controllers: they may decide status, never markup.** `Todo.Handler` takes a `Pool`
  and returns a view record (`TodosView`, `TodoMutationView`, …), or throws the `RouteError` it
  wants — `editTodoForm` answers `status404 "Todo not found"` for a row that is gone. Rendering is
  never its business, and both mounts call the same nine functions unchanged, which is what keeps
  them identical.
- **Infrastructure lives in `Service/`.** `Service.*` never imports a feature or `Htmx.*`, and a
  feature never reaches hasql-pool, colog or Grace directly — it goes through `Service.Hasql`,
  `Service.Logger`, `Service.Grace`. What is asked of a module stays with the caller: the prompt is
  `Todo.Generate`'s, the runner is the module's.
- **Routing owns the fallbacks.** The trie answers a method mismatch with `405` + `Allow` and an
  unmatched path with `Home.Route.notFoundResponse`; a handler must not hand-roll *those* — it may
  still answer an unknown row with its own status.
- **Name a capture after the field it feeds** — `{todoId}`, never `{id}`: the splice binds the
  capture name in the generated code, and `id` shadows Prelude's, which is four warnings in
  `ghcid.txt` for no gain.
- **One of each shared thing — import it where importing is legal:** the 404 body
  (`Home.Route.notFoundResponse`, `Home.View.page404`), todo URLs (`Todo.View.todoLinks`), the swap
  constant (`listSwap`), the asset mount (`/static`, in `Site`). Across a seam the import is the
  violation, so a literal is the right choice there: `Home.View` links to `/app/todos` by spelling
  it, and `Todo/Test.hs` pins that link.
- **Assets are contributed, not routed.** A feature exports `assetEntries` + `assetSources`
  (`Todo.Static`); `Site` embeds them once for the whole site. Never add a route for a file.

The whole graph is one `grep -rn '^import [A-Z]' src/` — every edge should match a rule above.

## Recipes

- **A route** — a constructor on the route ADT, a line in the `[routes|…|]` block, a `dispatchTodo`
  clause, the twin in `Todo.Servant`, and a case in `webBehaviorTests` (which runs it against both
  prefixes).
- **A view** — an `Html ()` producer in `Todo/View.hs` taking `TodoLinks` first; serve it with
  `viewResponse` from the route.
- **A query** — a `…Session :: Session a` in `Todo/Db.hs` built with `typedSql`, called through
  `runDbOr500 pool …` so a failed session becomes a 500. Decoder order must equal SELECT order —
  `Todo/Type.hs` records why a mismatch fails at runtime, not at compile time.
- **An embedded asset** — a key constant, its URL, `assetSources` and `assetEntries` in the
  feature's `Static.hs`, plus its names in the `Site` splice lists.
- **A feature** — a `Foo/` subdir with its four slices: Model (`Type.hs`, `Db.hs`), View (`View.hs`,
  and `Static.hs` if it ships assets), Controller (`Handler.hs` plus `Route.hs` and/or `Servant.hs`)
  and `Test.hs`. Then one branch per controller in `Site.app`, and the asset names in the `Site`
  splice lists if it has any.
