---
name: jolt
description: Port and debug Clojure libraries on Jolt by preserving their existing Clojure source and adding the smallest required host-class or native FFI seams. Use for Jolt compatibility, Java host interop, Jolt shims, and Jolt nREPL development.
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

A `.jolt` namespace is appropriate only for a truly target-specific boundary,
such as native FFI code that has no JVM implementation. Keep that boundary thin;
call the existing Clojure code above it.

## Overriding a namespace

A different tool from the registrations above. Use it when the gap is a whole
namespace's *content* — Jolt does not ship it, or ships it missing names — and
not when the gap is state or ordering.

- Extension precedence does not do this by itself. `.jolt` > `.clj` > `.cljc` is
  precedence *within* a source root; `resolve-on-roots` consults the copy baked
  into the binary before any project root, so a project `foo.jolt` is silently
  ignored. Declare it with `:jolt/replaces [foo]` in the project's `deps.edn`.
  Only the project may declare one, it covers the namespace's children, and it is
  whole-namespace — resolution never falls through to the original. Verify by
  deleting the key: the file then stops being read at all.
- Re-provide the original by delegating to it, never by vendoring a copy:

  ```clojure
  (load-string (slurp (clojure.java.io/resource "clojure/core/async.clj")))
  ```

  `io/resource` resolves to what the running binary carries (embedded stdlib) or
  to the jar entry (a dependency), so it cannot drift from the revision in use. A
  copy silently freezes the project at whatever was copied.
- A `:require` cannot express this. It resolves namespace *names*, and the
  implementation lives in the namespace being shadowed — requiring it resolves
  back to the shadow itself, where it is a no-op. That is why the re-provide
  names a path.
- Definitions placed *after* that evaluation inherit the shadowed namespace's
  state, including its `:refer-clojure :exclude`. A bare `reduce` inside
  `clojure.core.async` is the channel operator, not `clojure.core/reduce`;
  qualify the excluded names.
- Guard with the right predicate. `(resolve 'a.b/c)` is truthy for a *dangling
  refer*: Jolt tolerates a ns form that `:refer`s a symbol not yet defined by
  interning an unbound var. A `when-not` on `resolve` then skips the definition
  and leaves a non-macro var that the analyzer calls as an ordinary function,
  surfacing as `Unable to resolve symbol: v__NN__auto ... raised while expanding
  the ... macro`. Test `(:macro (meta ...))` when installing a macro.
- Adding vars to a namespace from *another* file needs `intern` plus
  `alter-meta!` with `:macro true`: Jolt's `intern` does not merge the fn's
  metadata onto the var the way the JVM's does. When the `.jolt` file *is* that
  namespace, plain `defmacro`/`defn` land in the right place and none of it is
  needed.
- Always re-run cold (`JOLT_AOT_CACHE=0`). The AOT cache hides ordering bugs: a
  cached namespace is never recompiled, so it never re-refers or re-resolves, and
  a shim that only works warm passes every test that does not force a rebuild.
- Overriding takes the namespace off its embedded fasl, so it is recompiled from
  source on every startup. Measure it (`/usr/bin/time -p`); core.async cost
  ~0.25 s against ~0.06 s stock.

Do not reach for this on a *state* gap. Patching a var with `alter-var-root`, or
setting properties that another library reads during macro expansion, is a
bootstrap question rather than a namespace one: an override would still need the
same patch and would add a re-provided namespace, a `:jolt/replaces` entry and
the startup cost on top. Properties also have to land before the library reading
them is *required*, which overriding a later-loading namespace cannot guarantee.

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
6. Run the enclosing Datalevin test namespace, the full canonical JVM API suite,
   and the static-link/package gates relevant to the slice.
7. Refactor only after the gates pass, then rerun them.

Do not suppress, bypass, or replace a failing behavior to make a gate green.
Fix the missing seam or expose the blocker with the exact failing test.

## REPL discipline

Load `.agents/skills/brepl/SKILL.md` before using `brepl`. Always send forms with
a quoted heredoc. Use the running Jolt nREPL for Jolt bindings and runtime
behavior, and the running Clojure nREPL only as the JVM semantic oracle.
