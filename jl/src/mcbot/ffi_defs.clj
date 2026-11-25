(ns mcbot.ffi-defs
  "Jolt bindings for gs/libmcbot.so. Follows test/goose/export_abi.clj.

  Layout rules from the header (gs/mcbot.h, packed push 1): BotPoseOut
  is 25 bytes (6 f32 then u8 grounded), BotHit is 53 bytes (u8 found,
  6 i64 cells from byte 1, f32 distance at 49), BotCell is 24 bytes.
  f32 members use real :float reads (Mixed precedent). Slices cross as
  {data :pointer, len :int64} over caller-owned arenas."
  (:require [jolt.ffi :as ffi]))

(ffi/load-library {:darwin "../gs/libmcbot.dylib"
                   :linux  "../gs/libmcbot.so"})

(ffi/defcfn goose-init "goose_init" [:int :pointer] :void)
(ffi/defcfn goose-exit "goose_exit" [] :void)

(ffi/defcfn bot-version "bot_version" [] :uint32)
(ffi/defcfn bot-walk-step "bot_walk_step"
  [:float :float :uint8 :uint8 :uint8 :int64] :void)
(ffi/defcfn bot-look "bot_look" [:float :float :pointer] :void)
(ffi/defcfn bot-ray "bot_ray" [:float :pointer] :void)
(ffi/defcfn bot-mine-ticks "bot_mine_ticks" [:int64 :pointer] :uint8)
(ffi/defcfn bot-place-once "bot_place_once" [:pointer] :uint8)
(ffi/defcfn bot-pick "bot_pick" [] :void)
(ffi/defcfn bot-select "bot_select" [:int64] :uint8)
(ffi/defcfn bot-craft "bot_craft" [:int64 :uint8] :int64)
(ffi/defcfn bot-reset "bot_reset" [:uint32] :void)
(ffi/defcfn bot-advance "bot_advance" [:float] :void)
(ffi/defcfn bot-pose "bot_pose" [:pointer] :void)
(ffi/defcfn bot-status "bot_status"
  [[:by-value [:struct [[:data :pointer] [:len :int64]]]]
   [:by-value [:struct [[:data :pointer] [:len :int64]]]]] :uint8)
(ffi/defcfn bot-get-block "bot_get_block" [:pointer] :uint8)
(ffi/defcfn bot-scan-window "bot_scan_window"
  [:pointer :pointer
   [:by-value [:struct [[:data :pointer] [:len :int64]]]]] :int64)
(ffi/defcfn bot-checksum "bot_checksum" [] :uint32)
(ffi/defcfn bot-save-len "bot_save_len" [] :int64)
(ffi/defcfn bot-save-write "bot_save_write"
  [[:by-value [:struct [[:data :pointer] [:len :int64]]]]] :int64)
(ffi/defcfn bot-restore "bot_restore"
  [[:by-value [:struct [[:data :pointer] [:len :int64]]]]] :uint8)
(ffi/defcfn bot-next-goal "bot_next_goal" [:pointer] :pointer)
(ffi/defcfn bot-block-name "bot_block_name" [:uint8 :pointer] :pointer)
(ffi/defcfn bot-day-time "bot_day_time" [] :float)

(def ^:private pose-size 25)
(def ^:private hit-size 53)
(def ^:private cell-size 24)

(defn- slice-of [arena data n]
  (let [sp (ffi/alloc arena 16)]
    (ffi/write sp :pointer data 0)
    (ffi/write sp :int64 n 8)
    sp))

(defn- bytes->string [p n]
  (apply str (map #(char (ffi/read p :uint8 %)) (range n))))

(defn init!
  "Own the runtime on the calling thread. Call once, on the pump thread."
  []
  (goose-init 0 ffi/null))

(defn read-pose [p]
  {:feet-x (ffi/read p :float 0) :feet-y (ffi/read p :float 4)
   :feet-z (ffi/read p :float 8) :yaw (ffi/read p :float 12)
   :pitch (ffi/read p :float 16) :vel (ffi/read p :float 20)
   :grounded (ffi/read p :uint8 24)})

(defn read-hit [p]
  {:found (ffi/read p :uint8 0)
   :ax (ffi/read p :int64 1) :ay (ffi/read p :int64 9)
   :az (ffi/read p :int64 17) :bx (ffi/read p :int64 25)
   :by (ffi/read p :int64 33) :bz (ffi/read p :int64 41)
   :distance (ffi/read p :float 49)})

(defn- write-cell! [p [x y z]]
  (ffi/write p :int64 x 0)
  (ffi/write p :int64 y 8)
  (ffi/write p :int64 z 16)
  p)

(defn- u8 [b] (if b 1 0))

(defn walk-step! [dx dz jump? run? sneak? ticks]
  (bot-walk-step (float dx) (float dz)
                 (u8 jump?) (u8 run?) (u8 sneak?) (long ticks))
  (long ticks))

(defn look! [dx dy]
  (ffi/with-arena [a]
    (let [buf (ffi/alloc a pose-size)]
      (bot-look (float dx) (float dy) buf)
      (read-pose buf))))

(defn ray! [reach]
  (ffi/with-arena [a]
    (let [buf (ffi/alloc a hit-size)]
      (bot-ray (float reach) buf)
      (read-hit buf))))

(defn mine-ticks! [n]
  (ffi/with-arena [a]
    (let [buf (ffi/alloc a hit-size)
          code (bot-mine-ticks (long n) buf)]
      [code (read-hit buf)])))

(defn place-once! []
  (ffi/with-arena [a]
    (let [buf (ffi/alloc a hit-size)
          code (bot-place-once buf)]
      [code (read-hit buf)])))

(defn pick! [] (bot-pick))

(defn select! [slot] (bot-select (long slot)))

(defn craft! [recipe all?] (bot-craft (long recipe) (u8 all?)))

(defn reset-world! [seed] (bot-reset seed))

(defn advance! [dt] (bot-advance (float dt)))

(defn pose! []
  (ffi/with-arena [a]
    (let [buf (ffi/alloc a pose-size)]
      (bot-pose buf)
      (read-pose buf))))

(defn status! []
  (ffi/with-arena [a]
    (let [bag (ffi/alloc a 32)
          rest (ffi/alloc a 16)
          code (bot-status (slice-of a bag 8) (slice-of a rest 16))]
      {:code code
       :bag (mapv (fn [i] (ffi/read bag :int32 (* 4 i))) (range 8))
       :tool (ffi/read rest :uint32 0)
       :selected (ffi/read rest :uint32 4)
       :day-time (/ (double (ffi/read rest :uint32 8)) 1000.0)
       :lamps (ffi/read rest :uint32 12)})))

(defn get-block! [cell]
  (ffi/with-arena [a]
    (bot-get-block (write-cell! (ffi/alloc a cell-size) cell))))

(defn scan-window!
  "Dense byte grid over [lo..hi], X fastest then Z then Y.
  Returns {:cells [[x y z b] ...] :truncated bool}."
  [lo hi]
  (let [[lx ly lz] lo [hx hy hz] hi
        nx (- hx lx -1) ny (- hy ly -1) nz (- hz lz -1)]
    (if (or (<= nx 0) (<= ny 0) (<= nz 0))
      {:truncated false :cells []}
      (ffi/with-arena [a]
        (let [total (* nx ny nz)
              out (ffi/alloc a total)
              n (bot-scan-window (write-cell! (ffi/alloc a cell-size) lo)
                                 (write-cell! (ffi/alloc a cell-size) hi)
                                 (slice-of a out total))]
          (if (neg? n)
            {:truncated true :cells []}
            {:truncated false
             :cells (vec (for [y (range ly (inc hy))
                               z (range lz (inc hz))
                               x (range lx (inc hx))]
                           [x y z (ffi/read out :uint8
                                           (+ (* (- y ly) nx nz)
                                              (* (- z lz) nx)
                                              (- x lx)))]))}))))))

(defn checksum! [] (bot-checksum))

(defn save-bytes! []
  (let [n (bot-save-len)]
    (ffi/with-arena [a]
      (let [out (ffi/alloc a n)
            wrote (bot-save-write (slice-of a out n))]
        (when (not= wrote n)
          (throw (ex-info "short save write" {:wrote wrote :len n})))
        (byte-array (map (fn [i] (ffi/read out :uint8 i)) (range n)))))))

(defn restore-bytes! [bytes]
  (ffi/with-arena [a]
    (let [n (alength bytes)
          base (ffi/alloc a n)]
      (dotimes [i n] (ffi/write base :uint8 (aget bytes i) i))
      (bot-restore (slice-of a base n)))))

(defn next-goal! []
  (ffi/with-arena [a]
    (let [lp (ffi/alloc a 8)
          p (bot-next-goal lp)]
      (bytes->string p (ffi/read lp :int64 0)))))

(defn block-name! [b]
  (ffi/with-arena [a]
    (let [lp (ffi/alloc a 8)
          p (bot-block-name b lp)]
      (bytes->string p (ffi/read lp :int64 0)))))

(defn day-time! [] (bot-day-time))
