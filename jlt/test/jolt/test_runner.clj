(ns jolt.test-runner
  ;; All test namespaces are required here in the ns form (in order) so that
  ;; Jolt's AOT/DCE sees the full compile closure. A top-level (require ...)
  ;; call is invisible to it: the binary then falls back to source
  ;; resolution at startup, which finds the Maven jar's clojure.core.async
  ;; (instead of the pre-seeded native one), pulls impl/timers, and dies on
  ;; (DelayQueue.). Keep this list in sync when adding tests.
  (:require [clojure.test :as test]
            [babashka.pod.datalevin-test]
            [superv.async-test]
            [jolt.superv-async-test]
            [jolt.superv-fibers-test]
            [jolt.superv-partial-cps-fibers-test]
            [is.simm.partial-cps.async-test]
            [is.simm.partial-cps.core-test]
            [is.simm.partial-cps.for-async-test]
            [is.simm.partial-cps.iteration-test]
            [is.simm.partial-cps.sequence-test]
            [is.simm.partial-cps.core-async-test]
            [jolt.partial-cps-core-async-test]
            [jolt.partial-cps-fibers-test]
            [jolt.superv-cps-test]
            [babashka.pod-test]
            ;; [jolt.add-deps]
            ;; [guardrails.bootstrap-test]
            ;; [guardrails.fulcro-spec-shim-test]
            ;; [com.fulcrologic.guardrails.config-spec]
            ;; [com.fulcrologic.guardrails.core-spec]
            ;; [com.fulcrologic.guardrails.impl.externs-spec]
            ;; [com.fulcrologic.guardrails.impl.parser-spec]
            ;; [com.fulcrologic.guardrails.malli.core-spec]
            ;; [com.fulcrologic.guardrails.malli.fulcro-spec-helpers-spec]
            ;; [com.fulcrologic.guardrails.utils-spec]
            ;; [taoensso.truss-tests] (AOT: var-args once-evaluation diverges)
            ))
;; [jolt.guardrails.bootstrap] commented out with the guardrails dep.

(def test-namespaces
  (let [always '[babashka.pod.datalevin-test
                 babashka.pod-test
                 ;; jolt.add-deps
                 ;; guardrails.bootstrap-test
                 ;; guardrails.fulcro-spec-shim-test
                 superv.async-test
                 jolt.superv-async-test
                 jolt.superv-fibers-test
                 jolt.superv-partial-cps-fibers-test
                 is.simm.partial-cps.async-test
                 is.simm.partial-cps.core-test
                 is.simm.partial-cps.for-async-test
                 is.simm.partial-cps.iteration-test
                 is.simm.partial-cps.sequence-test
                 is.simm.partial-cps.core-async-test
                 jolt.partial-cps-core-async-test
                 jolt.partial-cps-fibers-test
                 jolt.superv-cps-test]
                 ;; taoensso.truss-tests (AOT: see require block note)
                 ]
         ;; guardrails '[com.fulcrologic.guardrails.config-spec
         ;;              com.fulcrologic.guardrails.core-spec
         ;;              com.fulcrologic.guardrails.impl.externs-spec
         ;;              com.fulcrologic.guardrails.impl.parser-spec
         ;;              com.fulcrologic.guardrails.malli.core-spec
         ;;              com.fulcrologic.guardrails.malli.fulcro-spec-helpers-spec
         ;;              com.fulcrologic.guardrails.utils-spec]
    always))

(defn -main
  "Run the suite. With no args runs everything (the gate). With namespace
  args runs only those — one file in isolation per process, to hunt
  order-dependent or pollution-masked failures, e.g.:
  ./jolt -A:test -m jolt.test-runner jolt.superv-async-test"
  [& nses]
  (let [selected (if (seq nses)
                   (mapv symbol nses)
                   test-namespaces)
        {:keys [fail error]} (apply test/run-tests selected)]
    (System/exit (if (zero? (+ fail error)) 0 1))))
