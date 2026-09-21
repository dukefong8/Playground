(ns jolt.guardrails.bootstrap
  "Sets Guardrails properties and installs the test-time compatibility shim."
  (:require [clojure.walk :as walk]
            [fulcro-spec.assertions :as assertions]))

(defonce ^:private fulcro-triple->assertion
  assertions/triple->assertion)

(defn enabled?
  "Whether Guardrails was explicitly enabled for this process.
   Defaults to false: only a GUARDRAILS_ENABLED value other than unset,
   empty, or \"false\" enables it."
  []
  (let [value (System/getenv "GUARDRAILS_ENABLED")]
    (boolean (and value
                  (not= "" value)
                  (not= "false" value)))))

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

;; Match Guardrails' upstream JVM test invocation. Guardrails is off by
;; default: any GUARDRAILS_ENABLED value other than unset, empty, or "false"
;; opts in, and every other value leaves the property cleared.
(System/setProperty "guardrails.config" "guardrails-test.edn")
(if (enabled?)
  (System/setProperty "guardrails.enabled" (System/getenv "GUARDRAILS_ENABLED"))
  (System/clearProperty "guardrails.enabled"))
