# mcbot control plane — design

## Problem

Bot authors need programmatic play (walk, mine, place, craft, read) driven
from bb over nREPL, without synthetic input and without forking the game.
The shape is non-obvious because `minecraft.goose` is 1640 lines of globals
with zero exports, heap-touching FFI may run only on the `goose_init` owner
thread, only value-legal, ref, slice, and out-param shapes may cross, the
256 KB block grid and save images cannot travel by value, and nREPL eval
threads are not guaranteed to be the owner. Full grounding is in
`/tmp/arena-mcbot/grounding.md` (47 lines, 7 constraints, 3 open unknowns
with probes).

## Usage (caller's view)

One `connect!`, then `run-actions!` with edn batches. Transport is
stdin-piped eval, exactly as `bb repl --connect` works today. Three call
sites ship in `candidate-1/package.md`: pillar builder (stateful build over
the wire), mine-until plus craft loop (sense and act at ms latency), and
deterministic replay (reset, walk, checksum). The caller imports one
namespace, speaks Action maps, and gets position-aligned outcome maps.

## Shape

One resident world, one pump thread, one registry. `jolt run` initializes
goose exactly once on the pump thread and parks it in a take, exec, deliver
loop over a core.async channel. nREPL eval threads only submit. Every op
dispatches through `mcbot.registry/actions`, so dispatch, validation, and
help derive from one list. Translation between edn and FFI is pure and lives
in `mcbot.translate`. Reads are actions on the same path, so replay logs are
complete. The public surface is two functions plus edn data. Validation runs
once at the registry boundary. Every action is bounded, so batches always
terminate. Judgment: this hides threading, packing, arenas, and batching
behind a deep but narrow surface, per model-the-domain and
boundary-discipline.

## Synthesis decision

Candidate 1 (resident pump plus registry) is the base. Only the resident
world closes sense and act loops at interactive latency with tick-level
determinism, and only it keeps Jolt functions plus data central, which is
the stated requirement. Candidate 2 (process per action plus save files)
loses: its latency cost is structural, while the base risks are probe-gated
unknowns with a defined probe order. No standalone cross-judge ran, per the
OpenCode mapping (all roles inherit the parent model, no requested
diversity), so the pick is scored directly against the rubric: thread safety
C2, interface depth C1, data-first tie, transport C2, verifiability tie,
single ownership C2.

## Grafts from candidate 2

- Atomic commit discipline for snapshot saves. A `:snapshot-save` path writes
  through `bot_save_write` to a temp image plus atomic rename, so a pump or
  world crash loses minutes instead of everything.
- Hard tick caps per action (1 to 600) plus channel capacity 64 with client
  chunking. Bounded batches always terminate and one caller cannot wedge
  the pump.
- Corruption envelope on save inputs. Restore paths validate before swapping
  state and return the uniform failure envelope, reusing the `valid_save`
  pattern through an accessor.
- Measurement ethos. The three probes below run before any FFI descriptor is
  frozen.

## Tradeoffs accepted

- We accept one long-lived process with owner-thread discipline in exchange
  for ms-latency batches and tick-deterministic replay.
- We accept thin FFI exports plus descriptors in exchange for bots using the
  exact verbs of human play, with no cheat paths and no forked logic.
- We accept edn over eval transport in exchange for zero client dependencies.
- We accept bounded actions only in exchange for batches that always
  terminate.
- We accept mine progress as a new global owned by `mcbot_ffi.goose` in
  exchange for leaving `minecraft.goose` gameplay-frozen.

## Alternatives considered

- Process per action plus save-file state. Rejected: per-step spawn plus
  restore destroys latency and transient state handling, and callers inherit
  a distributed-systems problem behind a small interface.
- Direct eval-thread FFI with no pump. Rejected: eval-thread ownership is an
  open unknown and off-owner heap calls segfault the process.
- Synthetic keyboard and mouse retained. Rejected: two ways to act, and the
  registry is the one programmatic path. The existing wtype bot stays as a
  demo harness only, not a control path.

## Red-flag screen (synthesized shape)

Shallow module passes. Two functions plus data hide threading, packing,
arenas, and batching. Information leakage passes. `translate.clj` is the
single parse point. Temporal decomposition passes. Registry owns op
semantics, pump owns thread ownership, translate owns representation.
Pass-through passes. Every boundary adds policy. Split ownership passes.
World and player go through pump exec only. Mine progress has one owner file.
Two ways passes. The registry is the one programmatic path. Importable
internals passes. Server namespaces are unreachable from the bb client
process. Hand-synced list passes. The registry map derives dispatch, spec,
and help.

## Implementation reconciliation

Built against the sketch with six accepted deviations, all recorded here.
Acceptance source is the live verification in this session.

- Middleware deleted. The sketch had a wrap-bot namespace. A plain
  run-batch eval needs no middleware, so that file is gone and the bb
  contract points at mcbot.server/run-batch! directly.
- Server holds the pump in a global atom. start-server! wires the real
  registry policy plus init! as on-owner-ready. stop-server! joins and
  forgets. Bare evals work with no session setup.
- Owner enforcement is structural. The pump binds *owner* on its thread.
  exec-action throws :wrong-thread off-owner. A stale-nREPL incident
  (old registry shadowing new code in a live session) confirmed the rule
  earns its place. Reload order is ffi-defs, pump, registry, translate,
  server, then stop and restart the pump.
- Envelopes merge in exec-action. Failure fragments keep their :ok false.
  translate/ok and translate/err were deleted as dead code. pose->map and
  hit->map moved to registry to avoid a require cycle. translate keeps
  input plans only.
- Save and load are real ops. fs/write-bytes plus atomic rename, restore
  through fs/read-all-bytes after an exists check. Graft from candidate 2.
- Float probe passed. BotPoseOut and BotHit use real :float fields per the
  Mixed precedent. No descriptor was frozen before the header existed.
- No goose_exit in the server. Teardown from a non-owner tears the runtime
  down, so the server never calls it. Process exit owns cleanup.

## Open questions and risks

- Resolved: float2 and float3 codegen is flat. Probes one and three are
  answered (chan plus promise plus future confirmed, LinkedBlockingQueue
  abandoned).
- Remaining: should :reset reseed mine progress and the clock, or preserve
  the clock across resets?
- Remaining: scan-window cap policy on truncation, cursor or refusal?

## Next implementation step

Done. The control plane is live: pump plus FFI plus bb transport verified
end to end. Remaining work is bot behavior built on run-batch!, not
plumbing.

## Module map

- `src/mcbot/registry.clj`: real specs, validation, help, exec bodies over
  FFI, owner enforcement, save and load ops.
- `src/mcbot/translate.clj`: real defaults, normalization, plan building.
- `src/mcbot/pump.clj`: real owner thread, ready gate, submit, stop.
- `src/mcbot/server.clj`: global handle, start and stop, run-batch,
  reset-world.
- `src/mcbot/ffi_defs.clj`: real bindings and memory helpers for libmcbot.
- `src/mcbot/verify.clj`: `-main` proof: reset, walk, determinism,
  snapshot, save round trip. Exit 0 green, 1 red.
- `bb/bot/mcbot_client.clj`: real local validation plus dry-run plan output.
  Transport waits for the pump.
