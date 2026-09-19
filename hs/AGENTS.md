# Haskell Project — Agent Guide

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
touch src/App/TodoTest.hs    # triggers auto-eval of tasty testRoute / tasty testDB
```

Then check the pane:

```bash
tmux capture-pane -t "$GHCW_PANE" -p -S -30 | grep -E "(OK|passed|failed|All)"
```

## Testing

```haskell
-- $> tasty testRoute    -- 8 route tests (5 existing + 3 generation tests)
-- $> tasty testDB       -- 1 DB CRUD test
```

Route tests use `appWithTodoGenerator` to inject a stub `GenerateTodoTitles` without calling Grace:

```haskell
appWithTodoGenerator (const (pure (Right ["Buy milk", "Write plan", "Pack lunch"]))) pool
```

Browser smoke tests use chrome-devtools:

```bash
# Navigate, fill input, click .lucky-todo, wait for LLM response
mcp__chrome_devtools_navigate_page url: "http://localhost:8000/todos"
mcp__chrome_devtools_evaluate_script function: "async () => { ... }"
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
