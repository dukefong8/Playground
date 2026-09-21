(ns jolt.taoensso
  "Host seams for the taoensso stack (tufte → encore → truss).

  tufte keeps its per-thread profiling state in a `java.util.Stack`
  (`taoensso/tufte/impl.cljc`, `pdata-local-push`/`pdata-local-pop`): the stack
  exists to support `profile/d` NESTING, so a push stashes the PData it
  interrupts and the matching pop restores it.

  Jolt models no `java.util.Vector`, and `Stack` is a Vector subclass, so the
  class is unknown — `(java.util.Stack.)` raises

      No matching ctor found for class java.util.Stack

  The value is only ever pushed, popped, and asked whether it is empty, and
  every one of those is LIFO — which is what Jolt's builtin ArrayDeque already
  answers. So the seam is two additive registrations rather than a Vector model
  or a vendored `taoensso.tufte.impl`:

    - the ctor, so `(java.util.Stack.)` yields an ArrayDeque-backed deque;
    - `empty` on ArrayDeque, which Jolt's shim does not carry.

  Both go through the PUBLIC seams (`__register-class-ctor!`,
  `jolt.host/extend-class!`), so Jolt's own ArrayDeque keeps answering every
  method it already has and nothing here shadows a built-in.

  The divergence this buys, stated plainly: the backing is an ArrayDeque, so

    - `(.empty x)` is now answerable on an ArrayDeque, where the JVM has no such
      method — additive only, nothing that works on the JVM stops working;
    - `(class stack)` reports `java.util.ArrayDeque`, not `java.util.Stack`;
    - ArrayDeque's `push` inserts at the FRONT, so a seq of the stack reads
      newest-first. JVM `Stack.push` appends, so its seq reads oldest-first.
      Same LIFO contract, opposite iteration order — invisible to tufte, which
      never walks the stack.

  No `:require`: both registrations are host-level, and tufte realizes its
  ThreadLocal's initial value lazily — on the first `profiled` form, long after
  every namespace has loaded — so requiring tufte here would add a dependency
  without buying an ordering guarantee.")

;; Stack's only constructor is the no-arg one; Vector's `(Vector. coll)` is not
;; inherited. Declaring the arity keeps `(java.util.Stack. [1 2])` a failure here
;; as it is on the JVM, rather than a silently-ignored argument — the JVM raises
;; IllegalArgumentException ("No matching ctor found"), this raises
;; ArityException, which is the same refusal in Jolt's own vocabulary.
(clojure.core/__register-class-ctor! "java.util.Stack" (fn [] (java.util.ArrayDeque.)))

;; The extend tier is consulted only where dispatch would otherwise raise "No
;; matching method", so this adds `empty` without touching isEmpty/push/pop.
(jolt.host/extend-class!
  "java.util.ArrayDeque"
  {:methods {"empty" (fn [self] (.isEmpty self))}})

;; ------------------------------------------------------ java.text.DecimalFormat
;;
;; `encore/format-num-fn` builds a US number formatter and tufte's
;; `format-pstats` renders through it, so the profile tables need four members
;; Jolt's `java.text.DecimalFormat` does not answer:
;;
;;   (.setGroupingSize nf 3)                  missing method
;;   (.setDecimalFormatSymbols nf (…Symbols.)) missing method
;;   (java.text.DecimalFormatSymbols.)          missing ctor
;;   (.setDecimalSeparator /.setGroupingSeparator …)
;;
;; Jolt's DecimalFormat is a fixed US formatter — `(.format nf 1234.5)` already
;; answers "1,234.50", grouping by 3 with '.' and ',' — so the values encore
;; asks for are the ones already in force. These registrations therefore HONOUR
;; the request when it matches and raise otherwise: accepting a grouping size or
;; separator pair Jolt cannot apply would silently format the number wrong, and
;; a wrong table that looks like a measurement is the one outcome worth failing
;; loudly over. Raising also matches what the unshimmed call already did (it
;; raised "No matching method"), so nothing that works today regresses.

(defn- us-separators?
  "Does `syms` still hold the US pair Jolt's DecimalFormat is fixed to?"
  [syms]
  (and (= \. (jolt.host/ref-get syms :decimal-separator))
       (= \, (jolt.host/ref-get syms :grouping-separator))))

(defn- unsupported! [what]
  (throw (UnsupportedOperationException.
           (str "jolt: " what " — Jolt's java.text.DecimalFormat is fixed to the US"
                " formatter (grouping size 3, '.' decimal, ',' grouping); this shim"
                " honours that configuration and cannot apply another."))))

;; A tagged table stands in for the class Jolt does not model. encore only ever
;; builds one to re-set the separators it already has (its own comment calls the
;; call "Redundant?"), so recording them is enough for `setDecimalFormatSymbols`
;; above to check.
(defn- decimal-format-symbols-ctor [& _]
  (let [t (jolt.host/tagged-table :java.text/DecimalFormatSymbols)]
    (jolt.host/ref-put! t :decimal-separator \.)
    (jolt.host/ref-put! t :grouping-separator \,)
    t))

(__register-class-methods!
  :java.text/DecimalFormatSymbols
  {"setDecimalSeparator"  (fn [self c] (jolt.host/ref-put! self :decimal-separator c) nil)
   "setGroupingSeparator" (fn [self c] (jolt.host/ref-put! self :grouping-separator c) nil)})

(jolt.host/extend-class! "java.text.DecimalFormatSymbols" {:ctor decimal-format-symbols-ctor})

(jolt.host/extend-class!
  "java.text.DecimalFormat"
  {:methods
   {"setGroupingSize"
    (fn [_ n] (if (= 3 n) nil (unsupported! (str "cannot set grouping size " n))))

    "setDecimalFormatSymbols"
    (fn [_ syms]
      (if (us-separators? syms) nil (unsupported! "cannot set non-US format symbols")))}})
