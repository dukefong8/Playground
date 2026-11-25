(ns jolt.partial-cps-core-async-test
  "Edge cases of the is.simm.partial-cps.core-async adapter contract that
  upstream's own suite does not pin.

  Written to be portable on purpose, so the same file runs on a JVM. That is the
  point: a case that passes on the JVM and fails here is a port divergence, and
  one that fails on both is an upstream bug. Neither is a test to relax — if one
  of these goes red, the expectation is the thing to check against the docstring
  and the JVM, never the other way round."
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.core.async :refer [chan put! close! <!! promise-chan]]
            [is.simm.partial-cps.core-async :as ca]
            [is.simm.partial-cps.async :refer [async await]]))

(defn- closed-chan [v]
  (let [c (chan 1)] (put! c v) (close! c) c))

;; ---------------------------------------------------------------- predicates

(deftest chan?-covers-non-obvious-shapes
  (testing "nil is not a channel (the some? guard)"
    (is (false? (ca/chan? nil))))
  (testing "promise-chan satisfies ReadPort, so it counts"
    (is (true? (ca/chan? (promise-chan)))))
  (testing "a closed channel is still a channel"
    (let [c (chan 1)] (close! c) (is (true? (ca/chan? c))))))

(deftest error?-discriminates
  (is (false? (ca/error? nil)))
  (is (false? (ca/error? 42)))
  (is (false? (ca/error? "boom")))
  (is (true? (ca/error? (ex-info "boom" {}))))
  (is (true? (ca/error? (RuntimeException. "boom")))))

;; ------------------------------------------------------------- unwrap-result

(deftest unwrap-result-direct
  (testing "plain data passes through untouched"
    (is (= 5 (ca/unwrap-result 5))))
  (testing "the sentinel restores genuine nil without a channel round-trip"
    (is (nil? (ca/unwrap-result ca/sentinel-nil)))))

;; -------------------------------------------------------------------- ->chan

(deftest ->chan-closed-empty-channel-yields-nil
  (testing "taking off a closed, never-fed channel is nil, not an error"
    (let [c (chan 1)] (close! c)
      (is (nil? (ca/unwrap-result (<!! (ca/->chan c))))))))

(deftest ->chan-passes-channels-through-untouched
  (testing "zero-copy: the very same channel object comes back"
    (let [c (closed-chan 7)]
      (is (identical? c (ca/->chan c)))
      (is (= 7 (ca/unwrap-result (<!! (ca/->chan c))))))))

(deftest ->chan-non-throwable-values-resolve-as-data
  (testing "only Throwables route to raise; anything else is a datum"
    (is (= "oops" (ca/unwrap-result (<!! (ca/->chan (closed-chan "oops"))))))))

;; --------------------------------------------------------------------- ->cps

(deftest ->cps-await-nil-and-empty-async
  (testing "nil normalizes to an immediately-resolving CPS"
    (is (nil? (ca/unwrap-result (<!! (ca/->chan (async (await (ca/->cps nil)))))))))
  (testing "an empty async body resolves nil through the bridge"
    (is (nil? (ca/unwrap-result (<!! (ca/->chan (async))))))))

(deftest chan->cps-takes-exactly-once
  (testing "a buffered channel with several values yields the first take"
    (let [c (chan 3)]
      (put! c 1) (put! c 2) (put! c 3) (close! c)
      (is (= 1 (ca/unwrap-result (<!! (ca/->chan (async (await (ca/->cps c)))))))))))

;; -------------------------------------------------------------------- rewrap

(deftest rewrap-normalizes-plain-exceptions
  (testing "a non-ex-info Throwable keeps its message, gets empty ex-data,
            and is kept as cause"
    (let [orig   (RuntimeException. "plain")
          thrown (try (ca/unwrap-result
                       (<!! (ca/->chan (fn [_ raise] (raise orig)))))
                      (catch clojure.lang.ExceptionInfo e e))]
      (is (= "plain" (.getMessage thrown)))
      (is (= {} (ex-data thrown)))
      (is (identical? orig (.getCause thrown))))))

(deftest rewrap-falls-back-when-message-is-nil
  (testing "a nil-message ex-info keeps its ex-data and falls back to (str e)"
    (let [orig   (ex-info nil {:k 1})
          thrown (try (ca/unwrap-result
                       (<!! (ca/->chan (fn [_ raise] (raise orig)))))
                      (catch clojure.lang.ExceptionInfo e e))]
      (is (= (str orig) (.getMessage thrown)))
      (is (= {:k 1} (ex-data thrown)))
      (is (identical? orig (.getCause thrown))))))

;; --------------------------------------------------------------- sync-or-cps

(deftest sync-or-cps-falsy-opts-take-the-async-branch
  (testing "missing or empty opts wrap a channel as an await-able CPS"
    (is (= 5 (ca/unwrap-result (<!! (ca/->chan (async (await (ca/sync-or-cps (closed-chan 5) nil))))))))
    (is (= 5 (ca/unwrap-result (<!! (ca/->chan (async (await (ca/sync-or-cps (closed-chan 5) {}))))))))))

(deftest sync-or-cps-sync-passes-values-through
  (testing "sync path passes the materialized value, including nil"
    (is (= 5 (ca/sync-or-cps 5 {:sync? true})))
    (is (nil? (ca/sync-or-cps nil {:sync? true})))))
