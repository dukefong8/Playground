(ns build-house
  "Sense-act cabin builder on the mcbot control plane. All behaviour in fns.
  State lives in the world, so every CLI run is one phase: quarry, site,
  floor, walls, roof, status. Each phase verifies its own work by scan."
  (:require [mcbot-client :as bot]
            [clojure.edn :as edn]))

(def conn {:host "127.0.0.1" :port 7888})
(def cobble 8)
(def dirt 2)

(defn run [batch]
  (bot/run-actions! conn batch))

(defn snap [] (first (run [{:op :snapshot}])))
(defn bag [] (:bag (snap)))
(defn cobbles [] (nth (bag) 1))
(defn dirt-n [] (nth (bag) 0))

(defn scan-box [lo hi]
  (get-in (first (run [{:op :snapshot :windows [{:lo lo :hi hi}]}]))
           [:blocks 0 :cells]))

(defn column-tops
  "Map [x z] to highest non-air y in the scanned cells."
  [cells]
  (reduce (fn [m [x y z b]] (if (zero? b) m (update m [x z] (fnil max -99) y)))
          {} cells))

(defn dry-tops
  "Map [x z] to [top-y block] for non-air columns."
  [cells]
  (reduce (fn [m [x y z b]] (if (zero? b) m (assoc m [x z] [y b]))) {} cells))

(defn find-site
  "Nearest 5x5 origin with equal dry tops. Returns [ox oz top] or nil."
  [cells x0 x1 z0 z1 px pz]
  (let [tops (dry-tops cells)
        cands (for [ox (range x0 x1) oz (range z0 z1)
                    :let [w (mapv #(get tops %) (for [x (range ox (+ ox 5)) z (range oz (+ oz 5))] [x z]))]
                    :when (and (every? some? w)
                               (apply = (map first w))
                               (every? #{1 2 3 4} (map second w)))]
                [ox oz (first (first w))])]
    (first (sort-by (fn [[ox oz _]]
                      (let [dx (- ox px) dz (- oz pz)]
                        (+ (* dx dx) (* dz dz))))
                    cands))))

(defn yaw-to [tx tz]
  (let [{:keys [feet yaw]} (:pose (snap))
        [px _ pz] feet
        tyaw (Math/atan2 (- tx px) (- (- tz pz)))
        d (- tyaw yaw)]
    (- d (* 2 Math/PI (Math/floor (/ (+ d Math/PI) (* 2 Math/PI)))))))

(defn face [dx dy]
  (run [{:op :look :dx (double dx) :dy (double dy)}]))

(defn goto [tx tz ticks]
  (let [d (yaw-to tx tz)]
    (run [{:op :look :dx (double (/ d 0.003)) :dy 0.0}
          {:op :walk :dir [0 1] :ticks ticks}])))

(defn aim-at
  "Aim the ray at a solid support cell so placement lands above it."
  [[sx sy sz]]
  (let [{:keys [feet yaw pitch]} (:pose (snap))
        [px py pz] feet
        dx (- (+ sx 0.5) px) dz (- (+ sz 0.5) pz)
        hd (Math/sqrt (+ (* dx dx) (* dz dz)))
        tyaw (Math/atan2 dx (- dz))
        d (let [dd (- tyaw yaw)]
            (- dd (* 2 Math/PI (Math/floor (/ (+ dd Math/PI) (* 2 Math/PI))))))
        ey (+ py 1.62)
        tp (Math/atan2 (- (+ sy 0.5) ey) (max hd 0.1))
        dp (- tp pitch)]
    (run [{:op :look :dx (double (/ d 0.003)) :dy (double (/ (- dp) 0.003))}])))

(defn cell-at [[x y z]]
  (let [cells (scan-box [x y z] [x y z])]
    (if (seq cells) (nth (first cells) 3) 0)))

(defn place-cell
  "Place the selected slot at T using support S. Aims, ray-checks that
  the hit would land exactly on T, and places only then. Never retries
  with perturbed aim: a miss means reposition, not spray. Returns true
  when a scan shows T filled."
  [[tx ty tz] [sx sy sz]]
  (run [{:op :select :slot 1}])
  (aim-at [sx sy sz])
  (let [hit (:hit (first (run [{:op :ray}])))]
    (if (= (:before hit) [tx ty tz])
      (do (run [{:op :place}])
          (not (zero? (cell-at [tx ty tz]))))
      false)))

(defn mine-until
  "Mine the faced block until (pred bag) or limit rounds. Returns bag."
  [pred limit]
  (loop [i 0]
    (let [b (:bag (snap))]
      (if (or (pred b) (>= i limit))
        b
        (do (run [{:op :mine :ticks 150}])
            (recur (inc i)))))))

(defn quarry-phase [want]
  (let [have (cobbles)]
    (if (>= have want)
      {:cobble have :mined 0}
      (do (run [{:op :select :slot 1}])
          (loop [i 0]
            (let [b (:bag (snap))]
              (if (or (>= (nth b 1) want) (>= i 40))
                {:cobble (nth b 1) :rounds i}
                (do
                  (let [p (:pose (snap))
                        [px py pz] (:feet p)]
                    (run [{:op :look :dx 250.0 :dy 0.0}
                           {:op :mine :ticks 200}]))
                  (recur (inc i))))))))))

(defn aim-at-cell
  "Aim the eye ray at the center of a cell."
  [[x y z]]
  (let [p (:pose (first (run [{:op :snapshot}])))
        [px py pz] (:feet p)
        dx (- (+ x 0.5) px)
        dz (- (+ z 0.5) pz)
        hd (max 0.1 (Math/sqrt (+ (* dx dx) (* dz dz))))
        tyaw (Math/atan2 dx (- dz))
        d (let [dd (- tyaw (:yaw p))]
            (- dd (* 2 Math/PI (Math/floor (/ (+ dd Math/PI) (* 2 Math/PI))))))
        ey (+ py 1.62)
        tp (Math/atan2 (- (+ y 0.5) ey) hd)
        dp (- tp (:pitch p))]
    (run [{:op :look :dx (double (/ d 0.003)) :dy (double (/ (- dp) 0.003))}])))

(defn ray-hit []
  (:hit (first (run [{:op :ray}]))))

(defn in-box? [[x0 y0 z0] [x1 y1 z1] [x y z]]
  (and (<= x0 x x1) (<= y0 y y1) (<= z0 z z1)))

(defn clear-box
  "Mine every solid cell inside the inclusive box, never touching
  anything outside it. Returns the air count afterwards."
  [lo hi]
  (let [[x0 y0 z0] lo [x1 y1 z1] hi]
    (doseq [x (range x0 (inc x1))
            y (range y0 (inc y1))
            z (range z0 (inc z1))]
      (aim-at-cell [x y z])
      (let [hit (ray-hit)]
        (when (and (:found hit) (in-box? lo hi (:at hit)))
          (run [{:op :mine :ticks 150}]))))
    (count (filter (fn [[_ _ _ b]] (zero? b)) (scan-box lo hi)))))

(defn -main [& args]
  (let [phase (first args)]
    (println
     (case phase
       "quarry" (quarry-phase 34)
       "status" (select-keys (snap) [:pose :bag :tool :goal])
       {:error :unknown-phase :phase phase}))))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
