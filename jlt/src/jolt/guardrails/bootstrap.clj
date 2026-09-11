(ns jolt.guardrails.bootstrap
  "Sets Guardrails properties and installs the test-time compatibility shim."
  (:require [clojure.walk :as walk]
            [fulcro-spec.assertions :as assertions]))

(defonce ^:private fulcro-triple->assertion
  assertions/triple->assertion)

(defn enabled?
  "Whether Guardrails was explicitly enabled for this process."
  []
  (let [value (System/getenv "GUARDRAILS_ENABLED")]
    (and value
         (not= "" value)
         (not= "false" value))))

(defn- symbolic-throwable [form]
  (if (= Throwable form)
    'java.lang.Throwable
    form))

(alter-var-root
  #'assertions/triple->assertion
  (fn [_]
    (fn [cljs? triple]
      (walk/postwalk symbolic-throwable
                     (fulcro-triple->assertion cljs? triple)))))

;; Match Guardrails' upstream JVM test invocation.
(System/setProperty "guardrails.config" "guardrails-test.edn")
(let [enabled (System/getenv "GUARDRAILS_ENABLED")]
  (if (or (= "" enabled) (= "false" enabled))
    (System/clearProperty "guardrails.enabled")
    (when enabled
      (System/setProperty "guardrails.enabled" enabled))))
