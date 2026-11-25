(ns mcbot.translate
  "Pure edn to plan translation. The only leakage boundary.

  Callers speak Action maps. The pump speaks FFI plans. Everything
  between is a pure function here, so validation, defaults, and
  normalization are testable without a library or a thread."
  (:require [mcbot.registry :as reg]))

(def defaults
  "Per-op defaults. Missing keys take these before validation."
  {:walk {:ticks 60 :jump? false :run? false :sneak? false}
   :ray  {:reach 6.0}
   :mine {:ticks 120}
   :craft {:all false}})

(defn normalize-dir
  "Scale [dx dz] to length at most 1, mirroring walk(). Pure."
  [[dx dz]]
  (let [dx (double dx) dz (double dz)
        len (Math/sqrt (+ (* dx dx) (* dz dz)))]
    (if (> len 1.0) [(/ dx len) (/ dz len)] [dx dz])))

(defn action->plan
  "Fill defaults, normalize, validate. Returns the executable plan map.
  Throws ex-info on :unknown-op or :bad-args."
  [{:keys [op] :as action}]
  (let [merged (merge (get defaults op) action)]
    (reg/validate-action merged)
    (cond-> merged
      (= op :walk) (update :dir normalize-dir))))
