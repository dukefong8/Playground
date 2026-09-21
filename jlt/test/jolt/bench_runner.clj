(ns jolt.bench-runner
  ;; Optimized-build counterpart to jolt.test-runner: the same suite minus
  ;; every namespace that requires Guardrails (its jar sources break Jolt's
  ;; --opt DCE reader). Runs with GUARDRAILS_ENABLED=false; see the bench
  ;; task in deps.edn. Keep this list in sync with test-runner's `always`
  ;; list, minus guardrails.bootstrap-test, guardrails.fulcro-spec-shim-test
  ;; (fulcro-spec.core pulls guardrails back in), and jolt.add-deps
  ;; (requires guardrails.core).
  (:require [clojure.test :as test]
            [jolt.guardrails.bootstrap]
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
            [jolt.partial-cps-runtime-test]
            [babashka.pod-test]
            [taoensso.truss-tests]))

(def test-namespaces
  '[babashka.pod.datalevin-test
    babashka.pod-test
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
    jolt.superv-cps-test
    jolt.partial-cps-runtime-test
    taoensso.truss-tests])

(defn -main
  "Run the guardrails-free suite (the bench gate). With namespace args runs
  only those, one file in isolation per process."
  [& nses]
  (let [selected (if (seq nses)
                   (mapv symbol nses)
                   test-namespaces)
        {:keys [fail error]} (apply test/run-tests selected)]
    (System/exit (if (zero? (+ fail error)) 0 1))))
