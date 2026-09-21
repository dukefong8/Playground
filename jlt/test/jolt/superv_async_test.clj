(ns jolt.superv-async-test
  "Contracts from superv.async's public API that its own suite does not reach.

  Its suite covers the go/supervision core (<?, <?-, go-try, go-super, the dataflow
  operators in its refer list) and leaves the rest of the namespace unexercised —
  the blocking twins, the callback ops, the exception-tracking protocol, most of
  the supervisor constructors, and the channel plumbing (tap, sub, engulf,
  debounce>>).

  Written to be portable on purpose, so the same file runs on a JVM. That is the
  point: a case that passes on the JVM and fails here is a port divergence, and
  one that fails on both is an upstream bug. Neither is a test to relax — if one
  of these goes red, the expectation is the thing to check against the docstring
  and the JVM, never the other way round."
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.core.async :as async :refer [<! >! chan close! go <!! >!! promise-chan]]
            [superv.async :as S]))

;; ---------------------------------------------------------------- predicates

(deftest chan?-discriminates
  (testing "chan? answers for channels and only channels"
    (is (true? (S/chan? (chan))))
    (is (true? (S/chan? (promise-chan))))
    (is (false? (S/chan? 42)))
    (is (false? (S/chan? "not a channel")))))

(deftest supervisor?-discriminates
  (is (true? (S/supervisor? S/S)))
  (is (true? (S/supervisor? (S/dummy-supervisor))))
  (is (false? (S/supervisor? 42)))
  (is (false? (S/supervisor? (chan)))))

(deftest check-supervisor-rejects-non-supervisors
  (is (nil? (S/check-supervisor S/S)))
  (is (thrown-with-msg? Exception
                        #"First argument is not a supervisor."
                        (S/check-supervisor 42))))

(deftest now-is-a-date
  (is (instance? java.util.Date (S/now))))

;; ------------------------------------------------------- the protocol itself

(deftest tracking-supervisor-protocol-round-trips
  (let [d (S/dummy-supervisor)]
    (testing "an id registered is the id unregistered"
      (let [id (S/-register-go d (fn [] :body))]
        (is (contains? @(:registered d) id))
        (S/-unregister-go d id)
        (is (not (contains? @(:registered d) id)))))
    (testing "a tracked exception is pending until freed"
      (let [e (ex-info "tracked" {})]
        (S/-track-exception d e)
        (is (= 1 (count @(:pending-exceptions d))))
        (S/-free-exception d e)
        (is (zero? (count @(:pending-exceptions d))))))
    (testing "the supervisor exposes channels for both of its ends"
      (is (some? (S/-error d)))
      (is (some? (S/-abort d))))))

;; ------------------------------------------------------------- blocking ops

(deftest <??--returns-values-and-throws-exceptions
  (testing "a plain value comes back"
    (let [c (chan 1)] (>!! c :v) (is (= :v (S/<??- c)))))
  (testing "an exception value is thrown, not returned"
    (let [c (chan 1)] (>!! c (ex-info "boom" {}))
      (is (thrown-with-msg? Exception #"boom" (S/<??- c))))))

(deftest throw-if-exception-passes-and-throws
  (is (= :ok (S/throw-if-exception S/S :ok)))
  (is (= :ok (S/throw-if-exception- :ok)))
  (is (thrown-with-msg? Exception #"boom"
                        (S/throw-if-exception S/S (ex-info "boom" {}))))
  (is (thrown-with-msg? Exception #"b2"
                        (S/throw-if-exception- (ex-info "b2" {})))))

;; ------------------------------------------------------- callback channel ops

(deftest take?-delivers-and-frees-the-exception
  (let [d (S/dummy-supervisor)
        c (chan 1)
        e (ex-info "tracked" {})
        got (promise)]
    (S/-track-exception d e)
    (>!! c e)
    (S/take? d c #(deliver got %))
    (is (= e (deref got 1000 ::timeout)))
    (testing "a taken exception is no longer pending — it has been delivered"
      (is (zero? (count @(:pending-exceptions d)))))))

(deftest put?-tracks-an-exception-passed-as-a-value
  (let [d (S/dummy-supervisor)
        c (chan 1)
        e (ex-info "tracked" {})
        got (promise)]
    (S/put? d c e #(deliver got %))
    (is (true? (deref got 1000 ::timeout)))
    (is (= 1 (count @(:pending-exceptions d))))
    (is (= e (<!! c)))))

;; ------------------------------------------------------------- supervisor ends

(deftest <?-aborts-when-the-supervisor-aborts
  (let [ab (promise-chan)
        d (S/map->TrackingSupervisor {:error (chan) :aborts [ab]
                                      :registered (atom {})
                                      :pending-exceptions (atom {})})
        f (go (try (S/<? d (chan)) (catch Exception e
                                     (:type (ex-data e)))))]
    (close! ab)
    (is (= :aborted (<!! f)))))

(deftest wrap-abort!-yields-the-abort-exception-instead-of-its-body
  (testing "not aborted: the body runs"
    (is (= :ran (<!! (go (S/wrap-abort! S/S :ran))))))
  (testing "aborted: it returns the :aborted ex-info rather than running the body"
    (let [ab (promise-chan)
          d (S/map->TrackingSupervisor {:error (chan) :aborts [ab]
                                        :registered (atom {})
                                        :pending-exceptions (atom {})})
          f (go (S/wrap-abort! d :ran))]
      (close! ab)
      (is (= :aborted (:type (ex-data (<!! f))))))))

(deftest try<?-and-try<??-catch-what-the-channel-throws
  (testing "try<? in a go block"
    (is (= "boom" (<!! (go (S/try<? S/S (go (ex-info "boom" {}))
                                     (catch Exception e
                                       (ex-message e))))))))
  (testing "try<?? blocks"
    (let [c (chan 1)] (>!! c (ex-info "b2" {}))
      (is (= "b2" (S/try<?? S/S c (catch Exception e
                                 (ex-message e))))))))

;; -------------------------------------------------------------- dataflow

(deftest go-loop-try--loops-unsupervised
  (testing "loop bindings recur and the final value is delivered"
    (is (= 10 (<!! (S/go-loop-try- [i 0 acc 0]
                      (if (< i 5) (recur (inc i) (+ acc i)) acc))))))
  (testing "the expansion carries the S symbol, not the live supervisor value"
    ;; go-loop-try- takes no supervisor argument; it must splice the symbol
    ;; so the reference resolves at runtime. Splicing the var's value embeds
    ;; a TrackingSupervisor (channels, atoms) in the form, which the JVM
    ;; tolerates as a constant but Jolt cannot compile into code.
    (let [[op s _] (macroexpand-1 '(superv.async/go-loop-try- [i 0] i))]
      (is (= 'superv.async/go-try- op))
      (is (= 'superv.async/S s)))))

(deftest reduce<?--reduces-with-plain-and-go-functions
  ;; reduce<?- returns a channel (it is go-try- around a blocking loop), so both
  ;; cases have to be read out of it.
  (testing "a plain reducing fn"
    (is (= 10 (<!! (S/reduce<?- (fn [acc x] (+ acc x)) 0 (range 5))))))
  (testing "a go-returning reducing fn is awaited, not accumulated as a channel"
    (is (= 6 (<!! (S/reduce<?- (fn [acc x] (go (+ acc x))) 0 [1 2 3]))))))

(deftest reduce>-reduces-a-channel
  (let [in (chan 8)]
    (go (doseq [x [1 2 3]] (>! in x)) (close! in))
    (is (= 6 (<!! (S/reduce> S/S (fn [acc x] (go (+ acc x))) 0 in))))))

(deftest <!*-takes-one-from-each-channel-in-order
  (is (= [1 2] (<!! (go (let [a (chan 1) b (chan 1)]
                          (>! a 1) (>! b 2)
                          (close! a) (close! b)
                          (S/<!* [a b])))))))

(deftest engulf-drains-and-closes
  (let [a (chan 2) b (chan 2)]
    (go (>! a 1) (close! a) (>! b 2) (close! b))
    (is (nil? (<!! (S/engulf S/S a b))))))

(deftest debounce>>-throttles-to-one-per-interval
  (testing "items spaced beyond the interval all come through"
    (let [in (chan 8)
          out (S/debounce>> S/S in 50)
          ;; Consume concurrently, via a go, rather than reading out after the
          ;; fact. debounce>>'s output is unbuffered, so a late reader lets the
          ;; producer block; by the time it is drained the input has closed, and
          ;; the closed input wins alts? against the pending timer and drops the
          ;; last value. A test that read it late would assert [1] and be
          ;; measuring its own harness rather than the debouncer.
          got (async/into [] out)]
      (>!! in 1) (Thread/sleep 120)
      (>!! in 2) (Thread/sleep 120)
      (close! in)
      (is (= [1 2] (<!! got))))))

(deftest tap-and-sub-deliver
  (testing "tap on a mult"
    (let [src (chan 4) m (async/mult src) t (chan 4)]
      (S/tap S/S m t)
      (>!! src :x)
      (is (= :x (<!! t)))))
  (testing "sub on a pub"
    (let [src (chan 4) p (async/pub src :topic) t (chan 4)]
      (S/sub S/S p :topic t)
      (>!! src {:topic :topic :v 1})
      (is (= {:topic :topic :v 1} (<!! t))))))

;; ------------------------------------------------------------ constructors

(deftest simple-supervisor-is-a-supervisor
  (let [s (S/simple-supervisor :error-fn (fn [_]))]
    (is (true? (S/supervisor? s)))
    (is (nil? (S/check-supervisor s)))
    (is (some? (S/-error s)))))
