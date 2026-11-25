(ns mcbot.server
  "Thin shell over the pump. No game logic here.

  The pump handle lives in a global so a bare nREPL eval can drive the
  game with no session setup: (mcbot.server/run-batch! '[...]).
  start-server! wires the real policy (registry dispatch over FFI) once.
  Eval threads only ever reach pump/submit!, never ffi."
  (:require [mcbot.ffi-defs :as defs]
            [mcbot.pump :as pump]
            [mcbot.registry :as reg]
            [mcbot.translate :as translate]))

(defonce pump-h (atom nil))

(defn ensure-pump!
  "Start the owner thread once and remember the handle. Idempotent."
  [opts]
  (or @pump-h (reset! pump-h (pump/start-pump! opts))))

(defn start-server!
  "Start the pump with the real registry policy and own the runtime.
  The single choke point: every heap call below runs on the owner thread."
  []
  (ensure-pump! {:exec-fn reg/exec-action
                 :on-owner-ready (fn [] (defs/init!))}))

(defn stop-server!
  "Shut the pump down and forget the handle."
  []
  (let [h @pump-h]
    (reset! pump-h nil)
    (when h (pump/stop-pump! h))))

(defn run-batch!
  "Translate then submit each action in order against the global pump.
  Returns the position-aligned outcome vector."
  [batch]
  (let [h @pump-h]
    (when-not h
      (throw (ex-info "no pump running: call start-server! first"
                      {:error :no-pump})))
    (mapv (fn [action] (pump/submit! h (translate/action->plan action)))
          batch)))

(defn reset-world!
  "One-call deterministic through the global pump."
  [seed]
  (let [h @pump-h]
    (when-not h
      (throw (ex-info "no pump running: call start-server! first"
                      {:error :no-pump})))
    (pump/submit! h (translate/action->plan {:op :reset :seed seed}))))
