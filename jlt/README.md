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

Expected result: `Ran 331 tests. 1115 assertions passed, 0 failures, 0 errors.`
That covers the Guardrails and Truss tests plus `superv.async`'s own suite,
which rides along on the test path — see [superv.async on Jolt](#supervasync-on-jolt).

To build the optimized binary without Guardrails, run the opt task
(`GUARDRAILS_ENABLED=false`, `jolt.opt-runner`, `--opt`):

```sh
./jolt opt
```

Expected result: `Ran 289 tests. 966 assertions passed, 0 failures, 0 errors.`
Guardrails-specific behavior specs are excluded in this mode, along with the
bootstrap, shim, and dep-loading tests that require Guardrails namespaces —
those sources break Jolt's `--opt` DCE reader, so the opt runner leaves
them out of the compile closure entirely.

Both tasks set `JOLT_AOT_CACHE=0` because Guardrails decides whether to emit
validation code during macro expansion. Jolt 0.8.6's AOT cache can reuse a
namespace compiled with different Guardrails settings, leaving checks disabled
even when `GUARDRAILS_ENABLED=true`. Compiling from source on each test run
ensures the test configuration takes effect without deleting the shared cache.

## Profiling the async backends

`./jolt bench` builds an optimized binary with `--opt` and runs it, so the
numbers it reports are the compiled ones. The two tasks above are unrelated:
`bench` profiles Jolt's two go-block backends — `:thread` (the default) and
`:fiber` — with [tufte](https://github.com/taoensso/tufte). The selector is
`clojure.core.async/*go-backend*`, defined natively by Jolt and read at **spawn**
time, so binding it around a workload covers every go block that workload
spawns, including ones inside functions it calls. `thread`/`io-thread` fix their
carrier at the call site and ignore the var, so they are out of scope.

```sh
./jolt bench
```

Defaults are `200` go-blocks × `50` park cycles, `5` reps, `10` loops. Jolt's
`:tasks` do **not** forward extra CLI args — `./jolt bench 100 50 3` silently
runs the defaults, and rebuilds first. To vary the workload, build once and
invoke the binary directly, which takes the numbers as ordinary arguments:

```sh
./jolt -A:test build -m jolt.bench-runner -o target/release/jlt-bench --opt
./target/release/jlt-bench 100 50 3 5   # [n k reps loops]
./target/release/jlt-bench --b-only     # microbenchmark layer only
```

Three layers, printed in this order:

- **(b) microbenchmark** — `n` go-blocks each doing `k` put/take cycles on a
  buffer-1 channel, `reps` times per backend, compared by tufte's clock total.
  This is the headline number: at the defaults the fiber backend finishes
  several times faster than `:thread` — runs on this machine have landed
  between ~4.6x and ~5.6x, so read it as an order of magnitude, not a
  constant. The gap also inverts for very small workloads, where per-go-block
  setup is not yet amortized.
- **(c) what parks and what pins** — `20` processes each sleeping the same
  `20 ms`, timed as one batch, across four cells: fiber/park, fiber/pin,
  fiber/thread, and thread. Parking releases the carrier, so a pinning workload
  serializes across carriers and takes proportionally longer.
- **(a) per-test** — each `deftest` of the backend-agnostic suites
  (`jolt.superv-async-test`, `jolt.superv-cps-test`,
  `jolt.partial-cps-core-async-test`) run under both backends, `loops` times,
  reported as a median — the first loop of each test pays warmup, and a mean
  would fold that outlier into every row.

`bench` is **observational, not a gate**. Its `-main` always exits `0` and never
inspects `clojure.test` counters, so layer (a) will happily run a failing test
without failing the run. `./jolt opt` is the gate.

Layer (a) enumerates test vars at run time, so its rows follow whatever is on
disk — editing one of those three suites changes the table without changing the
harness.

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
else — 28 tests and 45 assertions of the 331 and 1115 above. That is the same
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

`test/jolt/superv_async_test.clj` adds 20 more tests and 47 assertions for the
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

Both report `Ran 20 tests containing 47 assertions. 0 failures, 0 errors.`

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

Two project-local shims run before the upstream namespaces that need them:

- fulcro-spec 3.2.10's generated `Throwable` class token is converted back to a
  fully-qualified symbol before Jolt analyzes `=throws=>` assertions. This one
  runs before the upstream test namespaces load.
- `src/jolt/taoensso.clj` (ns `jolt.taoensso`, required for effect by
  `jolt.bench-runner` and `jolt.taoensso-test`) covers the host surface tufte's
  dependency chain needs and Jolt does not model. tufte keeps its per-thread
  profiling state in a `java.util.Stack`, and `Stack` subclasses `Vector`, which
  Jolt models no more than it models `Stack`, so the first `profiled` form dies
  with `No matching ctor found for class java.util.Stack`. Since the value is
  only pushed, popped, and asked whether it is empty — all LIFO — the shim
  registers the ctor onto Jolt's builtin `ArrayDeque` and adds the `empty`
  method that deque lacks, through the public `__register-class-ctor!` and
  `jolt.host/extend-class!` seams. A second half registers the four
  `java.text.DecimalFormat`/`DecimalFormatSymbols` members that `encore`'s
  number formatter needs for `tufte/format-pstats`; it honours the US
  configuration Jolt's formatter is fixed to and raises on any other, so a table
  is never silently formatted wrong. **That half is currently unexercised** —
  the profiler renders its own tables rather than calling `format-pstats`, and
  tufte's upstream suite is not vendored into this project.

The seven files under `test/com/fulcrologic/guardrails` and Truss's upstream
`test/taoensso/truss_tests.cljc` are copied unchanged (apart from the
documented Jolt branches in the Truss file). Jolt's
[time provider](https://jolt-lang.net/docs/api/time.html)
supplies `DateTimeFormatter` for the test dependency graph.

Guardrails' separate `src/test-clj-kondo` suite is not a runtime-library test
and is not included: clj-kondo reaches Cheshire/Jackson's JVM-only
`JsonFactory`, which is outside Jolt's documented pure-CLJ/CLJC dependency
boundary.
