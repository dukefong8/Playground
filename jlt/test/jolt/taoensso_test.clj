(ns jolt.taoensso-test
  "Regression coverage for `jolt.taoensso`'s java.util.Stack seam.

  The seam exists because tufte's per-thread profiling state is a
  `java.util.Stack`, which Jolt does not model: every `profiled` form ends in a
  `pdata-local-pop`, so the FIRST profile of any kind realizes the ThreadLocal's
  `(java.util.Stack.)` initial value and dies with

      No matching ctor found for class java.util.Stack

  `jolt.bench-runner` hit exactly that. The tests below pin both halves of the seam —
  the constructor, and the push/pop round trip the nesting exists for — through
  tufte's own `profiled`, so the assertion is on the unmodified library."
  (:require [clojure.test :refer [deftest is testing]]
            [jolt.taoensso]
            [taoensso.tufte :as tufte]))

(deftest the-stack-constructor-is-registered
  (testing "the ctor Jolt does not model"
    (let [s (java.util.Stack.)]
      (is (true? (.empty s)) "a fresh Stack is empty")
      (.push s :only)
      (is (= 1 (.size s)))
      (is (false? (.empty s)))
      (is (= :only (.pop s)) "LIFO")
      (is (true? (.empty s)) "and drains back to empty"))))

(deftest profiled-round-trips-the-pdata-stack
  (testing "the unmodified `profiled` — the call that used to raise"
    (let [[result pstats] (tufte/profiled {:dynamic? false}
                            (tufte/p :work (* 6 7)))]
      (is (= 42 result))
      ;; `second` is unrealized: deref yields the RealizedPStats record carrying
      ;; {:clock … :stats …}. Same two steps jolt.bench-runner's own reader takes.
      (is (= [:work] (mapv key (:stats @pstats)))
          "the profile recorded its one p id"))))

(deftest nested-profiling-pushes-and-pops
  (testing "nesting is what drives .push, and the outer pdata must survive .pop"
    (let [inner (atom nil)
          [result pstats] (tufte/profiled {:dynamic? false}
                            (tufte/p :outer
                              (let [[v inner-ps] (tufte/profiled {:dynamic? false}
                                                   (tufte/p :inner 7))]
                                (reset! inner [v (mapv key (:stats @inner-ps))])
                                v)))]
      (is (= 7 result))
      (is (= [7 [:inner]] @inner) "the inner profile ran and recorded")
      (is (= [:outer] (mapv key (:stats @pstats)))
          "the interrupted pdata was restored, so :outer lands in the outer"))))
