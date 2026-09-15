---
name: jolt
description: Port and debug Clojure libraries on Jolt by preserving their existing Clojure source and adding the smallest required host-class or native FFI seams. Use for Jolt compatibility, Java host interop, Jolt shims, AOT builds, and Jolt nREPL development.
---

# Jolt library development

Preserve the library's Clojure implementation and semantics. Treat Jolt's host
interop layer as the compatibility boundary for Java classes used by otherwise
portable Clojure code.

## Sources of truth

Before implementing a missing host seam:

1. Read the official [Host Interop documentation](https://jolt-lang.net/docs/host-interop.html).
2. Check the active Jolt version and relevant entries in `../jolt/CHANGELOG.md`.
3. Inspect `../jolt/host/chez/java`, `../jolt/jolt-core`, and Jolt's tests for the
   current registration and dispatch patterns.
4. Inspect the library's existing `.clj` namespace and JVM class behavior. Use a
   JVM nREPL as a semantic oracle, except that target-specific native bindings
   must run only in Jolt.

Do not rely on remembered Jolt behavior when the documentation or current source
can answer the question.

## Boundary rule

Do not create a `.jolt` rewrite for a Clojure namespace merely because it imports
or calls JVM classes. Keep the `.clj` namespace and register the missing class
surface:

- unknown class or constructor: `__register-class-ctor!`
- static field or method: `__register-class-statics!`
- methods on a tagged host value: `__register-class-methods!`
- exact `instance?`: `__register-instance-check!`
- superclass and interface relationships: `jolt.host/register-class-supers!`
- a missing member on a class Jolt already shims: `jolt.host/extend-class!`

Use `jolt.host/tagged-table`, `ref-put!`, and `ref-get` for stateful class
representations, following Jolt's documented pattern. Register literal JVM class
and member names exactly as they appear in interop forms.

A `.jolt` namespace is appropriate only for truly target-specific code with no
JVM implementation (native FFI). Keep that boundary thin; call the existing
Clojure code above it.

## Do not override namespaces Jolt ships

Never shadow a namespace the binary already carries (`clojure.core.async` and
its `impl.*` parts, `clojure.core`, …): resolution consults the baked-in copy
before project roots, so a project copy is silently ignored, and forcing one
takes the namespace off its embedded fasl — recompiled from source on every
startup, drifting from upstream. If Jolt ships it missing names, add host
seams (above) instead of vendoring the namespace.

This covers state gaps too: patching a var with `alter-var-root`, or setting
properties a library reads during macro expansion, is a bootstrap/ordering
question, and an override would still need the same patch plus the extra
namespace, entry, and startup cost.

## AOT build rules

JIT green does not imply AOT green. A set that passes under `jolt run` can
fail to compile, fail at startup, or fail assertions as a binary. Gate every
slice that must ship as one:

1. Requires MUST live in the ns form, in load order. A top-level `(require
   ...)` call is invisible to AOT/DCE static closure: the binary falls back
   to source resolution at startup and may load the wrong artifact. Observed:
   the Maven jar's `clojure.core.async` instead of the pre-seeded native one,
   pulling `impl/timers` → `(DelayQueue.)` boom. Keep the list in sync when
   adding tests.
2. Build AND run: `jolt build -m NS -o OUT --opt`, then execute OUT and read
   its summary. Build success proves nothing about startup or semantics.
   Capture the binary's real exit code — a `| tail` pipeline masks it.
3. Isolate per test namespace with temporary `-main` entries (one ns each),
   build each, delete the entries after. A full-runner failure names no file;
   per-test builds blame precisely (e.g. the DCE reader dying on guardrails
   `core.cljc`).
4. `JOLT_AOT_CACHE=0` for build matrices. A shared AOT cache across sequential
   `--opt` builds produced broken binaries (`Unknown class t`); determinism
   first. Always re-run cold for the same reason.
5. `GUARDRAILS_ENABLED=false` to disable (not unset — Jolt sets the property
   itself when guardrails is present).

## TDD loop

Work one missing seam at a time:

1. Add or select the smallest test that loads and exercises the unchanged
   Clojure code.
2. Run it in the Jolt nREPL and record the exact missing-host failure. This is the
   RED gate.
3. Verify the same observable behavior in the JVM oracle when the code is not a
   Jolt-only native binding.
4. Add the smallest registration or class extension. If the behavior is a
   generally useful JDK/Clojure host surface, implement it in `../jolt` and add a
   focused Jolt host regression test. Keep library-specific representations with
   the library and declare their provided host classes as required by Jolt's
   dependency metadata.
5. Rebuild Jolt when its host source changes, restart the Jolt nREPL, and rerun
   the focused test. This is the GREEN gate.
6. Run the enclosing test namespace, the full canonical suite, and the
   static-link/package gates relevant to the slice.
7. Refactor only after the gates pass, then rerun them.

Do not suppress, bypass, or replace a failing behavior to make a gate green.
Fix the missing seam or expose the blocker with the exact failing test.

## REPL discipline

Load `.agents/skills/brepl/SKILL.md` before using `brepl`. Always send forms with
a quoted heredoc. Use the running Jolt nREPL for Jolt bindings and runtime
behavior, and the running Clojure nREPL only as the JVM semantic oracle.
