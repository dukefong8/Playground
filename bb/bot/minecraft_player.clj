(ns minecraft-player
  "Keyboard-only player for ../gs/minecraft.goose, driven via wtype.

  Mining needs a left-mouse hold and wtype speaks only the
  virtual-keyboard protocol, so this bot is keyboard-only and mining is
  the documented gap. To cover mining, drive the game through the
  export_abi.goose shared library (bound from test/goose/export_abi.clj)
  instead of synthetic input."
  (:require [babashka.process :as proc]
            [babashka.fs :as fs]))

(def ^:dynamic *dry-run* false)

(def key-names
  {"W" "w" "A" "a" "S" "s" "D" "d"
   "Space" "space" "Shift" "Shift_L" "Ctrl" "Control_L"
   "Up" "Up" "Down" "Down" "Left" "Left" "Right" "Right"
   "E" "e" "C" "c" "H" "h"
   "1" "1" "2" "2" "3" "3" "4" "4"
   "5" "5" "6" "6" "7" "7" "8" "8"
   "Escape" "Escape" "F5" "F5" "F9" "F9" "F12" "F12"})

(defn wtype?
  []
  (boolean (fs/which "wtype")))

(defn ensure-wtype!
  []
  (when-not (wtype?)
    (throw (ex-info "wtype not found; install wtype for Wayland virtual-keyboard input"
                    {:missing "wtype"}))))

(defn- wkey [k]
  (or (get key-names k)
      (throw (ex-info (str "unknown key: " k) {:key k}))))

(defn tap!
  [k {:keys [pause-after-ms] :or {pause-after-ms 120}}]
  (let [w (wkey k)]
    (if *dry-run*
      (prn {:op :tap :key k :wtype w :pause-after-ms pause-after-ms})
      (do (ensure-wtype!)
          (proc/sh "wtype" "-k" w)
          (Thread/sleep (long pause-after-ms))))))

(defn hold!
  [k {:keys [hold-ms pause-after-ms] :or {hold-ms 400 pause-after-ms 200}}]
  (let [w (wkey k)]
    (if *dry-run*
      (prn {:op :hold :key k :wtype w :hold-ms hold-ms :pause-after-ms pause-after-ms})
      (do (ensure-wtype!)
          (proc/sh "wtype" "-P" w)
          (Thread/sleep (long hold-ms))
          (proc/sh "wtype" "-p" w)
          (Thread/sleep (long pause-after-ms))))))

(defn press!
  [k {:keys [hold-ms] :or {hold-ms 80} :as opts}]
  (hold! k (assoc opts :hold-ms hold-ms)))

(defn plan-session
  [{:keys [seed goal] :or {seed 0} :as _session}]
  (let [s (long (or seed 0))
        _ goal
        step (fn [k hold pause i]
               {:key k
                :hold-ms (+ hold (mod (+ s (* i 37)) 120))
                :pause-after-ms (+ pause (mod (+ s (* i 91)) 180))})]
    [(step "W" 1500 400 1)
     (step "Left" 600 250 2)
     (step "Right" 600 250 3)
     (step "Up" 400 250 4)
     (step "Space" 90 300 5)
     (step "1" 70 200 6)
     (step "3" 70 200 7)
     (step "5" 70 350 8)
     (step "C" 80 700 9)
     (step "C" 80 500 10)
     (step "E" 100 400 11)
     (step "F5" 80 600 12)
     (step "Escape" 80 700 13)
     (step "Escape" 80 300 14)]))

(defn- play-step!
  [{:keys [key hold-ms] :as step}]
  (if (<= (long hold-ms) 250)
    (tap! key step)
    (hold! key step)))

(defn perform!
  ([plan] (perform! plan nil))
  ([plan {:keys [dry-run]}]
   (binding [*dry-run* (boolean dry-run)]
     (doseq [step plan] (play-step! step))
     plan)))

(defn -main
  [& args]
  (loop [args (vec args) dry-run false seed 0]
    (cond
      (empty? args)
      (do (perform! (plan-session {:seed seed}) {:dry-run dry-run}) nil)
      (= (first args) "--dry-run")
      (recur (subvec args 1) true seed)
      (= (first args) "--seed")
      (if-let [v (get args 1)]
        (recur (subvec args 2) dry-run
               (try (Long/parseLong v)
                    (catch NumberFormatException _
                      (binding [*out* *err*] (println (str "bad --seed: " v)))
                      (System/exit 2))))
        (do (binding [*out* *err*] (println "missing value for --seed"))
            (System/exit 2)))
      :else
      (do (binding [*out* *err*] (println (str "unknown arg: " (first args))))
          (System/exit 2)))))
