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
tmux capture-pane -t Work:1 -p -S -30   # check auto-run test output
```

GHC error codes → <https://errors.haskell.org/index.html>

## Eval Comments (ghciwatch auto-run)

`-- $> expr` comments in source files are auto-evaluated by ghciwatch on reload. Test results appear in the tmux pane buffer. To trigger tests:

```bash
touch src/App/TodoTest.hs    # triggers auto-eval of tasty testRoute / tasty testDB
```

Then check the pane:

```bash
tmux capture-pane -t Work:1 -p -S -30 | grep -E "(OK|passed|failed|All)"
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

## Hole-Driven Development

Write type signatures first; use `_` for unknowns. Check typed-hole suggestions in `ghcid.txt` immediately on save. Fill holes incrementally.
