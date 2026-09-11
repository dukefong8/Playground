(ns jolt.test-runner
  (:require [clojure.test :as test]
            [jolt.guardrails.bootstrap]))

;; Keep bootstrap ahead of upstream macro expansion.
(require 'babashka.pod.datalevin-test
         'jolt.babashka.pod-test
         'jolt.guardrails.add-deps-test
         'jolt.guardrails.bootstrap-test
         'jolt.guardrails.fulcro-spec-shim-test
         'com.fulcrologic.guardrails.config-spec
         'com.fulcrologic.guardrails.core-spec
         'com.fulcrologic.guardrails.impl.externs-spec
         'com.fulcrologic.guardrails.impl.parser-spec
         'com.fulcrologic.guardrails.malli.core-spec
         'com.fulcrologic.guardrails.malli.fulcro-spec-helpers-spec
         'com.fulcrologic.guardrails.utils-spec
         'taoensso.truss-tests)

(def test-namespaces
  (let [always '[babashka.pod.datalevin-test
                 jolt.babashka.pod-test
                 jolt.guardrails.add-deps-test
                 jolt.guardrails.bootstrap-test
                 jolt.guardrails.fulcro-spec-shim-test
                 taoensso.truss-tests]
        guardrails '[com.fulcrologic.guardrails.config-spec
                     com.fulcrologic.guardrails.core-spec
                     com.fulcrologic.guardrails.impl.externs-spec
                     com.fulcrologic.guardrails.impl.parser-spec
                     com.fulcrologic.guardrails.malli.core-spec
                     com.fulcrologic.guardrails.malli.fulcro-spec-helpers-spec
                     com.fulcrologic.guardrails.utils-spec]]
    (if (jolt.guardrails.bootstrap/enabled?)
      (into (vec always) guardrails)
      always)))

(defn -main [& _]
  (let [{:keys [fail error]} (apply test/run-tests test-namespaces)]
    (System/exit (if (zero? (+ fail error)) 0 1))))
