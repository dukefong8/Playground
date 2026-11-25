(ns mcbot-client
  "Thin bb client for the Goose block world, driven over nREPL.

  Local validation runs before any round trip. Dry run returns the plan
  (the exact eval text) without sending it, so plans stay reviewable.
  The live path spawns one `bb repl --connect host:port` per batch with the
  eval text on stdin, scans stdout for the marker, and parses the outcome.

  Success returns the outcome vector. Transport problems return
  {:ok false :error :transport :detail {...}} and never throw.
  Only invalid local args (bad batch, bad conn, bad timeout) throw ex-info."
  (:require [babashka.fs :as fs]
            [babashka.process :as p]
            [clojure.edn :as edn]
            [clojure.string :as str]))

(def ^:dynamic *dry-run* false)

(def default-timeout-ms 120000)

(def default-host "127.0.0.1")

(def default-port 7889)

(def marker ":mcbot-out")

(def eval-template
  "(do (require 'mcbot.server) (println :mcbot-out) (prn (mcbot.server/run-batch! '%s)))")

(defn default-form-fn
  "Server-contract eval text for one batch EDN string."
  [batch-edn]
  (format eval-template batch-edn))

(defn validate-batch
  "Nil when batch is a non-empty vector of :op maps. Throws ex-info otherwise."
  [batch]
  (when-not (and (vector? batch) (seq batch) (every? :op batch))
    (throw (ex-info "batch must be a non-empty vector of :op maps"
                    {:batch batch})))
  nil)

(defn build-eval-string
  "Pure: batch data to the exact eval text the transport would send.
  Optional {:form-fn (fn [batch-edn-str] eval-str)} overrides the server
  contract form, so tests can point at a stub form."
  ([batch] (build-eval-string batch nil))
  ([batch {:keys [form-fn]}]
   (validate-batch batch)
   ((or form-fn default-form-fn) (pr-str batch))))

(defn connect!
  "Remember the server address. No IO, no nREPL client needed for dry runs."
  [{:keys [host port]}]
  (when-not (and host port)
    (throw (ex-info "connect! needs :host and :port" {:host host :port port})))
  {:host host :port port :ok true})

(defn- truncate
  "Bound outbound detail strings so failures stay readable."
  [s n]
  (let [s (str s)]
    (if (<= (count s) n) s (str (subs s 0 n) "...<truncated>"))))

(defn- strip-prompt
  "Drop a leading `user=>` prompt: piped `bb repl --connect` prefixes the
  echoed line with it, so the marker arrives as `user=> :mcbot-out`."
  [line]
  (-> line (str/replace #"^\s*user=>\s*" "") str/trim))

(defn- marker?
  [line]
  (str/ends-with? (strip-prompt line) marker))

(defn- extract-outcome-line
  "First non-blank line after the LAST marker line. Nil when absent."
  [stdout]
  (let [lines (str/split-lines (or stdout ""))
        idxs (keep-indexed (fn [i line] (when (marker? line) i)) lines)]
    (when (seq idxs)
      (let [after (drop (inc (last idxs)) lines)]
        (first (remove str/blank? after))))))

(defn- parse-outcomes
  "Outcome vector parsed from raw STDOUT. Throws ex-info when the marker is
  missing, the line is unparsable, or the value is not a vector."
  [stdout]
  (let [line (extract-outcome-line stdout)]
    (when-not line
      (throw (ex-info "missing :mcbot-out marker in server output"
                      {:reason :missing-marker
                       :stdout-tail (truncate stdout 2000)})))
    (let [v (try
              (edn/read-string line)
              (catch Exception e
                (throw (ex-info "unparsable outcome line"
                                {:reason :unparsable-output
                                 :output (truncate line 2000)}
                                e))))]
      (when-not (vector? v)
        (throw (ex-info "outcome is not a vector"
                        {:reason :unexpected-shape
                         :output (truncate (pr-str v) 2000)})))
      v)))

(defn- send-batch!
  "One piped `bb repl --connect host:port` round trip. Returns the outcome
  vector, or {:ok false :error :transport :detail {...}}. Never throws."
  [conn eval-text timeout-ms]
  (let [addr (str (:host conn) ":" (:port conn))]
    (if-not (fs/which "bb")
      {:ok false :error :transport
       :detail {:reason :bb-not-found
                :message "bb binary not on PATH"
                :addr addr}}
      (let [proc (try
                   (p/process ["bb" "repl" "--connect" addr]
                              {:in (str eval-text "\n")
                               :out :string
                               :err :string})
                   (catch Exception e
                     {:spawn-error e}))]
        (if (:spawn-error proc)
          {:ok false :error :transport
           :detail {:reason :spawn-failed
                    :message (ex-message (:spawn-error proc))
                    :addr addr}}
          (let [res (deref proc timeout-ms ::timeout)]
            (cond
              (= res ::timeout)
              (do
                (try (p/destroy proc) (catch Exception _))
                (try (deref proc 5000 nil) (catch Exception _))
                {:ok false :error :transport
                 :detail {:reason :timeout
                          :timeout-ms timeout-ms
                          :addr addr}})

              (not= 0 (:exit res))
              {:ok false :error :transport
               :detail {:reason :non-zero-exit
                        :exit (:exit res)
                        :addr addr
                        :stderr (truncate (:err res) 2000)
                        :stdout-tail (truncate (:out res) 2000)}}

              :else
              (try
                (parse-outcomes (:out res))
                (catch clojure.lang.ExceptionInfo e
                  {:ok false :error :transport
                   :detail (assoc (ex-data e)
                                  :addr addr
                                  :exit (:exit res)
                                  :stdout-tail (truncate (:out res) 2000))})
                (catch Exception e
                  {:ok false :error :transport
                   :detail {:reason :transport-error
                            :message (ex-message e)
                            :addr addr}})))))))))

(defn run-actions!
  "Validate locally, then send one batch. Dry run returns the plan map.
  Live success returns the outcome vector; transport failures return
  {:ok false :error :transport :detail {...}}. Only invalid local args throw."
  ([conn batch] (run-actions! conn batch nil))
  ([conn batch {:keys [dry-run timeout-ms form-fn]
                :or {timeout-ms default-timeout-ms}}]
   (validate-batch batch)
   (when-not (and (map? conn) (:host conn) (:port conn))
     (throw (ex-info "conn needs :host and :port" {:conn conn})))
   (when-not (and (integer? timeout-ms) (pos? timeout-ms))
     (throw (ex-info "timeout-ms must be a positive integer"
                     {:timeout-ms timeout-ms})))
   (if (or dry-run *dry-run*)
     {:dry-run true :conn (select-keys conn [:host :port])
      :eval (build-eval-string batch {:form-fn form-fn})
      :actions (count batch)}
     (send-batch! conn
                  (build-eval-string batch {:form-fn form-fn})
                  timeout-ms))))

(def usage-str
  (str "usage: mcbot-client [--dry-run] [--host H] [--port P] '<batch-edn>'\n"
       "  --dry-run   print the plan (exact eval text) without sending it\n"
       "  --host H    nREPL host (default " default-host ")\n"
       "  --port P    nREPL port (default " default-port ")\n"
       "  batch-edn   EDN vector of :op maps, e.g. '[{:op :forward} {:op :jump}]'\n"
       "exit codes: 0 success, 2 usage/validation error, 1 transport failure"))

(defn- parse-cli
  "Returns {:opts {:dry-run :host :port} :positionals [...]}, or
  {:error msg} / {:help true} for usage paths."
  [args]
  (loop [remaining (seq args)
         opts {:dry-run false :host default-host :port default-port}
         positionals []]
    (cond
      (nil? remaining)
      {:opts opts :positionals positionals}

      (= (first remaining) "--dry-run")
      (recur (next remaining) (assoc opts :dry-run true) positionals)

      (= (first remaining) "--help")
      {:help true}

      (= (first remaining) "-h")
      {:help true}

      (= (first remaining) "--host")
      (if-let [v (second remaining)]
        (recur (nnext remaining) (assoc opts :host v) positionals)
        {:error "missing value for --host"})

      (= (first remaining) "--port")
      (if-let [v (second remaining)]
        (let [n (try (Long/parseLong v) (catch Exception _ nil))]
          (if (and n (<= 1 n 65535))
            (recur (nnext remaining) (assoc opts :port n) positionals)
            {:error (str "invalid --port: " v)}))
        {:error "missing value for --port"})

      (str/starts-with? (first remaining) "-")
      {:error (str "unknown flag: " (first remaining))}

      :else
      (recur (next remaining) opts (conj positionals (first remaining))))))

(defn run-cli!
  "CLI without exiting: prints, returns the exit code. -main adds System/exit."
  [args]
  (let [{:keys [opts positionals error help]} (parse-cli args)]
    (cond
      help
      (do (println usage-str) 0)

      error
      (do (binding [*out* *err*]
            (println (str "error: " error))
            (println usage-str))
          2)

      (empty? positionals)
      (do (binding [*out* *err*]
            (println "error: missing batch edn")
            (println usage-str))
          2)

      :else
      (let [batch-str (str/join " " positionals)
            batch (try (edn/read-string batch-str)
                       (catch Exception e
                         (binding [*out* *err*]
                           (println (str "error: batch is not valid EDN: "
                                         (ex-message e)))
                           (println usage-str))
                         ::bad-edn))]
        (if (= batch ::bad-edn)
          2
          (let [v (try
                    (validate-batch batch)
                    nil
                    (catch clojure.lang.ExceptionInfo e
                      e)
                    (catch Exception e
                      (ex-info "invalid batch" {:cause (ex-message e)})))]
            (if v
              (do (binding [*out* *err*]
                    (println (str "error: " (ex-message v)))
                    (println (str "detail: " (pr-str (ex-data v)))))
                  2)
              (let [conn (try
                           (connect! {:host (:host opts) :port (:port opts)})
                           (catch clojure.lang.ExceptionInfo e
                             (binding [*out* *err*]
                               (println (str "error: " (ex-message e))))
                             ::bad-conn))]
                (if (= conn ::bad-conn)
                  2
                  (let [res (try
                              (run-actions! conn batch
                                            {:dry-run (:dry-run opts)
                                             :timeout-ms default-timeout-ms})
                              (catch clojure.lang.ExceptionInfo e
                                {:ok false :error :local
                                 :detail {:message (ex-message e)
                                          :data (ex-data e)}})
                              (catch Exception e
                                {:ok false :error :local
                                 :detail {:message (ex-message e)}}))]
                    (cond
                      (and (map? res) (:dry-run res))
                      (do (prn res) 0)

                      (and (map? res) (false? (:ok res)) (= :transport (:error res)))
                      (do (binding [*out* *err*]
                            (println "transport failure:")
                            (prn res))
                          1)

                      (and (map? res) (false? (:ok res)))
                      (do (binding [*out* *err*]
                            (println (str "error: " (get-in res [:detail :message])))
                            (prn res))
                          2)

                      :else
                      (do (prn res) 0))))))))))))

(defn -main
  [& args]
  (System/exit (run-cli! args)))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))