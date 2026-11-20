#pragma once
#include <stdint.h>
#if (defined(__GNUC__) || defined(__clang__)) && !defined(__TINYC__)
#define GS_ALIGN1 __attribute__((aligned(1)))
#else
#define GS_ALIGN1
#endif
typedef int16_t gs_i16 GS_ALIGN1;
typedef int32_t gs_i32 GS_ALIGN1;
typedef int64_t gs_i64 GS_ALIGN1;
typedef uint16_t gs_u16 GS_ALIGN1;
typedef uint32_t gs_u32 GS_ALIGN1;
typedef uint64_t gs_u64 GS_ALIGN1;
typedef float gs_f32 GS_ALIGN1;
typedef double gs_f64 GS_ALIGN1;
typedef struct gs_stack gs_stack;
#pragma pack(push, 1)
typedef struct { uint8_t *base; int64_t len; } gs_rhdr;
typedef struct { gs_rhdr *hdr; gs_stack *stk; } gs_rref;
typedef struct { gs_rhdr *hdr; gs_stack *stk; gs_rhdr *fl; gs_stack *flstk; } gs_pref;

typedef struct { double e[23]; } a23_f64;

typedef struct { uint64_t e[20]; } a20_u64;

typedef struct { uint64_t e[28]; } a28_u64;

typedef struct { uint64_t e[1392]; } a1392_u64;

typedef struct Program_g Program_g;
typedef struct Op_g Op_g;
enum {
    Op_g_Push_g_k = 0,
    Op_g_Load_g_k = 1,
    Op_g_Store_g_k = 2,
    Op_g_Add_g_k = 3,
    Op_g_Sub_g_k = 4,
    Op_g_Mul_g_k = 5,
    Op_g_Dup_g_k = 6,
    Op_g_Jump_g_k = 7,
    Op_g_JumpIfZero_g_k = 8,
    Op_g_Print_g_k = 9,
    Op_g_Halt_g_k = 10,
};

typedef struct Op_g_Push_p Op_g_Push_p;
struct Op_g_Push_p {
    int64_t v_g;
};

typedef struct Op_g_Load_p Op_g_Load_p;
struct Op_g_Load_p {
    uint8_t slot_g;
};

typedef struct Op_g_Store_p Op_g_Store_p;
struct Op_g_Store_p {
    uint8_t slot_g;
};

typedef struct Op_g_Jump_p Op_g_Jump_p;
struct Op_g_Jump_p {
    uint16_t to_g;
};

typedef struct Op_g_JumpIfZero_p Op_g_JumpIfZero_p;
struct Op_g_JumpIfZero_p {
    uint16_t to_g;
};

struct Op_g {
    uint8_t tag;
    union {
        Op_g_Push_p v_Push_g;
        Op_g_Load_p v_Load_g;
        Op_g_Store_p v_Store_g;
        Op_g_Jump_p v_Jump_g;
        Op_g_JumpIfZero_p v_JumpIfZero_g;
    } u;
};

typedef struct { Op_g e[256]; } a256_Op_g;

struct Program_g {
    int64_t len_g;
    a256_Op_g ops_g;
};

typedef struct { Op_g *data; int64_t len; } sl_Op_g;

typedef struct { uint8_t *data; int64_t len; } sl_u8;

typedef struct { gs_i64 *data; int64_t len; } sl_i64;

typedef struct Pair_g Pair_g;
struct Pair_g {
    int32_t a_g;
    int64_t b_g;
};

typedef struct Mixed_g Mixed_g;
struct Mixed_g {
    float f_g;
    double g_g;
};

typedef struct { int32_t e[4]; } a4_i32;

typedef struct { uint8_t len; int32_t e[4]; } l4_i32;

typedef struct Grid_g Grid_g;
struct Grid_g {
    a4_i32 cells_g;
};

typedef struct Color_g Color_g;
enum {
    Color_g_Red_g_k = 0,
    Color_g_Green_g_k = 1,
    Color_g_Blue_g_k = 2,
};

struct Color_g {
    uint8_t tag;
};

typedef struct Shape_g Shape_g;
enum {
    Shape_g_Dot_g_k = 0,
    Shape_g_Circle_g_k = 1,
    Shape_g_Rect_g_k = 2,
};

typedef struct Shape_g_Circle_p Shape_g_Circle_p;
struct Shape_g_Circle_p {
    double r_g;
};

typedef struct Shape_g_Rect_p Shape_g_Rect_p;
struct Shape_g_Rect_p {
    double w_g;
    double h_g;
};

struct Shape_g {
    uint8_t tag;
    union {
        Shape_g_Circle_p v_Circle_g;
        Shape_g_Rect_p v_Rect_g;
    } u;
};

typedef struct { Shape_g *data; int64_t len; } sl_Shape_g;

typedef Pair_g *r_Pair_g GS_ALIGN1;
typedef a4_i32 *r_a4_i32 GS_ALIGN1;
typedef Grid_g *r_Grid_g GS_ALIGN1;
typedef Shape_g *r_Shape_g GS_ALIGN1;
typedef Color_g *r_Color_g GS_ALIGN1;
typedef struct { gs_i32 *data; int64_t len; } sl_i32;

typedef struct { Pair_g *data; int64_t len; } sl_Pair_g;

typedef struct { Color_g *data; int64_t len; } sl_Color_g;

typedef struct Outcome_g Outcome_g;
struct Outcome_g {
    int64_t steps_g;
};

typedef struct { int64_t e[8]; } a8_i64;

typedef struct { uint8_t len; uint8_t e[64]; } l64_u8;

typedef struct { int64_t e[16]; } a16_i64;

typedef struct ByteSet_g ByteSet_g;
typedef ByteSet_g *r_ByteSet_g GS_ALIGN1;
typedef struct { uint8_t e[256]; } a256_b;

typedef struct { uint8_t e[3]; } a3_u8;

typedef struct { uint8_t e[16]; } a16_u8;

struct ByteSet_g {
    a256_b members_g;
    uint8_t kind_g;
    uint8_t invert_g;
    a3_u8 bytes_g;
    a16_u8 lo_g;
    a16_u8 hi_g;
};

typedef gs_i32 *r_i32 GS_ALIGN1;
typedef gs_i64 *r_i64 GS_ALIGN1;
#pragma pack(pop)

#ifdef __cplusplus
extern "C" {
#endif
void goose_init(int argc, char **argv);
void goose_exit(void);
void goose_vm_disassemble(sl_Op_g gs_export_arg0);
gs_i64 goose_vm_run(sl_Op_g gs_export_arg0_2);
gs_i64 goose_vm_try_run(sl_Op_g gs_export_arg0_3);
const uint8_t * goose_vm_last_abort(gs_i64 *gs_export_len_4);
gs_i64 sc_add(gs_i64 gs_export_arg0_4, gs_i64 gs_export_arg1);
gs_i64 sc_mul(gs_i64 gs_export_arg0_5, gs_i64 gs_export_arg1_2);
gs_i64 sc_clamp(gs_i64 gs_export_arg0_6, gs_i64 gs_export_arg1_3, gs_i64 gs_export_arg2);
gs_i64 sc_fib(gs_i64 gs_export_arg0_7);
void sc_noop(void);
gs_i64 sc_sum_stack(gs_i64 gs_export_arg0_8);
gs_i64 sc_sum_slice(sl_i64 gs_export_arg0_9);
gs_i64 sc_thread_double(gs_i64 gs_export_arg0_10);
gs_i64 sc_thread_fail(gs_i64 gs_export_arg0_11);
gs_i64 sc_fixed_array(gs_i64 gs_export_arg0_12);
int8_t abi_i8(int8_t gs_export_arg0_13);
uint8_t abi_u8(uint8_t gs_export_arg0_14);
gs_i16 abi_i16(gs_i16 gs_export_arg0_15);
gs_u16 abi_u16(gs_u16 gs_export_arg0_16);
gs_i32 abi_i32(gs_i32 gs_export_arg0_17);
gs_u32 abi_u32(gs_u32 gs_export_arg0_18);
gs_i64 abi_i64(gs_i64 gs_export_arg0_19);
gs_u64 abi_u64(gs_u64 gs_export_arg0_20);
gs_f32 abi_f32(gs_f32 gs_export_arg0_21);
gs_f64 abi_f64(gs_f64 gs_export_arg0_22);
uint8_t abi_not(uint8_t gs_export_arg0_23);
Pair_g abi_pair_make(gs_i32 gs_export_arg0_24, gs_i64 gs_export_arg1_4);
gs_i64 abi_pair_sum(Pair_g gs_export_arg0_25);
gs_f64 abi_mixed_sum(Mixed_g gs_export_arg0_26);
gs_i64 abi_arr_sum(a4_i32 gs_export_arg0_27);
a4_i32 abi_arr_make(void);
gs_i64 abi_static_sum(l4_i32 gs_export_arg0_28);
gs_i64 abi_grid_sum(Grid_g gs_export_arg0_29);
Color_g abi_color_next(Color_g gs_export_arg0_30);
gs_f64 abi_shape_area(Shape_g gs_export_arg0_31);
Shape_g abi_shape_make(gs_f64 gs_export_arg0_32, gs_f64 gs_export_arg1_5);
gs_f64 abi_shape_sum(sl_Shape_g gs_export_arg0_33);
void abi_pair_shift(r_Pair_g gs_export_arg0_34, gs_i32 gs_export_arg1_6);
void abi_arr_bump(r_a4_i32 gs_export_arg0_35);
void abi_grid_bump(r_Grid_g gs_export_arg0_36);
void abi_shape_grow(r_Shape_g gs_export_arg0_37);
void abi_color_advance(r_Color_g gs_export_arg0_38);
gs_i64 abi_i32_sum_slice(sl_i32 gs_export_arg0_39);
gs_i64 abi_pair_sum_slice(sl_Pair_g gs_export_arg0_40);
gs_i64 abi_const_i32_sum(sl_i32 gs_export_arg0_41);
Color_g abi_color_of(sl_Color_g gs_export_arg0_42, gs_i64 gs_export_arg1_7);
const uint8_t * abi_hello(gs_i64 *gs_export_len_46);
#ifdef __cplusplus
}
#endif
