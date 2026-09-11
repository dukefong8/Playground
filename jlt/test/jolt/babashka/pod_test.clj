(ns jolt.babashka.pod-test
  (:require [clojure.test :refer [deftest is]]
            [babashka.pods.impl :as pods-impl]
            [cheshire.core :as json]
            [cognitect.transit :as transit]))

(deftest json-compatibility
  (let [value {:op "invoke" :args [1 true nil]}]
    (is (= value
           (json/parse-string-strict (json/generate-string value) true)))))

(deftest transit-compatibility
  (let [value [{:db/valueType :db.type/string} #{:a :b}]
        out (java.io.ByteArrayOutputStream.)]
    (transit/write (transit/writer out :json) value)
    (is (= value
           (transit/read
            (transit/reader
             (java.io.ByteArrayInputStream. (.toByteArray out)) :json))))
    (is (= value
           (pods-impl/transit-json-read
            ::smoke
            (pods-impl/transit-json-write ::smoke value))))))
