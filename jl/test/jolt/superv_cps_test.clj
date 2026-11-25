(ns jolt.superv-cps-test
  "Coverage for superv.async.partial-cps, the native supervision half of the
  partial-cps bridge: abort-racing takes, supervised CPS channels, and
  tracking-aware unwrapping.

  Written to be portable on purpose, so the same file runs on a JVM. That is
  the point: a case that passes on the JVM and fails here is a port
  divergence, and one that fails on both is an upstream bug. Neither is a test
  to relax — if one of these goes red, the expectation is the thing to check
  against the docstring and the JVM, never the other way round."
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.core.async :as a :refer [chan put! close! <!!]]
            [superv.async :as S]
            [superv.async.partial-cps :as scps]
            [is.simm.partial-cps.async :refer [async await]]
            [is.simm.partial-cps.core-async :as ca]))

(defn- fed-chan
  "Buffer-1 channel pre-fed with v and closed."
  [v]
  (doto (chan 1) (put! v) (close!)))

(defn- test-supervisor
  "Fresh supervisor with a single deterministic abort channel. Note the
   plural :aborts — the record field is a collection; singular :abort leaves
   a nil abort channel that alts! hangs on."
  []
  (let [abort (chan)]
    {:sup (S/map->TrackingSupervisor {:error (chan) :aborts [abort]
                                      :registered (atom {}) :pending-exceptions (atom {})})
     :abort abort}))

;; ---------------------------------------------------------------- stake-cps

(deftest stake-resolves-data
  (testing "a ready channel resolves through an awaited stake-cps"
    (let [{:keys [sup]} (test-supervisor)]
      (is (= 9 (ca/unwrap-result (<!! (ca/->chan (async (await (scps/stake-cps sup (fed-chan 9))))))))))))

(deftest stake-abort-raises
  (testing "aborting mid-await raises instead of hanging (the gap vs ->cps)"
    (let [{:keys [sup abort]} (test-supervisor)
          hanging (chan)]
      (a/go (a/<! (a/timeout 150)) (close! abort))
      (is (= [:aborted "Aborted operations" :aborted]
             (try (ca/unwrap-result (<!! (ca/->chan (async (await (scps/stake-cps sup hanging))))))
                  :hung
                  (catch clojure.lang.ExceptionInfo e
                    [:aborted (ex-message e) (:type (ex-data e))])))))))

(deftest stake-error-reraise
  (testing "an error value taken off the channel rethrows with message +
            ex-data, tracking untouched"
    (let [{:keys [sup]} (test-supervisor)
          err-ch (doto (chan 1) (put! (ex-info "stake-boom" {:k 3})) (close!))]
      (is (= [:caught "stake-boom" {:k 3} 0]
             (try (ca/unwrap-result (<!! (ca/->chan (async (await (scps/stake-cps sup err-ch))))))
                  (catch clojure.lang.ExceptionInfo e
                    [:caught (ex-message e) (ex-data e) (count @(:pending-exceptions sup))])))))))

(deftest stake-rejects-non-channels
  (testing "anything but a channel fails fast instead of hanging a go on alts!"
    (let [{:keys [sup]} (test-supervisor)]
      (is (thrown? AssertionError (scps/stake-cps sup 42)))
      (is (thrown? AssertionError (scps/stake-cps sup (fn [_ _])))))))

;; ----------------------------------------------------------- supervised-chan

(deftest supervised-registers-during-flight
  (testing "the computation is registered while in flight, gone after"
    (let [{:keys [sup]} (test-supervisor)
          gate (atom nil)
          c (scps/supervised-chan sup (fn [resolve _] (reset! gate resolve)))]
      (is (true? (pos? (count @(:registered sup)))))
      (@gate :v)
      (<!! c)
      (is (zero? (count @(:registered sup)))))))

(deftest supervised-tracks-raises
  (testing "a raise is tracked, delivered, and unregistered"
    (let [{:keys [sup]} (test-supervisor)]
      (is (= ["tracked" 1 0]
             (try (ca/unwrap-result (<!! (scps/supervised-chan sup (fn [_ raise] (raise (ex-info "tracked" {:k 2}))))))
                  (catch clojure.lang.ExceptionInfo e
                    [(ex-message e) (count @(:pending-exceptions sup)) (count @(:registered sup))])))))))

(deftest supervised-skips-aborted-tracking
  (testing "aborted raises still raise, but are never tracked (go-try rule)"
    (let [{:keys [sup]} (test-supervisor)]
      (is (= [:aborted 0]
             (try (ca/unwrap-result (<!! (scps/supervised-chan sup (fn [_ raise] (raise (ex-info "Aborted operations" {:type :aborted}))))))
                  (catch clojure.lang.ExceptionInfo e
                    [:aborted (count @(:pending-exceptions sup))])))))))

(deftest supervised-passes-values-through
  (testing "non-CPS input goes straight to ca/->chan unsupervised"
    (let [{:keys [sup]} (test-supervisor)]
      (is (= [42 0]
             [(ca/unwrap-result (<!! (scps/supervised-chan sup 42)))
              (count @(:registered sup))])))))

;; ------------------------------------------------------------- unwrap-result

(deftest unwrap-frees-tracked-errors
  (testing "a tracked error rethrows and leaves pending clean"
    (let [{:keys [sup]} (test-supervisor)
          e (ex-info "free-me" {})]
      (S/-track-exception sup e)
      (is (= [1 "free-me" 0]
             [(count @(:pending-exceptions sup))
              (try (scps/unwrap-result sup e)
                   (catch clojure.lang.ExceptionInfo x (ex-message x)))
              (count @(:pending-exceptions sup))]))))
  (testing "plain data passes through untouched"
    (let [{:keys [sup]} (test-supervisor)]
      (is (= 5 (scps/unwrap-result sup 5))))))

;; --------------------------------------------------------------- full loop

(deftest full-loop-stake-async-supervised-unwrap
  (testing "stake -> async -> supervised-chan -> unwrap preserves a superv
            error end to end with supervision books at zero"
    (let [{:keys [sup]} (test-supervisor)
          src (S/go-try sup (throw (ex-info "full-loop" {:n 1})))]
      (is (= [[:caught "full-loop" {:n 1}] 0 0]
             (try (scps/unwrap-result sup (<!! (scps/supervised-chan sup (fn [resolve raise] ((scps/stake-cps sup src) resolve raise)))))
                  (catch clojure.lang.ExceptionInfo e
                    [[:caught (ex-message e) (ex-data e)]
                     (count @(:pending-exceptions sup))
                     (count @(:registered sup))])))))))
