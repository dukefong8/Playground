// A little block world, built entirely from code: terrain, caves, trees,
// pixel textures, sky, and even the tiny font. There are no asset files.
// Start empty-handed, gather wood, make a pick, mine stone and coal, then
// build a cabin and light it. This is a programming sample, not an engine:
// a finite grid, a few plain structs, and one update/draw loop.
//
//   goose samples/30_mini_minecraft.goose
//   goose samples/30_mini_minecraft.goose -- --seed 123
//   goose samples/30_mini_minecraft.goose -- --frames 120
//   goose samples/30_mini_minecraft.goose -- --test
//
// WASD walk; Space jump/swim up; Shift run; mouse or arrows look.
// Ctrl sneaks slowly and stops at ledges; jumping releases that protection.
// Hold left mouse to mine; right mouse or E places (hold to build a row).
// 1-8 or wheel selects a slot; middle click picks the aimed-at material.
// C opens crafting; hold Shift with a recipe to make all affordable batches.
// H toggles help. Menus release the mouse cursor.
// Escape pauses/resumes; F5 saves; F9 loads; F12 takes a screenshot.
// Losing focus pauses. Click or Escape resumes when you return.
// Close the window to quit. Saving is explicit, to mini_minecraft.sav in
// the working directory; starting a new game never overwrites a save.
// --frames runs a fresh, deterministic world and saves mini_minecraft.png.
// --test checks gameplay without opening a window or touching save files.
//
// Deliberate limits: 80 x 40 x 80 blocks, no mobs, hunger, damage, dropped
// items, fluid simulation, tool wear, or infinite streaming. Water stays
// where it was generated. Materials go straight into the inventory.
// Lamps are full blocks, with at most sixteen placed lights. Lighting is
// approximate, so it can leak through a wall. Tools are permanent upgrades.
// A day lasts ten minutes; night is peaceful, but lamps help you see.
//
// Collision with this grid is simpler to show directly than to maintain
// a separate physics world full of static boxes.

import std;
import vec;
import math;
import os;
import gfx;
import mcworld;

// --- blocks and game state ----------------------------------------------------

struct Mesh {
    vertices: gfx::Buffer,
    indices:  gfx::Buffer,
    count:    i64,
}
var meshes: Mesh[CHUNKS_X * CHUNKS_Z];

// --- a 256 x 16 texture atlas, painted one pixel at a time --------------------

fn make_atlas() -> gfx::Texture {
    var pixels: u8[>..] = [];
    for y in TILE_SIZE {
        for tile in TILES {
            for x in TILE_SIZE { pixels.append(pixel(tile, x, y)); }
        }
    }
    let texture = gfx::texture2d(TILE_SIZE * TILES, TILE_SIZE);
    if texture.id == 0 || !gfx::update_texture(texture, pixels) {
        abort(str("texture: ", gfx::error()));
    }
    texture
}

// --- exposed faces, split into 16 x 40 x 16 chunks ----------------------------

fn rebuild_chunk(cx: i64, cz: i64) {
    // Scratch lives only until this function returns. The GPU owns a copy.
    var vertices: Vertex[>..] = [];
    var indices:  u32[>..]    = [];
    for y in HEIGHT {
        for z in cz * CHUNK..(cz + 1) * CHUNK {
            for x in cx * CHUNK..(cx + 1) * CHUNK {
                let c = cell(x, y, z);
                let b = block_at(c);
                if b == AIR { continue; }
                for face in 6 {
                    if face_visible(b, block_at(c + NORMAL[face])) {
                        add_face(vertices, indices, c, b, face);
                    }
                }
            }
        }
    }
    let i = cz * CHUNKS_X + cx;
    if meshes[i].vertices.id != 0 { gfx::release(meshes[i].vertices); }
    if meshes[i].indices.id != 0 { gfx::release(meshes[i].indices); }
    meshes[i] = Mesh { count: indices.len, .. };
    if indices.len > 0 {
        meshes[i].vertices = gfx::vertex_buffer(bytes_of(vertices));
        meshes[i].indices = gfx::index_buffer(bytes_of(indices));
        if meshes[i].vertices.id == 0 || meshes[i].indices.id == 0 {
            abort(str("chunk buffers: ", gfx::error()));
        }
    }
}
fn rebuild_dirty() {
    // Drain one flag per chunk (dirty_take clears what it reports), then
    // refresh the sky columns once and rebuild exactly the marked chunks.
    var dirty: bool[CHUNKS_X * CHUNKS_Z] = [false; CHUNKS_X * CHUNKS_Z];
    var any = false;
    for i in CHUNKS_X * CHUNKS_Z {
        dirty[i] = dirty_take(i);
        any = any || dirty[i];
    }
    if !any { return; }
    for z in DEPTH {
        for x in WIDTH { column_top[z * WIDTH + x] = highest(x, z); }
    }
    for cz in CHUNKS_Z {
        for cx in CHUNKS_X {
            if dirty[cz * CHUNKS_X + cx] { rebuild_chunk(cx, cz); }
        }
    }
}

// --- shaders ----------------------------------------------------------------

// Every field begins on a 16-byte boundary, exactly as GLSL std140 wants.
// eye.w is time; target.w is mining progress, or -1 if nothing is targeted.
struct Scene {
    view_proj: gfx::mat4,
    eye:       float4,
    target:    float4,
    lights:    float4[MAX_LAMPS],
    haze:      float4,
    sun:       float4,        // xyz: direction, w: daylight strength
}
let scene_uniform = """
    layout(set = 3, binding = 0) uniform Scene {
        mat4 view_proj;
        vec4 eye;
        vec4 target;
        vec4 lights[16];
        vec4 haze;
        vec4 sun;
    };
    """;
let world_vertex = """
    layout(location = 0) in vec3 a_pos;
    layout(location = 1) in vec3 a_normal;
    layout(location = 2) in vec2 a_uv;
    layout(location = 3) in float a_shade;
    layout(location = 4) in float a_material;
    layout(set = 1, binding = 0) uniform Camera { mat4 view_proj; };
    layout(location = 0) out vec3 v_world;
    layout(location = 1) out vec3 v_normal;
    layout(location = 2) out vec2 v_uv;
    layout(location = 3) out float v_shade;
    layout(location = 4) flat out float v_material;
    void main() {
        v_world = a_pos;
        v_normal = a_normal;
        v_uv = a_uv;
        v_shade = a_shade;
        v_material = a_material;
        gl_Position = view_proj * vec4(a_pos, 1.0);
    }
    """;
let world_fragment = """
    layout(location = 0) in vec3 v_world;
    layout(location = 1) in vec3 v_normal;
    layout(location = 2) in vec2 v_uv;
    layout(location = 3) in float v_shade;
    layout(location = 4) flat in float v_material;
    layout(set = 2, binding = 0) uniform sampler2D atlas;
    layout(location = 0) out vec4 result;
    void main() {
        vec3 base = texture(atlas, v_uv).rgb;
        float direct = max(dot(v_normal, sun.xyz), 0.0) * sun.w;
        vec3 light = mix(vec3(0.10, 0.14, 0.23), vec3(0.64, 0.73, 0.82) * 0.48, sun.w);
        light += vec3(0.66, 0.59, 0.43) * direct;
        light *= v_shade;
        for (int i = 0; i < 16; i++) {
            float d = length(lights[i].xyz - v_world);
            float glow = max(0.0, 1.0 - d / 7.0);
            light += vec3(1.0, 0.63, 0.25) * glow * glow * lights[i].w;
        }
        if (v_material == 12.0) light = max(light, vec3(1.1, 0.96, 0.7));
        if (v_material == 10.0) {
            float wave = sin(v_world.x * 2.7 + eye.w) * sin(v_world.z * 3.1 - eye.w);
            base += vec3(0.04, 0.07, 0.08) * wave;
            light = max(light, vec3(mix(0.15, 0.72, sun.w)));
        }
        vec3 color = base * light;
        vec3 cell = floor(v_world - v_normal * 0.002);
        bool targeted = all(lessThan(abs(cell - target.xyz), vec3(0.1)));
        if (v_material >= 0.0 && target.w >= 0.0 && targeted) {
            vec3 local = fract(v_world);
            vec3 edge = min(local, 1.0 - local) + abs(v_normal);
            float border = min(edge.x, min(edge.y, edge.z));
            if (border < 0.018) color = vec3(1.0, 0.91, 0.57);
            // A progressively denser cracked pattern while holding mine.
            vec3 crack = abs(fract(v_world * 5.0 + sin(v_world.zxy * 13.0) * 0.2) - 0.5);
            if (target.w > 0.0 && min(crack.x + crack.y, crack.y + crack.z) < target.w * 0.18)
                color *= 0.28;
        }
        float fog = smoothstep(34.0, 83.0, length(eye.xyz - v_world));
        if (haze.w > 0.0) fog = 1.0 - exp(-length(eye.xyz - v_world) * 0.17);
        result = vec4(mix(color, haze.rgb, fog), 1.0);
    }
    """;
let sky_vertex = """
    layout(location = 0) out vec2 v_uv;
    void main() {
        vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
        v_uv = p;
        gl_Position = vec4(p * 2.0 - 1.0, 0.9999, 1.0);
    }
    """;
struct Sky { ahead: float4, right: float4, up: float4, info: float4, sun: float4, haze: float4 }
let sky_fragment = """
    layout(location = 0) in vec2 v_uv;
    layout(location = 0) out vec4 result;
    layout(set = 3, binding = 0) uniform Sky {
        vec4 ahead; vec4 right; vec4 up; vec4 info; vec4 sun; vec4 haze;
    };
    void main() {
        vec2 p = v_uv * 2.0 - 1.0;
        vec3 ray = normalize(ahead.xyz + right.xyz * p.x * info.x + up.xyz * p.y);
        vec3 zenith = mix(vec3(0.008, 0.015, 0.045), vec3(0.29, 0.57, 0.79), sun.w);
        vec3 color = mix(haze.rgb, zenith,
                         clamp(ray.y * 1.4, 0.0, 1.0));
        float glow = pow(max(dot(ray, sun.xyz), 0.0), 32.0);
        color += vec3(0.18, 0.14, 0.05) * glow * sun.w;
        if (ray.y > 0.0 && dot(ray, sun.xyz) > 0.9975) color = vec3(1.0, 0.95, 0.72);
        if (ray.y > 0.0 && dot(ray, -sun.xyz) > 0.9985) color = vec3(0.72, 0.79, 0.9);
        // A sparse hash of direction cells makes stars stay fixed as we turn.
        vec3 star_cell = floor(ray * 220.0);
        float star = fract(sin(dot(star_cell, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
        if (ray.y > 0.12 && star > 0.9985) color += vec3(0.65) * (1.0 - sun.w);
        if (ray.y > 0.08) {
            vec2 p = ray.xz * (30.0 / ray.y) + vec2(info.y * 0.22, 0.0);
            vec2 grid = floor(p / 5.0);
            float n = sin(grid.x * 1.7 + sin(grid.y * 2.3)) + cos(grid.y * 1.2);
            vec3 cloud = mix(vec3(0.09, 0.12, 0.20), vec3(0.95, 0.96, 0.92), sun.w);
            if (n > 0.8) color = mix(color, cloud, smoothstep(0.08, 0.3, ray.y));
        }
        if (info.z > 0.0) color = vec3(0.08, 0.28, 0.38);
        result = vec4(color, 1.0);
    }
    """;

// --- a tiny immediate-mode HUD, also drawn with gfx ---------------------------

// A 5 x 7 font is enough for this sample. Each row is a five-bit mask.
// No font file, font rasterizer, or text texture is needed: set bits become
// little rectangles in the same batch as the panels and inventory icons.
fn glyph(c: u8) -> u8[7] {
    match c {
        'A' => [14, 17, 17, 31, 17, 17, 17], 'B' => [30, 17, 17, 30, 17, 17, 30],
        'C' => [14, 17, 16, 16, 16, 17, 14], 'D' => [30, 17, 17, 17, 17, 17, 30],
        'E' => [31, 16, 16, 30, 16, 16, 31], 'F' => [31, 16, 16, 30, 16, 16, 16],
        'G' => [14, 17, 16, 23, 17, 17, 15], 'H' => [17, 17, 17, 31, 17, 17, 17],
        'I' => [14, 4, 4, 4, 4, 4, 14], 'J' => [7, 2, 2, 2, 18, 18, 12],
        'K' => [17, 18, 20, 24, 20, 18, 17], 'L' => [16, 16, 16, 16, 16, 16, 31],
        'M' => [17, 27, 21, 21, 17, 17, 17], 'N' => [17, 25, 21, 19, 17, 17, 17],
        'O' => [14, 17, 17, 17, 17, 17, 14], 'P' => [30, 17, 17, 30, 16, 16, 16],
        'Q' => [14, 17, 17, 17, 21, 18, 13], 'R' => [30, 17, 17, 30, 20, 18, 17],
        'S' => [15, 16, 16, 14, 1, 1, 30], 'T' => [31, 4, 4, 4, 4, 4, 4],
        'U' => [17, 17, 17, 17, 17, 17, 14], 'V' => [17, 17, 17, 17, 17, 10, 4],
        'W' => [17, 17, 17, 21, 21, 21, 10], 'X' => [17, 17, 10, 4, 10, 17, 17],
        'Y' => [17, 17, 10, 4, 4, 4, 4], 'Z' => [31, 1, 2, 4, 8, 16, 31],
        '0' => [14, 17, 19, 21, 25, 17, 14], '1' => [4, 12, 4, 4, 4, 4, 14],
        '2' => [14, 17, 1, 2, 4, 8, 31], '3' => [30, 1, 1, 14, 1, 1, 30],
        '4' => [2, 6, 10, 18, 31, 2, 2], '5' => [31, 16, 16, 30, 1, 1, 30],
        '6' => [14, 16, 16, 30, 17, 17, 14], '7' => [31, 1, 2, 4, 8, 8, 8],
        '8' => [14, 17, 17, 14, 17, 17, 14], '9' => [14, 17, 17, 15, 1, 1, 14],
        '-' => [0, 0, 0, 31, 0, 0, 0], '+' => [0, 4, 4, 31, 4, 4, 0],
        '.' => [0, 0, 0, 0, 0, 12, 12], ':' => [0, 12, 12, 0, 12, 12, 0],
        '/' => [1, 2, 2, 4, 8, 8, 16], '(' => [2, 4, 8, 8, 8, 4, 2],
        ')' => [8, 4, 2, 2, 2, 4, 8], _ => [0; 7],
    }
}
struct HudVertex { pos: float2, uv: float2, color: u8[4] }
let INK:   u8[4] = [235, 237, 223, 255];
let MUTED: u8[4] = [166, 183, 181, 255];
let GOLD:  u8[4] = [250, 209, 116, 255];
let PANEL: u8[4] = [22, 34, 40, 225];
let WHITE: u8[4] = [255, 255, 255, 255];

fn quad(out: HudVertex[>..]&, x: f32, y: f32, w: f32, h: f32, color: u8[4], tile: i64) {
    let a = HudVertex { float2 { x, y }, atlas_uv(tile, 0.0, 0.0), color };
    let b = HudVertex { float2 { x + w, y }, atlas_uv(tile, 1.0, 0.0), color };
    let c = HudVertex { float2 { x + w, y + h }, atlas_uv(tile, 1.0, 1.0), color };
    let d = HudVertex { float2 { x, y + h }, atlas_uv(tile, 0.0, 1.0), color };
    out.append([a, b, c, a, c, d]);
}
fn rect(out: HudVertex[>..]&, x: f32, y: f32, w: f32, h: f32, color: u8[4]) {
    quad(out, x, y, w, h, color, WHITE_TILE);
}
fn text(out: HudVertex[>..]&, x: f32, y: f32, words: const u8[:], color: u8[4], scale: f32) {
    var at = x;
    for c in words {
        let rows = glyph(c);
        for row in 7 {
            for col in 5 {
                if (rows[row] & (1 << (4 - col))) != 0 {
                    rect(out, at + col * scale, y + row * scale, scale, scale, color);
                }
            }
        }
        at += 6.0 * scale;
    }
}
fn centred(out: HudVertex[>..]&, middle: f32, y: f32, words: const u8[:], color: u8[4]) {
    text(out, middle - words.len * 6.0, y, words, color, 2.0);
}
fn hud(out: HudVertex[>..]&, size: float2, hit: Hit, progress: f32,
       crafting: bool, paused: bool, help: bool) {
    rect(out, 18.0, 18.0, 418.0, 99.0, PANEL);
    rect(out, 18.0, 18.0, 4.0, 99.0, GOLD);
    text(out, 34.0, 31.0, "MINI MINECRAFT", GOLD, 2.0);
    text(out, 34.0, 56.0, next_goal(), INK, 1.5);
    let tool = if game.tool == 0 { "HANDS" } else if game.tool == 1 { "WOODEN PICK" } else { "STONE PICK" };
    text(out, 34.0, 79.0, str(tool, "  /  SEED ", game.seed), MUTED, 1.0);
    let phase = if daylight() < 0.2 { "NIGHT - LIGHT YOUR HOME" }
                else if day_time > 450.0 { "DAWN" }
                else if day_time > 270.0 { "DUSK - CRAFT SOME LAMPS" }
                else if day_time < 150.0 { "MORNING" } else { "AFTERNOON" };
    text(out, 34.0, 95.0, phase, MUTED, 1.0);

    if help && !crafting && !paused {
        let x = size.x - 316.0;
        rect(out, x, 18.0, 298.0, 192.0, PANEL);
        text(out, x + 14.0, 31.0, "MAKE YOURSELF AT HOME", GOLD, 1.5);
        let lines: const u8[:][9] = [
            "WASD WALK  /  SPACE JUMP OR SWIM", "SHIFT RUN  /  ARROWS LOOK",
            "CTRL SNEAK - STOPS AT LEDGES",
            "MOUSE LOOK  /  LEFT HOLD MINE", "RIGHT OR E PLACE - HOLD TO BUILD",
            "MIDDLE CLICK PICKS MATERIAL",
            "1-8 OR WHEEL SELECT  /  C CRAFT", "F5 SAVE  /  F9 LOAD  /  F12 PHOTO",
            "ESC PAUSE  /  H HIDE HELP"];
        for i in lines.len { text(out, x + 14.0, 58.0 + i * 16.0, lines[i], INK, 1.0); }
    } else if !crafting && !paused { text(out, size.x - 132.0, 26.0, "H - HELP", INK, 1.5); }

    let bar_x = (size.x - SLOTS * 66.0) * 0.5;
    let bar_y = size.y - 82.0;
    for i in SLOTS {
        let x = bar_x + i * 66.0;
        rect(out, x, bar_y, 62.0, 64.0, if game.selected == i { GOLD } else { PANEL });
        rect(out, x + 3.0, bar_y + 3.0, 56.0, 58.0, PANEL);
        let tile = if i == 7 { 10 } else { tile_for(SLOT_BLOCK[i], 4) };
        let tint: u8[4] = if game.bag[i] == 0 { [105, 110, 113, 255] } else { WHITE };
        quad(out, x + 17.0, bar_y + 8.0, 28.0, 28.0, tint, tile);
        text(out, x + 7.0, bar_y + 8.0, str(i + 1), GOLD, 1.0);
        text(out, x + 7.0, bar_y + 40.0, SLOT_NAME[i], MUTED, 1.0);
        text(out, x + 7.0, bar_y + 51.0, str(game.bag[i]), INK, 1.0);
    }
    centred(out, size.x * 0.5, bar_y - 25.0, SLOT_NAME[game.selected], INK);
    if !crafting && !paused {
        let cx = size.x * 0.5;
        let cy = size.y * 0.5;
        rect(out, cx - 7.0, cy - 2.0, 15.0, 5.0, PANEL);
        rect(out, cx - 2.0, cy - 7.0, 5.0, 15.0, PANEL);
        rect(out, cx - 6.0, cy, 13.0, 1.0, INK);
        rect(out, cx, cy - 6.0, 1.0, 13.0, INK);
        if hit.found {
            let label = block_name(block_at(hit.at));
            text(out, cx - label.len * 3.0, cy + 22.0, label, INK, 1.0);
            if progress > 0.0 {
                rect(out, cx - 40.0, cy + 37.0, 80.0, 5.0, PANEL);
                rect(out, cx - 40.0, cy + 37.0, 80.0 * progress, 5.0, GOLD);
            }
        }
    }
    if message_time > 0.0 {
        let width: f32 = message.len * 9.0 + 28.0;
        rect(out, (size.x - width) * 0.5, bar_y - 65.0, width, 28.0, PANEL);
        text(out, (size.x - width) * 0.5 + 14.0, bar_y - 57.0, message, GOLD, 1.5);
    }
    if crafting {
        let x = (size.x - 504.0) * 0.5;
        let y = (size.y - 300.0) * 0.5;
        rect(out, x, y, 504.0, 300.0, PANEL);
        rect(out, x, y, 504.0, 3.0, GOLD);
        text(out, x + 22.0, y + 20.0, "CRAFTING", GOLD, 2.0);
        text(out, x + 22.0, y + 48.0, "CLICK A RECIPE OR PRESS ITS NUMBER", MUTED, 1.5);
        let titles: const u8[:][4] = ["1  FOUR PLANKS", "2  WOODEN PICK", "3  STONE PICK", "4  FOUR LAMPS"];
        let costs: const u8[:][4] = ["1 WOOD", "5 PLANKS", "3 STONE + 2 PLANKS + WOODEN PICK",
                                      "1 COAL + 1 PLANK"];
        for i in 4 {
            let row_y = y + 78.0 + i * 46.0;
            rect(out, x + 16.0, row_y, 472.0, 40.0, [42, 57, 60, 250]);
            let ready = can_craft(i);
            text(out, x + 28.0, row_y + 7.0, titles[i], if ready { INK } else { MUTED }, 1.5);
            let owned = (i == 1 && game.tool >= 1) || (i == 2 && game.tool >= 2);
            text(out, x + 424.0, row_y + 8.0, if ready { "READY" } else if owned { "OWNED" } else { "NEED" },
                 if ready { GOLD } else { MUTED }, 1.0);
            text(out, x + 28.0, row_y + 26.0, costs[i], MUTED, 1.0);
        }
        text(out, x + 22.0, y + 264.0, "HOLD SHIFT WITH A RECIPE TO CRAFT ALL.", GOLD, 1.0);
        text(out, x + 22.0, y + 280.0, "TOOLS EQUIP AUTOMATICALLY. C OR ESC CLOSES.", MUTED, 1.0);
    } else if paused {
        rect(out, (size.x - 400.0) * 0.5, size.y * 0.5 - 45.0, 400.0, 90.0, PANEL);
        centred(out, size.x * 0.5, size.y * 0.5 - 26.0, "PAUSED", GOLD);
        text(out, size.x * 0.5 - 162.0, size.y * 0.5 + 4.0,
             "CLICK OR ESC TO RESUME. F5 SAVES.", INK, 1.5);
    }
}
let hud_vertex = """
    layout(location = 0) in vec2 a_pos;
    layout(location = 1) in vec2 a_uv;
    layout(location = 2) in vec4 a_color;
    layout(set = 1, binding = 0) uniform Screen { vec4 size; };
    layout(location = 0) out vec2 v_uv;
    layout(location = 1) out vec4 v_color;
    void main() {
        v_uv = a_uv; v_color = a_color;
        gl_Position = vec4(a_pos.x / size.x * 2.0 - 1.0, 1.0 - a_pos.y / size.y * 2.0, 0.0, 1.0);
    }
    """;
let hud_fragment = """
    layout(location = 0) in vec2 v_uv;
    layout(location = 1) in vec4 v_color;
    layout(set = 2, binding = 0) uniform sampler2D atlas;
    layout(location = 0) out vec4 result;
    void main() { result = texture(atlas, v_uv) * v_color; }
    """;

// --- the program: input, simulation, mesh updates, and drawing ---------------

fn main() {
    var seed: u32 = 2026;
    var frames = -1;
    var test = false;
    let argv = args();
    var a = 1;
    while a < argv.len {
        if argv[a] == "--test" { test = true; a++; continue; }
        if a + 1 >= argv.len || (argv[a] != "--seed" && argv[a] != "--frames") {
            write_stderr("usage: mini_minecraft [--seed N] [--frames N] [--test]\n");
            exit(1);
        }
        let n, ok = parse_int(argv[a + 1]);
        if !ok || n < 0 || n > 2147483647 || (argv[a] == "--frames" && n == 0) {
            write_stderr("seed must be 0..2147483647; frames must be 1..2147483647\n");
            exit(1);
        }
        if argv[a] == "--seed" { seed = n as u32; } else { frames = n; }
        a += 2;
    }
    if test {
        gameplay_tests();
        if frames < 0 { return; }
    }
    generate(seed);
    guard gfx::open("Goose: mini Minecraft", 1280, 800, gfx::WINDOW_RESIZABLE) else {
        write_stderr(str("gfx: ", gfx::error(), "\n"));
        return;
    }
    // close releases every remaining GPU object, including chunk buffers.
    defer gfx::close();
    let atlas = make_atlas();
    let sampler = gfx::sampler(gfx::NEAREST, gfx::CLAMP);
    let world_pipeline = gfx::pipeline(embed_shader("vert", world_vertex),
        embed_shader("frag", scene_uniform, world_fragment),
        gfx::PipelineDesc { cull: gfx::CULL_BACK, depth_test: true, depth_write: true });
    let sky_pipeline = gfx::pipeline(embed_shader("vert", sky_vertex), embed_shader("frag", sky_fragment));
    var hud_desc = gfx::PipelineDesc { blend: gfx::BLEND_ALPHA };
    hud_desc.formats[2] = gfx::VERTEX_UBYTE4_NORM;
    let hud_pipeline = gfx::pipeline(embed_shader("vert", hud_vertex),
                                     embed_shader("frag", hud_fragment), hud_desc);
    if sampler.id == 0 || world_pipeline.id == 0 || sky_pipeline.id == 0 || hud_pipeline.id == 0 {
        abort(str("renderer: ", gfx::error()));
    }
    rebuild_dirty();
    var hud_buffer = gfx::Buffer { 0 };
    // This small fixed array sets the buffer's capacity once. Each frame
    // uploads only the live fragments; the GPU buffer is reused throughout.
    let empty_debris: Vertex[MAX_DEBRIS * 6] = [Vertex { .. }; MAX_DEBRIS * 6];
    let debris_buffer = gfx::vertex_buffer(bytes_of(empty_debris));
    if debris_buffer.id == 0 { abort(str("fragment buffer: ", gfx::error())); }
    var crafting = false;
    var paused = !gfx::focused();
    var help = true;
    var drawn = 0;
    var elapsed:     f32 = 0.0;
    var accumulator: f32 = 0.0;
    var progress:    f32 = 0.0;
    var mining_at = cell(-1, -1, -1);
    var place_delay: f32 = 0.0;
    var wait_for_buttons = false;
    let keys: const u8[:][SLOTS] = ["1", "2", "3", "4", "5", "6", "7", "8"];
    if !paused && !gfx::set_mouse_relative(true) { say("MOUSE CAPTURE FAILED - USE ARROW KEYS TO LOOK"); }

    while gfx::frame() {
        let pixels = gfx::screen_size();
        if pixels.x <= 0 || pixels.y <= 0 {
            paused = true;
            crafting = false;
            progress = 0.0;
            accumulator = 0.0;
            gfx::set_mouse_relative(false);
            continue;
        }
        // A logical canvas keeps the HUD legible on high-density screens.
        let scale = max(0.5, min<f32>(pixels.x / 960.0, pixels.y / 600.0));
        let screen = float2 { pixels.x / scale, pixels.y / scale };
        let mouse = gfx::mouse_pos() / float2 { scale, scale };
        let dt: f32 = if frames > 0 { 1.0 / 60.0 } else { min(gfx::delta_time(), 0.05) as f32 };
        message_time = max(0.0, message_time - dt);
        let was_playing = !paused && !crafting;
        let was_crafting = crafting;
        // A loss followed by a gain in the same frame must still pause.
        // gfx clears held input and releases capture on every focus loss.
        var lost_focus = !gfx::focused();
        for event in gfx::events() {
            if event.kind == gfx::EVENT_FOCUS_LOST { lost_focus = true; }
        }
        if lost_focus { paused = true; crafting = false; }
        else {
            if gfx::key_pressed("H") { help = !help; }
            if gfx::key_pressed("Escape") {
                if crafting { crafting = false; } else { paused = !paused; }
            } else if paused && gfx::mouse_pressed(gfx::MOUSE_LEFT) { paused = false; }
            else if gfx::key_pressed("C") && !paused { crafting = !crafting; }
            if gfx::key_pressed("F5") { save_game(); }
            if gfx::key_pressed("F9") { load_game(); progress = 0.0; accumulator = 0.0; }
        }
        let playing = !paused && !crafting;
        if playing != was_playing {
            // The default visible cursor returns in menus. Changing capture
            // also discards stale motion, so reopening the game cannot jump.
            if !gfx::set_mouse_relative(playing) && playing {
                say("MOUSE CAPTURE FAILED - USE ARROW KEYS TO LOOK");
            }
            wait_for_buttons = true;
        }
        // A resume/menu click must be released before it can mine or build.
        if !gfx::mouse_down(gfx::MOUSE_LEFT) && !gfx::mouse_down(gfx::MOUSE_RIGHT) {
            wait_for_buttons = false;
        }

        if crafting && was_crafting {
            let x = (screen.x - 504.0) * 0.5;
            let y = (screen.y - 300.0) * 0.5 + 78.0;
            for i in 4 {
                let row_y = y + i * 46.0;
                let clicked = gfx::mouse_pressed(gfx::MOUSE_LEFT) && mouse.x >= x + 16.0 &&
                    mouse.x < x + 488.0 && mouse.y >= row_y && mouse.y < row_y + 40.0;
                if clicked || gfx::key_pressed(keys[i]) {
                    craft_batches(i, gfx::key_down("Left Shift") || gfx::key_down("Right Shift"));
                }
            }
        }
        if playing && was_playing {
            elapsed += dt;
            advance_time(dt);
            animate_debris(dt);
            for i in SLOTS { if gfx::key_pressed(keys[i]) { game.selected = i as i32; } }
            let wheel = gfx::mouse_wheel();
            if wheel != 0.0 {
                let step = if wheel > 0.0 { -1 } else { 1 };
                game.selected = ((game.selected + step + SLOTS) % SLOTS) as i32;
            }
            if gfx::mouse_relative() {
                let delta = gfx::mouse_delta();
                game.player.yaw += delta.x * 0.003;
                game.player.pitch -= delta.y * 0.003;
            }
            if gfx::key_down("Left") { game.player.yaw -= dt * 1.8; }
            if gfx::key_down("Right") { game.player.yaw += dt * 1.8; }
            if gfx::key_down("Up") { game.player.pitch += dt * 1.5; }
            if gfx::key_down("Down") { game.player.pitch -= dt * 1.5; }
            game.player.pitch = clamp(game.player.pitch, -1.5, 1.5);
            game.player.yaw = (game.player.yaw + PI) % TAU - PI;

            var direction = float2_0;
            if gfx::key_down("W") { direction.y += 1.0; }
            if gfx::key_down("S") { direction.y -= 1.0; }
            if gfx::key_down("D") { direction.x += 1.0; }
            if gfx::key_down("A") { direction.x -= 1.0; }
            accumulator += dt;
            let sneak = gfx::key_down("Left Ctrl") || gfx::key_down("Right Ctrl");
            while accumulator >= STEP {
                walk(direction, gfx::key_down("Space"), gfx::key_down("Left Shift"), sneak);
                accumulator -= STEP;
            }
        } else { accumulator = 0.0; }

        var hit = ray(eye(), forward(), 6.0);
        if playing && was_playing && !wait_for_buttons {
            if gfx::mouse_pressed(gfx::MOUSE_MIDDLE) { pick_material(hit); }
            if hit.found && gfx::mouse_down(gfx::MOUSE_LEFT) {
                if hit.at != mining_at { progress = 0.0; mining_at = hit.at; }
                let seconds = mining_seconds(block_at(hit.at));
                if seconds > 0.0 { progress += dt / seconds; } else { progress = 0.0; }
                if progress >= 1.0 {
                    mine(hit.at);
                    progress = 0.0;
                    hit = ray(eye(), forward(), 6.0);
                }
            } else { progress = 0.0; mining_at = cell(-1, -1, -1); }
            // Edges include a press and release between frames. Held input
            // repeats slowly enough to build a wall without emptying a stack.
            place_delay = max(0.0, place_delay - dt);
            if gfx::key_pressed("E") || gfx::mouse_pressed(gfx::MOUSE_RIGHT) ||
               (place_delay == 0.0 && (gfx::key_down("E") || gfx::mouse_down(gfx::MOUSE_RIGHT))) {
                place(hit);
                place_delay = 0.22;
                hit = ray(eye(), forward(), 6.0);
            }
        } else { progress = 0.0; place_delay = 0.0; }
        rebuild_dirty();

        // The frame's temporary HUD array is freed at this iteration's end.
        // Reuse its GPU buffer until growth needs a larger one.
        var hud_vertices: HudVertex[>..] = [];
        hud(hud_vertices, screen, hit, progress, crafting, paused, help);
        let hud_bytes = bytes_of(hud_vertices);
        if hud_buffer.id == 0 || gfx::buffer_size(hud_buffer) < hud_bytes.len {
            if hud_buffer.id != 0 { gfx::release(hud_buffer); }
            hud_buffer = gfx::buffer(gfx::BUFFER_VERTEX, hud_bytes.len * 2, hud_bytes);
            if hud_buffer.id == 0 { abort(str("HUD buffer: ", gfx::error())); }
        } else if !gfx::update_buffer(hud_buffer, hud_bytes) { abort(str("HUD upload: ", gfx::error())); }

        let ahead = forward();
        let right = normalize(cross(ahead, float3 { 0.0, 1.0, 0.0 }));
        let up = cross(right, ahead);
        let fragments = debris_vertices(right, up);
        if fragments.len > 0 && !gfx::update_buffer(debris_buffer, bytes_of(fragments)) {
            abort(str("fragment upload: ", gfx::error()));
        }
        let aspect = pixels.x as f32 / pixels.y;
        let view = gfx::look_at(eye(), eye() + ahead, float3 { 0.0, 1.0, 0.0 });
        let view_proj = gfx::mul(gfx::perspective(1.15, aspect, 0.05, 150.0), view);
        let underwater = block_at(floor_cell(eye())) == WATER;
        let sky_color = horizon();
        let haze = if underwater { float4 { 0.08, 0.28, 0.38, 1.0 } }
                   else { float4 { sky_color.x, sky_color.y, sky_color.z, 0.0 } };
        let sun_dir = sun_direction();
        let sun = float4 { sun_dir.x, sun_dir.y, sun_dir.z, daylight() };
        let target = if hit.found && !crafting && !paused {
            float4 { hit.at.x, hit.at.y, hit.at.z, progress }
        } else { float4 { 0.0, 0.0, 0.0, -1.0 } };
        let camera = eye();
        let scene = Scene { view_proj, float4 { camera.x, camera.y, camera.z, elapsed },
                            target, lamps, haze, sun };
        let lens = tan(1.15 as f32 * 0.5);
        let sky = Sky {
            float4 { ahead.x / lens, ahead.y / lens, ahead.z / lens, 0.0 },
            float4 { right.x, right.y, right.z, 0.0 },
            float4 { up.x, up.y, up.z, 0.0 },
            float4 { aspect, elapsed, if underwater { 1.0 } else { 0.0 }, 0.0 }, sun, haze };

        gfx::begin_screen(haze);
        gfx::bind(sky_pipeline);
        gfx::uniforms(gfx::FRAGMENT, 0, sky);
        gfx::draw(3);
        gfx::bind(world_pipeline);
        gfx::bind_texture(gfx::FRAGMENT, 0, atlas, sampler);
        gfx::uniforms(gfx::VERTEX, 0, view_proj);
        gfx::uniforms(gfx::FRAGMENT, 0, scene);
        for m in meshes {
            if m.count == 0 { continue; }
            gfx::bind_vertex_buffer(m.vertices);
            gfx::bind_index_buffer(m.indices, 4);
            gfx::draw_indexed(m.count);
        }
        if fragments.len > 0 {
            gfx::bind_vertex_buffer(debris_buffer);
            gfx::draw(fragments.len);
        }
        gfx::bind(hud_pipeline);
        gfx::bind_texture(gfx::FRAGMENT, 0, atlas, sampler);
        gfx::bind_vertex_buffer(hud_buffer);
        gfx::uniforms(gfx::VERTEX, 0, float4 { screen.x, screen.y, 0.0, 0.0 });
        gfx::draw(hud_vertices.len);
        gfx::end_pass();
        if gfx::key_pressed("F12") {
            if gfx::screenshot("mini_minecraft.png") { say("SAVED MINI_MINECRAFT.PNG"); }
            else { say("SCREENSHOT FAILED"); }
        }
        drawn++;
        if drawn == frames { break; }
    }
    if frames > 0 {
        let saved = gfx::screenshot("mini_minecraft.png");
        print("drew ", drawn, " frames; saved mini_minecraft.png: ", saved);
    }
}
