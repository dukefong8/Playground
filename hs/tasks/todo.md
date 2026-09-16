# Todo: hasql-th → ihp-typed-sql migration

- [x] Task 0: DATABASE_URL in make dev loop (via ../.envrc + direnv allow)
- [x] Task 1 (spike): getTodosSession → typedSql
- [x] Task 2: remaining read sessions → typedSql
- [x] Checkpoint: testDB + testRoute green on reads
- [x] Task 3: write sessions + test truncate → typedSql
- [x] Checkpoint: full suites green, no behavior change
- [x] Task 4: drop Hasql.TH / hasql-th, green
- [ ] You: re-run make env (materialize hasql-th removal), restart make dev [SKIPPED per user]
- [ ] You: commit hs branch + ihp-checkout patch; re-enable pighcid hook?
