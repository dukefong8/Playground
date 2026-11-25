(ns mcbot.pump
  "Owner-thread pump. Heap-touching FFI runs here and nowhere else.

  The pump is mechanism: it owns thread handoff and knows nothing about
  game ops. The caller injects policy as :exec-fn. nREPL eval threads are
  pure submitters through submit!. The owner thread is recorded twice:
  the :owner-id atom for cross-thread introspection, and the *owner*
  dynamic binding for same-thread enforcement inside exec."
  (:require [clojure.core.async :as async]))

(def chan-cap 64)
(def shutdown ::shutdown)

(def ^:dynamic *owner* nil)

(defn- owner-loop! [req-chan exec-fn owner-id ready]
  (reset! owner-id (.getId (Thread/currentThread)))
  (deliver ready true)
  (binding [*owner* (.getId (Thread/currentThread))]
    (loop []
      (let [msg (async/<!! req-chan)]
        (if (identical? msg shutdown)
          :stopped
          (let [{:keys [action p]} msg]
            (deliver p (try (exec-fn action)
                            (catch Throwable e
                              {:op (:op action) :ok false :reason :exec-threw
                               :detail (ex-message e)})))
            (recur)))))))

(defn start-pump!
  "Start the owner thread and park it in take, exec, deliver.
  :exec-fn runs on the owner thread for every submitted action.
  :on-owner-ready runs first on the owner thread (load library plus
  goose_init go here once the lib exists). Returns a handle map."
  [{:keys [exec-fn on-owner-ready]}]
  (let [req-chan (async/chan chan-cap)
        owner-id (atom nil)
        ready (promise)
        task (future
               (when on-owner-ready (on-owner-ready))
               (owner-loop! req-chan exec-fn owner-id ready))]
    {:chan req-chan :task task :owner-id owner-id :ready ready}))

(defn submit!
  "Enqueue one action plan from any thread and block for its outcome.
  Waits for the owner thread to be ready first. Never touches ffi directly."
  [{:keys [chan ready] :as handle} action]
  (let [r (deref ready 30000 ::not-ready)]
    (when (= r ::not-ready)
      (throw (ex-info "pump owner never became ready"
                      {:error :pump-not-ready}))))
  (let [p (promise)]
    (async/>!! chan {:action action :p p})
    @p))

(defn owner-thread?
  "True when called on the pump owner thread. Pure introspection."
  [{:keys [owner-id]}]
  (= (.getId (Thread/currentThread)) @owner-id))

(defn stop-pump!
  "Send shutdown and join the owner thread. Returns its final value.
  Never calls goose_exit from a non-owner thread: the owner exits its
  own loop, and runtime teardown (if any) belongs to :on-owner-stop."
  [{:keys [chan task]}]
  (async/>!! chan shutdown)
  @task)
