# Guardrails and Truss on Jolt

This example declares `com.fulcrologic/guardrails` 1.3.4 and
`com.taoensso/truss` 2.5.1 in `deps.edn`, then runs their migrated tests under
Jolt. Guardrails tests come from upstream tag
[`guardrails-1.3.4`](https://github.com/fulcrologic/guardrails/tree/guardrails-1.3.4)
(commit `854ebb1d6eb8a1501f4ba12adf4c1a6718df1a62`).

Run the test suite JIT (the task explicitly enables Guardrails):

```sh
./jolt test
```

Expected result: `Ran 323 tests. 1090 assertions passed, 0 failures, 0 errors.`
That covers the Guardrails and Truss tests plus `superv.async`'s own suite,
which rides along on the test path — see [superv.async on Jolt](#supervasync-on-jolt).

To build the optimized binary without Guardrails, run the bench task
(`GUARDRAILS_ENABLED=false`, `jolt.bench-runner`, `--opt`):

```sh
./jolt bench
```

Expected result: `Ran 284 tests. 951 assertions passed, 0 failures, 0 errors.`
Guardrails-specific behavior specs are excluded in this mode, along with the
bootstrap, shim, and dep-loading tests that require Guardrails namespaces —
those sources break Jolt's `--opt` DCE reader, so the bench runner leaves
them out of the compile closure entirely.

Both tasks set `JOLT_AOT_CACHE=0` because Guardrails decides whether to emit
validation code during macro expansion. Jolt 0.8.6's AOT cache can reuse a
namespace compiled with different Guardrails settings, leaving checks disabled
even when `GUARDRAILS_ENABLED=true`. Compiling from source on each test run
ensures the test configuration takes effect without deleting the shared cache.

## Enabling Guardrails

Current Jolt does not accept JVM-style `-Dguardrails.enabled=true` on its
command line. It has no JVM, and its documented `-J` compatibility option is
[accepted but ignored](https://github.com/jolt-lang/jolt/blob/1462939ebdef86c7a68aad2cd2986a5738f405f8/jolt-core/jolt/main.clj#L773-L774).
Jolt does implement `System/getProperty` and `System/setProperty`, so
`bootstrap.clj` sets `guardrails.enabled` before requiring any Guardrails
namespace. Guardrails is disabled by default; enable it with
`GUARDRAILS_ENABLED`:

```sh
./jolt test
```

An unset, empty, or `false` value clears the property. Guardrails treats
every other property value as enabled; `production` is its explicit opt-in
value for production ClojureScript builds.

## superv.async on Jolt

`superv.async` is declared as a `:local/root` dependency and runs on Jolt
unmodified — no project-local shim and no `:jolt/replaces`. Its suite is on the
`:test` alias's `:extra-paths`, so `./jolt test` covers it along with everything
else — 28 tests and 45 assertions of the 323 and 1090 above. That is the same
tally it reports on a JVM, so the port is not merely loading:

```sh
cd ../../superv.async && clojure -Sdeps '{:paths ["src" "test"]}' -M \
  -e "(require 'superv.async-test) (clojure.test/run-tests 'superv.async-test)"
```

What lets it run is two pieces of upstream `core.async`'s surface that Jolt did
not ship, now implemented in its stdlib instead of worked around per project:

- **`alt!` / `alt!!`**, upstream's macros over the `alts!` / `alts!!` Jolt
  already had. `superv.async` :refers both.
- **`clojure.core.async.impl.protocols`**, carrying `ReadPort`. `superv.async`
  reaches it by `(:import (clojure.core.async.impl.protocols ReadPort))` and by
  `(satisfies? clojure.core.async.impl.protocols/ReadPort ch)`, and Jolt's
  channels are native, so both questions needed answering for a value that has
  no deftype behind it.

A bare `(require 'clojure.core.async)` installs both — the overlay's ns form
requires the protocols namespace, as upstream's does — so nothing has to
remember an ordering. Jolt 0.8.6 and earlier do not have them; this runs against
a Jolt built from `main` after the core.async work landed.

`test/jolt/superv_async_test.clj` adds 19 more tests and 44 assertions for the
parts of its public API that suite never reaches — the blocking twins, the
callback ops, the exception-tracking protocol, the supervisor constructors, and
the channel plumbing (`tap`, `sub`, `engulf`, `debounce>>`). That file is
deliberately portable so the same one runs on a JVM, which is the point of it: a
case that passes there and fails here is a port divergence, and one that fails on
both is an upstream bug. Run it against the oracle with:

```sh
cd ../../superv.async && clojure -Sdeps \
  '{:paths ["src" "/Users/duke/dev/Playground/jlt/test"]}' -M \
  -e "(require 'jolt.superv-async-test) (clojure.test/run-tests 'jolt.superv-async-test)"
```

Both report `Ran 19 tests containing 44 assertions. 0 failures, 0 errors.`

## Compatibility layer

Guardrails depends on Clojure 1.12.5, so `deps.edn` explicitly supplies that
release's `spec.alpha` 0.5.238 and `core.specs.alpha` 0.4.74 artifacts. This
follows Jolt's source-based [Maven dependency model](https://jolt-lang.net/docs/building-and-deps.html#whats-supported).
fulcro-spec is test-only (`:aliases :test :extra-deps`) and excludes its older
transitive Guardrails and Malli copies; Malli 0.20.1 is pinned directly to
match Guardrails 1.3.4. The project requires Jolt 0.8.2 or newer, which natively
implements the three-argument `ns-resolve` used by Guardrails.

Jolt 0.8.6 no longer enables the `:bb` reader feature by default, so
`deps.edn` explicitly opts in with `:jolt/features [:bb]`. This lets
fulcro-spec use its Babashka-compatible branches, avoiding its JVM-only
`cljs.test` dependency.

One project-local shim runs before the upstream test namespaces load:

- fulcro-spec 3.2.10's generated `Throwable` class token is converted back to a
  fully-qualified symbol before Jolt analyzes `=throws=>` assertions.

The seven files under `test/com/fulcrologic/guardrails` and Truss's upstream
`test/taoensso/truss_tests.cljc` are copied unchanged (apart from the
documented Jolt branches in the Truss file). Jolt's
[time provider](https://jolt-lang.net/docs/api/time.html)
supplies `DateTimeFormatter` for the test dependency graph.

Guardrails' separate `src/test-clj-kondo` suite is not a runtime-library test
and is not included: clj-kondo reaches Cheshire/Jackson's JVM-only
`JsonFactory`, which is outside Jolt's documented pure-CLJ/CLJC dependency
boundary.
