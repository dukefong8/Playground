# Implementation Plan: hasql-th → ihp-typed-sql migration (hs/)

## Objective
Replace all raw `Hasql.TH` quasiquoters (`vectorStatement`, `maybeStatement`,
`resultlessStatement`) in `hs/src/App/Todo.hs` (+ test truncate in
`hs/src/App/TodoTest.hs`) with strict `typedSql` + `IHP.TypedSql.Hasql`
session runners. End state: no `Hasql.TH` import in `src/`, `hasql-th`
dropped from `make env`. `Todo` domain type, HTML/htmx rendering, routes,
and Grace generation logic are unchanged.

Decisions (approved in discussion):
- Scope: full sessions, stable `Pool` (`Database.hs` untouched — strangler pattern)
- Quasiquoter: strict `typedSql` (all queries already use explicit columns)
- Compile-time schema: `DATABASE_URL` derived from exported `PG*` env vars
  (no `schema.sql`; `AUTO_DB` alone can't work — empty cluster, no DDL source)
- `ihp-typed-sql` patched locally for hasql-2.0.1.0 (`pqi-native` adapter)

## Prerequisite (done, other repo)
`/home/duke/dev/ihp` branch `decouple-ihp-typed-sql`, uncommitted:
- `ihp-typed-sql/.../Metadata.hs`: `acquire Pqi.adapter settings`
  (hasql-2 arg order)
- `ihp-typed-sql.cabal`: manual flag `libpq-backend` (default True);
  `pqi-ffi` + `-DLIBPQ_BACKEND` when set, `pqi-native` otherwise.
  Caller decides at build time (quoter internals can't take runtime args);
  default restores hasql-1.x transport with no new sysdeps.
  Override: `-f -libpq-backend` for the native transport.
`make env` green after patch. Follow-up there (not here): `Test/.../TypedSqlSpec.hs:1973`
generated blob still calls 1-arg `HasqlPool.acquire`; needs the same adapter
treatment when `cabal test` is run in the ihp repo.

## Task List

### Phase 0: Environment (gates everything)
- [ ] Task 0: `DATABASE_URL` for the `make dev` loop comes from `../.envrc`
  (already exports `PG*` + derived `DATABASE_URL`; deliberately NOT
  duplicated in `hs/Makefile`). Requires `direnv allow` in
  `/home/duke/dev/Playground` + a `make dev` restart so the running
  ghciwatch inherits it. No secrets in repo: password stays in env.
  Verify: `DATABASE_URL` present in the loop's env, `ghcid.txt` green.

### Checkpoint: env
- [ ] `ghcid.txt` says `All good` after Makefile change
- [ ] `.ghc.environment.*` present with `ihp-typed-sql` exposed

### Phase 1: Read sessions (one full path, smallest blast radius)
- [ ] Task 1 (spike): `getTodosSession` → `typedSql` + `sqlQueryTypedSession`,
  adapt `SqlRow` → `Todo` at boundary. Uses typed holes + `ghcid.txt`
  suggestions for the unknown result shape.
  Verify: `ghcid.txt` green, `tasty testDB` still passes (same rows back).
- [ ] Task 2: `getTodoSession`, `todoTitleExistsSession`,
  `getTodoByTitleSession`, `getTodoByTitleExceptSession`,
  `todoTitleExistsExceptSession` → `typedSql` (`AtMostOneRow` → `Maybe`).
  Verify: `ghcid.txt` green, duplicate/404 route paths behave (testRoute).

### Checkpoint: reads
- [ ] `tasty testDB` + `tasty testRoute` green via ghciwatch evals

### Phase 2: Write sessions
- [ ] Task 3: `addTodoSession`, `toggleTodoSession`, `deleteTodoSession`,
  `clearCompletedSession`, `updateTodoTitleSession`,
  `truncateTodosSession` (test) → `typedSql` + `sqlExecTypedSession`.
  Verify: full `testDB` CRUD + `testRoute` htmx flow green.

### Checkpoint: writes
- [ ] All 8 route tests + DB CRUD green, no behavior change

### Phase 3: Cleanup
- [ ] Task 4: remove `Hasql.TH` imports, drop `hasql-th` from `make env`
  (keep `hasql-dynamic-statements`: `ihp-typed-sql` builds on it).
  Verify: `grep -r Hasql.TH src/` empty, fresh `make env` green,
  `ghcid.txt` green, full suites green.

## Risks and Mitigations
| Risk | Impact | Mitigation |
|---|---|---|
| `DATABASE_URL` missing in dev shell → every `typedSql` fails compile | High | Task 0 first; fail-fast guard in Makefile |
| `SqlRow` shape/field access differs from guess | Low | Hole-driven: `_` + `ghcid.txt` suggestions |
| Cardinality inference (`Maybe` vs list) mismatches handler code | Med | Read queries keep `Maybe` flow (404/duplicate paths already handle it) |
| `make env` solver drops `hasql-th`/`pqi-native` (observed in failed-run plan) | Med | Verify `.ghc.environment` exposes them post-Task 4; else diagnose solver |
| Upstream ihp ports hasql-2 differently → local patch conflicts | Low | Patch is 4 lines, separate commit when committed |

## Open Questions
- Where to commit the ihp-checkout patch (separate commit there? upstream PR?)

## Verification (every task)
- `cat ghcid.txt` → `All good`; tmux ghciwatch pane shows eval results
- `tasty testDB`, `tasty testRoute` via `-- $>` eval comments (never `cabal`/`stack`)

## Phase 4: Hardening (done, same branch)
- A1 `TodoFilter` ADT (`ShowAll|ShowActive|ShowCompleted`), parsed once via
  `parseTodoFilter` at form/query boundaries; views/render take the ADT,
  `todoFilterName` renders hrefs + hidden input. Invalid values → `ShowAll`
  in one place (same lenient behavior as before, now explicit).
- A2 normalize-on-parse: `T.strip` moved into `FromForm` instances
  (add/update/generate); handler-side `normalizeTitle` calls removed
  (idempotent, so semantics unchanged). `editingTitle` now shows the
  stripped title on duplicate (was raw input) — cosmetic, arguably a fix.
- A3 `TodoId` newtype (`toTodoId` at routes via `checkedInt64`,
  `toRowId :: TodoId -> Id' "todos"` at `=`-on-PK SQL sites,
  `unTodoId` unwrap for views/tests/`<>` params). `routeTodoIdOr404`
  returns `Either Response TodoId`; handler + session sigs updated.
  Note: record accessor impossible under `NoFieldSelectors` — plain
  newtype + manual `unTodoId`.
- B3 render fusion: counts + matched list in one `foldl'` pass
  (`todoMatchesFilter`); order and search-independent counts preserved.
- C2 positional-coupling comment on the `TypedSqlRow` instance.
- Accepted warnings: orphan `PrimaryKey` instance (per-table instances
  belong to app code by design); pre-existing App.hs warnings untouched.
- Deferred per discussion: B2 (Prelude keeps strict-wrapper), A4, B4, C3, C4.
