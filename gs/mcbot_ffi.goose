// Headless bot control over mcworld.goose: thin exported wrappers, no gfx,
// no main. The host calls goose_init once on one thread and drives every
// export from that thread; heap-touching exports are not thread-safe.
// All slices are caller-owned ({data, len}) and never kept. String results
// ride bot_msg (clear/append/return) and stay valid until the next call
// that writes bot_msg. Mining progress is bot_mine_progress, written only
// by bot_mine_ticks and bot_reset.

import std;
import vec;
import math;
import mcworld;

// Packed, order-exact shapes: the host reads the generated header's packed
// layout, so field order here is the ABI (cf. export_abi.md section 1).
struct BotCell { x: i64, y: i64, z: i64 }
struct BotHit { found: u8, ax: i64, ay: i64, az: i64, bx: i64, by: i64, bz: i64, distance: f32 }
struct BotPoseOut { feet_x: f32, feet_y: f32, feet_z: f32, yaw: f32, pitch: f32, vel: f32, grounded: u8 }

var bot_mine_progress: f32 = 0.0;
var bot_msg: u8[>..] = [];

fn fill_pose(out: BotPoseOut&) {
    out.feet_x = game.player.feet.x;
    out.feet_y = game.player.feet.y;
    out.feet_z = game.player.feet.z;
    out.yaw = game.player.yaw;
    out.pitch = game.player.pitch;
    out.vel = game.player.velocity;
    out.grounded = 0;
    if game.player.grounded { out.grounded = 1; }
}
fn fill_hit(out: BotHit&, hit: Hit) {
    out.found = 0;
    if hit.found { out.found = 1; }
    out.ax = hit.at.x;
    out.ay = hit.at.y;
    out.az = hit.at.z;
    out.bx = hit.before.x;
    out.by = hit.before.y;
    out.bz = hit.before.z;
    out.distance = hit.distance;
}
fn store_le32(out: u8[:], at: i64, v: i64) {
    out[at] = (v & 255) as u8;
    out[at + 1] = ((v >> 8) & 255) as u8;
    out[at + 2] = ((v >> 16) & 255) as u8;
    out[at + 3] = ((v >> 24) & 255) as u8;
}

export fn bot_version() -> u32 { return game.version; }

export fn bot_walk_step(dx: f32, dz: f32, jump: bool, run: bool, sneak: bool, ticks: i64) {
    let dir = float2 { dx, dz };
    for i in ticks { walk(dir, jump, run, sneak); }
}

export fn bot_look(dx: f32, dy: f32, out: BotPoseOut&) {
    // Same verbs as the window loop's mouse look, without the mouse.
    game.player.yaw += dx * 0.003;
    game.player.pitch -= dy * 0.003;
    game.player.pitch = clamp(game.player.pitch, -1.5, 1.5);
    game.player.yaw = (game.player.yaw + PI) % TAU - PI;
    fill_pose(out);
}

export fn bot_ray(reach: f32, out: BotHit&) {
    fill_hit(out, ray(eye(), forward(), reach));
}

export fn bot_mine_ticks(n: i64, out: BotHit&) -> u8 {
    // Hold mine for n frame-steps (1/60 each) against the faced block.
    // Progress carries across calls; mine one target at a time. Returns 2
    // when a block broke, 1 while working, 0 with no mineable target.
    let hit = ray(eye(), forward(), 6.0);
    if !hit.found {
        fill_hit(out, hit);
        return 0;
    }
    let seconds = mining_seconds(block_at(hit.at));
    if seconds <= 0.0 {
        fill_hit(out, hit);
        return 0;
    }
    bot_mine_progress += n * (1.0 / 60.0) / seconds;
    if bot_mine_progress < 1.0 {
        fill_hit(out, hit);
        return 1;
    }
    bot_mine_progress = 0.0;
    if mine(hit.at) {
        fill_hit(out, ray(eye(), forward(), 6.0));
        return 2;
    }
    fill_hit(out, hit);
    return 0;
}

export fn bot_place_once(out: BotHit&) -> u8 {
    var hit = ray(eye(), forward(), 6.0);
    if place(hit) {
        hit = ray(eye(), forward(), 6.0);
        fill_hit(out, hit);
        return 1;
    }
    fill_hit(out, hit);
    return 0;
}

export fn bot_pick() {
    pick_material(ray(eye(), forward(), 6.0));
}

export fn bot_select(slot: i64) -> u8 {
    if slot >= 0 && slot < SLOTS {
        game.selected = slot as i32;
        return 1;
    }
    return 0;
}

export fn bot_craft(recipe: i64, all: bool) -> i64 {
    return craft_batches(recipe, all);
}

export fn bot_reset(seed: u32) {
    generate(seed);
    bot_mine_progress = 0.0;
    bot_msg.clear();
}

export fn bot_advance(dt: f32) {
    advance_time(dt);
}

export fn bot_pose(out: BotPoseOut&) {
    fill_pose(out);
}

export fn bot_status(bag: i32[:], rest: u8[:]) -> u8 {
    // bag: 8 hotbar counts. rest (16 bytes): tool, selected, day millis,
    // lamp count, each little-endian i32/u32. Lengths are checked first.
    if bag.len != SLOTS || rest.len != 16 {
        return 0;
    }
    for i in SLOTS { bag[i] = game.bag[i]; }
    store_le32(rest, 0, game.tool);
    store_le32(rest, 4, game.selected);
    store_le32(rest, 8, (day_time * 1000.0) as i64);
    store_le32(rest, 12, lamp_count);
    return 1;
}

export fn bot_get_block(c: BotCell&) -> u8 {
    return block_at(cell(c.x, c.y, c.z));
}

export fn bot_scan_window(lo: BotCell&, hi: BotCell&, out: u8[:]) -> i64 {
    // X fastest, then Z, then Y. Returns the count written, or -1 when out
    // is too small (nothing is written then).
    let nx = hi.x - lo.x + 1;
    let ny = hi.y - lo.y + 1;
    let nz = hi.z - lo.z + 1;
    if nx <= 0 || ny <= 0 || nz <= 0 {
        return 0;
    }
    let total = nx * ny * nz;
    if out.len < total {
        return -1;
    }
    var i = 0;
    for y in lo.y..hi.y + 1 {
        for z in lo.z..hi.z + 1 {
            for x in lo.x..hi.x + 1 {
                out[i] = block_at(cell(x, y, z));
                i++;
            }
        }
    }
    return total;
}

export fn bot_checksum() -> u32 {
    return world_checksum();
}

export fn bot_save_len() -> i64 {
    let image = save_image();
    return image.len;
}

export fn bot_save_write(out: u8[:]) -> i64 {
    let image = save_image();
    if out.len < image.len {
        return -1;
    }
    for i in image.len { out[i] = image[i]; }
    return image.len;
}

export fn bot_restore(image: const u8[:]) -> u8 {
    if restore(image) {
        return 1;
    }
    return 0;
}

export fn bot_next_goal() -> const u8[:] {
    bot_msg.clear();
    bot_msg.append(next_goal());
    return bot_msg;
}

export fn bot_block_name(b: u8) -> const u8[:] {
    bot_msg.clear();
    bot_msg.append(block_name(b));
    return bot_msg;
}

export fn bot_day_time() -> f32 {
    return day_time;
}
