# Guardrails and Truss on Jolt

This example declares `com.fulcrologic/guardrails` 1.3.3 and
`com.taoensso/truss` 2.5.1 in `deps.edn`, then runs their migrated tests under
Jolt. Guardrails tests come from upstream tag
[`guardrails-1.3.3`](https://github.com/fulcrologic/guardrails/tree/guardrails-1.3.3)
(commit `bcaca53295667aa5215ab8f92d2eb8f30fc90e23`).

Run the test suite (the task explicitly enables Guardrails):

```sh
./jolt test
```

Expected result: `Ran 109 tests. 789 assertions passed, 0 failures, 0 errors.`
That covers the Guardrails and Truss tests plus `superv.async`'s own suite,
which rides along on the test path — see [superv.async on Jolt](#supervasync-on-jolt).

To build with Guardrails disabled, use the same optimized entry point with
`GUARDRAILS_ENABLED=false`:

```sh
JOLT_AOT_CACHE=0 GUARDRAILS_ENABLED=false ./jolt -M:test build -m jolt.test-runner --opt
```

Expected result: `Ran 73 tests. 656 assertions passed, 0 failures, 0 errors.`
Guardrails-specific behavior specs are excluded in this mode, while the
bootstrap test verifies that macro-expanded checks are actually absent. The
`superv.async` suite is unaffected either way, so both totals move by its 27
tests and 44 assertions.

The test task sets `JOLT_AOT_CACHE=0` because Guardrails decides whether to emit
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

An unset, empty, or `false` value leaves the property unset. Guardrails treats
every other property value as enabled; `production` is its explicit opt-in
value for production ClojureScript builds.

## superv.async on Jolt

`superv.async` is declared as a `:local/root` dependency and runs on Jolt behind
one project-local shim. Its suite is on the `:test` alias's `:extra-paths`, so
`./jolt test` covers it along with everything else — 27 tests and 44 assertions
of the 109 and 789 above. That is the same tally it reports on a JVM, so the port
is not merely loading:

```sh
cd ../../superv.async && clojure -Sdeps '{:paths ["src" "test"]}' -M \
  -e "(require 'superv.async-test) (clojure.test/run-tests 'superv.async-test)"
```

`test/superv/async_jolt_test.clj` adds 19 more tests and 44 assertions for the
parts of its public API that suite never reaches — the blocking twins, the
callback ops, the exception-tracking protocol, the supervisor constructors, and
the channel plumbing (`tap`, `sub`, `engulf`, `debounce>>`). That file is
deliberately portable so the same one runs on a JVM, which is the point of it: a
case that passes there and fails here is a port divergence, and one that fails on
both is an upstream bug. Run it against the oracle with:

```sh
cd ../../superv.async && clojure -Sdeps \
  '{:paths ["src" "/Users/duke/dev/Playground/jlt/test"]}' -M \
  -e "(require 'superv.async-jolt-test) (clojure.test/run-tests 'superv.async-jolt-test)"
```

Both report `Ran 19 tests containing 44 assertions. 0 failures, 0 errors.`

The shim is project-local by necessity: Jolt ships its stdlib inside the binary,
so nothing here is visible to another project. It stands in for two gaps Jolt
itself could close.

`src/clojure/core/async/impl/protocols.jolt` carries both. They share a file
because the namespace name is not free — superv.async reaches the protocol side
with `(:import (clojure.core.async.impl.protocols ReadPort))`, so a shim it can
find has to live under exactly that name — and one namespace is what
`jolt.test-runner` has to require before the suite.

- **ReadPort**, the namespace Jolt does not ship at all. Jolt's channels are
  native records that report the class name `ManyToManyChannel` but no
  interfaces and no host tags, so `value-host-tags` answers `("Object")` for a
  channel and neither protocol dispatch nor `instance?` can reach one. The file
  defines `ReadPort` — the only name superv.async imports, and it calls no
  protocol method — registers the channel's class-graph row, registers an
  instance check for the `:import`ed class name, and delegates `take!` to the
  native op. `.jolt` because it is not portable Clojure: it calls
  `jolt.host/register-class-supers!` and `__register-instance-check!`.
- **`alt!` / `alt!!`**, which Jolt's `core.async` does not define (`alts!` and
  `alts!!` it does). The shared `do-alt` expansion is upstream's, verbatim apart
  from parameterising the alts op, and the macros are interned into
  `clojure.core.async`.

## How the shim loads

A bare `(require 'clojure.core.async)` installs the shim. Nothing has to
remember to do it first, which matters because the ordering is load-bearing:
`superv.async` only `:import`s `impl.protocols` — an `:import` does not load a
namespace — and its `<<?`/`alt?` macros expand to `alt!`, so reaching
`superv.async` first would bake in symbols that never resolve.

`src/clojure/core/async.jolt` plus `:jolt/replaces [clojure.core.async]` in
`deps.edn` are what make that work, and `test/jolt/test_runner.clj` no longer
mentions the shim at all — it just requires the suite. Jolt's own
`clojure.core.async` loads the shim through `superv.async`'s own `:require`.

The file **delegates rather than replaces**: `clojure.java.io/resource` reads the
overlay back out of the running binary and `load-string` evaluates it, then the
shim loads on top. Vendoring a copy of that 43 KB overlay would freeze this
project at whatever revision it was copied from; reading it back cannot drift.

It cannot be a `:require` line, which is the only odd-looking part. `:require`
resolves a *namespace*, and the namespace holding the implementation is the one
being shadowed — requiring it there resolves back to this file. Shadowing is
exactly what stops the real overlay from loading, so re-providing it has to name
its source by path.

This is the coarsest override Jolt offers, and it is not free: forcing
`clojure.core.async` off its embedded fasl means the overlay is recompiled from
source, so a bare require costs ~0.25 s against ~0.06 s stock. Deleting the
`:jolt/replaces` line is the whole revert — the `.jolt` then stops being read
and the suite needs `(require 'clojure.core.async.impl.protocols)` ahead of it
again. Worth recording that a `.jolt` cannot shadow a stdlib namespace on its
own: `resolve-on-roots` consults the binary's embedded copy before any project
source root, so without `:jolt/replaces` such a file is silently ignored.

## Compatibility layer

Guardrails depends on Clojure 1.12.5, so `deps.edn` explicitly supplies that
release's `spec.alpha` 0.5.238 and `core.specs.alpha` 0.4.74 artifacts. This
follows Jolt's source-based [Maven dependency model](https://jolt-lang.net/docs/building-and-deps.html#whats-supported).
fulcro-spec is test-only (`:aliases :test :extra-deps`) and excludes its older
transitive Guardrails and Malli copies; Malli 0.20.1 is pinned directly to
match Guardrails 1.3.3. The project requires Jolt 0.8.2 or newer, which natively
implements the three-argument `ns-resolve` used by Guardrails.

Jolt 0.8.6 no longer enables the `:bb` reader feature by default, so
`deps.edn` explicitly opts in with `:jolt/features [:bb]`. This lets
fulcro-spec use its Babashka-compatible branches, avoiding its JVM-only
`cljs.test` dependency.

One project-local shim runs before the upstream test namespaces load:

- fulcro-spec 3.2.9's generated `Throwable` class token is converted back to a
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
