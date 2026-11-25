(ns jolt.partial-cps-fibers-test
  "partial-cps bridged to core.async running on Jolt's fiber backend
  (`clojure.core.async/*go-backend*`).

  JOLT-ONLY — like its sibling jolt.superv-fibers-test, this file cannot run on
  a JVM: JVM core.async has no *go-backend* and no jolt.fibers. Every case below
  was probed live before being written down.

  On the docs question of whether the two parking styles (closure-rewritten
  direct parks vs continuation-capturing parks inside calls/try/alts!) interfere
  with partial-cps: they cannot by construction. The adapter never parks — both
  directions are built on non-parking `take!`/`put!`, so the per-site choice
  never touches adapter code. It only ever applies to consumer-side `go` blocks,
  where the docs guarantee identical semantics; `both-park-styles-agree`
  pins that guarantee through the bridge.

  Deliberately NOT covered here: awaiting take!-resolved channels inside a
  CPS-transformed loop (doseq/loop). That shape hangs backend-independently
  (reproduced on `:thread` too), so it is upstream partial-cps scope, not fiber
  scope. Loop-free sequential awaits are used instead."
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.core.async :as a :refer [chan put! close! <!!]]
            [is.simm.partial-cps.async :refer [async await]]
            [is.simm.partial-cps.core-async :as ca]
            [is.simm.partial-cps.sequence :as seq]
            [jolt.fibers :as fib]))

(defmacro with-fiber
  "Run body with core.async go blocks spawning on fibers."
  [& body]
  `(binding [a/*go-backend* :fiber] ~@body))

(defn- fed-chan
  "Buffer-1 channel pre-fed with v and closed."
  [v]
  (doto (chan 1) (put! v) (close!)))

(defn- take-one
  "Plain-function take: a park inside a called function, i.e. the capturing
   style from the fibers doc."
  [ch]
  (a/<! ch))

;; ------------------------------------------------- bridge under the backend

(deftest fiber-fed-channel-awaited
  (testing "a channel fed by a fiber go block awaits cleanly inside async"
    (is (= 41
           (with-fiber
             (let [c (chan 1)]
               (a/go (a/>! c 41))
               (ca/unwrap-result (<!! (ca/->chan (async (await (ca/->cps c))))))))))))

(deftest chan-consumed-with-park-in-fiber-go
  (testing "->chan output parks a fiber go with <! "
    (is (= 42
           (with-fiber
             (<!! (a/go (a/<! (ca/->chan (async 42))))))))))

(deftest blocking-take-parks-in-fiber-go
  (testing "on a fiber <!! parks like <!, so it works inside go"
    (is (= 7
           (with-fiber
             (<!! (a/go (<!! (ca/->chan (async (await (ca/->cps (fed-chan 7)))))))))))))

(deftest raise-crosses-bridge-on-fiber
  (testing "a raise inside async rethrows across ->chan with message + ex-data"
    (is (= [:caught "fiber-raise" {:k 1}]
           (with-fiber
             (try (ca/unwrap-result (<!! (ca/->chan (async (await (ca/->cps (fn [_ raise] (raise (ex-info "fiber-raise" {:k 1})))))))))
                  (catch clojure.lang.ExceptionInfo e
                    [:caught (ex-message e) (ex-data e)])))))))

(deftest nil-survives-bridge-on-fiber
  (testing "genuine nil round-trips through the sentinel under the backend"
    (is (nil? (with-fiber
                (ca/unwrap-result (<!! (ca/->chan (async (await (ca/->cps nil)))))))))))

(deftest timeout-channel-unwraps-to-nil
  (testing "a timeout channel (closes with no value) parks then unwraps to nil"
    (is (nil? (with-fiber
                (ca/unwrap-result (<!! (ca/->chan (async (await (ca/->cps (a/timeout 30))))))))))))

(deftest sequential-awaits-on-fiber
  (testing "several loop-free awaits resolve in order"
    (is (= [1 2 3]
           (with-fiber
             (ca/unwrap-result
              (<!! (ca/->chan (async [(await (ca/->cps (fed-chan 1)))
                                      (await (ca/->cps (fed-chan 2)))
                                      (await (ca/->cps (fed-chan 3)))])))))))))

(deftest both-park-styles-agree-through-bridge
  (testing "rewritten direct parks, capturing try-nested parks, and capturing
            helper-fn parks all deliver the same bridged value"
    (is (= [:v :v :v]
           (with-fiber
             (let [mk (fn [] (ca/->chan (async :v)))]
               [(<!! (a/go (let [v (a/<! (mk))] v)))
                (<!! (a/go (try (a/<! (mk)) (catch Exception _ :caught))))
                (<!! (a/go (take-one (mk))))]))))))

(deftest thread-fed-channel-awaited
  (testing "an OS-thread producer (a/thread) feeds an await under the backend"
    (is (= :from-thread
           (with-fiber
             (ca/unwrap-result (<!! (ca/->chan (async (await (ca/->cps (a/thread (Thread/sleep 20) :from-thread))))))))))))

(deftest sequence-composes-on-fiber
  (testing "async sequence ops compose with the bridge on a fiber go"
    (is (= [2 3 4]
           (with-fiber
             (<!! (a/go (a/<! (ca/->chan (async (await (seq/into [] (seq/sequence (map inc) [1 2 3])))))))))))))

(deftest spawned-fiber-drives-bridge
  (testing "a fib/spawn body can block-take a bridged async; join returns it"
    (is (= :via-spawn
           (fib/join (fib/spawn (fn [] (ca/unwrap-result (<!! (ca/->chan (async :via-spawn)))))))))))
