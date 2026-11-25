// Headless block-world state and rules: terrain, physics, mining,
// crafting, saves, and the software-renderer helpers (atlas pixels,
// face culling). No gfx, no main: this file links into a shared
// library for bot control (see mcbot_ffi.goose) and is imported by
// minecraft.goose for rendering. Mesh/GPU upload and the window loop
// stay in minecraft.goose, which drains chunk_dirty via dirty_take.

import std;
import vec;
import math;
import os;

// --- blocks and game state ----------------------------------------------------
let WIDTH = 80;
let HEIGHT = 40;
let DEPTH = 80;
let VOLUME = WIDTH * HEIGHT * DEPTH;
let CHUNK = 16;
let CHUNKS_X = WIDTH / CHUNK;
let CHUNKS_Z = DEPTH / CHUNK;
let SEA = 12;
let SLOTS = 8;
let MAX_LAMPS = 16;
let DAY_LENGTH: f32 = 600.0;

let AIR:     u8 = 0;
let GRASS:   u8 = 1;
let DIRT:    u8 = 2;
let STONE:   u8 = 3;
let SAND:    u8 = 4;
let WOOD:    u8 = 5;
let LEAVES:  u8 = 6;
let PLANKS:  u8 = 7;
let COBBLE:  u8 = 8;
let COAL:    u8 = 9;
let WATER:   u8 = 10;
let BEDROCK: u8 = 11;
let LAMP:    u8 = 12;

// Inventory slots are separate from block IDs: stone drops cobblestone,
// grass drops dirt, and coal is a crafting ingredient rather than a block.
let SLOT_BLOCK: u8[SLOTS]          = [DIRT, COBBLE, WOOD, PLANKS, LEAVES, SAND, LAMP, AIR];
let SLOT_NAME:  const u8[:][SLOTS] =
    ["DIRT", "STONE", "WOOD", "PLANKS", "LEAVES", "SAND", "LAMPS", "COAL"];

struct Cell { x: i64, y: i64, z: i64 }
struct Player {
    feet:     float3,
    velocity: f32,
    yaw:      f32,
    pitch:    f32,
    grounded: bool,
}

// This small, pointer-free record is the save header. The large block grid
// stays in global storage: passing or copying Game never copies the world.
// Transient input and GPU handles are kept outside the saved state.
struct Game {
    version:  u32,
    seed:     u32,
    player:   Player,
    bag:      i32[SLOTS],
    tool:     i32,             // 0: hands, 1: wooden pick, 2: stone pick
    selected: i32,
}
var game:     Game;
var blocks:   u8[VOLUME];
var day_time: f32 = 90.0;       // Morning; zero is sunrise.

// --- sun and clock ------------------------------------------------------------
// Compute lighting once per frame, not once per block. The meshes contain
// only static sky exposure, so a moving sun never needs to rebuild them.
fn sun_direction() -> float3 {
    let angle: f32 = day_time / DAY_LENGTH * TAU;
    normalize(float3 { -cos(angle), sin(angle), 0.3 })
}
fn daylight() -> f32 { clamp(sun_direction().y * 3.0 + 0.35, 0.0, 1.0) }
fn horizon() -> float3 {
    let day = daylight();
    let dusk = 1.0 - abs(day * 2.0 - 1.0);
    float3 { 0.045, 0.065, 0.12 } * f3(1.0 - day) +
        float3 { 0.70, 0.82, 0.87 } * f3(day) + float3 { 0.30, 0.04, 0.0 } * f3(dusk)
}
fn advance_time(dt: f32) { day_time = (day_time + dt) % DAY_LENGTH; }

// --- lamps, messages, debris --------------------------------------------------
var lamps:  float4[MAX_LAMPS];
var lamp_count = 0;
var message:      u8[..100];
var message_time: f32 = 0.0;

// Cosmetic fragments are a fixed pool: breaking another block reuses the
// oldest slots. They never affect collisions, inventory, or saved games.
let MAX_DEBRIS = 48;
struct Debris { pos: float3, velocity: float3, life: f32, tile: i64 }
var debris: Debris[MAX_DEBRIS];
var next_debris = 0;

fn scatter(c: Cell, b: u8) {
    for i in 12 {
        let h = hash(c.x + i, c.y, c.z, game.seed);
        let velocity = float3 { (h & 255) / 64.0 - 2.0, 1.5 + ((h >> 8) & 255) / 128.0,
                                ((h >> 16) & 255) / 64.0 - 2.0 };
        debris[next_debris] = Debris {
            position(c) + f3(0.5) + velocity * f3(0.12), velocity, 0.45 + i * 0.012, tile_for(b, 4) };
        next_debris = (next_debris + 1) % MAX_DEBRIS;
    }
}
fn animate_debris(dt: f32) {
    for i in MAX_DEBRIS {
        if debris[i].life <= 0.0 { continue; }
        debris[i].life -= dt;
        debris[i].velocity.y -= 10.0 * dt;
        debris[i].pos += debris[i].velocity * f3(dt);
    }
}

fn say(text: const u8[:]) {
    message.resize(0);
    message.append(text);
    message_time = 4.0;
}

// --- small grid helpers -------------------------------------------------------
fn f3(n: f32) -> float3 { float3 { n, n, n } }
fn cell(x: i64, y: i64, z: i64) -> Cell { Cell { x, y, z } }
fn floor_cell(p: float3) -> Cell {
    Cell { floor(p.x) as i64, floor(p.y) as i64, floor(p.z) as i64 }
}
fn position(c: Cell) -> float3 { float3 { c.x, c.y, c.z } }
fn inside(c: Cell) -> bool {
    c.x >= 0 && c.x < WIDTH && c.y >= 0 && c.y < HEIGHT && c.z >= 0 && c.z < DEPTH
}
fn index(c: Cell) -> i64 { (c.y * DEPTH + c.z) * WIDTH + c.x }

fn block_at(c: Cell) -> u8 {
    if !inside(c) { return AIR; }
    blocks[index(c)]
}
fn solid(b: u8) -> bool { b != AIR && b != WATER }
fn put(c: Cell, b: u8) {
    if inside(c) { blocks[index(c)] = b; }
}

// --- chunk dirty flags, taken by the renderer ---------------------------------
// The flags live here, not on the GPU meshes: the renderer takes each
// flag once with dirty_take and rebuilds that chunk. edit() marks every
// chunk touched by its one-cell border; most edits still touch one chunk.
var chunk_dirty: u8[CHUNKS_X * CHUNKS_Z];
fn dirty_take(i: i64) -> bool {
    if chunk_dirty[i] != 0 {
        chunk_dirty[i] = 0;
        return true;
    }
    false
}
fn dirty_mark_all() {
    for i in CHUNKS_X * CHUNKS_Z { chunk_dirty[i] = 1; }
}
fn find_lamps() {
    lamps = [float4_0; MAX_LAMPS];
    lamp_count = 0;
    for y in HEIGHT {
        for z in DEPTH {
            for x in WIDTH {
                if block_at(cell(x, y, z)) == LAMP && lamp_count < MAX_LAMPS {
                    lamps[lamp_count] = float4 { x + 0.5, y + 0.5, z + 0.5, 1.0 };
                    lamp_count++;
                }
            }
        }
    }
}

fn edit(c: Cell, b: u8) {
    let old = block_at(c);
    put(c, b);
    // Corner shading samples diagonal neighbours too. Rebuild all chunks
    // touched by a one-cell border; most edits still touch only one chunk.
    for dz in -1..2 {
        for dx in -1..2 {
            let x = c.x + dx;
            let z = c.z + dz;
            if x >= 0 && x < WIDTH && z >= 0 && z < DEPTH {
                chunk_dirty[(z / CHUNK) * CHUNKS_X + x / CHUNK] = 1;
            }
        }
    }
    if old == LAMP || b == LAMP { find_lamps(); }
}

// --- deterministic terrain -----------------------------------------------------
// Unsigned arithmetic wraps. A coordinate hash needs no mutable random
// state, so adding a tree does not change the hills or texture patterns.
fn hash(x: i64, y: i64, z: i64, seed: u32) -> u32 {
    var h = (x as! u32) * 374761393 + (y as! u32) * 668265263;
    h += (z as! u32) * 2246822519 + seed * 3266489917;
    h = (h ^ (h >> 13)) * 1274126177;
    h ^ (h >> 16)
}
fn noise_value(x: i64, z: i64) -> f32 {
    (hash(x, 0, z, game.seed) & 65535) / 65535.0
}
fn noise(x: f32, z: f32) -> f32 {
    let ix = floor(x) as i64;
    let iz = floor(z) as i64;
    let fx = x - ix;
    let fz = z - iz;
    let u = fx * fx * (3.0 - 2.0 * fx);
    let v = fz * fz * (3.0 - 2.0 * fz);
    let a = noise_value(ix, iz) * (1.0 - u) + noise_value(ix + 1, iz) * u;
    let b = noise_value(ix, iz + 1) * (1.0 - u) + noise_value(ix + 1, iz + 1) * u;
    a * (1.0 - v) + b * v
}
fn ground_height(x: i64, z: i64) -> i64 {
    let broad = noise(x / 24.0, z / 24.0);
    let detail = noise(x / 8.0, z / 8.0);
    // A basin guarantees a lake; a broad ridge gives the cave a hillside.
    let lake = max(0.0, 1.0 - sqrt((x - 23.0) * (x - 23.0) +
                                  (z - 28.0) * (z - 28.0)) / 18.0);
    let ridge = max(0.0, 1.0 - abs(x - 58.0) / 15.0);
    let terrain = 13.0 + broad * 7.0 + detail * 3.0 - lake * 11.0 + ridge * 7.0;
    let distance = sqrt((x - 40.0) * (x - 40.0) + (z - 40.0) * (z - 40.0));
    let clearing = clamp((distance - 8.0) / 5.0, 0.0, 1.0);
    floor(19.0 * (1.0 - clearing) + terrain * clearing) as i64
}
fn highest(x: i64, z: i64) -> i64 {
    var y = HEIGHT - 1;
    while y > 0 && !solid(block_at(cell(x, y, z))) { y--; }
    y
}
fn tree(x: i64, z: i64) {
    let base = ground_height(x, z) + 1;
    if block_at(cell(x, base - 1, z)) != GRASS { return; }
    let height = 4 + (hash(x, 1, z, game.seed) % 2) as i64;
    for y in base + 3..base + height + 2 {
        let radius = if y == base + height + 1 { 1 } else { 2 };
        for dz in -radius..radius + 1 {
            for dx in -radius..radius + 1 {
                if abs(dx) == 2 && abs(dz) == 2 { continue; }
                let c = cell(x + dx, y, z + dz);
                if block_at(c) == AIR { put(c, LEAVES); }
            }
        }
    }
    for y in base..base + height { put(cell(x, y, z), WOOD); }
}
fn respawn() {
    // Search dry ground from the centre, without placing the player in a
    // trunk, a leaf canopy, a saved building, or the lake.
    for radius in 0..WIDTH / 2 {
        for z in max(1, 40 - radius)..min(DEPTH - 1, 41 + radius) {
            for x in max(1, 40 - radius)..min(WIDTH - 1, 41 + radius) {
                let y = highest(x, z);
                let b = block_at(cell(x, y, z));
                if (b == GRASS || b == SAND || b == STONE) && y >= SEA && y < HEIGHT - 3 {
                    game.player = Player {
                        feet: float3 { x + 0.5, y + 1.001, z + 0.5 },
                        velocity: 0.0, yaw: -0.4, pitch: -0.12, grounded: false };
                    return;
                }
            }
        }
    }
    game.player = Player { feet: float3 { 40.5, 41.0, 40.5 }, .. };
}
fn generate(seed: u32) {
    game = Game { version: 1, seed: seed, .. };
    day_time = 90.0;
    debris = [Debris { .. }; MAX_DEBRIS];
    message_time = 0.0;
    for i in VOLUME { blocks[i] = AIR; }
    for z in DEPTH {
        for x in WIDTH {
            let top = ground_height(x, z);
            for y in 0..max(top + 1, SEA + 1) {
                var b = STONE;
                if y == 0 { b = BEDROCK; }
                else if y > top { b = WATER; }
                else if y == top { b = if top <= SEA + 1 { SAND } else { GRASS }; }
                else if y >= top - 3 { b = if top <= SEA + 1 { SAND } else { DIRT }; }
                else {
                    // Coarse vein clusters with little ragged edges.
                    let vein = hash(x / 3, y / 3, z / 3, seed) % 13 == 0;
                    if vein && hash(x, y, z, seed) % 4 != 0 { b = COAL; }
                    let cave = sin(x * 0.24) + cos(z * 0.21) + sin(y * 0.55 + x * 0.11);
                    if y > 2 && y < top - 4 && cave > 2.25 { b = AIR; }
                }
                put(cell(x, y, z), b);
            }
        }
    }
    // A walk-in tunnel starts at the clearing and slopes into the ridge.
    // Carving overlapping little spheres is easy to read and modify.
    let entrance = ground_height(46, 40);
    for step in 22 {
        let cx: f32 = 45.0 + step * 0.65;
        let cy: f32 = entrance + 1.3 - step * 0.22;
        let cz: f32 = 40.0 - step * 0.38;
        for y in 2..HEIGHT - 1 {
            for z in 28..44 {
                for x in 43..63 {
                    let d = float3 { x + 0.5 - cx, y + 0.5 - cy, z + 0.5 - cz };
                    if length_sq(d) < 3.2 { put(cell(x, y, z), AIR); }
                }
            }
        }
    }
    for z in 4..DEPTH - 4 {
        for x in 4..WIDTH - 4 {
            let clearing = abs(x - 40) < 11 && abs(z - 40) < 11;
            if !clearing && x % 4 == 0 && z % 4 == 0 && hash(x, 5, z, seed) % 3 == 0 {
                tree(x, z);
            }
        }
    }
    tree(38, 34);           // The first resource is always a few steps away.
    respawn();
    find_lamps();
    dirty_mark_all();
}

// --- walking, swimming, and a grid ray -----------------------------------------
let RADIUS:      f32 = 0.29;
let BODY_HEIGHT: f32 = 1.8;
let EYE_HEIGHT:  f32 = 1.62;
let STEP:        f32 = 1.0 / 120.0;

fn eye() -> float3 { game.player.feet + float3 { 0.0, EYE_HEIGHT, 0.0 } }
fn forward() -> float3 {
    let p = game.player;
    float3 { sin(p.yaw) * cos(p.pitch), sin(p.pitch), -cos(p.yaw) * cos(p.pitch) }
}
fn overlaps(feet: float3, c: Cell) -> bool {
    feet.x + RADIUS > c.x && feet.x - RADIUS < c.x + 1 &&
    feet.y + BODY_HEIGHT > c.y && feet.y < c.y + 1 &&
    feet.z + RADIUS > c.z && feet.z - RADIUS < c.z + 1
}
fn blocked(feet: float3) -> bool {
    // The finite map's edges are walls, while its sky is open.
    if feet.x < RADIUS || feet.z < RADIUS || feet.x > WIDTH - RADIUS ||
       feet.z > DEPTH - RADIUS || feet.y < 1.0 { return true; }
    let lo = floor_cell(feet - float3 { RADIUS, 0.0, RADIUS });
    let hi = floor_cell(feet + float3 { RADIUS, BODY_HEIGHT - 0.001, RADIUS });
    for y in lo.y..hi.y + 1 {
        for z in lo.z..hi.z + 1 {
            for x in lo.x..hi.x + 1 {
                if solid(block_at(cell(x, y, z))) { return true; }
            }
        }
    }
    false
}
fn wet(feet: float3) -> bool {
    block_at(floor_cell(feet + float3 { 0.0, 0.05, 0.0 })) == WATER
}
fn supported(feet: float3) -> bool {
    // Leave a little overlap with the floor when sneaking onto a ledge.
    // Water does not count as support, and only the layer below the feet
    // matters: a nearby wall must not let us walk off a roof.
    let margin: f32 = RADIUS - 0.02;
    let lo = floor_cell(feet - float3 { margin, 0.05, margin });
    let hi = floor_cell(feet + float3 { margin, -0.05, margin });
    for z in lo.z..hi.z + 1 {
        for x in lo.x..hi.x + 1 {
            if solid(block_at(cell(x, lo.y, z))) { return true; }
        }
    }
    false
}
fn move_axis(delta: float3, keep_support: bool = false) -> bool {
    let start = game.player.feet;
    if !blocked(start + delta) && (!keep_support || supported(start + delta)) {
        game.player.feet += delta;
        return false;
    }
    // Find the contact point. The fixed timestep bounds each move to less
    // than a block, and bisection leaves the player just outside the wall.
    var lo: f32 = 0.0;
    var hi: f32 = 1.0;
    for i in 10 {
        let mid = (lo + hi) * 0.5;
        let candidate = start + delta * f3(mid);
        if blocked(candidate) || (keep_support && !supported(candidate)) { hi = mid; }
        else { lo = mid; }
    }
    game.player.feet += delta * f3(lo);
    true
}
fn walk(direction: float2, jump: bool, run: bool, sneak: bool = false) {
    let swimming = wet(game.player.feet);
    let speed: f32 = if swimming { 2.6 } else if sneak { 1.5 } else if run { 6.0 } else { 4.2 };
    let right = float3 { cos(game.player.yaw), 0.0, sin(game.player.yaw) };
    let ahead = float3 { sin(game.player.yaw), 0.0, -cos(game.player.yaw) };
    var input = direction;
    if length_sq(input) > 1.0 { input = normalize(input); }
    let delta = (right * f3(input.x) + ahead * f3(input.y)) * f3(speed * STEP);
    let keep_support = sneak && game.player.grounded && !jump && !swimming;
    move_axis(float3 { delta.x, 0.0, 0.0 }, keep_support);
    move_axis(float3 { 0.0, 0.0, delta.z }, keep_support);
    if swimming {
        game.player.velocity = max(game.player.velocity - 4.0 * STEP, -2.0);
        if jump {
            game.player.velocity = 4.0;
            // A kick near the surface clears a one-block shore. Testing
            // the feet for water keeps this active until we actually exit.
            if block_at(floor_cell(game.player.feet + float3 { 0.0, 1.0, 0.0 })) != WATER {
                game.player.velocity = 8.0;
            }
        }
    } else {
        if jump && game.player.grounded { game.player.velocity = 8.0; }
        game.player.velocity = max(game.player.velocity - 23.0 * STEP, -30.0);
    }
    let hit = move_axis(float3 { 0.0, game.player.velocity * STEP, 0.0 });
    game.player.grounded = hit && game.player.velocity < 0.0;
    if hit { game.player.velocity = 0.0; }
}

struct Hit { found: bool, at: Cell, before: Cell, distance: f32 }
fn ray(origin: float3, direction: float3, reach: f32) -> Hit {
    // DDA: cross exactly one grid plane each step. This neither skips thin
    // targets nor guesses the placement face from a small sampling step.
    var at = floor_cell(origin);
    var before = at;
    let step = Cell { if direction.x >= 0.0 { 1 } else { -1 },
                      if direction.y >= 0.0 { 1 } else { -1 },
                      if direction.z >= 0.0 { 1 } else { -1 } };
    let delta = float3 {
        if abs(direction.x) < 0.00001 { 1.0e8 } else { abs(1.0 / direction.x) },
        if abs(direction.y) < 0.00001 { 1.0e8 } else { abs(1.0 / direction.y) },
        if abs(direction.z) < 0.00001 { 1.0e8 } else { abs(1.0 / direction.z) } };
    var next = float3 {
        (if step.x > 0 { at.x + 1.0 - origin.x } else { origin.x - at.x }) * delta.x,
        (if step.y > 0 { at.y + 1.0 - origin.y } else { origin.y - at.y }) * delta.y,
        (if step.z > 0 { at.z + 1.0 - origin.z } else { origin.z - at.z }) * delta.z };
    var travelled: f32 = 0.0;
    while travelled <= reach {
        if solid(block_at(at)) { return Hit { true, at, before, travelled }; }
        before = at;
        if next.x <= next.y && next.x <= next.z {
            travelled = next.x;
            next.x += delta.x;
            at.x += step.x;
        } else if next.y <= next.z {
            travelled = next.y;
            next.y += delta.y;
            at.y += step.y;
        } else {
            travelled = next.z;
            next.z += delta.z;
            at.z += step.z;
        }
    }
    Hit { found: false, .. }
}

// --- mining, building, and four recipes ----------------------------------------
fn drop_slot(b: u8) -> i64 {
    if b == GRASS || b == DIRT { return 0; }
    if b == STONE || b == COBBLE { return 1; }
    if b == COAL { return 7; }
    for i in SLOTS { if SLOT_BLOCK[i] == b { return i; } }
    -1
}
fn pick_material(hit: Hit) {
    if !hit.found { return; }
    let slot = drop_slot(block_at(hit.at));
    if slot >= 0 && SLOT_BLOCK[slot] != AIR {
        game.selected = slot as i32;
        if game.bag[slot] == 0 { say("MINE SOME OF THIS MATERIAL FIRST"); }
    }
}
fn mining_seconds(b: u8) -> f32 {
    if b == BEDROCK { return 0.0; }
    if b == STONE || b == COBBLE || b == COAL {
        if game.tool == 0 { return 0.0; }
        return if game.tool == 1 { 1.15 } else { 0.45 };
    }
    if b == WOOD { return 1.0; }
    if b == PLANKS { return 0.65; }
    if b == LEAVES || b == LAMP { return 0.18; }
    0.35
}
fn mine(c: Cell) -> bool {
    let b = block_at(c);
    let slot = drop_slot(b);
    if slot < 0 || mining_seconds(b) <= 0.0 { return false; }
    if game.bag[slot] >= 999 { say("THAT STACK IS FULL (999)"); return false; }
    game.bag[slot]++;
    edit(c, AIR);
    scatter(c, b);
    true
}
fn place(hit: Hit) -> bool {
    if !hit.found || hit.at == hit.before || !inside(hit.before) { return false; }
    let slot = game.selected;
    let b = SLOT_BLOCK[slot];
    if b == AIR { say("COAL IS FOR CRAFTING LAMPS"); return false; }
    if game.bag[slot] == 0 { say("MINE OR CRAFT SOME FIRST"); return false; }
    if solid(block_at(hit.before)) || overlaps(game.player.feet, hit.before) { return false; }
    if b == LAMP && lamp_count == MAX_LAMPS {
        say("SIXTEEN LIGHTS MAX - PICK ONE UP FIRST");
        return false;
    }
    edit(hit.before, b);
    game.bag[slot]--;
    true
}
fn can_craft(recipe: i64) -> bool {
    if recipe == 0 { return game.bag[2] >= 1 && game.bag[3] <= 995; }
    if recipe == 1 { return game.tool == 0 && game.bag[3] >= 5; }
    if recipe == 2 { return game.tool == 1 && game.bag[1] >= 3 && game.bag[3] >= 2; }
    if recipe == 3 { return game.bag[7] >= 1 && game.bag[3] >= 1 && game.bag[6] <= 995; }
    false
}
fn craft(recipe: i64) -> bool {
    if !can_craft(recipe) {
        say("NOT ENOUGH MATERIALS, OR UPGRADE ALREADY OWNED");
        return false;
    }
    if recipe == 0 {
        game.bag[2]--;
        game.bag[3] += 4;
        say("MADE FOUR PLANKS");
        return true;
    }
    if recipe == 1 {
        game.bag[3] -= 5;
        game.tool = 1;
        say("WOODEN PICK - NOW YOU CAN MINE STONE");
        return true;
    }
    if recipe == 2 {
        game.bag[1] -= 3;
        game.bag[3] -= 2;
        game.tool = 2;
        say("STONE PICK - FASTER MINING");
        return true;
    }
    if recipe == 3 {
        game.bag[7]--;
        game.bag[3]--;
        game.bag[6] += 4;
        say("MADE FOUR LAMPS - SELECT SLOT 7 TO PLACE");
        return true;
    }
    false
}
fn craft_batches(recipe: i64, all: bool) -> i64 {
    if !craft(recipe) { return 0; }
    var batches = 1;
    // can_craft checks both ingredients and stack capacity. Tools become
    // unavailable once owned, so even "craft all" makes only one upgrade.
    while all && can_craft(recipe) {
        craft(recipe);
        batches++;
    }
    if batches > 1 {
        say(str("MADE ", batches * 4, if recipe == 0 { " PLANKS" } else { " LAMPS" }));
    }
    batches
}

// --- explicit saves ------------------------------------------------------------
fn valid_save(g: const Game&, cells: const u8[:]) -> bool {
    if cells.len != VOLUME { return false; }
    if g.version != 1 || g.tool < 0 || g.tool > 2 || g.selected < 0 || g.selected >= SLOTS {
        return false;
    }
    for n in g.bag { if n < 0 || n > 999 { return false; } }
    var lights = 0;
    for b in cells {
        if b > LAMP { return false; }
        if b == LAMP { lights++; }
    }
    if lights > MAX_LAMPS { return false; }
    let p = g.player;
    // Positive tests reject NaNs as well as out-of-range values.
    if !(p.feet.x >= RADIUS && p.feet.x <= WIDTH - RADIUS &&
         p.feet.z >= RADIUS && p.feet.z <= DEPTH - RADIUS &&
         p.feet.y >= 1.0 && p.feet.y <= HEIGHT + 8.0 &&
         p.yaw >= -100.0 && p.yaw <= 100.0 && abs(p.pitch) <= 1.5 &&
         abs(p.velocity) <= 30.0) { return false; }
    for z in DEPTH {
        for x in WIDTH { if cells[z * WIDTH + x] != BEDROCK { return false; } }
    }
    true
}
fn save_image() -> u8[>..] {
    var image: u8[>..] = [];
    image.append("GSM2");
    to_bytes([game], image);
    image.append(blocks);
    to_bytes([day_time], image);
    image
}
fn restore(image: const u8[:]) -> bool {
    // The header uses Goose's framed serialization; the grid is just bytes
    // of block IDs. Validate both before changing anything in the game.
    let header_size = to_bytes([Game { .. }]).len;
    let grid_end = 4 + header_size + VOLUME;
    let clock_size = to_bytes([day_time]).len;
    if image.len < 4 { return false; }
    let legacy = image[..4] == "GSM1";
    if legacy {
        if image.len != grid_end { return false; }
    } else if image[..4] != "GSM2" || image.len != grid_end + clock_size { return false; }
    var header, ok = from_bytes<Game[>..]>(image[4..4 + header_size]);
    if !ok || header.len != 1 { return false; }
    let saved_blocks = image[4 + header_size..grid_end];
    if !valid_save(header[0], saved_blocks) { return false; }
    // The first version had no clock. Old worlds resume in the morning.
    var saved_time: f32 = 90.0;
    if !legacy {
        let clock, clock_ok = from_bytes<f32[>..]>(image[grid_end..]);
        if !clock_ok || clock.len != 1 || !(clock[0] >= 0.0 && clock[0] < DAY_LENGTH) { return false; }
        saved_time = clock[0];
    }
    game = header[0];
    day_time = saved_time;
    debris = [Debris { .. }; MAX_DEBRIS];
    for i in VOLUME { blocks[i] = saved_blocks[i]; }
    if blocked(game.player.feet) { respawn(); }
    find_lamps();
    dirty_mark_all();
    true
}
fn save_game() {
    let image = save_image();
    if write_file_atomic("mini_minecraft.sav", image) { say("SAVED MINI_MINECRAFT.SAV"); }
    else { say("SAVE FAILED - CHECK THE WORKING DIRECTORY"); }
}
fn load_game() {
    var image: u8[>..] = [];
    if !read_file("mini_minecraft.sav", image) { say("NO READABLE MINI_MINECRAFT.SAV"); return; }
    if !restore(image) { say("SAVE FILE IS DAMAGED OR INCOMPATIBLE"); return; }
    say("WORLD LOADED");
}

// --- a 256 x 16 texture atlas, painted one pixel at a time ----------------------
let TILE_SIZE = 16;
let TILES = 16;
let WHITE_TILE = 14;
let TILE_COLOR: int3[TILES] = [
    int3 { 101, 153, 58 }, int3 { 126, 89, 55 }, int3 { 126, 89, 55 },
    int3 { 129, 132, 130 }, int3 { 220, 204, 150 }, int3 { 106, 76, 43 },
    int3 { 173, 137, 81 }, int3 { 65, 120, 48 }, int3 { 177, 135, 79 },
    int3 { 126, 131, 133 }, int3 { 121, 126, 128 }, int3 { 52, 126, 176 },
    int3 { 61, 64, 74 }, int3 { 244, 198, 94 }, int3 { 255, 255, 255 },
    int3 { 255, 255, 255 }];

fn tile_for(b: u8, face: i64) -> i64 {
    if b == GRASS { return if face == 2 { 0 } else if face == 3 { 2 } else { 1 }; }
    if b == WOOD { return if face == 2 || face == 3 { 6 } else { 5 }; }
    if b == DIRT { return 2; }
    if b == STONE { return 3; }
    if b == SAND { return 4; }
    if b == LEAVES { return 7; }
    if b == PLANKS { return 8; }
    if b == COBBLE { return 9; }
    if b == COAL { return 10; }
    if b == WATER { return 11; }
    if b == BEDROCK { return 12; }
    if b == LAMP { return 13; }
    WHITE_TILE
}

fn pixel(tile: i64, x: i64, y: i64) -> u8[4] {
    var color = TILE_COLOR[tile];
    var grain = (hash(x, tile, y, 71) % 27) as i64 - 13;
    if tile == 1 && y < 3 + (hash(x / 2, 0, 0, 8) % 3) as i64 {
        color = TILE_COLOR[0];
    }
    if tile == 3 { grain += if (x + y * 3) % 11 == 0 { -20 } else { 0 }; }
    if tile == 5 { grain += if (x + (y / 5)) % 4 == 0 { -30 } else { 9 }; }
    if tile == 6 {
        let ring = max(abs(x - 7), abs(y - 7));
        grain += if ring % 3 == 0 { -30 } else { 12 };
    }
    if tile == 7 {
        grain += if hash(x / 2, 0, y / 2, 17) % 3 == 0 { -28 } else { 10 };
    }
    if tile == 8 {
        if y % 4 == 0 || (x + (y / 4) * 7) % 16 == 0 { grain = -42; }
        else { grain += if y % 4 == 1 { 12 } else { 0 }; }
    }
    if tile == 9 {
        let row = y / 5;
        if y % 5 == 0 || (x + row * 3) % 7 == 0 { grain = -45; }
        else if y % 5 == 1 { grain = 18; }
    }
    if tile == 10 && hash(x / 2, 0, y / 2, 9) % 5 == 0 { color = int3 { 32, 34, 39 }; }
    if tile == 11 { grain = if (x + y * 3) % 13 < 2 { 20 } else { 0 }; }
    if tile == 12 { grain *= 2; }
    if tile == 13 {
        if x < 2 || x > 13 || y < 2 || y > 13 { color = int3 { 94, 66, 39 }; }
        else { grain = if x == 7 || y == 7 { 25 } else { 0 }; }
    }
    if tile >= WHITE_TILE { grain = 0; }
    [clamp(color.x + grain, 0, 255) as u8, clamp(color.y + grain, 0, 255) as u8,
     clamp(color.z + grain, 0, 255) as u8, 255]
}

fn atlas_uv(tile: i64, x: f32, y: f32) -> float2 {
    // Sample inside the tile, so the nearest sampler never grabs a pixel
    // from its neighbour, even right at the edge of a face.
    float2 { (tile * TILE_SIZE + 0.5 + x * 15.0) / (TILE_SIZE * TILES),
             (0.5 + y * 15.0) / TILE_SIZE }
}

// --- exposed faces, split into 16 x 40 x 16 chunks ------------------------------
struct Vertex {
    pos:      float3,
    normal:   float3,
    uv:       float2,
    shade:    f32,
    material: f32,
}
let NORMAL: Cell[6] = [Cell { 1, 0, 0 }, Cell { -1, 0, 0 },
                        Cell { 0, 1, 0 }, Cell { 0, -1, 0 },
                        Cell { 0, 0, 1 }, Cell { 0, 0, -1 }];
let ACROSS: Cell[6] = [Cell { 0, 0, -1 }, Cell { 0, 0, 1 },
                        Cell { 1, 0, 0 }, Cell { 1, 0, 0 },
                        Cell { 1, 0, 0 }, Cell { -1, 0, 0 }];
let UP: Cell[6] = [Cell { 0, 1, 0 }, Cell { 0, 1, 0 },
                    Cell { 0, 0, -1 }, Cell { 0, 0, 1 },
                    Cell { 0, 1, 0 }, Cell { 0, 1, 0 }];
let CORNERS: float2[4] = [float2 { -1.0, -1.0 }, float2 { 1.0, -1.0 },
                          float2 { 1.0, 1.0 }, float2 { -1.0, 1.0 }];
var column_top: i64[WIDTH * DEPTH];

fn offset(c: Cell, dir: Cell, amount: i64) -> Cell {
    Cell { c.x + dir.x * amount, c.y + dir.y * amount, c.z + dir.z * amount }
}
fn sky_light(c: Cell) -> f32 {
    if c.x < 0 || c.x >= WIDTH || c.z < 0 || c.z >= DEPTH { return 1.0; }
    if c.y > column_top[c.z * WIDTH + c.x] { return 1.0; }
    0.32
}
fn face_visible(b: u8, neighbour: u8) -> bool {
    if b == WATER { return neighbour == AIR; }
    neighbour == AIR || neighbour == WATER
}
fn add_face(vertices: Vertex[>..]&, indices: u32[>..]&, c: Cell, b: u8, face: i64) {
    let n = NORMAL[face];
    let u = ACROSS[face];
    let v = UP[face];
    let outside = c + n;
    let base = vertices.len as u32;
    for corner in CORNERS {
        let side_u = offset(outside, u, corner.x as i64);
        let side_v = offset(outside, v, corner.y as i64);
        let diagonal = offset(side_u, v, corner.y as i64);
        let a = solid(block_at(side_u));
        let d = solid(block_at(side_v));
        let e = solid(block_at(diagonal));
        // Three neighbouring blocks darken a corner; two touching sides
        // close it completely, even if the diagonal happens to be air.
        var occlusion = 0;
        if a { occlusion++; }
        if d { occlusion++; }
        if e { occlusion++; }
        if a && d { occlusion = 3; }
        let shade = sky_light(outside) * (1.0 - occlusion * 0.16);
        let p = position(c) + f3(0.5) + position(n) * f3(0.5) +
                position(u) * f3(corner.x * 0.5) + position(v) * f3(corner.y * 0.5);
        let uv = atlas_uv(tile_for(b, face), corner.x * 0.5 + 0.5, 0.5 - corner.y * 0.5);
        vertices.push(Vertex { p, position(n), uv, shade, b });
    }
    indices.append([base, base + 1, base + 2, base, base + 2, base + 3]);
}

fn debris_vertices(right: float3, up: float3) -> Vertex[>..] {
    // Camera-facing squares reuse the world's texture atlas and lighting.
    // Only a small patch of each tile is needed for a chip of that material.
    var vertices: Vertex[>..] = [];
    let order: i64[6] = [0, 1, 2, 0, 2, 3];
    let normal = cross(right, up);
    for bit in debris {
        if bit.life <= 0.0 { continue; }
        let size: f32 = 0.065 * min(1.0, bit.life * 8.0);
        for i in order {
            let corner = CORNERS[i];
            let p = bit.pos + right * f3(corner.x * size) + up * f3(corner.y * size);
            let uv = atlas_uv(bit.tile, 0.5 + corner.x * 0.125, 0.5 - corner.y * 0.125);
            vertices.push(Vertex { p, normal, uv, sky_light(floor_cell(p)), -1.0 });
        }
    }
    vertices
}

// --- goal and material text (also shown by the HUD) -----------------------------
fn next_goal() -> const u8[:] {
    if game.tool == 0 && game.bag[2] < 2 && game.bag[3] < 5 { return "GATHER TWO WOOD BLOCKS"; }
    if game.tool == 0 { return "C - MAKE PLANKS AND A WOODEN PICK"; }
    if game.tool == 1 { return "MINE THREE STONE - C TO UPGRADE"; }
    if game.bag[6] == 0 && lamp_count == 0 { return "FIND COAL - C TO CRAFT LAMPS"; }
    "BUILD A CABIN - LIGHT YOUR CAVE"
}
fn block_name(b: u8) -> const u8[:] {
    if b == BEDROCK { return "BEDROCK - UNBREAKABLE"; }
    if (b == STONE || b == COAL || b == COBBLE) && game.tool == 0 { return "NEEDS A PICK - PRESS C"; }
    if b == GRASS { return "GRASS"; }
    if b == COAL { return "COAL ORE"; }
    let slot = drop_slot(b);
    if slot >= 0 { return SLOT_NAME[slot]; }
    ""
}

// --- gameplay checks, with no window -------------------------------------------
fn world_checksum() -> u32 {
    var h: u32 = 2166136261;
    for b in blocks { h = (h ^ b) * 16777619; }
    h
}
fn gameplay_tests() {
    generate(123);
    let checksum = world_checksum();
    assert(!blocked(game.player.feet));
    assert(valid_save(game, blocks));
    assert(daylight() == 1.0 && sun_direction().y > 0.0);
    day_time = 450.0;
    assert(daylight() == 0.0 && sun_direction().y < 0.0);
    day_time = DAY_LENGTH - 0.25;
    advance_time(0.5);
    assert(abs(day_time - 0.25) < 0.001);
    generate(123);
    assert(checksum == world_checksum());
    var counts: i64[13] = [0; 13];
    for b in blocks { counts[b]++; }
    assert(counts[WOOD] > 20 && counts[WATER] > 20 && counts[COAL] > 20);
    generate(321);
    assert(checksum != world_checksum());

    // A small, controlled arena isolates movement and interaction from the
    // terrain generator. All checks call the same functions as the game.
    game = Game { version: 1, seed: 7, .. };
    for i in VOLUME { blocks[i] = AIR; }
    for z in DEPTH {
        for x in WIDTH { put(cell(x, 0, z), BEDROCK); }
    }
    game.player = Player { feet: float3 { 10.5, 1.001, 10.5 }, .. };
    put(cell(10, 2, 7), WOOD);
    let hit = ray(eye(), float3 { 0.0, 0.0, -1.0 }, 6.0);
    assert(hit.found && hit.at == cell(10, 2, 7) && hit.before == cell(10, 2, 8));
    assert(!ray(eye(), float3 { 1.0, 0.0, 0.0 }, 6.0).found);
    assert(mine(hit.at) && game.bag[2] == 1 && block_at(hit.at) == AIR);
    assert(debris[0].life > 0.0);
    animate_debris(1.0);
    for bit in debris { assert(bit.life <= 0.0); }
    assert(!mine(cell(10, 0, 10)));
    assert(craft(0) && game.bag[3] == 4 && game.bag[2] == 0);
    assert(!craft(1));
    game.bag[2] = 1;
    assert(craft(0) && craft(1) && game.tool == 1 && game.bag[3] == 3);
    for x in 3 { put(cell(15 + x, 1, 10), STONE); assert(mine(cell(15 + x, 1, 10))); }
    assert(craft(2) && game.tool == 2 && game.bag[1] == 0 && game.bag[3] == 1);
    put(cell(15, 1, 10), COAL);
    assert(mine(cell(15, 1, 10)) && craft(3) && game.bag[6] == 4);
    game.selected = 6;
    assert(place(hit) && block_at(hit.before) == LAMP && lamp_count == 1);
    game.selected = 0;
    pick_material(Hit { true, hit.before, hit.at, 1.0 });
    assert(game.selected == 6 && game.bag[6] == 3);
    assert(!place(hit));                // Cannot place twice in the same cell.
    let self_hit = Hit { true, cell(10, 1, 9), cell(10, 1, 10), 1.0 };
    assert(!place(self_hit));               // Cannot trap the player in a block.
    assert(mine(hit.before) && lamp_count == 0);
    for i in 120 { walk(float2_0, false, false); }
    assert(game.player.grounded && abs(game.player.feet.y - 1.0) < 0.005);
    var peak: f32 = 0.0;
    for i in 180 {
        walk(float2_0, i == 0, false);
        peak = max(peak, game.player.feet.y);
    }
    assert(peak > 2.1 && game.player.grounded);
    for y in 1..5 { put(cell(11, y, 10), STONE); }
    for i in 120 { walk(float2 { 1.0, 0.0 }, false, true); }
    assert(game.player.feet.x < 10.711 && !blocked(game.player.feet));
    assert(blocked(float3 { 0.0, 1.0, 2.0 }));

    // A low ceiling stops a jump; swimming can climb a one-block shore.
    put(cell(10, 3, 10), STONE);
    for i in 40 { walk(float2_0, i == 0, false); }
    assert(game.player.feet.y < 1.201 && !blocked(game.player.feet));
    game.player = Player { feet: float3 { 30.5, 1.0, 30.5 }, .. };
    for y in 1..4 {
        for x in 29..32 { put(cell(x, y, 30), WATER); }
        put(cell(32, y, 30), SAND);
    }
    put(cell(32, 4, 30), SAND);
    for i in 240 { walk(float2 { 1.0, 0.0 }, true, false); }
    assert(game.player.feet.x > 32.5 && !blocked(game.player.feet));
    game.player = Player { feet: float3 { 30.5, 1.0, 30.5 }, .. };
    for i in 240 { walk(float2 { 1.0, 0.0 }, true, false, true); }
    assert(game.player.feet.x > 32.5 && !blocked(game.player.feet));

    // Sneaking holds every edge and corner of a one-block platform, even
    // if run is held too. Jumping or releasing sneak still lets us leave.
    put(cell(60, 3, 60), STONE);
    let directions: float2[8] = [
        float2 { 1.0, 0.0 }, float2 { -1.0, 0.0 },
        float2 { 0.0, 1.0 }, float2 { 0.0, -1.0 },
        float2 { 1.0, 1.0 }, float2 { -1.0, 1.0 },
        float2 { 1.0, -1.0 }, float2 { -1.0, -1.0 }];
    for direction in directions {
        game.player = Player { feet: float3 { 60.5, 4.001, 60.5 }, grounded: true, .. };
        for i in 240 { walk(direction, false, true, true); }
        assert(game.player.feet.y > 3.999 && game.player.grounded && supported(game.player.feet));
    }
    for i in 120 { walk(float2 { -1.0, -1.0 }, false, false); }
    assert(game.player.feet.y < 3.0);
    game.player = Player { feet: float3 { 60.5, 4.001, 60.5 }, grounded: true, .. };
    for i in 120 { walk(float2 { 1.0, 0.0 }, i == 0, false, true); }
    assert(game.player.feet.x > 61.3 && game.player.feet.y < 3.95);
    game.player = Player { feet: float3 { 60.5, 4.001, 60.5 }, grounded: true, .. };
    put(cell(60, 3, 60), AIR);
    for i in 120 { walk(float2_0, false, false, true); }
    assert(game.player.feet.y < 1.01);       // Mining the floor still makes us fall.

    // Bulk crafting consumes only complete recipes, respects stack space,
    // and buys a permanent tool once. Ordinary crafting still makes one batch.
    let saved_inventory = game.bag;
    let saved_tool = game.tool;
    game.bag[2] = 3;
    game.bag[3] = 0;
    assert(craft_batches(0, false) == 1 && game.bag[2] == 2 && game.bag[3] == 4);
    assert(craft_batches(0, true) == 2 && game.bag[2] == 0 && game.bag[3] == 12);
    game.bag[2] = 3;
    game.bag[3] = 994;
    assert(craft_batches(0, true) == 1 && game.bag[2] == 2 && game.bag[3] == 998);
    assert(craft_batches(0, true) == 0 && game.bag[2] == 2);
    game.bag[7] = 3;
    game.bag[3] = 2;
    game.bag[6] = 0;
    assert(craft_batches(3, true) == 2 && game.bag[7] == 1 && game.bag[3] == 0 && game.bag[6] == 8);
    game.tool = 0;
    game.bag[3] = 10;
    assert(craft_batches(1, true) == 1 && game.tool == 1 && game.bag[3] == 5);
    assert(craft_batches(1, true) == 0 && game.bag[3] == 5);
    game.bag[1] = 6;
    assert(craft_batches(2, true) == 1 && game.tool == 2 && game.bag[1] == 3 && game.bag[3] == 3);
    game.bag = saved_inventory;
    game.tool = saved_tool;

    // Out-of-range reach, negative directions, and chunk-border edits.
    put(cell(30, 8, 30), STONE);
    assert(!ray(float3 { 20.5, 8.5, 30.5 }, float3 { 1.0, 0.0, 0.0 }, 6.0).found);
    let back = ray(float3 { 33.5, 8.5, 30.5 }, float3 { -1.0, 0.0, 0.0 }, 6.0);
    assert(back.found && back.before == cell(31, 8, 30));
    for i in CHUNKS_X * CHUNKS_Z { dirty_take(i); }
    edit(cell(15, 8, 15), PLANKS);
    assert(dirty_take(0) && dirty_take(1) && dirty_take(CHUNKS_X) && dirty_take(CHUNKS_X + 1));

    game.selected = 6;
    game.bag[6] = 20;
    for i in MAX_LAMPS { edit(cell(i + 1, 2, 1), LAMP); }
    assert(lamp_count == MAX_LAMPS && !place(back));
    assert(game.bag[6] == 20);
    game.bag[2] = 999;
    put(cell(20, 2, 20), WOOD);
    assert(!mine(cell(20, 2, 20)) && block_at(cell(20, 2, 20)) == WOOD);

    day_time = 450.0;
    var image = save_image();
    let saved_checksum = world_checksum();
    let saved_bag = game.bag;
    blocks[0] = AIR;
    game.bag[0] = 123;
    day_time = 90.0;
    assert(restore(image) && valid_save(game, blocks));
    assert(world_checksum() == saved_checksum && game.bag == saved_bag);
    assert(day_time == 450.0);
    // Non-finite/out-of-range clocks cannot replace a good world.
    day_time = -1.0;
    let bad_clock = save_image();
    day_time = 450.0;
    assert(!restore(bad_clock) && day_time == 450.0);
    let grid_start = 4 + to_bytes([Game { .. }]).len;
    var legacy: u8[>..] = [];
    legacy.append(image[..grid_start + VOLUME]);
    legacy[3] = '1';
    assert(restore(legacy) && day_time == 90.0);
    assert(world_checksum() == saved_checksum && game.bag == saved_bag);
    assert(!restore(image[..image.len - 1]));
    assert(!restore(image[..2]));
    image[0] = 'X';
    assert(!restore(image) && world_checksum() == saved_checksum);
    image[0] = 'G';
    image[grid_start] = AIR;
    assert(!restore(image));
    game.selected = 100;
    assert(!valid_save(game, blocks));
    print("mini minecraft: terrain, ray, mining, crafting, placement, movement, daylight and saves passed");
}
