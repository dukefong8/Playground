(ns mcbot.registry
  "The single list every bot action flows through.

  Each entry is {:spec :doc :exec}. Dispatch, validation, and help text
  derive from this map, so adding an op is one entry here and nothing
  else. :exec fns run on the pump thread only; exec-action refuses to
  run anywhere else (the pump binds mcbot.pump/*owner*)."
  (:require [babashka.fs :as fs]
            [mcbot.ffi-defs :as defs]
            [mcbot.pump :as pump]))

(def ^:private max-ticks 600)

(defn- dir2? [d]
  (and (vector? d) (= 2 (count d)) (every? number? d)))

(defn- int-in? [lo hi]
  (fn [n] (and (integer? n) (<= lo n hi))))

(defn- cell? [c]
  (and (vector? c) (= 3 (count c)) (every? integer? c)))

(declare known-ops)

(defn pose->map
  "Flat pose reads to the Pose shape callers see. Pure."
  [{:keys [feet-x feet-y feet-z yaw pitch vel grounded]}]
  {:feet [(double feet-x) (double feet-y) (double feet-z)]
   :yaw (double yaw) :pitch (double pitch)
   :grounded (not (zero? grounded))
   :velocity (double vel)})

(defn hit->map
  "Flat hit reads to the hit shape callers see. Pure."
  [{:keys [found ax ay az bx by bz distance]}]
  (if (zero? found)
    {:found false}
    {:found true :at [ax ay az] :before [bx by bz]
     :distance (double distance)}))

(def actions
  {:walk     {:spec {:dir dir2? :ticks (int-in? 1 600)}
              :doc  "Step physics :ticks times along :dir [dx dz]."
              :exec (fn [{:keys [dir ticks jump? run? sneak?]}]
                      (defs/walk-step! (first dir) (second dir)
                                      jump? run? sneak? ticks)
                      {:ticks-done ticks :pose (pose->map (defs/pose!))})}
   :look     {:spec {:dx number? :dy number?}
              :doc  "Look by pixel deltas :dx :dy (yaw += dx * 0.003)."
              :exec (fn [{:keys [dx dy]}]
                      {:pose (pose->map (defs/look! dx dy))})}
   :ray      {:spec {:reach number?}
              :doc  "Sense the faced block. Defaults :reach 6.0."
              :exec (fn [{:keys [reach]}]
                      {:hit (hit->map (defs/ray! reach))})}
   :mine     {:spec {:ticks (int-in? 1 600)}
              :doc  "Hold mine :ticks steps against the faced block."
              :exec (fn [{:keys [ticks]}]
                      (let [[code hit] (defs/mine-ticks! ticks)]
                        {:code code :mined (= code 2) :busy (= code 1)
                         :hit (hit->map hit)}))}
   :place    {:spec {}
              :doc  "Place the selected slot at the faced air cell."
              :exec (fn [_]
                      (let [[code hit] (defs/place-once!)]
                        {:placed (= code 1) :hit (hit->map hit)}))}
   :pick     {:spec {}
              :doc  "Select the faced material (middle-click verb)."
              :exec (fn [_] (defs/pick!) {})}
   :select   {:spec {:slot (int-in? 0 7)}
              :doc  "Select hotbar slot 0..7."
              :exec (fn [{:keys [slot]}]
                      (if (zero? (defs/select! slot))
                        {:ok false :reason :bad-slot :slot slot}
                        {:selected slot}))}
   :craft    {:spec {:recipe (int-in? 0 3) :all boolean?}
              :doc  "Run recipe 0..3, all batches when :all."
              :exec (fn [{:keys [recipe all]}]
                      (let [batches (defs/craft! recipe all)
                            tool (:tool (defs/status!))]
                        {:batches batches :tool tool}))}
   :reset    {:spec {:seed integer?}
              :doc  "Regenerate the world with :seed. Deterministic."
              :exec (fn [{:keys [seed]}]
                      (defs/reset-world! seed)
                      {:seed seed :checksum (defs/checksum!)})}
   :snapshot {:spec {}
              :doc  "Read pose, bag, tool, clock. Optional :windows for blocks."
              :exec (fn [{:keys [windows]}]
                      (let [status (defs/status!)
                            pose (pose->map (defs/pose!))]
                        (merge {:pose pose :goal (defs/next-goal!)}
                               (select-keys status [:bag :tool :selected
                                                   :day-time :lamps])
                               (when (seq windows)
                                 {:blocks (mapv (fn [{:keys [lo hi]}]
                                                 (defs/scan-window! lo hi))
                                               windows)}))))}
   :checksum {:spec {}
              :doc  "World checksum for replay equality."
              :exec (fn [_] {:checksum (defs/checksum!)})}
   :time     {:spec {:dt number?}
              :doc  "Advance the day clock by :dt."
              :exec (fn [{:keys [dt]}]
                      (defs/advance! dt)
                      {:day-time (defs/day-time!)})}
   :save-file {:spec {:path string?}
               :doc  "Write the world image to :path (atomic)."
               :exec (fn [{:keys [path]}]
                       (let [bytes (defs/save-bytes!)
                             tmp (str path ".tmp")]
                         (fs/write-bytes tmp bytes)
                         (fs/move tmp path {:replace-existing true})
                         {:path path :bytes (alength bytes)}))}
   :load-file {:spec {:path string?}
               :doc  "Restore the world image from :path."
               :exec (fn [{:keys [path]}]
                       (when-not (fs/exists? path)
                         (throw (ex-info "save not found"
                                        {:error :bad-args :path path})))
                       (let [code (defs/restore-bytes!
                                   (fs/read-all-bytes path))]
                         (if (zero? code)
                           {:ok false :reason :corrupt-save :path path}
                           {:path path :checksum (defs/checksum!)})))}
   :help     {:spec {}
              :doc  "List known ops with one-line docs."
              :exec (fn [_] {:ops (known-ops)})}})

(defn known-ops
  "Sorted op keywords, derived from the registry."
  []
  (sort (keys actions)))

(defn validate-action
  "Nil when action is well formed. Throws ex-info with :error
  :unknown-op or :bad-args otherwise."
  [{:keys [op] :as action}]
  (if-let [entry (get actions op)]
    (let [spec (:spec entry)
          bad (remove (fn [[k pred]] (pred (get action k))) spec)]
      (when (seq bad)
        (throw (ex-info "bad action args" {:error :bad-args :op op
                                           :keys (mapv first bad)})))
      nil)
    (throw (ex-info "unknown op" {:error :unknown-op :op op}))))

(defn- check-owner! [op]
  (let [owner @#'pump/*owner*]
    (when (and (some? owner)
               (not= (.getId (Thread/currentThread)) owner))
      (throw (ex-info "heap exec off owner thread"
                      {:error :wrong-thread :op op})))))

(defn exec-action
  "Validate then run on the calling thread. The pump binds
  mcbot.pump/*owner*, so direct eval-thread calls refuse with
  :wrong-thread. Merges the op envelope; an :ok already present
  (failure fragments) is never overwritten."
  [{:keys [op] :as action}]
  (validate-action action)
  (check-owner! op)
  (let [fragment (((get actions op) :exec) action)]
    (merge {:op op} (if (contains? fragment :ok)
                      fragment
                      (assoc fragment :ok true)))))

(defn help-text
  "One line per op, derived from the registry."
  []
  (mapv (fn [op] (str (name op) " - " (get-in actions [op :doc])))
        (known-ops)))
