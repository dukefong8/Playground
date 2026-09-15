(ns superv.async.partial-cps
  "Native supervision for partial-cps: the missing supervisor half of the
  is.simm.partial-cps.core-async bridge.

  The generic adapter deliberately knows nothing about supervisors: its
  channel take hangs forever when a supervisor aborts mid-await (where S/<?
  would raise), and computations in CPS flight never appear in the
  supervisor's registered/pending tracking. The three fns here close exactly
  those gaps, mirroring the corresponding superv.async constructs:

  - `stake-cps` — S/<? as an awaitable CPS: races supervisor-abort against
    the data channel with priority and raises `{:type :aborted}` on abort.
  - `supervised-chan` — go-try's register/track/unregister contract wrapped
    around a CPS fn handed to ->chan.
  - `unwrap-result` — ca/unwrap-result that first frees a tracked error, so a
    supervised raise taken off the channel leaves pending-exceptions clean
    (mirrors throw-if-exception).

  Portability: everything here is built from portable constructs (go, alts!,
  ex-info) and runs on the JVM, in CLJS, and on either Jolt backend.

  This namespace lives in jlt (not in superv.async itself) so the tests it
  supports are self-contained: it needs partial-cps on the classpath, which
  only test consumers have. Base superv.async users never touch it.

  Caveats, all observed live — read before composing:
  1. `stake-cps` captures `(-abort S)` ONCE per take. On TrackingSupervisor
     that is a rand-nth of 1000 abort chans; capturing once per take mirrors
     S/<? and is the correct granularity.
  2. Custom supervisors need `:aborts [ch]` (plural, a collection). The
     record field is `:aborts`; building with singular `:abort` leaves a nil
     abort channel, and alts! over nil hangs silently (observed on Jolt).
  3. Abort raises are never tracked, mirroring go-try's `:aborted` guard.
  4. `supervised-chan` takes a CPS fn. Plain values/channels pass straight to
     ca/->chan unsupervised — there is nothing in flight to supervise.
  5. Tracked raises stay pending until `unwrap-result` (or -free-exception)
     runs; the stale-timeout sweep is the backstop. `ca/unwrap-result` alone
     does NOT free — that is why this ns has its own.
  6. Do NOT use raw S/<? inside a partial-cps `async` body and expect parking:
     on Jolt it accidentally works by BLOCKING the invoking thread (on the JVM
     it throws). On a carrier thread that pins the carrier. Await
     `(stake-cps S ch)` instead.
  7. Awaiting take!-resolved channels inside a CPS-transformed LOOP
     (doseq/loop) hangs backend-independently — upstream partial-cps scope,
     not fiber scope. Use loop-free sequential awaits with bridge channels.
  8. On fibers, blocking takes (S/<<??, unwrap off a bare <!!) inside a
     spawned fiber pin its carrier while blocked. Prefer parking takes in
     fiber bodies; reserve blocking takes for real threads."
  (:require [clojure.core.async :as async :refer [go alts!]]
            [superv.async :as S]
            [is.simm.partial-cps.core-async :as ca]))

(defn stake-cps
  "S/<? as a partial-cps CPS fn `(fn [resolve raise])`, so it is `await`-able
  inside a partial-cps `async`.

  Races the supervisor abort channel against ch with priority (like S/<?): on
  abort raises `(ex-info \"Aborted operations\" {:type :aborted})` instead of
  hanging; error values free their supervision tracking and raise rewrapped;
  data resolves. One `go` per take; alts! (not two take!s) so no callback is
  left dangling on the losing side.

  Takes a CHANNEL only (like S/<?). Anything else fails fast with an
  AssertionError: alts! over a non-channel would blow up inside the spawned
  go, leaving resolve/raise permanently unfired — i.e. a silent hang. Never
  trade that for a hang."
  [S ch]
  (assert (ca/chan? ch) (str "stake-cps takes a channel, got: " (pr-str ch)))
  (let [abort (S/-abort S)]
    (fn [resolve raise]
      (go (let [[v p] (alts! [abort ch] :priority true)]
            (if (= p abort)
              (raise (ex-info "Aborted operations" {:type :aborted}))
              (if (ca/error? v)
                (do (S/-free-exception S v)
                    (raise (ca/rewrap v)))
                (resolve v))))))))

(defn supervised-chan
  "go-try's supervision contract around a CPS fn, normalized to a channel via
  ca/->chan: registers the computation on entry, tracks non-aborted raises,
  unregisters on either continuation. Plain values/channels pass through to
  ca/->chan unsupervised."
  [S cps]
  (if (fn? cps)
    (let [id (S/-register-go S 'supervised-cps)]
      (ca/->chan (fn [resolve raise]
                   (cps (fn [v] (S/-unregister-go S id)
                          (resolve v))
                        (fn [e] (when-not (= (:type (ex-data e)) :aborted)
                                  (S/-track-exception S e))
                          (S/-unregister-go S id)
                          (raise e))))))
    (ca/->chan cps)))

(defn unwrap-result
  "ca/unwrap-result that first frees a supervision-tracked error, so a raise
  produced under `supervised-chan` (or taken from a go-try channel) leaves
  pending-exceptions clean. Mirrors throw-if-exception; freeing a non-error
  is a harmless no-op."
  [S v]
  (S/-free-exception S v)
  (ca/unwrap-result v))
