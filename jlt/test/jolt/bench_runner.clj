(ns jolt.bench-runner
  "Profile async performance and compare Jolt's core.async backends.

  Jolt's go blocks run on a backend named by `clojure.core.async/*go-backend*`,
  read at SPAWN time and `^:dynamic`, so a `binding` around a whole workload
  selects the backend for every go block it starts: `:thread` (the default) puts
  each go block on a real OS thread, `:fiber` on a Jolt fiber.

  Two layers, because they answer different questions:

    (a) per-test — run each individual deftest of the backend-agnostic suites
        under both backends, `loops` times each, and report per-test means. This
        is finer than timing a whole run-tests call, which clojure.test harness
        overhead dominated. The three `*fibers*` namespaces are excluded: they
        bind `:fiber` internally (16/14/8 sites), so they are not A/B-able
        without edits. No suite declares fixtures, so test-var is the whole run.

    (b) microbenchmark — a repeatable async workload (N go-blocks x K park
        cycles), profiled per backend. This is the comparison.

    (c) what parks and what pins — `units` concurrent processes each doing the
        same sleep, timed as a batch. Parking releases the fiber's carrier and
        overlaps; pinning (Thread/sleep) holds it and serializes. See the
        layer's own header for the cells and why concurrency is required.

  Run:
    ./jolt bench                                   ; task, both layers, defaults
    ./jolt -A:test -m jolt.bench-runner 200 50 10       ; n=200 k=50 reps=10
    ./jolt -A:test -m jolt.bench-runner --b-only        ; microbenchmark only

  Jolt's :tasks do not forward extra CLI args, so n/k/reps and --b-only only
  take effect through the raw `-m` form above; `./jolt bench <args>` silently
  runs the defaults.

  tufte's `format-pstats` cannot run on Jolt yet: it routes through
  encore/format-num-fn, which needs java.text.DecimalFormat.setGroupingSize and
  a java.text.DecimalFormatSymbols class that Jolt does not shim. The MEASUREMENT
  is unaffected, so the tables below are rendered from the pstats data directly —
  `(deref pstats)` is a RealizedPStats record carrying
  {:clock {:total ns} :stats {id {:n :sum :min :max :mean :p50 :p90 :p99}}}."
  (:require [clojure.core.async :as a]
            [clojure.test :as test]
            [superv.async :as S]
            [jolt.fibers :as fib]
            ;; Before tufte: registers the java.util.Stack ctor its impl needs.
            [jolt.taoensso]
            [taoensso.tufte :as tufte]
            [is.simm.partial-cps.async :as pca]
            [is.simm.partial-cps.core-async :as ca]
            ;; Layer (a)'s targets are required HERE rather than at run time: a
            ;; top-level (require ...) is invisible to AOT/DCE, so under
            ;; `build -m jolt.bench-runner --opt` the namespaces would not be compiled
            ;; into the binary, run-tests would find no vars, and every row would
            ;; read "Ran 0 tests". Same trap jlt/b2afec3 records for the runner.
            [jolt.superv-async-test]
            [jolt.superv-cps-test]
            [jolt.partial-cps-core-async-test]))

(def backends [:thread :fiber])

;; ---------------------------------------------------------------- workload

(defn park-workload
  "N go-blocks, each doing K put/take cycles on a buffer-1 channel. Every cycle
  parks, so the cost of parking and resuming dominates — which is the thing the
  two backends actually differ on. Returns when all N have finished.

  The body BLOCKS on the main thread (a/<!!) rather than parking: tufte's
  `profiled` defaults to `:dynamic? false`, and its docs warn that parking calls
  inside such a body can throw. Blocking is not parking, so the default is safe
  here — `:dynamic? true` still fails on this Jolt for unrelated reasons."
  [n k]
  (let [ch (a/chan 1)
        done (a/chan n)]
    (dotimes [_ n]
      (a/go
        (dotimes [_ k] (a/>! ch 1) (a/<! ch))
        (a/>! done true)))
    (dotimes [_ n] (a/<!! done))))

(defn profile-workload
  "Run `park-workload` under `backend`, once, and return its RealizedPStats."
  [backend n k]
  (binding [a/*go-backend* backend]
    (-> (tufte/profiled {:dynamic? false}
          (tufte/p :async-workload (park-workload n k)))
        second
        deref)))

;; ---------------------------------------------------------------- rendering

(defn- ms [ns] (/ (Math/round (* 1000.0 (/ (double ns) 1e6))) 1000.0))

(defn- rj [x w]
  (let [s (str x)]
    (if (>= (count s) w) s (str (apply str (repeat (- w (count s)) " ")) s))))

(defn- lj [x w]
  (let [s (str x)]
    (if (>= (count s) w) s (str s (apply str (repeat (- w (count s)) " "))))))

(defn- stat-row [label {:keys [n mean min p50 max p90]}]
  (str "  " (lj label 16) (rj n 5) (rj (ms mean) 11) (rj (ms min) 11)
       (rj (ms p50) 11) (rj (ms p90) 11) (rj (ms max) 11)))

(defn- stat-header []
  (str "  " (lj "id" 16) (rj "n" 5) (rj "mean(ms)" 11) (rj "min(ms)" 11)
       (rj "p50(ms)" 11) (rj "p90(ms)" 11) (rj "max(ms)" 11)))

(defn- print-profile [title rps]
  (println)
  (println title)
  (println (stat-header))
  (doseq [[id s] (sort-by (comp str key) (:stats rps))]
    (println (stat-row (name id) s)))
  (println (str "  " (lj "clock (total)" 16) (rj "" 5) (rj (ms (:total (:clock rps))) 11))))

;; ------------------------------------------------- layer (b): microbenchmark

(defn- summarize [xs]
  (let [s (sort xs)
        n (count s)
        ;; double, or integer ns sums divide to a Ratio and every call to ms
        ;; reports "1/3" instead of a number.
        mean (/ (double (reduce + s)) n)]
    {:n n
     :mean mean
     :min (first s)
     :p50 (nth s (quot n 2))
     :max (last s)}))

(defn- repeat-workload
  "Run the workload `reps` times under `backend`; the run times in ns."
  [backend n k reps]
  (doall (for [_ (range reps)]
           (:total (:clock (profile-workload backend n k))))))

(defn- microbenchmark [n k reps]
  (println (str "\n=== (b) async microbenchmark: " n " go-blocks x " k
                " park cycles, " reps " reps per backend ==="))
  (let [results (into {} (for [b backends] [b (summarize (repeat-workload b n k reps))]))]
    (println)
    (println (str "  " (lj "backend" 10) (rj "reps" 5) (rj "mean(ms)" 11) (rj "min(ms)" 11)
                  (rj "p50(ms)" 11) (rj "max(ms)" 11)))
    (doseq [b backends]
      (let [{:keys [n mean min p50 max]} (results b)]
        (println (str "  " (lj b 10) (rj n 5) (rj (ms mean) 11) (rj (ms min) 11)
                      (rj (ms p50) 11) (rj (ms max) 11)))))
    (let [t (get-in results [:thread :mean]) f (get-in results [:fiber :mean])
          speedup (/ (double t) (double f))]
      (println)
      (println (str "  fiber speedup (thread mean / fiber mean): "
                    (rj (/ (Math/round (* 100.0 speedup)) 100.0) 8)
                    "x" (if (> speedup 1.0) "  (fiber faster)" "  (fiber SLOWER)"))))
    results))

;; ------------------------------------------------ layer (a): namespace-level

(def backend-agnostic-namespaces
  "Suites with no internal *go-backend* binding, so a binding around the run
  selects the backend for everything they spawn."
  '[jolt.superv-async-test
    jolt.superv-cps-test
    jolt.partial-cps-core-async-test])

(defn- ns-test-vars
  "The deftest vars of a namespace, in name order."
  [ns-sym]
  (->> (ns-interns ns-sym)
       vals
       (filter #(:test (meta %)))
       (sort-by #(str (:name (meta %))))))

(defn- run-var-timed
  "Run ONE test var under `backend`, returning elapsed NANOSECONDS (raw, like
  the microbenchmark's clock totals — converting here and again at the table
  double-converted and rounded every row to 0.0).

  These suites declare no fixtures, so test-var is the whole story. The report
  counters are rebound per run so the 2 x loops invocations cannot accumulate
  into the process's totals."
  [v backend]
  (binding [a/*go-backend* backend
            test/*report-counters* (ref test/*initial-report-counters*)]
    (let [t0 (System/nanoTime)]
      (test/test-var v)
      (- (System/nanoTime) t0))))

(defn- per-test [loops]
  (println (str "\n=== (a) per-test: " loops " loops per backend, median (p50) ms ==="))
  (println "    (median, not mean: the first loop of each test pays warmup —")
  (println "     a 85us/52us/54us spread on one test is typical, and a mean")
  (println "     would fold that outlier into every row.)")
  (doseq [ns-sym backend-agnostic-namespaces]
    (println)
    (println (str "  " ns-sym))
    (println (str "    " (lj "test" 46) (rj ":thread" 11) (rj ":fiber" 11) (rj "speedup" 10)))
    (doseq [v (ns-test-vars ns-sym)]
      (let [tm (summarize (doall (for [_ (range loops)] (run-var-timed v :thread))))
            fm (summarize (doall (for [_ (range loops)] (run-var-timed v :fiber))))
            sp (/ (double (:p50 tm)) (double (:p50 fm)))]
        (println (str "    " (lj (:name (meta v)) 46)
                      (rj (ms (:p50 tm)) 11) (rj (ms (:p50 fm)) 11)
                      (rj (/ (Math/round (* 100.0 sp)) 100.0) 10)))))))

;; --------------------------- layer (c): what parks and what pins
;;
;; The axis is the one https://jolt-lang.net/docs/fibers.html#what_parks_and_what_pins
;; draws. A fiber runs on a CARRIER — an OS thread shared by many fibers — and
;; what the blocking unit does to that carrier is the whole story:
;;
;;   park  a channel op (a/<! on a timeout is the sleeping case) RELEASES the
;;         carrier, so every fiber queued behind keeps running.
;;   pin   Thread/sleep — like file IO, slurp, or an FFI call — HOLDS it. Jolt
;;         cannot move a waiting fiber, because a captured continuation can only
;;         be resumed on the thread that captured it, so the fibers behind are
;;         stranded until it returns.
;;
;; Pinning is invisible without CONCURRENCY: with one fiber, pin and park cost
;; the same. So every cell spawns `units` processes that all run the same
;; `sleep-ms` unit at once, and times the WHOLE batch. Parking overlaps them and
;; finishes in about sleep-ms; pinning serializes them across the carriers and
;; takes about units/carriers x sleep-ms.
;;
;; Cells, same concurrency, same sleep:
;;   :fiber/park    (a/<! (a/timeout sleep-ms))                 -> releases
;;   :fiber/pin     (Thread/sleep sleep-ms)                     -> holds
;;   :fiber/thread  (a/<! (a/thread (Thread/sleep sleep-ms)))   -> the docs'
;;                  documented escape: the blocking work runs on a real OS
;;                  thread while the fiber parks on the channel.
;;   :thread        the same sleep with *go-backend* :thread, where every go IS
;;                  its own OS thread — no shared carrier, so no hazard. This is
;;                  the control: it should match :fiber/park, not :fiber/pin.

(def ^:private sleep-ms 20)
(def ^:private units 20)

(defn- batch
  "Spawn `units` processes under `backend` via (spawn done), wait for all of
  them, and return the elapsed NANOSECONDS for the WHOLE batch — the figure
  pinning distorts. Per-unit timing would hide it entirely. Raw ns, converted
  once at the table (converting here too rounds every row to 0.0)."
  [backend spawn]
  (binding [a/*go-backend* backend]
    (let [done (a/chan units)
          t0 (System/nanoTime)]
      (dotimes [_ units] (spawn done))
      (dotimes [_ units] (a/<!! done))
      (- (System/nanoTime) t0))))

(defn- park-unit
  "Sleeps by parking on a timeout channel — the carrier is released."
  [done]
  (a/go (a/<! (a/timeout sleep-ms)) (a/>! done true)))

(defn- pin-unit
  "Sleeps by holding the carrier outright."
  [done]
  (a/go (Thread/sleep sleep-ms) (a/>! done true)))

(defn- thread-unit
  "The documented escape: real blocking work on a thread, fiber parks on it."
  [done]
  (a/go (a/<! (a/thread (Thread/sleep sleep-ms))) (a/>! done true)))

(def park-styles
  [[:fiber/park   (fn [] (batch :fiber park-unit))]
   [:fiber/pin    (fn [] (batch :fiber pin-unit))]
   [:fiber/thread (fn [] (batch :fiber thread-unit))]
   [:thread       (fn [] (batch :thread pin-unit))]])

(defn- park-style-comparison [reps]
  (println (str "\n=== (c) what parks and what pins: " units " concurrent x "
                sleep-ms "ms sleep, " reps " reps (batch ms) ==="))
  (println (str "    a batch that PLAYS FAIR finishes in ~" sleep-ms
                "ms; one that PINS the carrier serializes and takes longer"))
  ;; pins serialize across the CARRIERS, so units/carriers waves is what the
  ;; pin row should approach — the ratio is uninterpretable without this.
  (println (str "    carriers: " (try (fib/carrier-count) (catch Exception _ "?"))
                ", units: " units "  -> a fully-serialized pin batch would be ~"
                (quot units (max 1 (try (fib/carrier-count) (catch Exception _ 1))))
                " waves"))
  (println)
  (println (str "  " (lj "cell" 15) (rj "n" 5) (rj "mean(ms)" 11) (rj "min(ms)" 11)
                (rj "p50(ms)" 11) (rj "max(ms)" 11)))
  (let [results (into {} (for [[label f] park-styles]
                           [label (summarize (doall (for [_ (range reps)] (f))))]))]
    (doseq [[label _] park-styles]
      (let [{:keys [n mean min p50 max]} (results label)]
        (println (str "  " (lj label 15) (rj n 5) (rj (ms mean) 11) (rj (ms min) 11)
                      (rj (ms p50) 11) (rj (ms max) 11)))))
    (let [r2 (fn [x] (/ (Math/round (* 100.0 x)) 100.0))
          p (double (:p50 (results :fiber/park)))
          i (double (:p50 (results :fiber/pin)))
          t (double (:p50 (results :fiber/thread)))
          h (double (:p50 (results :thread)))]
      (println)
      (println (str "  pin/park           <- what holding the carrier costs: "
                    (rj (r2 (/ i p)) 8) "x"))
      (println (str "  thread/park        <- the docs' escape vs parking:     "
                    (rj (r2 (/ t p)) 8) "x"))
      (println (str "  thread-backend/park <- control, no shared carrier:     "
                    (rj (r2 (/ h p)) 8) "x")))
    results))

;; ------------------------------------------------------------------- main

(defn -main [& args]
  (let [args (vec args)
        bench-only? (some #{"--b-only"} args)
        nums (mapv parse-long (filter #(re-matches #"\d+" %) args))
        n (or (first nums) 200)
        k (or (second nums) 50)
        reps (or (nth nums 2 nil) 5)
        loops (or (nth nums 3 nil) 10)]
    (println (str "jolt " (System/getProperty "jolt.version")
                  "  backends " backends))
    (microbenchmark n k reps)
    (when-not bench-only?
      ;; Layer (c) needs only FEW samples: each batch takes tens of ms and the
      ;; effect it measures is a multiple, not a few percent. (Its predecessor,
      ;; the cheap-vs-capture axis, was percent-scale and needed ~200.)
      (park-style-comparison loops)
      (per-test loops))
    (println)
    (System/exit 0)))
