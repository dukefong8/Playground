(ns mcbot.verify
  "End-to-end proof against the live library. Exits 0 on green, 1 on red.

  Determinism core: reset to a seed, walk, checksum twice across a fresh
  reset and require equality. Save round trip: image out, restore, same
  checksum. No window, no screenshots."
  (:require [mcbot.server :as server]))

(defn- check [label cond*]
  (println (if cond* "PASS" "FAIL") label)
  cond*)

(defn -main [& _]
  (let [ok (atom true)
        note (fn [label c] (swap! ok #(and % (check label c))))]
    (try
      (server/start-server!)
      (note "server started" true)
      (let [r1 (server/run-batch! [{:op :reset :seed 123}])
            c1 (:checksum (first r1))]
        (note "reset returns checksum" (and (:ok (first r1)) (some? c1)))
        (let [w (server/run-batch! [{:op :walk :dir [0 1] :ticks 120}])]
          (note "walk ticks done" (= 120 (:ticks-done (first w))))
          (note "walk moved pose" (some? (get-in (first w) [:pose :feet]))))
        (let [c2 (:checksum (first (server/run-batch! [{:op :checksum}])))]
          (server/run-batch! [{:op :reset :seed 123}
                               {:op :walk :dir [0 1] :ticks 120}])
          (let [c3 (:checksum (first (server/run-batch! [{:op :checksum}])))]
            (note "deterministic replay" (= c2 c3)))))
        (let [s (first (server/run-batch! [{:op :snapshot}]))]
          (note "snapshot shape"
                (and (:ok s) (some? (:pose s)) (= 8 (count (:bag s)))
                (string? (:goal s)))))
        (let [sv (first (server/run-batch! [{:op :save-file
                                             :path "/tmp/mcbot-verify.sav"}]))]
          (note "save file" (and (:ok sv) (pos? (:bytes sv))))
        (let [before (:checksum (first (server/run-batch! [{:op :checksum}])))]
          (server/run-batch! [{:op :walk :dir [0 1] :ticks 60}])
          (server/run-batch! [{:op :load-file
                                :path "/tmp/mcbot-verify.sav"}])
          (let [after (:checksum (first (server/run-batch! [{:op :checksum}])))]
            (note "save restore round trip" (= before after)))))
      (catch Throwable e
        (reset! ok false)
        (println "FAIL exception" (ex-message e) (ex-data e)))
      (finally
        (try (server/stop-server!) (catch Throwable _ nil))))
    (System/exit (if @ok 0 1))))
