(ns jolt.superv-partial-cps-fibers-test
  "Three-way integration: superv.async supervision (go-try / <? / exceptions)
  composed with partial-cps async/await, all running on Jolt's fiber backend.

  JOLT-ONLY — JVM core.async has no *go-backend* and no jolt.fibers, so this
  file cannot run on the JVM oracle. Every case was probed live before being
  written down.

  Two behaviors from the fibers doc are pinned here deliberately:
  - parking works through function calls (a <? / await / blocking take hidden
    in a called helper parks the fiber; the JVM state machine could never do
    this);
  - <! and <!! (and alts! / alts!!) are the same parking operation on a fiber,
    so both spellings are used inside go-try bodies and asserted equal."
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.core.async :as a :refer [chan put! close! <! <!!]]
            [superv.async :as S]
            [is.simm.partial-cps.async :refer [async await]]
            [is.simm.partial-cps.core-async :as ca]))

(defmacro with-fiber
  "Run body with core.async go blocks spawning on fibers."
  [& body]
  `(binding [a/*go-backend* :fiber] ~@body))

(defn- fed-chan
  "Buffer-1 channel pre-fed with v and closed."
  [v]
  (doto (chan 1) (put! v) (close!)))

(defn- superv-take
  "Parking take hidden one call deep: S/<? inside a plain function."
  [S ch]
  (S/<? S ch))

(defn- cps-take
  "Blocking take of a bridged async hidden one call deep."
  [ch]
  (<!! (ca/->chan (async (await (ca/->cps ch))))))

;; ------------------------------------------------- the three layers together

(deftest async-inside-go-try-on-fiber
  (testing "a partial-cps async block nested in a superv go-try body"
    (is (= [11]
           (with-fiber
             (S/<<?? S/S (S/go-try S/S (<!! (ca/->chan (async (await (ca/->cps (fed-chan 11)))))))))))))

(deftest superv-error-crosses-cps-bridge
  (testing "superv throw -> go-try value -> CPS raise -> async error path ->
            ->chan error -> S/<?? rethrow, message + ex-data intact throughout"
    (is (= [:caught "deep-boom" {:layer :superv}]
           (with-fiber
             (let [failing (S/go-try S/S (throw (ex-info "deep-boom" {:layer :superv})))]
               (try (doall (S/<<?? S/S (ca/->chan (async (await (ca/->cps failing))))))
                    (catch clojure.lang.ExceptionInfo e
                      [:caught (ex-message e) (ex-data e)]))))))))

(deftest take-op-equivalence-on-fiber
  (testing "<! and <!! inside a fiber go-try take the same value"
    (is (= [[:a] [:b]]
           (with-fiber
             [(S/<<?? S/S (S/go-try S/S (<! (fed-chan :a))))
              (S/<<?? S/S (S/go-try S/S (<!! (fed-chan :b))))])))))

(deftest parking-through-nested-helpers
  (testing "one go-try parks through two helpers: S/<? in one, a blocking
            bridged-async take in the other"
    (is (= [[:l2 :l3]]
           (with-fiber
             (S/<<?? S/S (S/go-try S/S [(superv-take S/S (fed-chan :l2))
                                        (cps-take (fed-chan :l3))])))))))

(deftest alts-bang-bang-parks-on-fiber
  (testing "alts!! is the same parking op on a fiber: racing a bridged async
            against a timeout resolves the ready side"
    (is (= [:won]
           (with-fiber
              (S/<<?? S/S (S/go-try S/S (let [[v _] (a/alts!! [(ca/->chan (async :won)) (a/timeout 500)])] v))))))))
