(ns goose.export-abi
  "Babashka port of `jl/test/goose/export_abi.clj`: the same five suites over
  the goose export ABI, driven through `babashka.ffi`.

  The three goose samples are combined into `../gs/export_abi.goose` and
  built as ONE dylib by the `goose-lib` task, because goose_init resolves to
  the first library loaded in a process.

  Every type's C shape comes from the generated `../gs/export_abi.h`, which
  wraps all types in `#pragma pack(push, 1)`. babashka.ffi layouts use natural
  alignment and cannot express packing, so a packed value crosses as a run of
  :uint8 fields at byte offsets. The exception is `Mixed`, whose register
  classification depends on member types: it uses the real field types
  `[:struct [[:g :double] [:f :float]]]`. Packed offsets (g at 0, f at 8) agree
  with the natural ones, so the descriptor applies even though its size is 16
  rather than the packed 12.

  Four host differences from the Jolt suite:

  - babashka.ffi returns a struct by value as a map and takes one as a map, so
    the `abi_*_make` results are read by writing the map into a buffer instead
    of Jolt's leading out-pointer convention.
  - A native SIGSEGV aborts the babashka process (exit 99). It cannot be
    turned into an exception, so the two off-thread fault probes run in a
    fresh `bb -e` process and assert the crash.
  - `:uint64` arguments are Clojure longs, so 18000000000000000000 crosses as
    its signed bit pattern and comes back signed.
  - Jolt fibers become `future`s, and the thread matrix also covers raw
    platform threads, virtual threads, and core.async go blocks. With
    core.async 1.8.741 a go block runs on a virtual thread. The ownership rule
    is the same in every context: value-only exports work, heap and goose
    worker exports fault."
  (:require [babashka.ffi :as ffi]
            [babashka.process :as process]
            [clojure.core.async :as async]
            [clojure.test :refer [deftest is testing use-fixtures]]))

;; ------------------------------------------------------------------
;; Process helpers: build the library, check compiler rejections, drive nREPL.

(defn- sh
  "Runs a command with stdout and stderr merged into a string. Kills it and
  reports ::timeout instead of hanging when it does not exit."
  [& args]
  (let [proc (apply process/process {:out :string :err :string} args)
        exit (deref (future (.waitFor (:proc proc))) 60000 ::timeout)]
    (if (= ::timeout exit)
      (do (process/destroy-tree proc) {:exit ::timeout :out "timed out"})
      {:exit exit :out (str @(:out proc) @(:err proc))})))

(def ^:private lib
  (ffi/load-library {:mac "../gs/libexport_abi.dylib"
                     :linux "../gs/libexport_abi.so"}))

(defn- cfn [c-name argtypes ret] (ffi/cfn lib c-name argtypes ret))

;; ------------------------------------------------------------------
;; Bindings. All three samples share this one goose_init.

(def ^:private goose-init (cfn "goose_init" [:int :pointer] :void))
(def ^:private goose-exit (cfn "goose_exit" [] :void))

;; The contained interpreter (from goose/19_vm.goose).
(def ^:private slice-layout [:struct [[:data :pointer] [:len :int64]]])
(def ^:private vm-run (cfn "goose_vm_run" [slice-layout] :int64))
(def ^:private vm-try-run (cfn "goose_vm_try_run" [slice-layout] :int64))
(def ^:private vm-last-abort (cfn "goose_vm_last_abort" [:pointer] :pointer))

;; Value-only exports — what may be called from a foreign thread.
(def ^:private sc-add (cfn "sc_add" [:int64 :int64] :int64))
(def ^:private sc-fib (cfn "sc_fib" [:int64] :int64))
(def ^:private sc-fixed-array (cfn "sc_fixed_array" [:int64] :int64))
(def ^:private sc-sum-stack (cfn "sc_sum_stack" [:int64] :int64))
(def ^:private sc-sum-slice (cfn "sc_sum_slice" [slice-layout] :int64))
(def ^:private sc-in-worker (cfn "sc_thread_double" [:int64] :int64))
(def ^:private sc-worker-fail (cfn "sc_thread_fail" [:int64] :int64))

;; One export per shape that may cross C.

(def ^:private i8  (cfn "abi_i8"  [:int8]   :int8))
(def ^:private u8  (cfn "abi_u8"  [:uint8]  :uint8))
(def ^:private i16 (cfn "abi_i16" [:int16]  :int16))
(def ^:private u16 (cfn "abi_u16" [:uint16] :uint16))
(def ^:private i32 (cfn "abi_i32" [:int32]  :int32))
(def ^:private u32 (cfn "abi_u32" [:uint32] :uint32))
(def ^:private i64 (cfn "abi_i64" [:int64]  :int64))
(def ^:private u64 (cfn "abi_u64" [:uint64] :uint64))
(def ^:private f32 (cfn "abi_f32" [:float]  :float))
(def ^:private f64 (cfn "abi_f64" [:double] :double))
(def ^:private not- (cfn "abi_not" [:uint8] :uint8))

;; goose packs every struct; a packed value is described as N one-byte fields
;; and written at byte offsets.
(defn- packed-layout [n]
  [:struct (mapv (fn [i] [(keyword (str "b" i)) :uint8]) (range n))])

(def ^:private pair-layout (packed-layout 12))
(def ^:private arr-layout (packed-layout 16))
(def ^:private static-layout (packed-layout 17))
(def ^:private shape-layout (packed-layout 17))
(def ^:private color-layout (packed-layout 1))

;; Mixed crosses by value only with its real field types: a :uint8 run would
;; arrive in general-purpose registers while C reads the float member as SSE.
(def ^:private mixed-layout [:struct [[:g :double] [:f :float]]])

;; Reading the packed Pair bytes with a natural declaration-order layout must
;; NOT give the same fields: that is the proof the packed layout is what crosses.
(def ^:private pair-natural [:struct [[:a :int32] [:b :int64]]])

(def ^:private pair-sum (cfn "abi_pair_sum" [pair-layout] :int64))
(def ^:private mixed-sum (cfn "abi_mixed_sum" [mixed-layout] :double))
(def ^:private arr-sum (cfn "abi_arr_sum" [arr-layout] :int64))
(def ^:private static-sum (cfn "abi_static_sum" [static-layout] :int64))
(def ^:private grid-sum (cfn "abi_grid_sum" [arr-layout] :int64))
(def ^:private shape-area (cfn "abi_shape_area" [shape-layout] :double))

(def ^:private arr-make (cfn "abi_arr_make" [] arr-layout))
(def ^:private pair-make (cfn "abi_pair_make" [:int32 :int64] pair-layout))
(def ^:private shape-make (cfn "abi_shape_make" [:double :double] shape-layout))

(def ^:private color-next (cfn "abi_color_next" [color-layout] color-layout))

(def ^:private pair-shift (cfn "abi_pair_shift" [:pointer :int32] :void))
(def ^:private arr-bump (cfn "abi_arr_bump" [:pointer] :void))
(def ^:private grid-bump (cfn "abi_grid_bump" [:pointer] :void))
(def ^:private shape-grow (cfn "abi_shape_grow" [:pointer] :void))
(def ^:private color-advance (cfn "abi_color_advance" [:pointer] :void))

(def ^:private i32-sum (cfn "abi_i32_sum_slice" [slice-layout] :int64))
(def ^:private pair-sum-of (cfn "abi_pair_sum_slice" [slice-layout] :int64))
(def ^:private const-sum (cfn "abi_const_i32_sum" [slice-layout] :int64))
(def ^:private shape-sum (cfn "abi_shape_sum" [slice-layout] :double))
(def ^:private color-of (cfn "abi_color_of" [slice-layout :int64] color-layout))

(def ^:private hello (cfn "abi_hello" [:pointer] :pointer))

;; ------------------------------------------------------------------
;; Helpers for the VM assembler and the packed C values.

(def ^:private stride 9)
(def ^:private max-ops 256)
(def ^:private op-tags
  {:push 0 :load 1 :store 2 :add 3 :sub 4 :mul 5
   :dup 6 :jump 7 :jump-if-zero 8 :print 9 :halt 10})

(defn- write-op! [base i instr]
  (let [tag (or (get op-tags (get instr :op))
                (throw (ex-info "unknown op" {:instruction instr})))
        at (* i stride)]
    (ffi/write base :uint8 tag at)
    (case (get instr :op)
      :push (ffi/write base :int64 (get instr :v) (inc at))
      (:load :store) (ffi/write base :uint8 (get instr :v) (inc at))
      (:jump :jump-if-zero) (ffi/write base :uint16 (get instr :v) (inc at))
      nil)))

(defn- vm-slice [arena ops]
  (let [n (count ops)
        base (ffi/alloc arena (* n stride))]
    (doseq [[i instr] (map-indexed vector ops)] (write-op! base i instr))
    {:data base :len n}))

(defn- bytes->string [p n]
  (let [s (ffi/reinterpret p n)]
    (apply str (map #(char (ffi/read s :uint8 %)) (range n)))))

(defn- last-abort []
  (with-open [a (ffi/confined-arena)]
    (let [lp (ffi/alloc a :int64)
          p (vm-last-abort lp)
          n (ffi/read lp :int64)]
      (when (pos? n) (bytes->string p n)))))

(defn- run-program [ops]
  (with-open [a (ffi/confined-arena)]
    (let [n (long (vm-try-run (vm-slice a ops)))]
      (if (neg? n)
        (throw (ex-info (if (= -1 n)
                          (str "goose aborted: " (last-abort))
                          (str "program has " (count ops) " instructions, limit is " max-ops))
                        {:status n :abort (when (= -1 n) (last-abort))}))
        n))))

(defn- run-program-unchecked [ops]
  (with-open [a (ffi/confined-arena)] (vm-run (vm-slice a ops))))

(def countdown
  (-> [{:op :push :v 3} {:op :store :v 0}
       {:op :load :v 0} {:op :jump-if-zero :v 10}
       {:op :load :v 0} {:op :print}
       {:op :load :v 0} {:op :push :v 1} {:op :sub} {:op :store :v 0}
       {:op :jump :v 2} {:op :halt}]
      (assoc 3 {:op :jump-if-zero :v 11})))

(def factorial
  [{:op :push :v 1} {:op :store :v 1}
   {:op :push :v 10} {:op :store :v 0}
   {:op :load :v 0} {:op :jump-if-zero :v 15}
   {:op :load :v 1} {:op :load :v 0} {:op :mul} {:op :store :v 1}
   {:op :load :v 0} {:op :push :v 1} {:op :sub} {:op :store :v 0}
   {:op :jump :v 4}
   {:op :load :v 1} {:op :print} {:op :halt}])

(def ^:private good [{:op :push :v 2} {:op :push :v 3} {:op :add}
                     {:op :print} {:op :halt}])

(def ^:private pair-size 12)
(def ^:private grid-size 16)
(def ^:private static-size 17)
(def ^:private shape-size 17)

(defn- pair-bytes! [p a b]
  (ffi/write p :int64 b 0)
  (ffi/write p :int32 a 8)
  p)

(defn- read-pair [p]
  [(ffi/read p :int32 8) (ffi/read p :int64 0)])

(defn- grid-bytes! [p xs]
  (doseq [[i v] (map-indexed vector xs)] (ffi/write p :int32 v (* 4 i)))
  p)

(defn- read-grid [p]
  (mapv (fn [i] (ffi/read p :int32 (* 4 i))) (range 4)))

(defn- static-bytes! [p n xs]
  (ffi/write p :uint8 n 0)
  (doseq [[i v] (map-indexed vector xs)] (ffi/write p :int32 v (+ 1 (* 4 i))))
  p)

;; The packed 17-byte Shape stays a byte container; the union is overlaid on
;; the payload at byte 1, where place + a byte offset read and write it.
(def ^:private shape-union
  [:union [[:circle [:struct [[:r :double]]]]
           [:rect   [:struct [[:w :double] [:h :double]]]]]])

(defn- shape-bytes! [p tag a b]
  (ffi/write p :uint8 tag 0)
  (let [payload (ffi/slice p 1)]
    (case tag
      1 (ffi/write payload (ffi/place shape-union [:circle :r]) (double a))
      2 (do (ffi/write payload (ffi/place shape-union [:rect :w]) (double a))
            (ffi/write payload (ffi/place shape-union [:rect :h]) (double b)))
      nil))
  p)

(defn- read-shape [p]
  [(ffi/read p :uint8 0)
   (ffi/read p (ffi/place shape-union [:circle :r]) 1)
   (ffi/read p (ffi/place shape-union [:rect :h]) 1)])

(defn- slice-of [data n]
  {:data data :len n})

(defn- sc-sum [xs]
  (with-open [a (ffi/confined-arena)]
    (let [base (ffi/alloc a (* 8 (count xs)))]
      (doseq [[i v] (map-indexed vector xs)] (ffi/write base :int64 v (* 8 i)))
      (sc-sum-slice (slice-of base (count xs))))))

(defn- sum-i32 [f xs]
  (with-open [a (ffi/confined-arena)]
    (let [base (ffi/alloc a (* 4 (count xs)))]
      (doseq [[i v] (map-indexed vector xs)] (ffi/write base :int32 v (* 4 i)))
      (f (slice-of base (count xs))))))

(defn- check [label want f]
  (is (= want (f)) label))

;; ------------------------------------------------------------------
;; Thread kinds. Each helper runs `f` on its thread and rethrows a failure in
;; the test thread, so a broken value-only export is an assertion error rather
;; than a hang.

(defn- on-platform [f]
  (let [p (promise)
        t (Thread. (reify Runnable
                     (run [_]
                       (deliver p (try {:ok (f)} (catch Throwable e {:err e}))))))]
    (.start t)
    (.join t)
    (let [{:keys [ok err]} @p]
      (if err (throw err) ok))))

(defn- on-virtual [f]
  (let [p (promise)
        t (-> (Thread/ofVirtual)
              (.start (reify Runnable
                        (run [_]
                          (deliver p (try {:ok (f)} (catch Throwable e {:err e})))))))]
    (.join t)
    (let [{:keys [ok err]} @p]
      (if err (throw err) ok))))

(defn- on-go [f]
  (let [c (async/chan 1)]
    (async/go
      (async/>! c (try {:ok (f)} (catch Throwable e {:err e}))))
    (let [[v port] (async/alts!! [c (async/timeout 10000)])]
      (if (= port c)
        (let [{:keys [ok err]} v]
          (if err (throw err) ok))
        (throw (ex-info "core.async go call timed out" {}))))))

;; ------------------------------------------------------------------
;; Host-thread initialization probes. goose_init takes effect once per
;; process and binds the runtime to the calling thread, so each probe runs in
;; a fresh babashka: the suite's own process initialized on the test thread.

(def ^:private host-init-form
  '(do
     (require '[babashka.ffi :as ffi] '[clojure.core.async :as a])
     (def lib (ffi/load-library {:mac "../gs/libexport_abi.dylib"
                                 :linux "../gs/libexport_abi.so"}))
     (defn cfn [n args ret] (ffi/cfn lib n args ret))
     (def init (cfn "goose_init" [:int :pointer] :void))
     (def exit (cfn "goose_exit" [] :void))
     (def fib (cfn "sc_fib" [:int64] :int64))
     (def stack (cfn "sc_sum_stack" [:int64] :int64))
     (def worker (cfn "sc_thread_double" [:int64] :int64))
     (defn run [] (init 0 ffi/null)
       (let [r [(fib 20) (stack 5) (worker 21)]]
         (exit)
         r))
     (defn on-platform [f]
       (let [p (promise)
             t (Thread. (reify Runnable (run [_] (deliver p (f)))))]
         (.start t)
         (.join t)
         @p))
     (defn on-virtual [f]
       (let [p (promise)
             t (-> (Thread/ofVirtual)
                   (.start (reify Runnable (run [_] (deliver p (f))))))]
         (.join t)
         @p))
     (println :init
              (case (first *command-line-args*)
                "platform" (on-platform run)
                "virtual" (on-virtual run)
                "go" (let [c (a/go (run))
                           [v port] (a/alts!! [c (a/timeout 30000)])]
                       (if (= port c) v :timeout))))))

(def ^:private owner-init-form
  '(do
     (require '[babashka.ffi :as ffi])
     (def lib (ffi/load-library {:mac "../gs/libexport_abi.dylib"
                                 :linux "../gs/libexport_abi.so"}))
     (defn cfn [n args ret] (ffi/cfn lib n args ret))
     (def init (cfn "goose_init" [:int :pointer] :void))
     (def exit (cfn "goose_exit" [] :void))
     (def fib (cfn "sc_fib" [:int64] :int64))
     (def stack (cfn "sc_sum_stack" [:int64] :int64))
     (def worker (cfn "sc_thread_double" [:int64] :int64))
     (def ready (promise))
     (def proceed (promise))
     (def done (promise))
     (def owner
       (Thread. (reify Runnable
                  (run [_]
                    (init 0 ffi/null)
                    (deliver ready true)
                    @proceed
                    (let [r [(fib 20) (stack 5) (worker 21)]]
                      (exit)
                      (deliver done r))))))
     (.start owner)
     @ready
     ;; A second init on a different thread is documented to do nothing.
     (init 0 ffi/null)
     (deliver proceed true)
     (println :owner @done)))

(def ^:private foreign-init-form
  '(do
     (require '[babashka.ffi :as ffi])
     (def lib (ffi/load-library {:mac "../gs/libexport_abi.dylib"
                                 :linux "../gs/libexport_abi.so"}))
     (defn cfn [n args ret] (ffi/cfn lib n args ret))
     (def init (cfn "goose_init" [:int :pointer] :void))
     (def stack (cfn "sc_sum_stack" [:int64] :int64))
     (def ready (promise))
     (def owner
       (Thread. (reify Runnable
                  (run [_] (init 0 ffi/null) (deliver ready true)))))
     (.start owner)
     @ready
     (.join owner)
     (println :main (stack 5))))

;; ------------------------------------------------------------------
;; Off-thread fault probes: a native SIGSEGV aborts the process, so each one
;; runs in a fresh babashka and the parent asserts the crash.

(def ^:private fault-form
  (str "(do (require '[babashka.ffi :as ffi] '[clojure.core.async :as a])"
       " (def lib (ffi/load-library {:mac \"../gs/libexport_abi.dylib\""
       " :linux \"../gs/libexport_abi.so\"}))"
       " ((ffi/cfn lib \"goose_init\" [:int :pointer] :void) 0 ffi/null)"
       " (def call (fn [] ((ffi/cfn lib \"%s\" [:int64] :int64) %d)))"
       " (defn attempt [f] (try (f) (catch Throwable e e)))"
       " (defn on-platform [f]"
       "   (let [p (promise)"
       "         t (Thread. (reify Runnable (run [_] (deliver p (attempt f)))))]"
       "     (.start t) (.join t) (deref p 10000 :timeout)))"
       " (defn on-virtual [f]"
       "   (let [p (promise)"
       "         t (-> (Thread/ofVirtual)"
       "               (.start (reify Runnable (run [_] (deliver p (attempt f))))))]"
       "     (.join t) (deref p 10000 :timeout)))"
       " (println :probe (case \"%s\""
       "   \"future\" (deref (future (attempt call)) 10000 :timeout)"
       "   \"platform\" (on-platform call)"
       "   \"virtual\" (on-virtual call)"
       "   \"go\" (let [c (a/go (attempt call))"
       "               [v port] (a/alts!! [c (a/timeout 10000)])]"
       "          (if (= port c) v :timeout))))))"))

(defn- fault-probe [kind c-name arg]
  (sh "bb" "-e" (format fault-form c-name arg kind)))

;; ------------------------------------------------------------------
;; nREPL end-to-end helpers.

(defn- free-port []
  (with-open [s (java.net.ServerSocket. 0)]
    (.getLocalPort s)))

(defn- port-open? [port]
  (try (with-open [s (java.net.Socket. "127.0.0.1" (int port))] true)
       (catch Exception _ false)))

(defn- wait-for-port [port timeout-ms]
  (let [deadline (+ (System/currentTimeMillis) timeout-ms)]
    (loop []
      (cond (port-open? port) true
            (< (System/currentTimeMillis) deadline)
            (do (Thread/sleep 100) (recur))
            :else false))))

(defn- spawn-server [port log]
  (process/process ["bash" "-c" (str "exec bb nrepl-server " port " > " log " 2>&1")]))

(defn- client [port form]
  (let [proc (process/process {:in (str form "\n") :out :string :err :string}
                              "bb" "repl" "--connect" (str port))
        exit (deref (future (.waitFor (:proc proc))) 60000 ::timeout)]
    (if (= ::timeout exit)
      (do (process/destroy-tree proc) {:exit ::timeout :out "timed out"})
      {:exit exit :out (str @(:out proc) @(:err proc))})))

(def ^:private e2e-form
  '(do
     (require '[babashka.ffi :as ffi])
     (def lib (ffi/load-library {:mac "../gs/libexport_abi.dylib"
                                 :linux "../gs/libexport_abi.so"}))
     (def gi (ffi/cfn lib "goose_init" [:int :pointer] :void))
     (def gtr (ffi/cfn lib "goose_vm_try_run" [[:struct [[:data :pointer] [:len :int64]]]] :int64))
     (def gla (ffi/cfn lib "goose_vm_last_abort" [:pointer] :pointer))
     (gi 0 ffi/null)
     (defn abort-msg []
       (with-open [a (ffi/confined-arena)]
         (let [lp (ffi/alloc a :int64)
               p (gla lp)
               n (ffi/read lp :int64)]
           (apply str (map #(char (ffi/read (ffi/reinterpret p n) :uint8 %)) (range n))))))
     (defn runvm [ops]
       (with-open [a (ffi/confined-arena)]
         (let [base (ffi/alloc a (* 9 (count ops)))]
           (doseq [[i {:keys [op v]}] (map-indexed vector ops)]
             (let [at (* 9 i)]
               (ffi/write base :uint8 (case op :push 0 :add 3 :sub 4 :jump-if-zero 8 :print 9 :halt 10) at)
               (when (= op :push) (ffi/write base :int64 v (inc at)))))
           (gtr {:data base :len (count ops)}))))
     (def good [{:op :push :v 2} {:op :push :v 3} {:op :add} {:op :print} {:op :halt}])
     (println :e2e-ok (runvm good))
     (let [n (runvm [{:op :push :v 1} {:op :jump-if-zero :v 3}
                     {:op :sub} {:op :halt}])]
       (println :e2e-abort (if (neg? n) (abort-msg) n)))
     (println :e2e-after (runvm good))))

;; ------------------------------------------------------------------
;; Fixture: one goose_init on the thread that runs all the tests.

(defn- with-runtime [f]
  (goose-init 0 ffi/null)
  (try (f) (finally (goose-exit))))

(use-fixtures :once with-runtime)

;; ------------------------------------------------------------------

(deftest vm-programs-and-containment
  (testing "assembled programs run"
    (check "countdown" 32 #(run-program countdown))
    (check "factorial" 119 #(run-program factorial))
    (check "2+3" 5 #(run-program good))
    (check "unchecked 2+3" 5 #(run-program-unchecked good))
    (check "patched factorial of 4" 53
           #(run-program (-> factorial
                             (assoc 2 {:op :push :v 4})
                             (assoc 3 {:op :store :v 0})))))
  (testing "an abort stays in the contained worker and throws in Clojure"
    (let [underflow [{:op :push :v 1} {:op :jump-if-zero :v 3}
                     {:op :sub} {:op :halt}]
          far-jump [{:op :push :v 1} {:op :jump :v 99} {:op :halt}]]
      (is (re-find #"goose aborted: pop on empty array"
                   (str (try (run-program underflow) nil
                             (catch Exception e (ex-message e))))))
      (is (re-find #"goose aborted: index 99 out of bounds"
                   (str (try (run-program far-jump) nil
                             (catch Exception e (ex-message e))))))
      (is (re-find #"limit is 256"
                   (str (try (run-program (vec (repeat 300 {:op :halt}))) nil
                             (catch Exception e (ex-message e)))))))
    (check "after the aborts" 119 #(run-program factorial)))
  (testing "goose_exit then goose_init again"
    (goose-exit)
    (goose-init 0 ffi/null)
    (check "after restart" 32 #(run-program countdown))))

(deftest scalars-and-flat-values-cross
  (testing "integer and float scalars, bool"
    (check "i8" -5 #(i8 -5))
    (check "u8" 250 #(u8 250))
    (check "i16" -300 #(i16 -300))
    (check "u16" 65000 #(u16 65000))
    (check "i32" -70000 #(i32 -70000))
    (check "u32" 4000000000 #(u32 4000000000))
    (check "i64" -5000000000000 #(i64 -5000000000000))
    ;; babashka.ffi takes :uint64 as a Clojure long, so the unsigned value
    ;; crosses as its signed bit pattern.
    (check "u64" -446744073709551616 #(u64 -446744073709551616))
    (check "f32" 1.5 #(f32 1.5))
    (check "f64" 2.25 #(f64 2.25))
    (check "bool" 0 #(not- 1)))
  (testing "flat fixed-size values by value"
    (check "Pair packed" 103
           #(with-open [a (ffi/confined-arena)]
              (pair-sum (ffi/read (pair-bytes! (ffi/alloc a pair-size) 3 100) pair-layout))))
    (is (not= [7 900]
              (with-open [a (ffi/confined-arena)]
                (let [buf (ffi/alloc a 16)
                      _ (ffi/write buf pair-layout (pair-make 7 900))
                      m (ffi/read buf pair-natural)]
                  [(:a m) (:b m)])))
        "a natural declaration-order layout must NOT match goose's packed struct")
    (check "Mixed packed" 3.75
           #(mixed-sum {:g 2.25 :f 1.5}))
    (check "i32[4]" 10 #(with-open [a (ffi/confined-arena)]
                           (arr-sum (ffi/read (grid-bytes! (ffi/alloc a grid-size) [1 2 3 4]) arr-layout))))
    (check "i32[..4] len 4" 10 #(with-open [a (ffi/confined-arena)]
                                  (static-sum (ffi/read (static-bytes! (ffi/alloc a static-size)
                                                                       4 [1 2 3 4])
                                                        static-layout))))
    (check "i32[..4] len 2" 11 #(with-open [a (ffi/confined-arena)]
                                  (static-sum (ffi/read (static-bytes! (ffi/alloc a static-size)
                                                                       2 [5 6])
                                                        static-layout))))
    (check "Grid" 10 #(with-open [a (ffi/confined-arena)]
                        (grid-sum (ffi/read (grid-bytes! (ffi/alloc a grid-size) [1 2 3 4])
                                            arr-layout))))
    (check "enum" 2 #(:b0 (color-next {:b0 1})))
    (check "enum with fields, Rect" 12.0
           #(with-open [a (ffi/confined-arena)]
              (shape-area (ffi/read (shape-bytes! (ffi/alloc a shape-size) 2 3 4) shape-layout))))
    (check "enum with fields, Dot" 0.0
           #(with-open [a (ffi/confined-arena)]
              (shape-area (ffi/read (shape-bytes! (ffi/alloc a shape-size) 0 0 0) shape-layout)))))
  (testing "T& as pointers"
    (check "Pair&" [8 105]
           #(with-open [a (ffi/confined-arena)]
              (let [p (pair-bytes! (ffi/alloc a pair-size) 3 100)]
                (pair-shift p 5)
                (read-pair p))))
    (check "i32[4]&" [2 3 4 5]
           #(with-open [a (ffi/confined-arena)]
              (let [p (grid-bytes! (ffi/alloc a grid-size) [1 2 3 4])]
                (arr-bump p)
                (read-grid p))))
    (check "Grid&" [2 3 4 5]
           #(with-open [a (ffi/confined-arena)]
              (let [p (grid-bytes! (ffi/alloc a grid-size) [1 2 3 4])]
                (grid-bump p)
                (read-grid p))))
    (check "enum&" 2 #(with-open [a (ffi/confined-arena)]
                        (let [p (ffi/alloc a 1)]
                          (ffi/write p :uint8 1 0)
                          (color-advance p)
                          (ffi/read p :uint8 0))))
    (check "Shape& Rect" [2 4.0 5.0]
           #(with-open [a (ffi/confined-arena)]
              (let [p (shape-bytes! (ffi/alloc a shape-size) 2 3 4)]
                (shape-grow p)
                (read-shape p))))
    (check "Shape& Circle" [1 3.5]
           #(with-open [a (ffi/confined-arena)]
              (let [p (shape-bytes! (ffi/alloc a shape-size) 1 2.5 0)]
                (shape-grow p)
                [(ffi/read p :uint8 0)
                 (ffi/read p (ffi/place shape-union [:circle :r]) 1)]))))
  (testing "T[:] as { data, len }"
    (check "i32[:]" 60 #(sum-i32 i32-sum [10 20 30]))
    (check "const i32[:]" 60 #(sum-i32 const-sum [10 20 30]))
    (check "Pair[:]" 307
           #(with-open [a (ffi/confined-arena)]
              (let [base (ffi/alloc a 24)]
                (pair-bytes! base 3 100)
                (ffi/write base :int64 200 12)
                (ffi/write base :int32 4 20)
                (pair-sum-of (slice-of base 2)))))
    (check "Color[:]" 2
           #(with-open [a (ffi/confined-arena)]
              (let [base (ffi/alloc a 3)]
                (doseq [[i v] (map-indexed vector [0 2 1])]
                  (ffi/write base :uint8 v i))
                (:b0 (color-of (slice-of base 3) 1)))))
    (check "Shape[:]" 10.0
           #(with-open [a (ffi/confined-arena)]
              (let [base (ffi/alloc a (* 3 shape-size))]
                (shape-bytes! base 0 0 0)
                (shape-bytes! (ffi/slice base 17) 2 2 3)
                (shape-bytes! (ffi/slice base 34) 2 1 4)
                (shape-sum (slice-of base 3))))))
  (testing "flat results come back as maps"
    (check "const u8[:] result" "hello from goose"
           #(with-open [a (ffi/confined-arena)]
              (let [lp (ffi/alloc a :int64)
                    p (hello lp)
                    n (ffi/read lp :int64)]
                (bytes->string p n))))
    (check "i32[4] result" [10 20 30 40]
           #(with-open [a (ffi/confined-arena)]
              (let [buf (ffi/alloc a arr-layout)]
                (ffi/write buf arr-layout (arr-make))
                (read-grid buf))))
    (check "Pair result" [7 900]
           #(with-open [a (ffi/confined-arena)]
              (let [buf (ffi/alloc a pair-layout)]
                (ffi/write buf pair-layout (pair-make 7 900))
                (read-pair buf))))
    (check "Shape result" [2 3.0 4.0]
           #(with-open [a (ffi/confined-arena)]
              (let [buf (ffi/alloc a shape-layout)]
                (ffi/write buf shape-layout (shape-make 3.0 4.0))
                (read-shape buf))))))

(deftest thread-ownership
  (testing "value-only exports work from futures"
    (check "add" 5 #(deref (future (sc-add 2 3))))
    (check "fib" 832040 #(deref (future (sc-fib 30))))
    (check "fixed-size array" 136 #(deref (future (sc-fixed-array 1))))
    (check "caller's slice" 15 #(deref (future (sc-sum [1 2 3 4 5]))))
    (is (every? #{832040}
                (map deref
                     (mapv (fn [_] (future (sc-fib 30))) (range 20))))
        "20 concurrent futures"))
  (testing "value-only exports work on platform, virtual and go threads"
    (doseq [[label run] [["platform" on-platform]
                         ["virtual" on-virtual]
                         ["go" on-go]]]
      (check (str label " add") 5 #(run (fn [] (sc-add 2 3))))
      (check (str label " fib") 6765 #(run (fn [] (sc-fib 20))))
      (check (str label " caller's slice") 6 #(run (fn [] (sc-sum [1 2 3]))))))
  (testing "a go block runs off the init thread"
    (is (not= (Thread/currentThread) (on-go #(Thread/currentThread)))))
  (testing "goose worker threads and host threads coexist"
    (let [host (mapv (fn [_] (future (sc-fib 20))) (range 10))
          goose (mapv (fn [_] (sc-in-worker 21)) (range 10))]
      (is (every? #{6765} (map deref host)))
      (is (every? #{42} goose))))
  (testing "goose worker results cross a core.async channel"
    ;; Only the init thread may spawn goose workers, so the init thread makes
    ;; the calls and the channel carries the values. The go block on the other
    ;; end waits on a virtual thread and never touches the ABI.
    (let [in (async/chan 4)
          out (async/chan 4)
          consumer (async/go
                     (loop [acc []]
                       (if-let [v (async/<! out)]
                         (recur (conj acc v))
                         acc)))]
      (doseq [n [1 2 3]] (async/>!! in n))
      (async/close! in)
      (loop []
        (when-let [n (async/<!! in)]
          (async/>!! out (sc-in-worker n))
          (recur)))
      (async/close! out)
      (is (= [2 4 6] (async/<!! consumer))))
    ;; A contained goose-thread failure is an ordinary return value, so it
    ;; rides the same channel.
    (let [c (async/chan 1)]
      (async/>!! c (sc-worker-fail 5))
      (is (= -1 (async/<!! c)))))
  (testing "the runtime heap and goose threads fault off the init thread"
    (doseq [kind ["future" "platform" "virtual" "go"]
            [c-name arg] [["sc_sum_stack" 5] ["sc_thread_double" 21]]]
      (let [{:keys [exit out]} (fault-probe kind c-name arg)]
        (is (not (zero? exit))
            (str c-name " on a " kind " thread should abort, exit " exit ": " out))
        (is (boolean (re-find #"(?i)segfault" out)) out))))
  (testing "the init thread still works"
    (check "heap" 10 #(sc-sum-stack 5))
    (check "worker" 42 #(sc-in-worker 21))
    (check "vm" 119 #(run-program factorial))))

(deftest host-thread-initialization
  (testing "a platform, virtual, or go thread can own the runtime"
    (doseq [kind ["platform" "virtual" "go"]]
      (let [{:keys [exit out]} (sh "bb" "-e" (pr-str host-init-form) kind)]
        (is (zero? exit) (str kind " init failed, exit " exit ": " out))
        (is (boolean (re-find #":init \[6765 10 42\]" out)) out))))
  (testing "a second init on another thread is a no-op and leaves the owner intact"
    (let [{:keys [exit out]} (sh "bb" "-e" (pr-str owner-init-form))]
      (is (zero? exit) (str "owner probe failed, exit " exit ": " out))
      (is (boolean (re-find #":owner \[6765 10 42\]" out)) out)))
  (testing "initializing elsewhere does not give another thread access"
    (let [{:keys [exit out]} (sh "bb" "-e" (pr-str foreign-init-form))]
      (is (not (zero? exit)) (str "main thread should fault, exit " exit ": " out))
      (is (boolean (re-find #"(?i)segfault" out)) out))))

(deftest boundary-rejections
  (let [path "/tmp/export-abi-reject.goose"
        reject (fn [body fragment]
                 (spit path (str body "\n"))
                 (let [{:keys [exit out]} (sh "goose" "check" path)]
                   (is (not (zero? exit)) (str "expected rejection: " body))
                   (is (boolean (re-find (re-pattern (java.util.regex.Pattern/quote fragment)) out))
                       (str "expected '" fragment "' in: " out))))
        accept (fn [body]
                 (spit path (str body "\n"))
                 (let [{:keys [exit out]} (sh "goose" "check" path)]
                   (is (zero? exit) (str "expected acceptance: " body " -> " out))))
        msg "only fixed-size values cross by value"]
    (reject "export \"x\" fn f(a: i32[..]) -> i64 { return a.len; }" msg)
    (reject "export \"x\" fn f(a: i32[..]&) -> i64 { return a.len; }" msg)
    (reject "export \"x\" fn f() -> i32[..] { return [..4]; }" msg)
    (reject "struct S { a: i32[..] }\nexport \"x\" fn f(s: S) -> i64 { return s.a.len; }" msg)
    (reject "export \"x\" fn f(a: i32[]) -> i64 { return a.len; }" msg)
    (reject "export \"x\" fn f(a: i32[varint]) -> i64 { return a.len; }" msg)
    (reject "export \"x\" fn f(a: i32[>..]) -> i64 { return a.len; }" msg)
    (reject "export \"x\" fn f(a: i32[>..<]) -> i64 { return a.len; }" msg)
    (reject "export \"x\" fn f(out: u8[>..]&) { out.push(65); }"
            "no public C representation")
    (accept "export \"x\" fn f(a: i32[..8]) -> i64 { return a.len; }")
    (accept "export \"x\" fn f(a: const i32[:]) -> i64 { return a.len; }")))

(deftest nrepl-end-to-end
  (let [port (free-port)
        ;; bb nrepl-server writes .nrepl-port into the project dir; keep a dev
        ;; REPL's file intact across the test.
        port-file (java.io.File. ".nrepl-port")
        saved (when (.exists port-file) (slurp port-file))
        log (str "/tmp/export-abi-bb-nrepl-" port ".log")
        server (spawn-server port log)]
    (try
      (is (wait-for-port port 10000) "nREPL server did not start")
      (let [{:keys [exit out]} (client port (pr-str e2e-form))]
        (is (zero? exit) (str "bb client failed: " out))
        (is (boolean (re-find #":e2e-ok 5" out)) out)
        (is (boolean (re-find #":e2e-abort" out)) out)
        (is (boolean (re-find #"pop on empty array" out)) out)
        (is (boolean (re-find #":e2e-after 5" out)) out))
      (let [text (slurp log)]
        (is (boolean (re-find #"out: 5" text)) (str "server stdout: " text)))
      (finally
        (process/destroy-tree server)
        (try (.waitFor (:proc server)) (catch Exception _))
        (if saved
          (spit port-file saved)
          (.delete port-file))))))
