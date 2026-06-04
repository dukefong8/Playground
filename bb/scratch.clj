(ns scratch
  {:core.typed {:check-config {:untyped-var-policy :any}}}
  (:require [malli.core :as m] 
            [malli.dev :as mdev]
            [malli.dev.pretty :as mpretty]
            [com.fulcrologic.guardrails.malli.core :refer [>defn => | ?]]
            [typed.clojure :as t])) 
            
(mdev/start! {:report (mpretty/reporter)})

(>defn apply-discount
  [price discount-pct]
  [:double :double => :double | #(< discount-pct 1.0)]
  (* price (- 1.0 discount-pct)))

(apply-discount 10 0.3)

(m/=> foo [:-> :int :int])
(defn foo [t] (inc t))

(foo 1)

(t/check-ns-clj)
(mdev/stop!)
