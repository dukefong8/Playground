(ns goose.minecraft
  "Jolt wrapper around ../gs/minecraft.goose, a Goose block-world game.

   Three modes, chosen once from the CLI args into an opts map:
   - headless verification (:test, --test): gameplay checks, no window.
   - deterministic render (:frames N, --frames N --seed S): a fresh world
     rendered N frames, saving mini_minecraft.png.
   - interactive play (:play): opens the gfx window, inherits terminal IO.

   The goose runtime is owned per process/thread (gs/export_abi.md §3-4),
   so the game always runs in its own `goose` process; this wrapper never
   loads its symbols in-process (no ffi/load-library here).")

(def ^:private default-seed 2026)
(def ^:private max-n 2147483647)

(def ^:private usage-str
  (str "usage: jolt -m goose.minecraft [--seed N] [--frames N] [--test]\n"
       "  --test runs headless gameplay checks without opening a window;\n"
       "  combine with --frames N to render N frames right after the checks.\n"
       "  --frames N renders N frames of a fresh world (--seed S, default 2026);\n"
       "  no flags opens the game window."))

(defn- sh
  "Runs a command with stdout and stderr merged into a string."
  [& args]
  (let [pb (ProcessBuilder. (into-array String (vec args)))]
    (.redirectErrorStream pb true)
    (let [p (.start pb)
          out (slurp (.getInputStream p))
          code (.waitFor p)]
      {:exit code :out out})))

(defn goose-file
  "Path to the game, resolved against the project dir (no home paths)."
  []
  (str (System/getProperty "user.dir") "/../gs/minecraft.goose"))

(defn- parse-int [s]
  (try (Long/parseLong s) (catch Exception _ nil)))

(defn parse-args
  "Pure: argv vector -> {:test :seed :frames :help} or {:error msg}."
  [args]
  (loop [args (vec args) acc {:test false :seed nil :frames nil :help false}]
    (if (empty? args)
      acc
      (let [a (first args)]
        (cond
          (or (= a "--help") (= a "-h")) (recur (vec (rest args)) (assoc acc :help true))
          (= a "--test") (recur (vec (rest args)) (assoc acc :test true))
          (or (= a "--seed") (= a "--frames"))
          (let [n (when (second args) (parse-int (second args)))]
            (if (nil? n)
              {:error (str a " needs an integer, got: " (pr-str (second args)))}
              (recur (vec (drop 2 args)) (assoc acc (keyword (subs a 2)) n))))
          :else {:error (str "unknown flag: " a)})))))

(defn validate
  "Pure: parsed args -> {:ok {:mode :test/:frames/:play :seed :frames}} or {:error msg}."
  [{:keys [test seed frames] :as parsed}]
  (if (:error parsed)
    parsed
    (cond
      (and (some? seed) (or (neg? seed) (> seed max-n))) {:error "seed must be 0..2147483647"}
      (and (some? frames) (or (< frames 1) (> frames max-n))) {:error "frames must be 1..2147483647"}
      test {:ok {:mode :test :seed (or seed default-seed) :frames (or frames -1)}}
      (some? frames) {:ok {:mode :frames :seed (or seed default-seed) :frames frames}}
      :else {:ok {:mode :play :seed (or seed default-seed) :frames -1}})))

(defn- game-args
  [{:keys [mode seed frames]}]
  (case mode
    :test (if (and (some? frames) (pos? frames))
            ["--test" "--frames" (str frames) "--seed" (str seed)]
            ["--test" "--seed" (str seed)])
    :frames ["--frames" (str frames) "--seed" (str seed)]
    :play ["--seed" (str seed)]))

(defn run-tests!
  "Headless gameplay checks in the game's own process. Prints output, returns exit."
  [opts]
  (let [{:keys [exit out]} (apply sh "goose" (goose-file) "--" (game-args opts))]
    (print out)
    (flush)
    exit))

(defn render-frames!
  "Deterministic render in the game's own process. Prints output, returns exit."
  [opts]
  (let [{:keys [exit out]} (apply sh "goose" (goose-file) "--" (game-args (assoc opts :mode :frames)))]
    (print out)
    (flush)
    exit))

(defn play!
  "Opens the game window. The child inherits our IO (nothing captured); returns its exit."
  [opts]
  (let [pb (ProcessBuilder. (into-array String (into ["goose" (goose-file) "--"] (game-args opts))))]
    (.inheritIO pb)
    (.waitFor (.start pb))))

(defn -main
  [& args]
  (let [parsed (parse-args (vec args))]
    (cond
      (:error parsed)
      (do (binding [*out* *err*] (println (:error parsed)) (println usage-str))
          (System/exit 1))

      (:help parsed)
      (do (println usage-str)
          (System/exit 0))

      :else
      (let [v (validate parsed)]
        (if (:error v)
          (do (binding [*out* *err*] (println (:error v)) (println usage-str))
              (System/exit 1))
          (System/exit (case (:mode (:ok v))
                         :test (run-tests! (:ok v))
                         :frames (render-frames! (:ok v))
                         :play (play! (:ok v)))))))))
