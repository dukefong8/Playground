(ns goose.export-abi
  "All goose-export tests in one place: the bindings, the VM programs, the
  boundary-shape matrix, thread ownership, compiler rejections and an nREPL
  end-to-end drive. `test/goose/export_abi.clj` is the only test/probe file.

  goose_init resolves to the first library loaded in a process, so the three
  goose samples are combined into `goose/export_abi.goose` and built as ONE
  dylib by the `goose-lib` task, which `jolt test` and `jolt opt` run first.

  Every type's C shape comes from the generated `goose/export_abi.h`; the
  header wraps all types in `#pragma pack(push, 1)`, while jolt.ffi/layout
  does not model packing. Packed values therefore usually cross as runs of
  :uint8 with fields at byte offsets, not as natural Jolt layouts — except
  where register classification depends on member types rather than bytes
  (see `Mixed` below), in which case the descriptor uses the real field
  types.

  | goose | generated C | Jolt |
  |---|---|---|
  | `i8` | `int8_t` | `:int8` |
  | `u8` | `uint8_t` | `:uint8` |
  | `i16` | `gs_i16` (`int16_t`) | `:int16` |
  | `u16` | `gs_u16` (`uint16_t`) | `:uint16` |
  | `i32` | `gs_i32` (`int32_t`) | `:int32` |
  | `u32` | `gs_u32` (`uint32_t`) | `:uint32` |
  | `i64` | `gs_i64` (`int64_t`) | `:int64` |
  | `u64` | `gs_u64` (`uint64_t`) | `:uint64`, comes back as a BigInt |
  | `f32` | `gs_f32` (`float`) | `:float` |
  | `f64` | `gs_f64` (`double`) | `:double` |
  | `bool` | `uint8_t` | `:uint8` or `:bool` |
  | struct `Pair{b:i64,a:i32}` | packed `struct { int64_t b; int32_t a; }`, 12 bytes | 12 :uint8 fields; b at 0, a at 8. Field order matters: `{a:i32,b:i64}` packs b at 4, C then passes the struct on the stack while Jolt passes it in registers, so it does not cross (reference §24) |
  | struct `Mixed{g:f64,f:f32}` | packed 12 bytes | real field types `[:struct [[:g :double] [:f :float]]]`, NOT :uint8 runs: the float member is classified SSE and crosses in XMM registers, while :uint8 runs cross in general-purpose ones. Packed offsets (g at 0, f at 8) agree with Chez's natural offsets here, so the descriptor applies |
  | struct `Grid{cells:i32[4]}` | `struct { struct { int32_t e[4]; } cells; }`, 16 bytes | 16 :uint8 fields, or `[:array :int32 4]` when the alignment agrees |
  | fixed `T[N]` | `struct { T e[N]; }` | `[:by-value [:struct [[:e [:array :int32 N]]]]]` for `i32[N]` |
  | static-capacity `T[..N]` | `struct { uint8_t len; T e[N]; }`; `i32[..4]` is 17 bytes | byte layout: len at 0, elements at 1 + 4i |
  | fixed-mode enum, no fields (`Color`) | `struct { uint8_t tag; }` | 1-byte packed layout, tags in declaration order |
  | fixed-mode enum with fields (`Shape`) | `struct { uint8_t tag; union { struct { double r; }; struct { double w, h; }; } u; }`, 17 bytes | packed 17-byte container; `[:union …]` layout over ptr+1 for the payload: `[:circle :r]`, `[:rect :w]`, `[:rect :h]`. A union cannot be passed by value, alone or inside a struct. |
  | `T&` to any of the above | `T *` | `:pointer` |
  | `T[:]`, `const T[:]` | `struct { T *data; int64_t len; }` | `[:by-value [:struct [[:data :pointer] [:len :int64]]]]` |
  | `const u8[:]` result | `const uint8_t *` plus `int64_t *` length out-param | `:pointer` return and a `:pointer` length buffer |
  | flat value result | C return value | extra LEADING pointer argument; read fields from that buffer |

  Rejected at an export boundary, so there is no Jolt binding:

  | goose | generated C | Jolt |
  |---|---|---|
  | `T[..]`, `T[]`, `T[varint]`, `T[>..]`, `T[>..<]` as value, reference, result or struct field | none: only fixed-size values cross by value | none |
  | `T[>..]&` builder | none: uses a reusable pool and has no public C representation | none |"
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [jolt.ffi :as ffi]
            [jolt.fibers :as fib]))

;; ------------------------------------------------------------------
;; Process helpers: build the library, check compiler rejections, drive nREPL.

(defn- sh
  "Runs a command with stdout and stderr merged into a string."
  [& args]
  (let [pb (ProcessBuilder. (into-array String (vec args)))]
    (.redirectErrorStream pb true)
    (let [p (.start pb)
          out (slurp (.getInputStream p))
          code (.waitFor p)]
      {:exit code :out out})))

(ffi/load-library {:darwin "goose/libexport_abi.dylib"
                   :linux  "goose/libexport_abi.so"})

;; ------------------------------------------------------------------
;; Bindings. All three samples share this one goose_init.

(ffi/defcfn goose-init "goose_init" [:int :pointer] :void)
(ffi/defcfn goose-exit "goose_exit" [] :void)

;; The contained interpreter (from goose/19_vm.goose).
(ffi/defcfn vm-run "goose_vm_run"
  [[:by-value [:struct [[:data :pointer] [:len :int64]]]]] :int64)
(ffi/defcfn vm-try-run "goose_vm_try_run"
  [[:by-value [:struct [[:data :pointer] [:len :int64]]]]] :int64)
(ffi/defcfn vm-last-abort "goose_vm_last_abort" [:pointer] :pointer)

;; Value-only exports — what may be called from a foreign thread.
(ffi/defcfn sc-add "sc_add" [:int64 :int64] :int64)
(ffi/defcfn sc-fib "sc_fib" [:int64] :int64)
(ffi/defcfn sc-fixed-array "sc_fixed_array" [:int64] :int64)
(ffi/defcfn sc-sum-stack "sc_sum_stack" [:int64] :int64)
(ffi/defcfn sc-sum-slice "sc_sum_slice"
  [[:by-value [:struct [[:data :pointer] [:len :int64]]]]] :int64)
(ffi/defcfn sc-in-worker "sc_thread_double" [:int64] :int64)

;; One export per shape that may cross C.

(ffi/defcfn i8  "abi_i8"  [:int8]   :int8)
(ffi/defcfn u8  "abi_u8"  [:uint8]  :uint8)
(ffi/defcfn i16 "abi_i16" [:int16]  :int16)
(ffi/defcfn u16 "abi_u16" [:uint16] :uint16)
(ffi/defcfn i32 "abi_i32" [:int32]  :int32)
(ffi/defcfn u32 "abi_u32" [:uint32] :uint32)
(ffi/defcfn i64 "abi_i64" [:int64]  :int64)
(ffi/defcfn u64 "abi_u64" [:uint64] :uint64)
(ffi/defcfn f32 "abi_f32" [:float]  :float)
(ffi/defcfn f64 "abi_f64" [:double] :double)
(ffi/defcfn not- "abi_not" [:uint8] :uint8)

;; goose packs every struct; jolt.ffi/layout does not model packing, so a
;; packed value is described as N one-byte fields and written at byte offsets.
(defn- packed [n]
  [:by-value [:struct (mapv (fn [i] [(keyword (str "b" i)) :uint8]) (range n))]])

(defmacro ^:private defcfn-packed-in
  [clj-name c-name n argtypes ret]
  `(ffi/defcfn ~clj-name ~c-name ~(into (vec argtypes) [(packed n)]) ~ret))

(defmacro ^:private defcfn-packed-out
  [clj-name c-name argtypes n]
  `(ffi/defcfn ~clj-name ~c-name ~(vec argtypes) ~(packed n)))

(defcfn-packed-in pair-sum "abi_pair_sum" 12 [] :int64)
;; Mixed crosses by value only with its real field types (see the table):
;; a :uint8 run would arrive in general-purpose registers while C reads XMM.
;; Chez's natural offsets for [double float] agree with the packed ones, so
;; this descriptor applies despite the size difference.
(ffi/defcfn mixed-sum "abi_mixed_sum"
  [[:by-value [:struct [[:g :double] [:f :float]]]]] :double)
(defcfn-packed-in arr-sum "abi_arr_sum" 16 [] :int64)
(defcfn-packed-in static-sum "abi_static_sum" 17 [] :int64)
(defcfn-packed-in grid-sum "abi_grid_sum" 16 [] :int64)
(defcfn-packed-in shape-area "abi_shape_area" 17 [] :double)

(defcfn-packed-out arr-make "abi_arr_make" [] 16)
(defcfn-packed-out pair-make "abi_pair_make" [:int32 :int64] 12)
(defcfn-packed-out shape-make "abi_shape_make" [:double :double] 17)

;; Reading a packed Pair back at Jolt's natural offsets must NOT give the
;; same fields: that is the proof the packed layout is what crosses.
;; (A natural-layout *argument* cannot serve as the control: addition
;; commutes, so a swapped struct sums the same.)

(ffi/defcfn color-next "abi_color_next"
  [[:by-value [:struct [[:b0 :uint8]]]]]
  [:by-value [:struct [[:b0 :uint8]]]])

(ffi/defcfn pair-shift "abi_pair_shift" [:pointer :int32] :void)
(ffi/defcfn arr-bump "abi_arr_bump" [:pointer] :void)
(ffi/defcfn grid-bump "abi_grid_bump" [:pointer] :void)
(ffi/defcfn shape-grow "abi_shape_grow" [:pointer] :void)
(ffi/defcfn color-advance "abi_color_advance" [:pointer] :void)

(ffi/defcfn i32-sum "abi_i32_sum_slice"
  [[:by-value [:struct [[:data :pointer] [:len :int64]]]]] :int64)
(ffi/defcfn pair-sum-of "abi_pair_sum_slice"
  [[:by-value [:struct [[:data :pointer] [:len :int64]]]]] :int64)
(ffi/defcfn const-sum "abi_const_i32_sum"
  [[:by-value [:struct [[:data :pointer] [:len :int64]]]]] :int64)
(ffi/defcfn shape-sum "abi_shape_sum"
  [[:by-value [:struct [[:data :pointer] [:len :int64]]]]] :double)
(ffi/defcfn color-of "abi_color_of"
  [[:by-value [:struct [[:data :pointer] [:len :int64]]]] :int64] :uint8)

(ffi/defcfn hello "abi_hello" [:pointer] :pointer)

;; ------------------------------------------------------------------
;; Helpers for the VM assembler and the packed C values.

(def ^:private vm-slice (ffi/layout [:struct [[:data :pointer] [:len :int64]]]))
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

(defn- vm-with-slice [arena ops f]
  (let [n (count ops)
        base (ffi/alloc arena (* n stride))]
    (doseq [[i instr] (map-indexed vector ops)] (write-op! base i instr))
    (ffi/with-layout [sp vm-slice]
      (ffi/write-field sp vm-slice :data base)
      (ffi/write-field sp vm-slice :len n)
      (f sp))))

(defn- bytes->string [p n]
  (apply str (map #(char (ffi/read p :uint8 %)) (range n))))

(defn- last-abort []
  (ffi/with-arena [a]
    (let [lp (ffi/alloc a 8)
          p (vm-last-abort lp)
          n (ffi/read lp :int64 0)]
      (when (pos? n) (bytes->string p n)))))

(defn- run-program [ops]
  (ffi/with-arena [a]
    (let [n (long (vm-with-slice a ops vm-try-run))]
      (if (neg? n)
        (throw (ex-info (if (= -1 n)
                          (str "goose aborted: " (last-abort))
                          (str "program has " (count ops) " instructions, limit is " max-ops))
                        {:status n :abort (when (= -1 n) (last-abort))}))
        n))))

(defn- run-program-unchecked [ops]
  (ffi/with-arena [a] (vm-with-slice a ops vm-run)))

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

(defn- mixed-bytes! [p g f]
  (ffi/write p :double g 0)
  (ffi/write p :float f 8)
  p)

(defn- grid-bytes! [p xs]
  (doseq [[i v] (map-indexed vector xs)] (ffi/write p :int32 v (* 4 i)))
  p)

(defn- read-grid [p]
  (mapv (fn [i] (ffi/read p :int32 (* 4 i))) (range 4)))

(defn- static-bytes! [p n xs]
  (ffi/write p :uint8 n 0)
  (doseq [[i v] (map-indexed vector xs)] (ffi/write p :int32 v (+ 1 (* 4 i))))
  p)

;; jolt.ffi accepts a [:union ...] layout and its nested field paths, but
;; refuses to pass a union by value ("alone or inside a struct"). The packed
;; 17-byte Shape therefore stays a byte container; the union is overlaid on
;; the payload at byte 1, where read-field/write-field accept a raw pointer.
(def ^:private shape-payload
  (ffi/layout [:union [[:circle [:struct [[:r :double]]]]
                       [:rect   [:struct [[:w :double] [:h :double]]]]]]))

(defn- shape-bytes! [p tag a b]
  (ffi/write p :uint8 tag 0)
  (let [payload (+ p 1)]
    (case tag
      1 (ffi/write-field payload shape-payload [:circle :r] (double a))
      2 (do (ffi/write-field payload shape-payload [:rect :w] (double a))
            (ffi/write-field payload shape-payload [:rect :h] (double b)))
      nil))
  p)

(defn- read-shape [p]
  (let [payload (+ p 1)]
    [(ffi/read p :uint8 0)
     (ffi/read-field payload shape-payload [:circle :r])
     (ffi/read-field payload shape-payload [:rect :h])]))

(defn- slice-of [a data n]
  (let [sp (ffi/alloc a 16)]
    (ffi/write sp :pointer data 0)
    (ffi/write sp :int64 n 8)
    sp))

(defn- sc-sum [xs]
  (ffi/with-arena [a]
    (let [base (ffi/alloc a (* 8 (count xs)))]
      (doseq [[i v] (map-indexed vector xs)] (ffi/write base :int64 v (* 8 i)))
      (sc-sum-slice (slice-of a base (count xs))))))

(defn- sum-i32 [f xs]
  (ffi/with-arena [a]
    (let [base (ffi/alloc a (* 4 (count xs)))]
      (doseq [[i v] (map-indexed vector xs)] (ffi/write base :int32 v (* 4 i)))
      (f (slice-of a base (count xs))))))

(defn- fault?
  "True when `f` ends in the SIGSEGV Jolt turns into an exception."
  [f]
  (try (f) false
       (catch Throwable e
         (boolean (re-find #"invalid memory reference" (str (ex-message e)))))))

(defn- check [label want f]
  (is (= want (f)) label))

;; ------------------------------------------------------------------
;; nREPL end-to-end helpers.

(defn- free-port []
  (let [s (java.net.ServerSocket. 0)
        p (.getLocalPort s)]
    (.close s)
    p))

(defn- spawn-server [port log]
  (let [cmd (str "exec jolt nrepl-server " port " --no-port-file > " log " 2>&1")]
    (.start (ProcessBuilder. (into-array String ["bash" "-c" cmd])))))

(defn- client [port form]
  (let [p (.start (ProcessBuilder.
                   (into-array String ["bb" "repl" "--connect" (str port)])))]
    (with-open [w (java.io.OutputStreamWriter. (.getOutputStream p))]
      (.write w (str form "\n"))
      (.flush w))
    {:exit (.waitFor p) :out (slurp (.getInputStream p))}))

(def ^:private e2e-form
  '(do
     (require '[jolt.ffi :as ffi])
     (ffi/load-library {:darwin "goose/libexport_abi.dylib"
                        :linux "goose/libexport_abi.so"})
     (ffi/defcfn gi "goose_init" [:int :pointer] :void)
     (ffi/defcfn gtr "goose_vm_try_run" [[:by-value [:struct [[:data :pointer] [:len :int64]]]]] :int64)
     (ffi/defcfn gla "goose_vm_last_abort" [:pointer] :pointer)
     (gi 0 ffi/null)
     (defn abort-msg []
       (ffi/with-arena [a]
         (let [lp (ffi/alloc a 8)
               p (gla lp)
               n (ffi/read lp :int64 0)]
           (apply str (map #(char (ffi/read p :uint8 %)) (range n))))))
     (defn runvm [ops]
       (ffi/with-arena [a]
         (let [base (ffi/alloc a (* 9 (count ops)))]
           (doseq [[i {:keys [op v]}] (map-indexed vector ops)]
             (let [at (* 9 i)]
               (ffi/write base :uint8 (case op :push 0 :add 3 :sub 4 :jump-if-zero 8 :print 9 :halt 10) at)
               (when (= op :push) (ffi/write base :int64 v (inc at)))))
           (ffi/with-arena [b]
             (let [sp (ffi/alloc b 16)]
               (ffi/write sp :pointer base 0)
               (ffi/write sp :int64 (count ops) 8)
               (gtr sp))))))
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
  (testing "an abort stays in the contained worker and throws in Jolt"
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
    (check "u64" 18000000000000000000N #(u64 18000000000000000000))
    (check "f32" 1.5 #(f32 1.5))
    (check "f64" 2.25 #(f64 2.25))
    (check "bool" 0 #(not- 1)))
  (testing "flat fixed-size values by value"
    (check "Pair packed" 103
           #(ffi/with-arena [a] (pair-sum (pair-bytes! (ffi/alloc a pair-size) 3 100))))
    (is (not= [7 900] (ffi/with-arena [a]
                        ;; a packed Pair read back at natural offsets
                        (let [buf (ffi/alloc a 16)]
                          (pair-make buf 7 900)
                          [(ffi/read buf :int32 0) (ffi/read buf :int64 8)])))
        "Jolt's natural offsets must NOT match goose's packed struct")
    (check "Mixed packed" 3.75
           #(ffi/with-arena [a] (mixed-sum (mixed-bytes! (ffi/alloc a 12) 2.25 1.5))))
    (check "i32[4]" 10 #(ffi/with-arena [a]
                          (arr-sum (grid-bytes! (ffi/alloc a grid-size) [1 2 3 4]))))
    (check "i32[..4] len 4" 10 #(ffi/with-arena [a]
                                 (static-sum (static-bytes! (ffi/alloc a static-size)
                                                            4 [1 2 3 4]))))
    (check "i32[..4] len 2" 11 #(ffi/with-arena [a]
                                 (static-sum (static-bytes! (ffi/alloc a static-size)
                                                            2 [5 6]))))
    (check "Grid" 10 #(ffi/with-arena [a]
                       (grid-sum (grid-bytes! (ffi/alloc a grid-size) [1 2 3 4]))))
    (check "enum" 2 #(ffi/with-arena [a]
                      (let [in (ffi/alloc a 1) out (ffi/alloc a 8)]
                        (ffi/write in :uint8 1 0)
                        (color-next out in)
                        (ffi/read out :uint8 0))))
    (check "enum with fields, Rect" 12.0
           #(ffi/with-arena [a]
              (shape-area (shape-bytes! (ffi/alloc a shape-size) 2 3 4))))
    (check "enum with fields, Dot" 0.0
           #(ffi/with-arena [a]
              (shape-area (shape-bytes! (ffi/alloc a shape-size) 0 0 0)))))
  (testing "T& as pointers"
    (check "Pair&" [8 105]
           #(ffi/with-arena [a]
              (let [p (pair-bytes! (ffi/alloc a pair-size) 3 100)]
                (pair-shift p 5)
                (read-pair p))))
    (check "i32[4]&" [2 3 4 5]
           #(ffi/with-arena [a]
              (let [p (grid-bytes! (ffi/alloc a grid-size) [1 2 3 4])]
                (arr-bump p)
                (read-grid p))))
    (check "Grid&" [2 3 4 5]
           #(ffi/with-arena [a]
              (let [p (grid-bytes! (ffi/alloc a grid-size) [1 2 3 4])]
                (grid-bump p)
                (read-grid p))))
    (check "enum&" 2 #(ffi/with-arena [a]
                       (let [p (ffi/alloc a 1)]
                         (ffi/write p :uint8 1 0)
                         (color-advance p)
                         (ffi/read p :uint8 0))))
    (check "Shape& Rect" [2 4.0 5.0]
           #(ffi/with-arena [a]
              (let [p (shape-bytes! (ffi/alloc a shape-size) 2 3 4)]
                (shape-grow p)
                (read-shape p))))
    (check "Shape& Circle" [1 3.5]
           #(ffi/with-arena [a]
              (let [p (shape-bytes! (ffi/alloc a shape-size) 1 2.5 0)]
                (shape-grow p)
                [(ffi/read p :uint8 0)
                 (ffi/read-field (+ p 1) shape-payload [:circle :r])]))))
  (testing "T[:] as { data, len }"
    (check "i32[:]" 60 #(sum-i32 i32-sum [10 20 30]))
    (check "const i32[:]" 60 #(sum-i32 const-sum [10 20 30]))
    (check "Pair[:]" 307
           #(ffi/with-arena [a]
              (let [base (ffi/alloc a 24)]
                (pair-bytes! base 3 100)
                (ffi/write base :int64 200 12)
                (ffi/write base :int32 4 20)
                (pair-sum-of (slice-of a base 2)))))
    (check "Color[:]" 2
           #(ffi/with-arena [a]
              (let [base (ffi/alloc a 3)]
                (doseq [[i v] (map-indexed vector [0 2 1])]
                  (ffi/write base :uint8 v i))
                (color-of (slice-of a base 3) 1))))
    (check "Shape[:]" 10.0
           #(ffi/with-arena [a]
              (let [base (ffi/alloc a (* 3 shape-size))]
                (shape-bytes! base 0 0 0)
                (shape-bytes! (+ base 17) 2 2 3)
                (shape-bytes! (+ base 34) 2 1 4)
                (shape-sum (slice-of a base 3))))))
  (testing "flat results use a leading buffer argument"
    (check "const u8[:] result" "hello from goose"
           #(ffi/with-arena [a]
              (let [lp (ffi/alloc a 8)
                    p (hello lp)
                    n (ffi/read lp :int64 0)]
                (bytes->string p n))))
    (check "i32[4] result" [10 20 30 40]
           #(ffi/with-arena [a]
              (let [buf (ffi/alloc a grid-size)]
                (arr-make buf)
                (read-grid buf))))
    (check "Pair result" [7 900]
           #(ffi/with-arena [a]
              (let [buf (ffi/alloc a pair-size)]
                (pair-make buf 7 900)
                (read-pair buf))))
    (check "Shape result" [2 3.0 4.0]
           #(ffi/with-arena [a]
              (let [buf (ffi/alloc a shape-size)]
                (shape-make buf 3.0 4.0)
                (read-shape buf))))))

(deftest fibers-and-thread-ownership
  (testing "value-only exports work from fibers"
    (check "add" 5 #(fib/join (fib/spawn (fn [] (sc-add 2 3)))))
    (check "fib" 832040 #(fib/join (fib/spawn (fn [] (sc-fib 30)))))
    (check "fixed-size array" 136 #(fib/join (fib/spawn (fn [] (sc-fixed-array 1)))))
    (check "caller's slice" 15 #(fib/join (fib/spawn (fn [] (sc-sum [1 2 3 4 5])))))
    (is (every? #{832040}
                (map fib/join
                     (mapv (fn [_] (fib/spawn (fn [] (sc-fib 30)))) (range 20))))
        "20 concurrent fibers"))
  (testing "the runtime heap and goose threads fault off the init thread"
    (is (fault? #(fib/join (fib/spawn (fn [] (sc-sum-stack 5))))))
    (is (fault? #(fib/join (fib/spawn (fn [] (sc-in-worker 21)))))))
  (testing "the init thread still works after those faults"
    (check "heap" 10 #(sc-sum-stack 5))
    (check "worker" 42 #(sc-in-worker 21))
    (check "vm" 119 #(run-program factorial))))

(deftest boundary-rejections
  (let [path "/tmp/export-abi-reject.goose"
        reject (fn [body fragment]
                 (spit path (str body "\n"))
                 (let [{:keys [exit out]} (sh "goose" "check" path)]
                   (is (not (zero? exit)) (str "expected rejection: " body))
                   (is (boolean (re-find (java.util.regex.Pattern/quote fragment) out))
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
        log (str "/tmp/export-abi-nrepl-" port ".log")
        server (spawn-server port log)]
    (try
      (Thread/sleep 1500)
      (let [{:keys [exit out]} (client port (pr-str e2e-form))]
        (is (zero? exit) (str "bb client failed: " out))
        (is (boolean (re-find #":e2e-ok 5" out)) out)
        (is (boolean (re-find #":e2e-abort" out)) out)
        (is (boolean (re-find #"pop on empty array" out)) out)
        (is (boolean (re-find #":e2e-after 5" out)) out))
      (let [text (slurp log)]
        (is (boolean (re-find #"out: 5" text)) (str "server stdout: " text)))
      (finally (.destroy server)))))
