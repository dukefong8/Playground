(ns ^:no-doc babashka.pod.datalevin-test
  (:require [babashka.pods :as pods]
            [clojure.test :refer [deftest is testing]]))

(when-not (find-ns 'pod.huahaiy.datalevin)
  (pods/load-pod "dtlv")
  (require 'pod.huahaiy.datalevin))
(in-ns 'babashka.pod.datalevin-test)
(alias 'd 'pod.huahaiy.datalevin)

(defn- temp-dir []
  (str (System/getProperty "java.io.tmpdir")
       "jolt-datalevin-pod-" (random-uuid)))

(defn- delete-tree! [path]
  (letfn [(delete! [file]
            (doseq [child (.listFiles file)]
              (delete! child))
            (.delete file))]
    (delete! (java.io.File. path))))

(deftest datalevin-pod-lifecycle
  (let [path (temp-dir)
        conn (d/get-conn
              path
              {:todo/name {:db/valueType :db.type/string
                           :db/cardinality :db.cardinality/one}})]
    (try
      (d/transact!
       conn [{:todo/id "smoke-1" :todo/name "Buy milk"}])
      (is (= "Buy milk"
             (d/q
              '[:find ?name . :where [?e :todo/name ?name]]
              (d/db conn))))
      (finally
        (d/close conn)
        (delete-tree! path)))))

(def core-api-vars
  '[pod-fn defpodfn with-conn with-kv with-transaction with-transaction-kv
    with-transaction-fn with-transaction-kv-fn
    entid entity add retract entity-db touch pull pull-many empty-db db? datom
    datom? datom-e datom-a datom-v init-db fill-db close-db datoms search-datoms
    count-datoms cardinality max-eid analyze seek-datoms fulltext-datoms
    rseek-datoms index-range conn? conn-from-db conn-from-datoms create-conn close
    datalog-index-cache-limit closed? transact! transact transact-async transact-async* with db-with tx-data->simulated-report
    reset-conn! listen! unlisten! db opts schema update-schema
    secondary-index-status process-secondary-index-jobs! wait-for-secondary-index
    get-conn clear q explain tempid resolve-tempid squuid squuid-time-millis
    hexify-string unhexify-string explicit-transaction-timeout
    set-explicit-transaction-timeout! open-kv datalog-kv k v put-buffer read-buffer
    close-kv closed-kv? dir open-dbi clear-dbi drop-dbi list-dbis copy stat entries
    sync txlog-watermarks open-tx-log create-snapshot! list-snapshots
    gc-txlog-segments! set-env-flags get-env-flags open-transact-kv
    close-transact-kv abort-transact-kv begin-kv-transaction commit-kv-transaction
    abort-kv-transaction open-transact close-transact abort-transact transact-kv
    transact-kv-async transact-kv-async* get-value get-rank get-by-rank sample-kv get-first get-first-n
    get-range range-seq key-range key-range-count key-range-list-count
    visit-key-range range-count get-some range-filter range-keep range-some
    range-filter-count visit open-list-dbi put-list-items del-list-items get-list
    visit-list list-count in-list? list-range list-range-count list-range-first
    list-range-first-n list-range-filter list-range-keep list-range-some
    list-range-filter-count visit-list-range new-search-engine search-index-writer
    write commit add-doc remove-doc clear-docs doc-indexed? doc-count search
    new-vector-index add-vec remove-vec clear-vector-index close-vector-index
    vector-index-info force-vec-checkpoint! vector-checkpoint-state search-vec
    re-index new-embedding-provider embedding-metadata embedding-dimensions
    embed-text embed-texts token-count token-counts truncate-item truncate-text
    close-embedding-provider new-llm-provider llm-metadata llm-context-size
    generate-text summarize-text llm-token-count close-llm-provider read-csv
    write-csv])

;; The upstream dtlv pod currently exposes `transact` as the raw
;; datalevin.async.AsyncResult. Transit cannot encode that value, so calling
;; it terminates the pod process. Keep it in the surface audit, and cover the
;; usable transaction entry points below, without pretending this transport
;; defect is passing behavior coverage.

(deftest datalevin-core-api-surface
  (doseq [api-var core-api-vars]
    (is (some? (ns-resolve 'pod.huahaiy.datalevin api-var))
        (str "missing pod export for datalevin.core/" api-var))))

(deftest datalevin-core-datalog-api
  (let [path   (temp-dir)
        schema {:name   {:db/valueType :db.type/string
                         :db/unique    :db.unique/identity}
                :age    {:db/valueType :db.type/long}
                :city   {:db/valueType :db.type/string}
                :friend {:db/valueType   :db.type/ref
                         :db/cardinality :db.cardinality/many}
                :body   {:db/valueType :db.type/string
                         :db/fulltext   true}}
        conn   (d/create-conn path schema)]
    (try
      (is (true? (d/conn? conn)))
      (is (not (true? (d/closed? conn))))
      (d/transact! conn [{:db/id 1 :name "Ada" :age 37 :body "red fox"}
                         {:db/id 2 :name "Grace" :age 42 :body "blue whale"
                          :friend [1]}])
      (let [db (d/db conn)]
        (testing "query, pull, explain, and multiple sources"
          (is (= #{["Ada"] ["Grace"]}
                 (d/q '[:find ?name :where [?e :name ?name]] db)))
          (is (= 37 (d/q '[:find ?age . :where [1 :age ?age]] db)))
          (is (= {:db/id 1 :name "Ada" :age 37 :body "red fox"}
                 (d/pull db '[*] 1)))
          (is (= [{:db/id 1 :name "Ada"} {:db/id 2 :name "Grace"}]
                 (d/pull-many db '[:db/id :name] [1 2])))
          (is (map? (d/explain {} '[:find ?name :where [?e :name ?name]] db)))
          (let [other-path (temp-dir)
                other      (d/create-conn other-path schema)]
            (try
              (d/transact! other [{:db/id 1 :name "Ada" :age 99}])
              (is (= #{["Ada"]}
                     (d/q '[:find ?name
                            :in $ $other
                            :where [$ ?e :name ?name]
                                   [$other ?e :age 99]]
                          db (d/db other))))
              (finally
                (d/close other)
                (delete-tree! other-path)))))
        (testing "entities, datoms, and indexes"
          (let [entity (d/entity db 1)]
            (is (= 1 (:db/id entity)))
            (is (= 1 (d/entid db [:name "Ada"])))
            (is (= db (d/entity-db entity)))
            (is (= 37 (:age (d/touch entity)))))
          (is (d/db? db))
          (is (d/datom? [1 :name "Ada"]))
          (is (= [1 :name "Ada"] (d/datom 1 :name "Ada")))
          (is (= 1 (d/datom-e [1 :name "Ada"])))
          (is (= :name (d/datom-a [1 :name "Ada"])))
          (is (= "Ada" (d/datom-v [1 :name "Ada"])))
          (is (= 7 (count (d/datoms db :eav))))
          (is (= 3 (count (d/search-datoms db 1 nil nil))))
          (is (= 1 (d/count-datoms db nil :name "Ada")))
          (is (= 2 (d/cardinality db :name)))
          (is (= 2 (d/max-eid db)))
          (is (some? (d/analyze db)))
          (is (seq (d/seek-datoms db :eav 1)))
          (is (seq (d/rseek-datoms db :eav 2)))
          (is (= 2 (count (d/index-range db :age 30 50))))
          (is (= 1 (count (d/fulltext-datoms db "red")))))
        (testing "simulated, staged, and explicit transactions"
          (let [report (d/tx-data->simulated-report
                        db [[:db/add 1 :age 38]])]
            (is (map? report))
            (is (map? (:db-before report)))
            (is (map? (:db-after report)))
            (is (= 2 (count (:tx-data report)))))
          (is (= 38
                 (d/q '[:find ?age . :where [1 :age ?age]]
                      (d/db-with db [[:db/add 1 :age 38]]))))
          (let [entity (d/entity db 1)]
            (d/transact! conn [(d/add entity :age 38)])
            (is (= 38 (:age (d/entity (d/db conn) 1)))))
          (d/with-transaction [tx conn]
            (d/transact! tx [[:db/add 1 :age 39]]))
          (is (= 39 (d/q '[:find ?age . :where [1 :age ?age]] (d/db conn))))
          (let [done (promise)]
            (d/transact-async conn [{:db/id 3 :name "Lin" :age 31}] nil
                                   #(deliver done %))
            (is (map? (deref done 5000 nil)))))
        (testing "listeners, schema, and re-index"
          (let [listener (d/pod-fn "core-api-listener" '[report] 'report)
                key      (d/listen! conn listener)]
            (d/transact! conn [{:db/id 4 :name "Jo"}])
            (is (map? (d/unlisten! conn key))))
          (is (= :db.type/string
                 (get-in (d/schema conn) [:name :db/valueType])))
          (d/update-schema conn {:nickname {:db/valueType :db.type/string}})
          (is (contains? (d/schema conn) :nickname))
          (let [reindexed (d/re-index
                           conn {:name {:db/valueType :db.type/string
                                        :db/unique :db.unique/identity
                                        :db/fulltext true}} {})]
            (is (= #{["Ada"] ["Grace"] ["Lin"] ["Jo"]}
                   (d/q '[:find ?name :where [?e :name ?name]]
                        (d/db reindexed))))
            (d/close reindexed)))
        (let [clear-path (temp-dir)
              clear-conn (d/create-conn clear-path)]
          (try
            (d/transact! clear-conn [{:db/id 1 :name "temporary"}])
            (is (= #{["temporary"]}
                   (d/q '[:find ?name :where [?e :name ?name]]
                        (d/db clear-conn))))
            (d/clear clear-conn)
            (d/close clear-conn)
            (let [reopened (d/create-conn clear-path)]
              (try
                (is (= #{}
                       (d/q '[:find ?name :where [?e :name ?name]]
                            (d/db reopened))))
                (finally
                  (d/close reopened))))
            (finally
              (when-not (d/closed? clear-conn)
                (d/close clear-conn))
              (delete-tree! clear-path))))
       (let [prior (d/explicit-transaction-timeout)]
         (d/set-explicit-transaction-timeout! 1000)
         (is (= 1000 (d/explicit-transaction-timeout)))
         (d/set-explicit-transaction-timeout! prior)))
      (finally
        (when-not (d/closed? conn)
          (d/close conn))
        (delete-tree! path)))))

(deftest datalevin-core-transact-query-pull-api
  (let [path (temp-dir)
        conn (d/create-conn
              path
              {:name   {:db/valueType :db.type/string
                         :db/unique    :db.unique/identity}
               :friend {:db/valueType   :db.type/ref
                        :db/cardinality :db.cardinality/many}})]
    (try
      (d/transact! conn [{:db/id 1 :name "Ada" :friend [2]}
                         {:db/id 2 :name "Grace"}])
      (testing "query entry points and query options"
        (let [db (d/db conn)]
          (is (= #{["Ada"] ["Grace"]}
                 (d/q '[:find ?name :where [?e :name ?name]] db)))
          (is (= "Ada"
                 (d/q '[:find ?name . :where [1 :name ?name]] db)))
          (is (= 1 (count (d/datoms db :eav 1 :name))))
          (is (pos? (:actual-result-size
                     (d/explain {:run? true}
                                '[:find ?name :where [?e :name ?name]]
                                db))))))
      (testing "transaction report, staged DB, and explicit abort"
        (let [report (d/with (d/db conn) [[:db/add 1 :name "Ada-with"]])]
          (is (map? report))
          (is (map? (:db-before report)))
          (is (map? (:db-after report)))
          (is (= "Ada-with"
                 (d/q '[:find ?name . :where [1 :name ?name]]
                      (:db-after report)))))
        (d/transact! conn [[:db/add 1 :name "Before-abort"]])
        (d/with-transaction [tx conn]
          (d/transact! tx [[:db/add 1 :name "Aborted"]])
          (is (= "Aborted"
                 (d/q '[:find ?name . :where [1 :name ?name]]
                      (d/db tx))))
          (is (nil? (d/abort-transact tx))))
        (is (= "Before-abort"
               (d/q '[:find ?name . :where [1 :name ?name]] (d/db conn)))))
      (testing "pull, pull-many, entities, and retract"
        (let [db (d/db conn)
              entity (d/entity db 2)]
          (is (= 1 (d/entid db [:name "Before-abort"])))
          (is (= db (d/entity-db entity)))
          (is (= "Grace" (:name (d/touch entity))))
          (is (= {:db/id 1
                  :name "Before-abort"
                  :friend [{:db/id 2 :name "Grace"}]}
                 (d/pull db '[:db/id :name {:friend [:db/id :name]}] 1)))
          (is (= {:db/id 1 :name "Before-abort"}
                 (d/pull db '[:db/id :name] 1 {})))
          (is (= [{:db/id 1 :name "Before-abort"}
                  {:db/id 2 :name "Grace"}]
                 (d/pull-many db '[:db/id :name] [1 2] {})))
          (let [op (d/retract (d/entity db 2) :name "Grace")]
            (is (= [:db/retract 2 :name "Grace"] op))
            (d/transact! conn [op])
            (is (= #{}
                   (d/q '[:find ?name :where [2 :name ?name]]
                        (d/db conn)))))))
      (let [reset-path (temp-dir)
            reset-db   (d/init-db [[3 :name "Reset"]] reset-path)]
        (try
          (is (map? (d/reset-conn! conn reset-db)))
          (is (= "Reset"
                 (d/q '[:find ?name . :where [3 :name ?name]]
                      (d/db conn))))
          (finally
            (d/close-db reset-db)
            (delete-tree! reset-path))))
      (finally
        (d/close conn)
        (delete-tree! path)))))

(deftest datalevin-core-kv-api
  (let [path (temp-dir)
        db   (d/open-kv path)]
    (try
      (is (not (true? (d/closed-kv? db))))
      (is (= path (d/dir db)))
      (d/open-dbi db "a")
      (d/transact-kv db "a" [[:put "a" 1] [:put "b" 2] [:put "c" 3]]
                     :string :long)
      (testing "basic reads and ranges"
        (is (= 3 (d/entries db "a")))
        (is (map? (d/stat db "a")))
        (is (= 2 (d/get-value db "a" "b" :string :long)))
        (is (= ["b" 2] (d/get-value db "a" "b" :string :long false)))
        (is (= 0 (d/get-rank db "a" "a" :string)))
        (is (= ["a" 1] (d/get-by-rank db "a" 0 :string :long false)))
        ;; The pod transport exposes this spillable result as an opaque tagged
        ;; value in Babashka and as a decoded tagged value in Jolt.
        (is (some? (d/sample-kv db "a" 1 :string :long false)))
        (is (= ["a" 1] (d/get-first db "a" [:closed "a" "c"]
                                      :string :long)))
        (is (= [["a" 1] ["b" 2]]
               (d/get-first-n db "a" 2 [:all] :string :long)))
        (is (= [["a" 1] ["b" 2] ["c" 3]]
               (d/get-range db "a" [:all] :string :long)))
        (is (= [["a" 1] ["b" 2] ["c" 3]]
               (d/range-seq db "a" [:all] :string :long)))
        (is (= ["a" "b" "c"] (d/key-range db "a" [:all] :string)))
        (is (= 3 (d/key-range-count db "a" [:all] :string)))
        (is (= 3 (d/range-count db "a" [:all] :string))))
      (testing "transactions and DBI lifecycle"
        (d/with-transaction-kv [tx db]
          (d/transact-kv tx "a" [[:put "d" 4]] :string :long))
        (let [tx (d/begin-kv-transaction db)]
          (d/transact-kv tx "a" [[:put "e" 5]] :string :long)
          (d/commit-kv-transaction tx))
        (let [tx (d/begin-kv-transaction db)]
          (d/transact-kv tx "a" [[:put "discarded" 0]] :string :long)
          (d/abort-kv-transaction tx))
        (is (= 4 (d/get-value db "a" "d" :string :long)))
        (is (= 5 (d/get-value db "a" "e" :string :long)))
        (is (nil? (d/get-value db "a" "discarded" :string :long)))
        (d/set-env-flags db #{:nosync} true)
        (is (contains? (d/get-env-flags db) :nosync))
        (is (nil? (d/sync db)))
        (d/open-dbi db "scratch")
        (d/transact-kv db "scratch" [[:put "x" "y"]] :string :string)
        (d/clear-dbi db "scratch")
        (is (nil? (d/get-value db "scratch" "x" :string :string)))
        (d/drop-dbi db "scratch")
        (is (not (some #{"scratch"} (d/list-dbis db)))))
      (testing "list operations"
        (d/open-list-dbi db "list")
        (d/put-list-items db "list" "a" [1 2 3] :string :long)
        (d/put-list-items db "list" "b" [4 5] :string :long)
        (is (= [1 2 3] (d/get-list db "list" "a" :string :long)))
        (is (= 3 (d/list-count db "list" "a" :string)))
        (is (d/in-list? db "list" "a" 2 :string :long))
        (is (= [["a" 1] ["a" 2] ["a" 3] ["b" 4] ["b" 5]]
               (d/list-range db "list" [:all] :string [:all] :long)))
        (is (= [["a" 1] ["a" 2]]
               (d/list-range-first-n db "list" 2 [:all] :string [:all] :long)))
        (d/del-list-items db "list" "a" [2] :string :long)
        (is (= [1 3] (d/get-list db "list" "a" :string :long))))
      (finally
        (d/close-kv db)
        (delete-tree! path)))))

(deftest datalevin-core-bulk-search-vector-idoc-api
  (testing "bulk database construction and filling"
    (let [path (temp-dir)
          db   (d/init-db [[1 :name "Ada"]] path)]
      (try
        (is (d/db? db))
        (is (= "Ada" (d/q '[:find ?name . :where [1 :name ?name]] db)))
        (let [filled (d/fill-db db [[2 :name "Grace"]])]
          (is (= "Grace" (d/q '[:find ?name . :where [2 :name ?name]] filled)))
          (d/close-db filled))
        (finally
          (delete-tree! path)))))
  (testing "Datalog-backed KV"
    (let [path (temp-dir)
          conn (d/create-conn path)
          kv   (d/datalog-kv conn)]
      (try
        (is (= path (d/dir kv)))
        (d/open-dbi kv "app-state")
        (d/transact-kv kv "app-state" [[:put "k" "v"]] :string :string)
        (is (= "v" (d/get-value kv "app-state" "k" :string :string true)))
        (finally
          (d/close conn)
          (delete-tree! path)))))
  (testing "standalone full-text search and writer"
    (let [path   (temp-dir)
          db     (d/open-kv path)
          engine (d/new-search-engine db {:index-position? true})]
      (try
        (d/add-doc engine 1 "The quick red fox")
        (d/add-doc engine 2 "A blue whale")
        (is (= [1] (d/search engine "red")))
        (is (d/doc-indexed? engine 1))
        (is (= 2 (d/doc-count engine)))
        (d/remove-doc engine 2)
        (is (= 1 (d/doc-count engine)))
        (d/clear-docs engine)
        (let [writer (d/search-index-writer db)]
          (d/write writer :doc/a "red fox")
          (d/commit writer)
          (let [writer-engine (d/new-search-engine db)]
            (is (= [:doc/a] (d/search writer-engine "red")))))
        (d/clear-docs engine)
        (is (= 0 (d/doc-count engine)))
        (finally
          (d/close-kv db)
          (delete-tree! path)))))
  (testing "standalone vector index"
    (let [path  (temp-dir)
          db    (d/open-kv path)
          index (d/new-vector-index db {:dimensions 3})
          v1    [1.0 0.0 0.0]
          v2    [0.0 1.0 0.0]]
      (try
        (d/add-vec index :one v1)
        (d/add-vec index :two v2)
        (is (= 2 (:size (d/vector-index-info index))))
        (is (= [:one] (d/search-vec index v1 {:top 1})))
        (is (= [[:one 0.0]]
               (d/search-vec index v1 {:top 1 :display :refs+dists})))
        (d/remove-vec index :two)
        (is (= 1 (:size (d/vector-index-info index))))
        (d/close-vector-index index)
        (finally
          (d/close-kv db)
          (delete-tree! path)))))
  (testing "idoc schema and query"
    (let [path (temp-dir)
          conn (d/create-conn
                path {:doc/idoc {:db/valueType :db.type/idoc
                                 :db/domain    "profiles"}})]
      (try
        (d/transact!
         conn [{:db/id 1 :doc/idoc {:status "active" :profile {:age 30}}}
               {:db/id 2 :doc/idoc {:status "inactive" :profile {:age 40}}}])
        (let [db (d/db conn)]
          (is (= #{[1]}
                 (d/q '[:find ?e
                        :where
                        [(idoc-match $ :doc/idoc {:status "active"})
                         [[?e ?a ?v]]]]
                      db)))
          (is (= #{[2]}
                 (d/q '[:find ?e
                        :in $ ?q
                        :where
                        [(idoc-match $ :doc/idoc ?q) [[?e ?a ?v]]]]
                      db '(> [:profile :age] 35)))))
        (finally
          (d/close conn)
          (delete-tree! path))))))

(deftest datalevin-core-operational-api
  (let [path (temp-dir)
        copy-path (temp-dir)
        db   (d/open-kv path {:wal? true})]
    (try
      (d/open-dbi db "a")
      (d/transact-kv db "a" [[:put "k" "v"]] :string :string)
      (testing "copy and WAL inspection"
        (is (map? (d/copy db copy-path)))
        (let [copied (d/open-kv copy-path)]
          (try
            (d/open-dbi copied "a")
            (is (= "v" (d/get-value copied "a" "k" :string :string)))
            (finally
              (d/close-kv copied))))
        (let [watermarks (d/txlog-watermarks db)
              log        (d/open-tx-log db 1 2)]
          (is (= true (:wal? watermarks)))
          (is (number? (:last-committed-lsn watermarks)))
          (is (>= (count log) 2))
          (is (= #{1 2} (set (map :lsn log))))))
      (testing "snapshots and WAL GC"
        (let [snapshot (d/create-snapshot! db)
              gc       (d/gc-txlog-segments! db)]
          (is (true? (:ok? snapshot)))
          (is (seq (d/list-snapshots db)))
          (is (true? (:ok? gc)))))
      (finally
        (d/close-kv db)
        (delete-tree! path)
        (delete-tree! copy-path)))))


(deftest datalevin-pod-kv
  (let [path (temp-dir)
        db (d/open-kv path)]
    (try
      (d/open-dbi db "smoke")
      (d/transact-kv
       db "smoke" [[:put "key" "value"]] :string :string)
      (is (= "value"
             (d/get-value
              db "smoke" "key" :string :string true)))
      (finally
        (d/close-kv db)
        (delete-tree! path)))))

(deftest datalevin-pod-csv
  (is (= [["a" "b,c" "d\"e"]
          ["line 1\nline 2" "" "tail"]]
         (d/read-csv
          "a,\"b,c\",\"d\\\"e\"\r\n\"line 1\nline 2\",,tail\n")))
  (is (= [["a" "b"] ["c" "d"]]
         (d/read-csv
          "a|b\r\nc|d" :separator (int \|) :quote (int \"))))
  (is (= [["a" ""]]
         (d/read-csv "a,")))
  (is (= [[""]]
         (d/read-csv "\n")))
  (is (= []
         (d/read-csv "")))
  (is (= [["name" "age"] ["Ada" "37"]]
         (d/read-csv
          (d/write-csv
           nil [["name" "age"] ["Ada" "37"]])))))

(deftest datalevin-pod-csv-backslash-before-closing-quote
  (is (= [["1" "value\\" "tail"]
          ["2" "next" "row"]]
         (d/read-csv
          "1,\"value\\\\\",tail\n2,next,row\n"))))

(deftest datalevin-pod-ident-and-pull
  (let [path (temp-dir)
        conn (d/get-conn
              path {:ref {:db/valueType :db.type/ref}})]
    (try
      (d/transact!
       conn [[:db/add 1 :db/ident :ent1]
             [:db/add 2 :db/ident :ent2]
             [:db/add 2 :ref 1]])
      (let [db (d/db conn)]
        (is (= 1
               (d/q
                '[:find ?v . :where [:ent2 :ref ?v]] db)))
        (is (= 2
               (d/q
                '[:find ?e . :where [?e :ref :ent1]] db)))
        (is (= {:db/ident :ent1}
               (select-keys
                (d/entity db :ent1)
                [:db/ident])))
        (is (= {:db/id 1 :db/ident :ent1}
               (d/pull db '[*] :ent1))))
      (finally
        (d/close conn)
        (delete-tree! path)))))
