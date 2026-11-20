// One shared library for test/export_abi.clj: the VM sample and the two
// export-boundary samples, combined so a single goose_init serves them all.
// (Three separate dylibs cannot share a process: goose_init resolves to the
// first one loaded.)
// A stack-machine bytecode interpreter. The program is an array of
// instructions, each a fixed-mode enum value (a 1-byte opcode plus room for
// one operand), and the dispatch loop is a `match` over it: no function
// pointers, no switch on a byte you then have to decode, and a jump target
// is just an index into the same array. Two programs are assembled by
// hand: a countdown loop and an iterative factorial. They are assembled in
// Jolt (src/goose/vm.clj), which builds this file as a shared library and
// calls `run` over jolt.ffi:
//
//   goose build --shared --header 19_vm.h 19_vm.goose
//   jolt -m goose.vm
//
// There is no `main` here: the host owns the top of the program.

import std;

enum Op {
    Push { v: i64 },                     // push a constant
    Load { slot: u8 },                   // push local variable `slot`
    Store { slot: u8 },                  // pop into local `slot`
    Add, Sub, Mul,                       // pop two, push the result
    Dup,                                 // duplicate the top
    Jump { to: u16 },                    // jump to instruction `to`
    JumpIfZero { to: u16 },              // pop; jump if it was zero
    Print,                               // pop and print
    Halt,
}

struct Vm { stack: i64[>..<] }

fn op_name(o: Op) -> u8[:] {
    match o {
        Push p => "push", Load l => "load", Store s => "store", Add => "add", Sub => "sub",
        Mul => "mul", Dup => "dup", Jump j => "jump", JumpIfZero j => "jz",
        Print => "print", Halt => "halt",
    }
}

// A listing: index, mnemonic, and the operand if there is one.
export "goose_vm_disassemble" fn disassemble(code: Op[:]) {
    for o, i in code {
        var l: u8[>..] = [];
        format_int(l, i, 10, 3, ' ');
        format(l, "  ", op_name(o));
        match o {
            Push p => format(l, " ", p.v),
            Load v => format(l, " ", v.slot),
            Store v => format(l, " ", v.slot),
            Jump j => format(l, " ", j.to),
            JumpIfZero j => format(l, " ", j.to),
            _ => {},
        }
        print(l);
    }
}

// Runs code from instruction 0 until Halt; returns the number of
// instructions executed. The operand stack is a grow-shrink array, the
// locals a small fixed array. The `match` is a switch on the tag byte with
// the operand read in place, and a jump is an index store.
export "goose_vm_run" fn run(code: Op[:]) -> i64 {
    var stack:  i64[>..<] = [];
    var locals: i64[8]    = [0; 8];
    var pc = 0;
    var steps = 0;
    loop {
        let op = code[pc];
        pc++;
        steps++;
        match op {
            Push p => { stack.push(p.v); },
            Load l => { stack.push(locals[l.slot]); },
            Store s => { locals[s.slot] = stack.pop(); },
            Add => { let b = stack.pop(); let a = stack.pop(); stack.push(a + b); },
            Sub => { let b = stack.pop(); let a = stack.pop(); stack.push(a - b); },
            Mul => { let b = stack.pop(); let a = stack.pop(); stack.push(a * b); },
            Dup => { let a = stack.pop(); stack.push(a); stack.push(a); },
            Jump j => { pc = j.to; },
            JumpIfZero j => { if stack.pop() == 0 { pc = j.to; } },
            Print => { print("  out: ", stack.pop()); },
            Halt => { break; },
        }
    }
    return steps;
}

// ---- Containment: a program that aborts fails the call, not the host.
//
// A worker's arguments must be flat, so a program crosses to it as an inline
// array rather than the slice the export takes. `thread_spawn_contained` keeps
// a failed check inside the worker: `thread_wait` returns false and hands back
// the message, where the same abort on main's thread would end the process.

const MaxOps: i64 = 256;

struct Program { len: i64, ops: Op[MaxOps] }
struct Outcome { steps: i64 }

var vm_abort: u8[>..] = [];

thread_fn interpret(p: Program) {
    var code: Op[>..] = [];
    for i in p.len { code.push(p.ops[i]); }
    qput(Outcome { steps: run(code) });
}

// The steps executed, -1 if the program aborted (see last_abort), or -2 if it
// is longer than MaxOps.
export "goose_vm_try_run" fn try_run(code: Op[:]) -> i64 {
    vm_abort.clear();
    if code.len > MaxOps { return -2; }
    var ops: Op[MaxOps] = [default<Op>(); MaxOps];
    for i in code.len { ops[i] = code[i]; }
    let id = thread_spawn_contained(interpret, Program { len: code.len, ops: ops });
    var why: u8[>..] = [];
    if thread_wait(id, why) {
        return qget<Outcome>().steps;
    }
    for b in why { vm_abort.push(b); }
    return -1;
}

// The message from the last failed try_run, with its goose location.
export "goose_vm_last_abort" fn last_abort() -> const u8[:] {
    return vm_abort;
}
// Exported functions for asking a narrow question: what does an exported
// goose function actually need from the thread that calls it?
//
// The first group takes and returns only scalars, declares only scalar
// locals, and allocates nothing: no arrays, no slices, no strings, so no
// data stack is touched.
//
// The last group does the opposite, as a control.

export "sc_add" fn add(a: i64, b: i64) -> i64 {
    return a + b;
}

export "sc_mul" fn mul(a: i64, b: i64) -> i64 {
    return a * b;
}

export "sc_clamp" fn clamp(v: i64, lo: i64, hi: i64) -> i64 {
    var r = v;
    if r < lo { r = lo; }
    if r > hi { r = hi; }
    return r;
}

// Iterative, so no call stack growth either.
export "sc_fib" fn fib(n: i64) -> i64 {
    var a: i64 = 0;
    var b: i64 = 1;
    var i: i64 = 0;
    while i < n {
        let t = a + b;
        a = b;
        b = t;
        i++;
    }
    return a;
}

export "sc_noop" fn noop() {
}

// ---- controls: these do use a data stack

// A grow-shrink array: allocation and stack traffic.
export "sc_sum_stack" fn sum_stack(n: i64) -> i64 {
    var s: i64[>..] = [];
    for i in n { s.push(i); }
    var t: i64 = 0;
    for x in s { t += x; }
    return t;
}

// Reads a caller-provided slice: no allocation, but a slice is a data-stack
// value.
export "sc_sum_slice" fn sum_slice(xs: i64[:]) -> i64 {
    var t: i64 = 0;
    for x in xs { t += x; }
    return t;
}

// ---- probe: does spawning a goose worker need a particular thread?

thread_fn double_worker(n: i64) {
    qput(n * 2);
}

thread_fn fail_worker(n: i64) {
    var s: i64[>..] = [];
    let x = s.pop();
    qput(x + n);
}

export "sc_thread_double" fn thread_double(n: i64) -> i64 {
    let id = thread_spawn_contained(double_worker, n);
    var why: u8[>..] = [];
    if thread_wait(id, why) { return qget<i64>(); }
    return -1;
}

export "sc_thread_fail" fn thread_fail(n: i64) -> i64 {
    let id = thread_spawn_contained(fail_worker, n);
    var why: u8[>..] = [];
    if thread_wait(id, why) { return qget<i64>(); }
    return -1;
}

// ---- probe: fixed-size local array, no grow/shrink, no heap
export "sc_fixed_array" fn fixed_array(n: i64) -> i64 {
    var a: i64[16] = [0; 16];
    var t: i64 = 0;
    for i in 16 { a[i] = i + n; }
    for x in a { t += x; }
    return t;
}
// Exports covering every shape the docs say may cross a C boundary, so a host
// can check the ABI in both directions (reference §24, "What may cross").
//
// Built by `jolt goose-abi`: `goose build --shared --header goose/21_abi.h`.
// The host header is the contract this file is testing.

// --- flat fixed-size values

struct Pair  { a: i32, b: i64 }     // padding between a and b
struct Mixed { f: f32, g: f64 }     // and between f and g
struct Grid  { cells: i32[4] }      // a struct holding a fixed array

enum Color { Red, Green, Blue }     // fixed-mode enum without fields
// Fixed-mode enum with fields: one tag byte plus its largest payload, inline.
enum Shape { Dot, Circle { r: f64 }, Rect { w: f64, h: f64 } }

// --- scalars, by value, both directions

export "abi_i8"   fn e_i8(x: i8) -> i8     { return x; }
export "abi_u8"   fn e_u8(x: u8) -> u8     { return x; }
export "abi_i16"  fn e_i16(x: i16) -> i16  { return x; }
export "abi_u16"  fn e_u16(x: u16) -> u16  { return x; }
export "abi_i32"  fn e_i32(x: i32) -> i32  { return x; }
export "abi_u32"  fn e_u32(x: u32) -> u32  { return x; }
export "abi_i64"  fn e_i64(x: i64) -> i64  { return x; }
export "abi_u64"  fn e_u64(x: u64) -> u64  { return x; }
export "abi_f32"  fn e_f32(x: f32) -> f32  { return x; }
export "abi_f64"  fn e_f64(x: f64) -> f64  { return x; }
export "abi_not"  fn e_not(b: bool) -> bool { return !b; }

// --- flat fixed-size values, by value

export "abi_pair_make" fn e_pair_make(a: i32, b: i64) -> Pair {
    return Pair { a: a, b: b };
}
export "abi_pair_sum" fn e_pair_sum(p: Pair) -> i64 {
    return p.a + p.b;
}
export "abi_mixed_sum" fn e_mixed_sum(m: Mixed) -> f64 {
    return m.f + m.g;
}
export "abi_arr_sum" fn e_arr_sum(xs: i32[4]) -> i64 {
    var t: i64 = 0;
    for x in xs { t += x; }
    return t;
}
export "abi_arr_make" fn e_arr_make() -> i32[4] {
    return [10, 20, 30, 40];
}
// A static-capacity array with a compile-time ceiling crosses as a flat value.
// Without the ceiling, `i32[..]` is variable-size (a u32 capacity and length)
// and is rejected as a value, a reference, a result, and a struct field:
//   "only fixed-size values cross by value"
// So does `i32[]`, `i32[varint]`, `i32[>..]` and `i32[>..<]`.
// A slice of any of them, `const i32[:]`, does cross (see abi_const_i32_sum).
export "abi_static_sum" fn e_static_sum(xs: i32[..4]) -> i64 {
    var t: i64 = 0;
    for x in xs { t += x; }
    return t;
}
export "abi_grid_sum" fn e_grid_sum(g: Grid) -> i64 {
    var t: i64 = 0;
    for x in g.cells { t += x; }
    return t;
}
export "abi_color_next" fn e_color_next(c: Color) -> Color {
    match c {
        Red   => { return Color.Green; },
        Green => { return Color.Blue; },
        Blue  => { return Color.Red; },
    }
}

// --- fixed-mode enum with fields

export "abi_shape_area" fn e_shape_area(s: Shape) -> f64 {
    match s {
        Dot        => { return 0.0; },
        Circle c   => { return 3.141592653589793 * c.r * c.r; },
        Rect r     => { return r.w * r.h; },
    }
}
export "abi_shape_make" fn e_shape_make(w: f64, h: f64) -> Shape {
    return Shape.Rect { w: w, h: h };
}
export "abi_shape_sum" fn e_shape_sum(ss: Shape[:]) -> f64 {
    var t: f64 = 0.0;
    for s in ss { t += e_shape_area(s); }
    return t;
}

// --- T&, as a pointer the callee writes through

export "abi_pair_shift" fn e_pair_shift(p: Pair&, dx: i32) {
    p.a += dx;
    p.b += dx;
}
export "abi_arr_bump" fn e_arr_bump(xs: i32[4]&) {
    for i in 4 { xs[i] += 1; }
}
export "abi_grid_bump" fn e_grid_bump(g: Grid&) {
    for i in 4 { g.cells[i] += 1; }
}
export "abi_shape_grow" fn e_shape_grow(s: Shape&) {
    match s {
        Dot      => {},
        Circle c => { s = Shape.Circle { r: c.r + 1.0 }; },
        Rect r   => { s = Shape.Rect { w: r.w + 1.0, h: r.h + 1.0 }; },
    }
}

export "abi_color_advance" fn e_color_advance(c: Color&) {
    match c {
        Red   => { c = Color.Green; },
        Green => { c = Color.Blue; },
        Blue  => { c = Color.Red; },
    }
}

// --- T[:], as { data, len }

export "abi_i32_sum_slice" fn e_i32_sum_slice(xs: i32[:]) -> i64 {
    var t: i64 = 0;
    for x in xs { t += x; }
    return t;
}
export "abi_pair_sum_slice" fn e_pair_sum_slice(ps: Pair[:]) -> i64 {
    var t: i64 = 0;
    for p in ps { t += p.a + p.b; }
    return t;
}
export "abi_const_i32_sum" fn e_const_i32_sum(xs: const i32[:]) -> i64 {
    var t: i64 = 0;
    for x in xs { t += x; }
    return t;
}
export "abi_color_of" fn e_color_of(cs: Color[:], i: i64) -> Color {
    return cs[i];
}

// --- a const u8[:] result: pointer plus an int64_t* length

export "abi_hello" fn e_hello() -> const u8[:] {
    return "hello from goose";
}

// --- T[>..]&: rejected at an export boundary. `goose check` answers:
//     parameter out uses a reusable pool and has no public C representation
// The docs say the same ("builders are not supported at the boundary"), so a
// host cannot hand a builder to an export. A builder crosses only the other
// way, as an `extern fn` parameter the host implements.
