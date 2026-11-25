# goose export ABI + thread interop matrix (bb)

Port of `jl/test/goose/export_abi.clj`, driven through `babashka.ffi`
(`org.babashka/ffi 0.1.3`, `org.clojure/core.async 1.8.741`).
Library: `../gs/export_abi.goose` built as ONE dylib by `bb goose-lib`
(`goose_init` resolves to the first library loaded in a process).

Run: `bb goose-test` from `bb/`. Last verified: `Ran 6 tests containing
121 assertions. 0 failures, 0 errors.` (twice, identical).

## 1. ABI shapes (`export_abi.clj:80-120`, `gs/export_abi.goose:231-381`)

`export_abi.h` wraps every type in `#pragma pack(push, 1)`. bb layouts use
natural alignment, so a packed value crosses as a run of `:uint8` fields at
byte offsets. Struct returns arrive as maps; write the map into a buffer to
read fields. Slices cross as maps `{:data pointer :len n}`.

| Shape | goose decl | bb pattern | check |
|---|---|---|---|
| i8/u8/i16/u16/i32/u32/i64/f32/f64/bool | `abi_i8` … `abi_not` | scalar cfn args | `-5, 250, -300, 65000, -70000, 4000000000, -5000000000000, 1.5, 2.25, 0` |
| u64 | `abi_u64` | signed long bit pattern | `-446744073709551616` round-trips (bb has no unsigned long) |
| Pair (packed 12: b@0, a@8) | `abi_pair_sum` | `packed-layout 12`, bytes at offsets | `103`; natural-order read provably differs |
| Mixed | `abi_mixed_sum` | real types `[:g :double][:f :float]` (a `:uint8` run would misclassify SSE vs GPR) | `3.75` |
| i32[4], i32[..4], Grid | `abi_arr_sum`, `abi_static_sum`, `abi_grid_sum` | `packed-layout 16/17` | `10`; len-2 static `11` |
| Color | `abi_color_next` | `packed-layout 1`, `:b0` | `2` |
| Shape (tag@0 + union payload@1) | `abi_shape_area` | byte run + `ffi/place` union overlay at offset 1 | Rect `12.0`, Dot `0.0` |
| Pair&, i32[4]&, Grid&, Color&, Shape& | `abi_pair_shift` … | pointer, write before / read after | `[8 105]`, `[2 3 4 5]`, `2`, `[2 4.0 5.0]`, `[1 3.5]` |
| i32[:], const i32[:], Pair[:], Color[:], Shape[:] | `abi_i32_sum_slice` … | `{:data :len}` maps over caller-owned arenas | `60`, `307`, `2`, `10.0` |
| const u8[:] result | `abi_hello` | pointer + out-len, byte reads (not NUL-terminated) | `"hello from goose"` |
| i32[4], Pair, Shape results | `abi_arr_make`, `abi_pair_make`, `abi_shape_make` | write returned map into buffer, read fields | `[10 20 30 40]`, `[7 900]`, `[2 3.0 4.0]` |
| VM | `goose_vm_run` / `try_run` / `last_abort` | 9-byte op encoding over slice map | countdown `32`, factorial `119`, `2+3 → 5`; abort message, 256-op limit, exit/init restart |

## 2. Boundary rejections (`boundary-rejections :726`)

`goose check` rejects with `only fixed-size values cross by value`:
`i32[..]` (value, `&`, result, struct field), `i32[]`, `i32[varint]`,
`i32[>..]`, `i32[>..<]`; `u8[>..]&` builder param with
`no public C representation`. Accepted: `i32[..8]`, `const i32[:]`.

## 3. Thread interop matrix (`thread-ownership :651`)

`sc_add`, `sc_fib`, `sc_fixed_array` (fixed local array, no heap) and
caller-slice `sc_sum_slice` (memory owned by caller) are value-only: safe
anywhere. `sc_sum_stack` (grow-shrink array) and `sc_thread_double` /
`sc_thread_fail` (spawn + wait) need the runtime owner. Off-owner they
SIGSEGV the process (exit 99, `Segfault detected` — uncatchable in-process,
so probes run in `bb -e` subprocesses). With core.async 1.8.741 a go block
runs on a virtual thread.

| context | value-only exports | `sc_sum_stack` (heap) | `sc_thread_double` (spawn+wait) |
|---|---|---|---|
| init thread | works | works (`10`) | works (`42`) |
| `future` | works | exit 99 segfault | exit 99 segfault |
| raw platform `Thread` | works | exit 99 segfault | exit 99 segfault |
| virtual `Thread/ofVirtual` | works (`fib 20 → 6765`) | exit 99 segfault | exit 99 segfault |
| core.async go block | works | exit 99 segfault | exit 99 segfault |

Also covered: 20 concurrent futures; 10 host futures + 10 init-thread goose
calls coexisting; go block provably off init thread; init thread unaffected
after the subprocess crashes.

Supported async shape: init thread makes the calls, channels carry values.
`[2 4 6]` round-trips through `in`/`out` chans with a go-block consumer that
never touches the ABI; contained failure `sc_thread_fail → -1` rides a
channel as an ordinary value (`:675-698`).

## 4. Who can own the runtime (`host-thread-initialization :711`)

`goose_init` takes effect once per process, on the calling thread; runtime
state (`gs_stks`) is thread-local. Each probe runs in a fresh `bb -e`
(the suite process already initialized on its test thread).

| probe | result |
|---|---|
| `init` on platform / virtual / go thread, then fib+stack+worker+exit | `[6765 10 42]`, exit 0, all three |
| owner inits on thread A, second `init` on thread B | no-op, owner intact `[6765 10 42]` |
| owner inits on thread A, another thread calls heap export | exit 99 segfault — init elsewhere grants nothing |
| `exit` on non-owner | tears runtime down; owner's next export fails `goose_init must be called…` (exit 1) |

Second runtime in-process: reload only. Concurrent runtimes need separate
processes. No `thread_spawn` is involved in any of this — ownership is just
which thread called `init`.

## 5. Goose-spawned child threads (spec §11.2, impl §6.8/§7)

Detached native pthreads created inside the runtime; invisible to the host.
No id, queue, or wait handle crosses the ABI in this library, and
`spawn`/`wait`/`qput`/`qget` are goose builtins with no C entry points, so bb
cannot create, wait, kill, or message a child directly. Verified against
compiled probes (`goose build`, JIT has no threads):

- Export blocks in `thread_wait`: a 500ms worker holds the init thread the
  full `505ms`; host sees only the return (`42`).
- Children run concurrently with each other, not the host: 4 × `sleep_ms(200)`
  → `~205ms` wall.
- Globals are copied at spawn: worker `counter += 1` saw `101`, main kept
  `100`. Args and queue elements are flat copies; queues live outside stack
  memory and outlive the sender (grandchild's `420` arrived after its spawner
  exited). Repeated `thread_wait` on a done id returns `true` immediately.
- Contained abort → `wait` is `false` + message → export returns a value
  (`-1`); uncontained / main-thread abort ends the process.

Consequence for bb: vthread/go interop is init-thread-mediated only.
Go blocks and virtual threads coordinate with the init thread over
host-side channels; the init thread alone drives goose, and goose children
resolve into plain return values before anything crosses to bb.

## 6. jl vs bb (`jl/test/goose/export_abi.clj` vs `bb/test/goose/export_abi.clj`)

- jl: `Ran 5 tests containing 82 assertions. 0 failures, 0 errors.`
  (`jolt -A:test -m jolt.test-runner goose.export-abi`)
- bb: `Ran 6 tests containing 121 assertions. 0 failures, 0 errors.`
  (`bb goose-test`)

Coverage parity: all 49 `check` labels identical; VM programs, all ABI
shapes, T& / T[:] / results, the 8 rejects + 2 accepts, and the nREPL
assertions (`:e2e-ok 5`, abort message, `:e2e-after 5`, server `out: 5`)
match. Deltas are host adaptations plus bb-only thread coverage:

| area | jl | bb |
|---|---|---|
| u64 | BigInt `18000000000000000000N` round-trips | signed-long bit pattern `-446744073709551616` (no unsigned long) |
| struct/enum results | leading out-pointer buffer arg | native map return, written into a buffer to read |
| Mixed arg | 12-byte buffer via `mixed-bytes!` | map `{:g 2.25 :f 1.5}` (same real-type descriptor) |
| off-init faults | in-process, `fault?` catches `invalid memory reference` (2 assertions) | subprocess `bb -e` probes, exit 99 + `segfault` (4 contexts × 2 exports × 2 assertions) |
| threads | `fib/spawn` + `fib/join`, 20 concurrent fibers | `future` + platform / virtual / go matrix, go-off-thread check, host+goose coexistence, channel round-trip (`[2 4 6]`, fail → `-1`) |
| ownership of runtime | fixture only | extra deftest: platform/virtual/go thread can init (`[6765 10 42]`); second init elsewhere is a no-op; init elsewhere grants nothing (segfault) |
| nREPL | `jolt nrepl-server --no-port-file`, fixed 1500ms sleep | `bb nrepl-server`, port poll, `.nrepl-port` snapshot/restore, 60s kill-on-timeout `sh`/`client` |
