(ns todo-filter
  "The todo page's client script: the live filter, the DataScript db it keeps in
  step with the rendered list, and the reagami component counting what is shown.

  The ns form keeps this file self-contained: scittle evaluates every x-scittle
  script in the ns the previous script left current, so a script carrying its own
  (:refer-clojure :exclude [...]) silently takes core vars away from everything
  loaded after it — pageShell loads reagami ahead of this file, and it excludes
  doseq, for, map, filter, vec, set, println ... . Declaring a ns makes load
  order irrelevant, and drops the nREPL session into todo-filter, where
  apply-todo-filter can be called directly.")
;;
;; State lives in the DOM, not in a JS variable:
;;   * active mode  -> data-filter-mode on section.todoapp (never swapped)
;;   * search query -> #todo-input's value
;;   * completion   -> each row's input.toggle.checked
;;   * row visible  -> li[hidden]        (derived, re-derived below)
;;   * selected link-> .selected on a[data-filter] (derived)
;;
;; htmx's morph swaps drop client-written attributes inside #todo-list, and nodes
;; it replaces are not re-processed, so every hook is an hx-on attribute on the
;; never-swapped section.todoapp: htmx binds them once on load and
;; htmx:finally:swap re-derives the whole view after every swap (main + OOB).
;;
;; One-way from there: the DOM is the source of truth, sync! mirrors it into the
;; db, and the db is only ever read — by the count query below, and by hand from
;; the REPL.
;; Required at the top level, not as an ns clause: an ns form's libspecs are
;; analysed before the datascript plugin bundle has registered datascript.core
;; with SCI, so a cold page fails with "Unable to resolve symbol:
;; datascript.core". A plain require loads first and resolves after.
(require '[datascript.core :as d])
(require '[reagami.core :as reagami])

;; ── the rendered list, mirrored into a db ────────────────────────────────────
;;
;; :todo/id is the suffix of the row's li#todo-<id>, so a re-sync updates the
;; same entity instead of appending a second one. :todo/shown? carries the
;; filter's verdict (li[hidden]) into the db, which is what lets the count be a
;; query rather than a pass over the DOM.

(def schema
  {:todo/id {:db/unique :db.unique/identity}})

(defonce conn (d/create-conn schema))

;; The row being edited renders as a form: its title lives in the input and it
;; carries no toggle, so :todo/completed is left as the db has it — the upsert
;; only writes the keys present, and dropping the attribute would lose the tick
;; for the length of the edit.
(defn row->todo [li]
  (let [label (.querySelector li "label")
        edit  (.querySelector li "input.edit")
        todo  {:todo/id     (js/parseInt (subs (.-id li) 5) 10)
               :todo/title  (cond label (.-textContent label)
                                  edit  (.-value edit))
               :todo/shown? (not (.-hidden li))}]
    (if edit
      todo
      (assoc todo :todo/completed (.contains (.-classList li) "completed")))))

(defn dom-todos []
  (->> (array-seq (.querySelectorAll js/document ".todo-list li"))
       ;; an editing row counts too: the filter exempts it from hiding, so the
       ;; count owes it a row while it is on screen
       (filter #(or (.querySelector % "label") (.querySelector % "input.edit")))
       (map row->todo)
       vec))

(defn sync!
  "Mirror the rendered list into the db. Returns what the pass did."
  []
  (let [todos (dom-todos)
        seen  (set (map :todo/id todos))
        gone  (remove seen (d/q '[:find [?id ...] :where [?e :todo/id ?id]] @conn))]
    (d/transact! conn (into todos (map (fn [id] [:db/retractEntity [:todo/id id]]) gone)))
    {:rows (count todos), :retracted (vec gone)}))

;; ── what is shown, counted in Datalog and drawn by reagami ───────────────────

(defn shown-count
  "Rows whose synced row is visible, counted by the query engine."
  [db]
  (or (d/q '[:find (count ?e) . :where [?e :todo/shown? true]] db) 0))

(defn count-view []
  ;; reagami writes the object's entries into the style attribute verbatim, so
  ;; the key has to be CSS-form. The class is the footer's own, so the count is
  ;; styled as the "# items left" counter beside it.
  [:span.todo-count {:style #js {"margin-left" "12px"}}
   [:strong (str (shown-count @conn))] " shown"])

;; The mount is created here rather than in the markup: it sits after the
;; server's own counter, and an htmx morph rebuilds that footer, so it is looked
;; up (and re-made) per render instead of held in a var.
(defn ensure-count-mount! []
  (or (.querySelector js/document "#shown-count")
      (when-let [anchor (.querySelector js/document ".todo-count")]
        (let [node (.createElement js/document "span")]
          (set! (.-id node) "shown-count")
          (.after anchor node)
          node))))

(defn render-count! []
  (when-let [node (ensure-count-mount!)]
    (reagami/render node (count-view))))

;; The watch is what makes the component reactive: anything that moves the db —
;; this file, the REPL, dataspex — redraws the count.
(add-watch conn ::count (fn [_ _ _ _] (render-count!)))

;; Both client-side views of the list re-derive from the same pass: the filter
;; writes li[hidden], then this mirrors that state and redraws.
(defn sync-and-render! []
  (sync!)
  ;; the watch covers db writes, but an empty list writes nothing, and the page
  ;; still owes the reader a "0 shown"
  (render-count!))

;; ── the filter ───────────────────────────────────────────────────────────────

(defn todo-app []
  (.querySelector js/document ".todoapp"))

(defn filter-mode []
  (or (some-> (todo-app) .-dataset .-filterMode) "all"))

(defn todo-search-text []
  (if-let [input (.querySelector js/document "#todo-input")]
    (.toLowerCase (or (.-value input) ""))
    ""))

;; The row being edited has neither a label nor a toggle (it renders as a form),
;; so it must be exempt — otherwise an active search hides it the moment you
;; double-click it and the edit form becomes unreachable.
(defn editing? [li]
  (.contains (.-classList li) "editing"))

(defn row-visible? [li q mode]
  (or (editing? li)
      (let [label (.querySelector li "label")
            text (if label (.toLowerCase (or (.-textContent label) "")) "")
            matches-search (or (= q "") (.includes text q))
            toggle (.querySelector li "input.toggle")
            completed (if toggle (boolean (.-checked toggle)) false)]
        (and matches-search
             (or (= mode "all")
                 (and (= mode "active") (not completed))
                 (and (= mode "completed") completed))))))

(defn apply-todo-filter []
  (let [q (todo-search-text)
        mode (filter-mode)]
    (doseq [li (array-seq (.. js/document (querySelectorAll ".todo-list li")))]
      (set! (.-hidden li) (not (row-visible? li q mode))))
    (doseq [a (array-seq (.. js/document (querySelectorAll ".filters a")))]
      (let [classes (.-classList a)]
        (if (= (.getAttribute a "data-filter") mode)
          (.add classes "selected")
          (.remove classes "selected")))))
  (sync-and-render!))

(defn set-filter-mode! [mode]
  (when-let [app (todo-app)]
    (set! (.-filterMode (.-dataset app)) (or mode "all")))
  (apply-todo-filter))

;; Called from the hx-on bodies in App.Todo's todoPage markup.
(aset js/window "todoFilterApply" apply-todo-filter)
(aset js/window "todoFilterSet" set-filter-mode!)

(apply-todo-filter)