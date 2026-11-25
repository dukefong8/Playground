(ns jolt.superv-fibers-test
  "superv.async running on Jolt's fiber backend (`clojure.core.async/*go-backend*`).

  JOLT-ONLY — unlike its sibling jolt.superv-async-test, this file cannot run on
  a JVM: JVM core.async has no *go-backend* and no jolt.fibers. Every case below
  was probed against the behaviors documented in
  https://jolt-lang.net/docs/fibers.html before being written down.

  Conventions used throughout: `with-fiber` binds the backend for the dynamic
  scope (the binding covers go blocks spawned by called functions too, since the
  var is read at spawn time). `<!!`/alt!!-based takes come from `S/<<??`, and any
  lazy drain is forced with `doall` INSIDE the `try` — realizing it while
  printing would throw outside the handler."
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.core.async :as a :refer [chan put! close! <!!]]
            [superv.async :as S]
            [jolt.fibers :as fib]))

(defmacro with-fiber
  "Run body with core.async go blocks spawning on fibers."
  [& body]
  `(binding [a/*go-backend* :fiber] ~@body))

(defn- fed-chan
  "Buffer-1 channel pre-fed with v and closed."
  [v]
  (doto (chan 1) (put! v) (close!)))

;; ------------------------------------------------- supervision on a fiber

(deftest go-try-and-<?-roundtrip-on-fiber
  (is (= 41 (with-fiber (<!! (S/go-try S/S (S/<? S/S (fed-chan 41))))))))

(deftest parking-works-through-helper-fns
  (testing "a <? hidden in a called function parks the fiber (impossible for
            the JVM state machine, which needs <! lexically in the go body)"
    (let [helper-take (fn [S ch] (S/<? S ch))]
      (is (= 41 (with-fiber
                  (<!! (S/go-try S/S (helper-take S/S (fed-chan 41))))))))))

(deftest blocking-take-inside-fiber-go
  (testing "on a fiber <!!/alts!! park rather than pin, so S/<?? is usable
            inside a go-try body"
    (is (= [7] (with-fiber (<!! (S/go-try S/S (S/<<?? S/S (fed-chan 7)))))))))

(deftest fan-in-ordered-take-on-fiber
  (testing "S/<?* takes one result per channel, in channel order"
    (is (= [1 2 3]
           (with-fiber
             (<!! (S/go-try S/S
                      (S/<?* S/S [(fed-chan 1) (fed-chan 2) (fed-chan 3)]))))))))

(deftest go-loop-try-accumulates-on-fiber
  (testing "go-loop-try with a <? per iteration"
    (is (= [0 1 2 3 4]
           (with-fiber
             (<!! (S/go-loop-try S/S [i 0 acc []]
                      (if (= i 5) acc (recur (inc i) (conj acc (S/<? S/S (fed-chan i))))))))))))

(deftest exception-tracking-across-fibers
  (testing "a throw inside a fiber go-try is tracked, delivered as a value,
            and rethrown with message + ex-data intact"
    (is (= [:caught "fiber-boom" {:k 9}]
           (with-fiber
             (let [c (S/go-try S/S (throw (ex-info "fiber-boom" {:k 9})))]
               (try (doall (S/<<?? S/S c))
                    (catch clojure.lang.ExceptionInfo e
                       [:caught (ex-message e) (ex-data e)]))))))))

(deftest go-monitor-sees-clean-finish
  (testing "superv.async converts the throw into a normal result value, so the
            underlying go completes cleanly and go-monitor reports nil"
    (is (= [:rethrown nil]
           (with-fiber
             (let [g (S/go-try S/S (throw (ex-info "mon-boom" {})))]
               [(try (doall (S/<<?? S/S g)) nil
                     (catch clojure.lang.ExceptionInfo _ :rethrown))
                (<!! (a/go-monitor g))])))
         "error value rethrows on take; monitor sees no abnormal death")))

(deftest timeout-parks-then-drains-nil
  (testing "parking on a timeout yields nil, which drains as an empty seq"
    (is (= '() (with-fiber (S/<<?? S/S (S/go-try S/S (S/<? S/S (a/timeout 50)))))))))

(deftest thread-try-feeds-fiber
  (testing "thread-try always uses a real OS thread; a fiber go-try consumes it"
    (is (= [:from-thread]
           (with-fiber
             (S/<<?? S/S (S/go-try S/S
                            (S/<? S/S (S/thread-try S/S (Thread/sleep 20) :from-thread)))))))))

(deftest locking-holds-across-park
  (testing "a monitor held across a <? keeps excluding: the second fiber runs
            only after the parked first one resumes and leaves"
    (is (= [:a-in :a-out :b]
           (with-fiber
             (let [lock (Object.) ch (chan) log (atom [])
                   a-done (S/go-try S/S (locking lock
                                          (swap! log conj :a-in)
                                          (S/<? S/S ch)
                                          (swap! log conj :a-out)))]
               (Thread/sleep 200)
               (let [b-done (S/go-try S/S (locking lock (swap! log conj :b)))]
                 (Thread/sleep 200)
                 (put! ch :go) (close! ch)
                 (<!! a-done) (<!! b-done)
                 @log)))))))

(deftest compute-bound-fiber-does-not-starve
  (testing "preemptive scheduling: a pure-computation go-try lets a queued
            go-try run; both complete"
    (is (= [:queued :spinner]
           (with-fiber
             (let [done (chan 2)]
               (S/go-try S/S (loop [i 0]
                               (if (< i 10000000) (recur (inc i)) (a/>! done :spinner))))
               (S/go-try S/S (a/>! done :queued))
                (sort [(S/<?? S/S done) (S/<?? S/S done)])))))))

;; ------------------------------------------------------- jolt.fibers itself

(deftest spawned-fiber-drives-superv
  (testing "a fib/spawn body can use blocking superv takes; join returns them"
    (is (= [:via-spawn]
            (fib/join (fib/spawn (fn [] (S/<<?? S/S (S/go-try S/S :via-spawn)))))))))

(deftest fiber-lifecycle
  (testing "a finished fiber reports :done and join returns its value"
    (let [f (fib/spawn (fn [] :done-fast))]
      (Thread/sleep 200)
      (is (= :done (fib/state f)))
      (is (= :done-fast (fib/join f))))))

(deftest fiber-monitor-delivers-error
  (testing "monitor! fires once with the death error"
    (let [p (promise)]
      (fib/monitor! (fib/spawn (fn [] (throw (ex-info "fib-boom" {}))))
                    (fn [e] (deliver p (ex-message e))))
      (is (= "fib-boom" (deref p 3000 :timeout))))))

(deftest fiber-join-timeout-gives-up
  (testing "join with a timeout returns the fallback instead of waiting"
    (is (= :not-yet (fib/join (fib/spawn (fn [] (Thread/sleep 500) :late)) 100 :not-yet)))))
