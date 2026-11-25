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

typedef struct vec2_g_f32 vec2_g_f32;
struct vec2_g_f32 {
    float x_g;
    float y_g;
};

typedef struct vec3_g_f32 vec3_g_f32;
struct vec3_g_f32 {
    float x_g;
    float y_g;
    float z_g;
};

typedef struct vec4_g_f32 vec4_g_f32;
struct vec4_g_f32 {
    float x_g;
    float y_g;
    float z_g;
    float w_g;
};

typedef struct vec2_g_f64 vec2_g_f64;
struct vec2_g_f64 {
    double x_g;
    double y_g;
};

typedef struct vec3_g_f64 vec3_g_f64;
struct vec3_g_f64 {
    double x_g;
    double y_g;
    double z_g;
};

typedef struct vec4_g_f64 vec4_g_f64;
struct vec4_g_f64 {
    double x_g;
    double y_g;
    double z_g;
    double w_g;
};

typedef struct vec2_g_i32 vec2_g_i32;
struct vec2_g_i32 {
    int32_t x_g;
    int32_t y_g;
};

typedef struct vec3_g_i32 vec3_g_i32;
struct vec3_g_i32 {
    int32_t x_g;
    int32_t y_g;
    int32_t z_g;
};

typedef struct vec4_g_i32 vec4_g_i32;
struct vec4_g_i32 {
    int32_t x_g;
    int32_t y_g;
    int32_t z_g;
    int32_t w_g;
};

typedef struct { uint8_t e[8]; } a8_u8;

typedef struct { uint8_t *data; int64_t len; } sl_u8;

typedef struct { sl_u8 e[8]; } a8_sl_u8;

typedef struct Game_g Game_g;
typedef struct Player_g Player_g;
struct Player_g {
    vec3_g_f32 feet_g;
    float velocity_g;
    float yaw_g;
    float pitch_g;
    uint8_t grounded_g;
};

typedef struct { int32_t e[8]; } a8_i32;

struct Game_g {
    uint32_t version_g;
    uint32_t seed_g;
    Player_g player_g;
    a8_i32 bag_g;
    int32_t tool_g;
    int32_t selected_g;
};

typedef struct { uint8_t e[256000]; } a256000_u8;

typedef struct { vec4_g_f32 e[16]; } a16_vec4_g_f32;

typedef struct { uint8_t len; uint8_t e[100]; } l100_u8;

typedef struct Debris_g Debris_g;
struct Debris_g {
    vec3_g_f32 pos_g;
    vec3_g_f32 velocity_g;
    float life_g;
    int64_t tile_g;
};

typedef struct { Debris_g e[48]; } a48_Debris_g;

typedef struct { uint8_t e[25]; } a25_u8;

typedef struct { vec3_g_i32 e[16]; } a16_vec3_g_i32;

typedef struct Cell_g Cell_g;
struct Cell_g {
    int64_t x_g;
    int64_t y_g;
    int64_t z_g;
};

typedef struct { Cell_g e[6]; } a6_Cell_g;

typedef struct { vec2_g_f32 e[4]; } a4_vec2_g_f32;

typedef struct { int64_t e[6400]; } a6400_i64;

typedef struct BotPoseOut_g BotPoseOut_g;
typedef BotPoseOut_g *r_BotPoseOut_g GS_ALIGN1;
typedef struct BotHit_g BotHit_g;
typedef BotHit_g *r_BotHit_g GS_ALIGN1;
typedef struct Hit_g Hit_g;
struct Hit_g {
    uint8_t found_g;
    Cell_g at_g;
    Cell_g before_g;
    float distance_g;
};

typedef struct { gs_i32 *data; int64_t len; } sl_i32;

typedef struct BotCell_g BotCell_g;
typedef BotCell_g *r_BotCell_g GS_ALIGN1;
struct BotPoseOut_g {
    float feet_x_g;
    float feet_y_g;
    float feet_z_g;
    float yaw_g;
    float pitch_g;
    float vel_g;
    uint8_t grounded_g;
};

struct BotHit_g {
    uint8_t found_g;
    int64_t ax_g;
    int64_t ay_g;
    int64_t az_g;
    int64_t bx_g;
    int64_t by_g;
    int64_t bz_g;
    float distance_g;
};

struct BotCell_g {
    int64_t x_g;
    int64_t y_g;
    int64_t z_g;
};

typedef struct { Game_g e[1]; } a1_Game_g;

typedef struct { float e[1]; } a1_f32;

typedef Game_g *r_Game_g GS_ALIGN1;
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
gs_u32 bot_version(void);
void bot_walk_step(gs_f32 gs_export_arg0, gs_f32 gs_export_arg1, uint8_t gs_export_arg2, uint8_t gs_export_arg3, uint8_t gs_export_arg4, gs_i64 gs_export_arg5);
void bot_look(gs_f32 gs_export_arg0_2, gs_f32 gs_export_arg1_2, r_BotPoseOut_g gs_export_arg2_2);
void bot_ray(gs_f32 gs_export_arg0_3, r_BotHit_g gs_export_arg1_3);
uint8_t bot_mine_ticks(gs_i64 gs_export_arg0_4, r_BotHit_g gs_export_arg1_4);
uint8_t bot_place_once(r_BotHit_g gs_export_arg0_5);
void bot_pick(void);
uint8_t bot_select(gs_i64 gs_export_arg0_6);
gs_i64 bot_craft(gs_i64 gs_export_arg0_7, uint8_t gs_export_arg1_5);
void bot_reset(gs_u32 gs_export_arg0_8);
void bot_advance(gs_f32 gs_export_arg0_9);
void bot_pose(r_BotPoseOut_g gs_export_arg0_10);
uint8_t bot_status(sl_i32 gs_export_arg0_11, sl_u8 gs_export_arg1_6);
uint8_t bot_get_block(r_BotCell_g gs_export_arg0_12);
gs_i64 bot_scan_window(r_BotCell_g gs_export_arg0_13, r_BotCell_g gs_export_arg1_7, sl_u8 gs_export_arg2_3);
gs_u32 bot_checksum(void);
gs_i64 bot_save_len(void);
gs_i64 bot_save_write(sl_u8 gs_export_arg0_14);
uint8_t bot_restore(sl_u8 gs_export_arg0_15);
const uint8_t * bot_next_goal(gs_i64 *gs_export_len_20);
const uint8_t * bot_block_name(uint8_t gs_export_arg0_16, gs_i64 *gs_export_len_21);
gs_f32 bot_day_time(void);
#ifdef __cplusplus
}
#endif
