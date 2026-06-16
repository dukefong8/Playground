# Haskell Project — Agent Guide

## Hard Rules

- **DO NOT run `cabal`, `stack`** — the project uses `ghciwatch` (via `make dev`) for REPL-driven development, not cabal/stack builds. All dependencies are pre-installed through `make env` (which internally uses `cabal install`).
- **Prefer Prelude first** — check `ghci -e ':browse Prelude'` and `ghci -e':hoogle <name>|<type>'` before adding any import from other modules. The project Prelude re-exports Relude, Optics, MonadThrow, MonadAsync, and Data.Strict.Wrapper — many common symbols are already in scope. Only add an explicit import when Prelude genuinely lacks what you need.

## Build & Error Feedback

ghciwatch (via `make`) runs in the background and writes live errors to `ghcid.txt`.
When nvim-mcp LSP is connected, use `mcp__nvim_buffer_diagnostics` to get HLS diagnostics.

Always consult BOTH sources before concluding code is clean:

```bash
cat ghcid.txt          # check compile errors / test failures
```

GHC error codes → <https://errors.haskell.org/index.html>

## Hole-Driven Development

Write type signatures first; use `_` for unknowns. Check typed-hole
suggestions in `ghcid.txt` immediately on save. Fill holes incrementally.

## REPL-Driven Development

1. Find the `ghci` pane in the tmux session
2. Send commands/snippets via tmux (e.g. `:browse! Prelude`)
3. Use eval comments to run expressions: `-- $> expr`

```bash
# Explore a module
ghci -e ':browse Prelude'
ghci -e ':browse Data.Map.Strict'

# Docs by name or type
ghci -e ':hoogle traverse'
ghci -e ':hoogle a -> Maybe b'
ghci -e ':hdoc traverse'
```

## Testing

```
-- In GHCi (or as eval comment):
tasty testRoute
tasty testDB
```
