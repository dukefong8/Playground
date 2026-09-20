(ns todo-filter
  "Todo live filter — client-side search + all/active/completed filtering.

  The ns form keeps this file self-contained: scittle evaluates every x-scittle
  script in the ns the previous script left current, so a script carrying its own
  (:refer-clojure :exclude [...]) silently takes core vars away from everything
  loaded after it — pageShell used to load reagami, which excluded doseq, for,
  map, filter, vec, set, println ... and broke this file at analysis time.
  Declaring a ns makes load order irrelevant, and drops the nREPL session into
  todo-filter, where apply-todo-filter can be called directly.")
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
          (.remove classes "selected"))))))

(defn set-filter-mode! [mode]
  (when-let [app (todo-app)]
    (set! (.-filterMode (.-dataset app)) (or mode "all")))
  (apply-todo-filter))

;; Called from the hx-on bodies in App.Todo's todoPage markup.
(aset js/window "todoFilterApply" apply-todo-filter)
(aset js/window "todoFilterSet" set-filter-mode!)

(apply-todo-filter)
