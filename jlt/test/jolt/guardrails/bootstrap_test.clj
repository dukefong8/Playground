(ns jolt.guardrails.bootstrap-test
  (:require [jolt.guardrails.bootstrap]
            [clojure.test :refer [deftest is testing]]
            [com.fulcrologic.guardrails.malli.core :refer [=> >defn]]))

(>defn guarded-identity [value]
  [:int => :int]
  value)

(deftest guardrails-enabled-environment-variable
  (testing "GUARDRAILS_ENABLED controls Malli macro expansion"
    (is (= 42 (guarded-identity 42)))
    (if (jolt.guardrails.bootstrap/enabled?)
      (is (thrown-with-msg? Throwable #"should be an int"
            (guarded-identity "42")))
      (is (= "42" (guarded-identity "42"))))))
