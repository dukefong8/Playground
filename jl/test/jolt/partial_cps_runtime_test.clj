(ns jolt.partial-cps-runtime-test
  "Contracts for is.simm.partial-cps.runtime's trampoline and binding helpers,
  which upstream's own suite never touches directly.

  Written to be portable on purpose, so the same file runs on a JVM. That is the
  point: a case that passes on the JVM and fails here is a port divergence, and
  one that fails on both is an upstream bug. Neither is a test to relax — if one
  of these goes red, the expectation is the thing to check against the docstring
  and the JVM, never the other way round."
  (:require [clojure.test :refer [deftest is testing]]
            [is.simm.partial-cps.runtime :as r]))

(def ^:dynamic *probe* 1)

(deftest thunk-round-trips
  (is (true? (r/thunk? (r/->thunk (fn [] 1)))))
  (is (true? (r/thunk? (r/->Thunk (fn [] 1)))))
  (is (false? (r/thunk? 42)))
  (is (false? (r/thunk? nil)))
  (is (= 7 (r/force-thunk (r/->thunk (fn [] 7))))))

(deftest bound-fn-conveys-bindings
  (testing "root value at capture time"
    (is (= 1 ((r/bound-fn (fn [] *probe*))))))
  (testing "a fn captured under binding sees the bound value after the binding exits"
    (let [f (binding [*probe* 99]
              (r/bound-fn (fn [] *probe*)))]
      (is (= 1 *probe*))
      (is (= 99 (f))))))
