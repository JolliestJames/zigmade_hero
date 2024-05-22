//
// TODO:
//
// ARCHITECTURE EXPLORATION
//
// - Z
//   - Need to make a solid concept of ground levels so the camera can
//     be freely placed in Z and have multiple ground levels in one sim
//     region
//   - Concept of ground in the collision loop so it can handle collisions
//     coming onto and off of stairwells
//   - Make sure flying things can go over low walls
//   - Figure out how you go up and down and how is this rendered?
//     "Frinstances"
//     z_fudge
// - Collision detection?
//   - Fix sword collisions
//   - Clean up predicate proliferation. Can we make a nice clean
//     set of flags/rules so that it's easy to understand how things work
//     in terms of special handling. This may involve making the iteration
//     handle everything instead of handling overlap outside and so on.
//   - Transient collision rules! Clear based on flag.
//     - Allow non-transient rules to override transient ones
//     - Entry/exit?
//   - What's the plan for robustness/shape definition?
//   - Implement reprojection to handle interpenetration
//   - "Things pushing other things"
// - Implement multiple sim regions per frame
//   - Per-entity clocking
//   - Sim region merging? Multiple players?
//   - Simple zoomed-out view for testing?
//
// - Debug code
//   - Fonts
//   - Logging
//   - Diagramming
//   - (Just enough GUI) Switches/sliders/etc.
//   - Draw tile chunks so we can verify that things are aligned/in the
//     chunks we want them to be in/etc.
//
// - Asset streaming
//
// - Audio
//   - Sound effect triggers
//   - Ambience sounds
//   - Music
//
// - Metagame/save game?
//   - How do you enter "save slot"?
//   - Persistent unlocks/etc.
//   - Do we allow saved games? Probably, just only for "pausing"
//   * Continuous save for crash recovery?
// - Rudimentary world gen (no quality, just "what sorts of things" we do
//   - Placement of background objects
//   - Connectivity?
//   - Non-overlapping?
//   - Map display
//     - Magnets - how they work?
// - AI
//   - Rudimentary monster behavior example
//   * Pathfinding
//   - AI "storage"
//
// * Animation, probably should lead into rendering
//   - Skeletal animation
//   - Particle systems
//
// PRODUCTION
// - Rendering
// - Game
//   - Entity system
//   - World generation
//

const std = @import("std");
const assert = std.debug.assert;
const rotl = std.math.rotl;
const platform = @import("zigmade_platform");
const world = @import("zigmade_world.zig");
const math = @import("zigmade_math.zig");
const sim = @import("zigmade_sim_region.zig");
const ety = @import("zigmade_entity.zig");
const intrinsics = @import("zigmade_intrinsics.zig");
const random = @import("zigmade_random.zig");
const INTERNAL = @import("builtin").mode == std.builtin.Mode.Debug;

const lossyCast = std.math.lossyCast;

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const Rectangle3 = math.Rectangle3;
const Entity = sim.Entity;
const SimRegion = sim.SimRegion;
const EntityType = sim.EntityType;
const MoveSpec = sim.MoveSpec;
const EntityCollisionVolume = sim.EntityCollisionVolume;
const EntityCollisionVolumeGroup = sim.EntityCollisionVolumeGroup;
const World = world.World;
const WorldPosition = world.WorldPosition;

const HeroBitmaps = struct {
    head: Bitmap,
    cape: Bitmap,
    torso: Bitmap,
    alignment: Vec2,
};

pub const LowEntity = struct {
    // TODO: It's kind of busted that pos can be invalid here
    // and we can store whether they would be invalid in the flags
    // Can we do something better?
    sim: Entity = .{},
    p: WorldPosition = .{},
};

const EntityVisiblePiece = struct {
    bitmap: ?*Bitmap = null,
    offset: Vec2,
    offset_z: f32,
    entity_zc: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    dim: Vec2,
};

// TODO: This is dumb, this should just be part of
// the renderer pushbuffer. Add correction of coordinates
// in there and be done with it
const EntityVisiblePieceGroup = struct {
    piece_count: u32 = 0,
    pieces: [32]EntityVisiblePiece,
    game_state: *GameState,
};

const AddLowEntityResult = struct {
    low_index: u32,
    low: *LowEntity,
};

const ControlledHero = struct {
    entity_index: u32 = 0,
    ddp: Vec2 = Vec2.splat(0),
    d_sword: Vec2 = Vec2.splat(0),
    dz: f32 = 0,
};

pub const PairwiseCollisionRule = struct {
    can_collide: bool,
    storage_index_a: u32,
    storage_index_b: u32,
    next_in_hash: ?*PairwiseCollisionRule,
};

pub const GameState = struct {
    world: ?*World = null,
    world_arena: MemoryArena,
    // TODO: Should we allow split-screen?
    camera_entity_index: u32,
    camera_p: WorldPosition,
    controlled_heroes: [5]ControlledHero,
    low_entity_count: u32 = 0,
    // TODO: Change name to StoredEntity
    low_entities: [100000]LowEntity,
    grass: [2]Bitmap,
    stone: [4]Bitmap,
    tuft: [3]Bitmap,
    backdrop: Bitmap,
    shadow: Bitmap,
    hero_bitmaps: [4]HeroBitmaps,
    tree: Bitmap,
    sword: Bitmap,
    stairwell: Bitmap,
    meters_to_pixels: f32,
    // TODO: Must be power of two
    collision_rule_hash: [256]?*PairwiseCollisionRule,
    first_free_collision_rule: ?*PairwiseCollisionRule,
    null_collision: *EntityCollisionVolumeGroup,
    sword_collision: *EntityCollisionVolumeGroup,
    stair_collision: *EntityCollisionVolumeGroup,
    player_collision: *EntityCollisionVolumeGroup,
    familiar_collision: *EntityCollisionVolumeGroup,
    monster_collision: *EntityCollisionVolumeGroup,
    wall_collision: *EntityCollisionVolumeGroup,
    standard_room_collision: *EntityCollisionVolumeGroup,
    ground_buffer_p: WorldPosition,
    ground_buffer: Bitmap,
};

pub const MemoryArena = struct {
    size: u32,
    base: [*]u8,
    used: u32,
};

const Bitmap = struct {
    width: i32,
    height: i32,
    pitch: i32,
    memory: [*]void,
};

const BitmapHeader = packed struct {
    file_type: u16,
    file_size: u32,
    reserved_1: u16,
    reserved_2: u16,
    bitmap_offset: u32,
    size: u32,
    width: i32,
    height: i32,
    planes: u16,
    bits_per_pixel: u16,
    compression: u32,
    size_of_bitmap: u32,
    horz_resolution: i32,
    vert_resolution: i32,
    colors_used: u32,
    colors_important: u32,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
};

pub fn invalidCodePath() void {
    std.debug.print("Invalid code path\n", .{});
    assert(false);
}

fn gameOutputSound(
    sound_buffer: *platform.GameSoundBuffer,
    game_state: *GameState,
) !void {
    _ = game_state;
    const tone_volume: i16 = 3_000;
    _ = tone_volume;
    const wave_period = @divTrunc(
        @as(i32, @intCast(sound_buffer.samples_per_second)),
        400,
    );
    _ = wave_period;
    var sample_out = sound_buffer.samples;

    for (0..@intCast(sound_buffer.sample_count)) |i| {
        //var sine_value = @sin(game_state.t_sine);
        //var sample_value = @as(i16, @intFromFloat(
        //    sine_value * @as(
        //        f16,
        //        @floatFromInt(tone_volume),
        //    ),
        //));

        const sample_value: i16 = 0;
        sample_out[2 * i] = sample_value;
        sample_out[2 * i + 1] = sample_value;

        //game_state.t_sine +=
        //    2.0 *
        //    std.math.pi *
        //    1.0 /
        //    @as(f32, @floatFromInt(wave_period));

        //if (game_state.t_sine > 2.0 * std.math.pi) {
        //    game_state.t_sine -= 2.0 * std.math.pi;
        //}
    }
}

fn drawRectangle(
    buffer: *const Bitmap,
    min: Vec2,
    max: Vec2,
    r: f32,
    g: f32,
    b: f32,
) void {
    var min_x: i32 = @intFromFloat(@round(min.x()));
    var min_y: i32 = @intFromFloat(@round(min.y()));
    var max_x: i32 = @intFromFloat(@round(max.x()));
    var max_y: i32 = @intFromFloat(@round(max.y()));

    if (min_x < 0) min_x = 0;
    if (min_y < 0) min_y = 0;
    if (max_x > buffer.width) max_x = buffer.width;
    if (max_y > buffer.height) max_y = buffer.height;
    if (min_x > max_x) max_x = min_x;
    if (min_y > max_y) max_y = min_y;

    const color: u32 =
        (@as(u32, (@intFromFloat(@round(r * 255.0)))) << 16) |
        (@as(u32, (@intFromFloat(@round(g * 255.0)))) << 8) |
        (@as(u32, (@intFromFloat(@round(b * 255.0)))) << 0);

    var row: [*]u8 = @as([*]u8, @alignCast(@ptrCast(buffer.memory))) +
        (@as(u32, @intCast(min_x)) *
        @as(u32, @intCast(platform.BITMAP_BYTES_PER_PIXEL))) +
        @as(u32, @bitCast(min_y *% buffer.pitch));

    for (@intCast(min_y)..@intCast(max_y)) |_| {
        var pixel: [*]u32 = @alignCast(@ptrCast(row));

        for (@intCast(min_x)..@intCast(max_x)) |_| {
            pixel[0] = color;
            pixel += 1;
        }

        row += @as(u32, @intCast(buffer.pitch));
    }
}

fn drawBitmap(
    buffer: *const Bitmap,
    bitmap: *Bitmap,
    real_x: f32,
    real_y: f32,
    c_alpha: f32,
) void {
    var min_x: i32 = @intFromFloat(@round(real_x));
    var min_y: i32 = @intFromFloat(@round(real_y));
    var max_x: i32 = min_x + bitmap.width;
    var max_y: i32 = min_y + bitmap.height;
    //var max_x: i32 = @intFromFloat(@round(real_x + @as(f32, @floatFromInt(bitmap.width))));
    //var max_y: i32 = @intFromFloat(@round(real_y + @as(f32, @floatFromInt(bitmap.height))));

    var source_offset_x: i32 = 0;
    if (min_x < 0) {
        source_offset_x = -min_x;
        min_x = 0;
    }

    var source_offset_y: i32 = 0;
    if (min_y < 0) {
        source_offset_y = -min_y;
        min_y = 0;
    }

    if (max_x > buffer.width) max_x = @intCast(buffer.width);
    if (max_y > buffer.height) max_y = @intCast(buffer.height);
    if (min_x > max_x) max_x = min_x;
    if (min_y > max_y) max_y = min_y;

    var source_row: [*]u8 = undefined;
    const bitmap_offset = source_offset_y * bitmap.pitch +
        platform.BITMAP_BYTES_PER_PIXEL * source_offset_x;

    if (bitmap_offset > 0) {
        source_row = @as([*]u8, @ptrCast(bitmap.memory)) +
            @as(usize, @intCast(bitmap_offset));
    } else {
        source_row = @as([*]u8, @ptrCast(bitmap.memory)) -
            @as(usize, @intCast(-bitmap_offset));
    }

    var dest_row: [*]u8 = @as([*]u8, @alignCast(@ptrCast(buffer.memory))) +
        (@as(u32, @intCast(min_x)) *
        @as(u32, @intCast(platform.BITMAP_BYTES_PER_PIXEL))) +
        @as(u32, @bitCast(min_y *% buffer.pitch));

    for (@intCast(min_y)..@intCast(max_y)) |_| {
        var dest: [*]u32 = @alignCast(@ptrCast(dest_row));
        var source: [*]align(@alignOf(u8)) u32 = @alignCast(@ptrCast(source_row));

        for (@intCast(min_x)..@intCast(max_x)) |_| {
            const sa: f32 = @floatFromInt((source[0] >> 24) & 0xFF);
            const rsa = sa / 255 * c_alpha;
            const sr: f32 = c_alpha * @as(f32, @floatFromInt((source[0] >> 16) & 0xFF));
            const sg: f32 = c_alpha * @as(f32, @floatFromInt((source[0] >> 8) & 0xFF));
            const sb: f32 = c_alpha * @as(f32, @floatFromInt((source[0] >> 0) & 0xFF));

            const da: f32 = @floatFromInt((dest[0] >> 24) & 0xFF);
            const dr: f32 = @floatFromInt((dest[0] >> 16) & 0xFF);
            const dg: f32 = @floatFromInt((dest[0] >> 8) & 0xFF);
            const db: f32 = @floatFromInt((dest[0] >> 0) & 0xFF);
            const rda = da / 255;

            const inv_rsa: f32 = 1 - rsa;
            // TODO: Check this for math errors
            const a = 255 * (rsa + rda - rsa * rda);
            const r = inv_rsa * dr + sr;
            const g = inv_rsa * dg + sg;
            const b = inv_rsa * db + sb;

            dest[0] = (lossyCast(u32, a + 0.5) << 24) |
                (lossyCast(u32, r + 0.5) << 16) |
                (lossyCast(u32, g + 0.5) << 8) |
                (lossyCast(u32, b + 0.5) << 0);

            dest += 1;
            source += 1;
        }

        dest_row += @as(usize, @intCast(buffer.pitch));

        if (bitmap.pitch > 0) {
            source_row += @as(usize, @intCast(bitmap.pitch));
        } else {
            source_row -= @as(usize, @intCast(-bitmap.pitch));
        }
    }
}

fn debugLoadBmp(
    thread: *platform.ThreadContext,
    readEntireFile: platform.debugPlatformReadEntireFile,
    file_name: [*:0]const u8,
) Bitmap {
    var result: Bitmap = undefined;

    const read_result = readEntireFile(thread, file_name);

    if (read_result.size != 0) {
        const header: *BitmapHeader = @alignCast(@ptrCast(read_result.contents));
        const pixels = @as([*]void, @ptrCast(read_result.contents)) + header.bitmap_offset;
        result.memory = pixels;
        result.width = @intCast(header.width);
        result.height = @intCast(header.height);

        assert(header.compression == 3);

        // NOTE: If using this generically, remember that BMP
        // files can go in either direction and height will be
        // negative for top-down
        // Also, there can be compression, etc. this is not complete
        // BMP loading code
        //
        // NOTE: Byte order memory is determined by the header itself,
        // so we have to read out the masks and convert pixels ourselves

        var source_dest: [*]align(@alignOf(u8)) u32 = @ptrCast(pixels);

        const red_mask = header.red_mask;
        const green_mask = header.green_mask;
        const blue_mask = header.blue_mask;
        const alpha_mask = ~(red_mask | green_mask | blue_mask);

        const red_scan = intrinsics.findLeastSigSetBit(red_mask);
        const green_scan = intrinsics.findLeastSigSetBit(green_mask);
        const blue_scan = intrinsics.findLeastSigSetBit(blue_mask);
        const alpha_scan = intrinsics.findLeastSigSetBit(alpha_mask);

        const red_shift_down = @as(u5, @intCast(red_scan.index));
        const green_shift_down = @as(u5, @intCast(green_scan.index));
        const blue_shift_down = @as(u5, @intCast(blue_scan.index));
        const alpha_shift_down = @as(u5, @intCast(alpha_scan.index));

        assert(red_scan.found);
        assert(green_scan.found);
        assert(blue_scan.found);
        assert(alpha_scan.found);

        for (0..@intCast(header.height)) |_| {
            for (0..@intCast(header.width)) |_| {
                const c = source_dest[0];

                var r: f32 = @floatFromInt((c & red_mask) >> red_shift_down);
                var g: f32 = @floatFromInt((c & green_mask) >> green_shift_down);
                var b: f32 = @floatFromInt((c & blue_mask) >> blue_shift_down);
                const a: f32 = @floatFromInt((c & alpha_mask) >> alpha_shift_down);
                const an = a / 255;

                r = r * an;
                g = g * an;
                b = b * an;

                source_dest[0] = (lossyCast(u32, a + 0.5) << 24) |
                    (lossyCast(u32, r + 0.5) << 16) |
                    (lossyCast(u32, g + 0.5) << 8) |
                    (lossyCast(u32, b + 0.5) << 0);

                source_dest += 1;
            }
        }
    }

    result.pitch = -result.width * platform.BITMAP_BYTES_PER_PIXEL;
    result.memory = @ptrCast(
        @as([*]u8, @ptrCast(result.memory)) +
            @as(usize, @intCast(-result.pitch * (result.height - 1))),
    );

    return result;
}

inline fn initializeArena(
    arena: *MemoryArena,
    size: u32,
    base: [*]void,
) void {
    arena.size = size;
    arena.base = @as([*]u8, @ptrCast(base));
    arena.used = 0;
}

inline fn pushSize(
    arena: *MemoryArena,
    size: u32,
) [*]u8 {
    assert((arena.used + size) <= arena.size);
    const result = arena.base + arena.used;
    arena.used += size;
    return result;
}

pub inline fn pushStruct(
    arena: *MemoryArena,
    comptime T: type,
) *T {
    const result = pushSize(arena, @sizeOf(T));
    return @as(*T, @alignCast(@ptrCast(result)));
}

pub inline fn pushArray(
    arena: *MemoryArena,
    count: u32,
    comptime T: type,
) [*]T {
    const result = pushSize(arena, count * @sizeOf(T));
    return @as([*]T, @alignCast(@ptrCast(result)));
}

inline fn zeroSize(size: u32, ptr: [*]void) void {
    // TODO: Check this for performance

    var byte: [*]u8 = @ptrCast(ptr);
    var index: usize = size;

    while (index > 0) : (index -= 1) {
        byte[0] = 0;
        byte += 1;
    }
}

pub inline fn zeroStruct(
    comptime T: type,
    ptr: *T,
) void {
    zeroSize(@sizeOf(T), @ptrCast(ptr));
}

pub inline fn getLowEntity(
    game_state: *GameState,
    index: u32,
) ?*LowEntity {
    var result: ?*LowEntity = null;

    if (index > 0 and index < game_state.low_entities.len) {
        result = &game_state.low_entities[index];
    }

    return result;
}

fn addLowEntity(
    game_state: *GameState,
    t: EntityType,
    p: *const WorldPosition,
) AddLowEntityResult {
    assert(game_state.low_entity_count < game_state.low_entities.len);

    const entity_index = game_state.low_entity_count;
    game_state.low_entity_count += 1;

    const low = &game_state.low_entities[entity_index];
    low.* = .{};
    low.sim.type = t;
    low.sim.collision = game_state.null_collision;
    low.p = world.nullPosition();

    world.changeEntityLocation(
        &game_state.world_arena,
        game_state.world,
        entity_index,
        low,
        p,
    );

    const result = AddLowEntityResult{
        .low = low,
        .low_index = entity_index,
    };

    // TODO: Do we need a begin/end paradigm for adding
    // entities so that they can be brought into the high set
    // when they are added and are in the camera region?

    return result;
}

fn addGroundedEntity(
    game_state: *GameState,
    t: EntityType,
    p: *WorldPosition,
    collision: *EntityCollisionVolumeGroup,
) AddLowEntityResult {
    var result: AddLowEntityResult = undefined;

    var entity = addLowEntity(game_state, t, p);
    entity.low.sim.collision = collision;
    result = entity;

    return result;
}

fn addStandardRoom(
    game_state: *GameState,
    abs_tile_x: i32,
    abs_tile_y: i32,
    abs_tile_z: i32,
) AddLowEntityResult {
    var pos = world.chunkPosFromTilePos(
        game_state.world.?,
        abs_tile_x,
        abs_tile_y,
        abs_tile_z,
        Vec3.splat(0),
    );

    var entity = addGroundedEntity(
        game_state,
        .space,
        &pos,
        game_state.standard_room_collision,
    );

    entity.low.sim.flags.traversable = true;

    return entity;
}

fn addWall(
    game_state: *GameState,
    abs_tile_x: i32,
    abs_tile_y: i32,
    abs_tile_z: i32,
) AddLowEntityResult {
    var pos = world.chunkPosFromTilePos(
        game_state.world.?,
        abs_tile_x,
        abs_tile_y,
        abs_tile_z,
        Vec3.splat(0),
    );

    var entity = addGroundedEntity(
        game_state,
        .wall,
        &pos,
        game_state.wall_collision,
    );

    entity.low.sim.flags.collides = true;

    return entity;
}

fn addStair(
    game_state: *GameState,
    abs_tile_x: i32,
    abs_tile_y: i32,
    abs_tile_z: i32,
) AddLowEntityResult {
    const game_world = game_state.world.?;

    var pos = world.chunkPosFromTilePos(
        game_world,
        abs_tile_x,
        abs_tile_y,
        abs_tile_z,
        Vec3.splat(0),
    );

    const entity = addGroundedEntity(
        game_state,
        .stairwell,
        &pos,
        game_state.stair_collision,
    );

    entity.low.sim.flags.collides = true;
    entity.low.sim.walkable_dim = entity.low.sim.collision.total_volume.dim.xy();
    entity.low.sim.walkable_height = game_world.tile_depth_in_meters;

    return entity;
}

fn initHitPoints(low: *LowEntity, count: u32) void {
    assert(count < low.sim.hit_points.len);
    low.sim.hit_point_max = count;

    for (0..low.sim.hit_point_max) |index| {
        var hit_point = &low.sim.hit_points[index];
        hit_point.flags = 0;
        hit_point.filled_amount = sim.HIT_POINT_SUB_COUNT;
    }
}

fn addPlayer(game_state: *GameState) AddLowEntityResult {
    var p = game_state.camera_p;
    const entity = addGroundedEntity(
        game_state,
        .hero,
        &p,
        game_state.player_collision,
    );
    entity.low.sim.flags.collides = true;
    entity.low.sim.flags.movable = true;

    initHitPoints(entity.low, 3);

    const sword = addSword(game_state);
    entity.low.sim.sword.index = sword.low_index;

    if (game_state.camera_entity_index == 0) {
        game_state.camera_entity_index = entity.low_index;
    }

    return entity;
}

fn addMonster(
    game_state: *GameState,
    abs_tile_x: i32,
    abs_tile_y: i32,
    abs_tile_z: i32,
) AddLowEntityResult {
    const game_world = game_state.world.?;

    var pos = world.chunkPosFromTilePos(
        game_world,
        abs_tile_x,
        abs_tile_y,
        abs_tile_z,
        Vec3.splat(0),
    );

    const entity = addGroundedEntity(
        game_state,
        .monster,
        &pos,
        game_state.monster_collision,
    );
    entity.low.sim.flags.collides = true;
    entity.low.sim.flags.movable = true;

    initHitPoints(entity.low, 3);

    return entity;
}

fn addSword(game_state: *GameState) AddLowEntityResult {
    const entity = addLowEntity(game_state, .sword, &world.nullPosition());

    entity.low.sim.collision = game_state.sword_collision;
    entity.low.sim.flags.movable = true;

    return entity;
}

fn addFamiliar(
    game_state: *GameState,
    abs_tile_x: i32,
    abs_tile_y: i32,
    abs_tile_z: i32,
) AddLowEntityResult {
    const game_world = game_state.world.?;

    var pos = world.chunkPosFromTilePos(
        game_world,
        abs_tile_x,
        abs_tile_y,
        abs_tile_z,
        Vec3.splat(0),
    );

    var entity = addGroundedEntity(
        game_state,
        .familiar,
        &pos,
        game_state.familiar_collision,
    );
    entity.low.sim.flags.collides = true;
    entity.low.sim.flags.movable = true;

    return entity;
}

fn pushPiece(
    group: *EntityVisiblePieceGroup,
    bitmap: ?*Bitmap,
    offset: Vec2,
    offset_z: f32,
    alignment: Vec2,
    dim: Vec2,
    color: Vec4,
    entity_zc: f32,
) void {
    assert(group.piece_count < group.pieces.len);

    var piece = &group.pieces[group.piece_count];
    group.piece_count += 1;
    piece.bitmap = bitmap;

    piece.offset = Vec2.sub(
        &Vec2.scale(
            &Vec2.init(offset.x(), -offset.y()),
            group.game_state.meters_to_pixels,
        ),
        &alignment,
    );

    piece.offset_z = offset_z;
    piece.entity_zc = entity_zc;
    piece.r = color.r();
    piece.g = color.g();
    piece.b = color.b();
    piece.a = color.a();
    piece.dim = dim;
}

fn pushBitmap(
    group: *EntityVisiblePieceGroup,
    bitmap: *Bitmap,
    offset: Vec2,
    offset_z: f32,
    alignment: Vec2,
    alpha: f32,
    entity_zc: f32,
) void {
    pushPiece(
        group,
        bitmap,
        offset,
        offset_z,
        alignment,
        Vec2.splat(0),
        Vec4.init(1, 1, 1, alpha),
        entity_zc,
    );
}

fn pushRect(
    group: *EntityVisiblePieceGroup,
    offset: Vec2,
    offset_z: f32,
    dim: Vec2,
    color: Vec4,
    entity_zc: f32,
) void {
    pushPiece(group, null, offset, offset_z, Vec2.splat(0), dim, color, entity_zc);
}

fn pushRectOutline(
    group: *EntityVisiblePieceGroup,
    offset: Vec2,
    offset_z: f32,
    dim: Vec2,
    color: Vec4,
    entity_zc: f32,
) void {
    const thickness = 0.1;

    // NOTE: Top and bottom
    pushPiece(
        group,
        null,
        Vec2.sub(&offset, &Vec2.init(0, 0.5 * dim.y())),
        offset_z,
        Vec2.splat(0),
        Vec2.init(dim.x(), thickness),
        color,
        entity_zc,
    );

    pushPiece(
        group,
        null,
        Vec2.add(&offset, &Vec2.init(0, 0.5 * dim.y())),
        offset_z,
        Vec2.splat(0),
        Vec2.init(dim.x(), thickness),
        color,
        entity_zc,
    );

    // NOTE: Left and right
    pushPiece(
        group,
        null,
        Vec2.sub(&offset, &Vec2.init(0.5 * dim.x(), 0)),
        offset_z,
        Vec2.splat(0),
        Vec2.init(thickness, dim.y()),
        color,
        entity_zc,
    );

    pushPiece(
        group,
        null,
        Vec2.add(&offset, &Vec2.init(0.5 * dim.x(), 0)),
        offset_z,
        Vec2.splat(0),
        Vec2.init(thickness, dim.y()),
        color,
        entity_zc,
    );
}

fn drawHitPoints(
    entity: *Entity,
    piece_group: *EntityVisiblePieceGroup,
) void {
    if (entity.hit_point_max >= 1) {
        const health_dim = Vec2.splat(0.2);
        const spacing_x = 1.5 * health_dim.x();
        var hit_p = Vec2.init(
            -0.5 * @as(f32, @floatFromInt(entity.hit_point_max - 1)) * spacing_x,
            -0.25,
        );

        const d_hit_p = Vec2.init(spacing_x, 0);

        for (0..entity.hit_point_max) |index| {
            const hit_point = entity.hit_points[index];
            var color = Vec4.init(1, 0, 0, 1);

            if (hit_point.filled_amount == 0) {
                color.v[0] = 0.2;
                color.v[1] = 0.2;
                color.v[2] = 0.2;
            }

            pushRect(piece_group, hit_p, 0, health_dim, color, 0);
            hit_p = Vec2.add(&hit_p, &d_hit_p);
        }
    }
}

fn clearCollisionRulesFor(game_state: *GameState, storage_index: u32) void {
    // TODO: Need to make a better data structure that allows removal
    // of collision rules without searching the entire table
    //
    // NOTE: One way to make removal easy would be to always
    // add both orders of pairs of sotrage indices to the hash
    // so no matter which position the entity is in it can be found
    // When doing first removal pass, remember the top of the free
    // list and when finished, do a pass through on all new
    // entries to the free list to remove the reverse of those
    // pairs
    //
    for (0..game_state.collision_rule_hash.len) |bucket| {
        var maybe_rule = &game_state.collision_rule_hash[bucket];

        while (maybe_rule.*) |rule| {
            if (rule.storage_index_a == storage_index or
                rule.storage_index_b == storage_index)
            {
                const removed = rule;
                maybe_rule.* = rule.next_in_hash;
                removed.next_in_hash = game_state.first_free_collision_rule;
                game_state.first_free_collision_rule = removed;
            } else {
                maybe_rule = &rule.next_in_hash;
            }
        }
    }
}

pub fn addCollisionRule(
    game_state: *GameState,
    storage_index_a: u32,
    storage_index_b: u32,
    can_collide: bool,
) void {
    var a = storage_index_a;
    var b = storage_index_b;

    // TODO: Collapse this with canCollide
    if (a > b) {
        const temp = a;
        a = b;
        b = temp;
    }

    // TODO: BETTER HASH FUNCTION
    var maybe_found: ?*PairwiseCollisionRule = null;
    const bucket = a & (game_state.collision_rule_hash.len - 1);
    var maybe_rule = game_state.collision_rule_hash[bucket];

    while (maybe_rule) |rule| : (maybe_rule = rule.next_in_hash) {
        if (rule.storage_index_a == a and
            rule.storage_index_b == b)
        {
            maybe_found = rule;
            break;
        }
    }

    if (maybe_found == null) {
        maybe_found = game_state.first_free_collision_rule;

        if (maybe_found) |found| {
            game_state.first_free_collision_rule = found.next_in_hash;
        } else {
            maybe_found = pushStruct(&game_state.world_arena, PairwiseCollisionRule);
        }

        if (maybe_found) |found| {
            found.next_in_hash = game_state.collision_rule_hash[bucket];
            maybe_found = found;
            game_state.collision_rule_hash[bucket] = found;
        }
    }

    if (maybe_found) |found| {
        found.storage_index_a = a;
        found.storage_index_b = b;
        found.can_collide = can_collide;
    }
}

fn makeSimpleGroundedCollision(
    game_state: *GameState,
    dim_x: f32,
    dim_y: f32,
    dim_z: f32,
) *EntityCollisionVolumeGroup {
    // TODO: Do not use world_arena, change to using fundamental_types arena, etc.
    var group = pushStruct(&game_state.world_arena, EntityCollisionVolumeGroup);

    group.volume_count = 1;

    group.volumes = pushArray(
        &game_state.world_arena,
        group.volume_count,
        EntityCollisionVolume,
    );

    group.total_volume.offset_p = Vec3.init(0, 0, 0.5 * dim_z);
    group.total_volume.dim = Vec3.init(dim_x, dim_y, dim_z);
    group.volumes.?[0] = group.total_volume;

    return group;
}

fn makeNullCollision(game_state: *GameState) *EntityCollisionVolumeGroup {
    // TODO: Do not use world_arena, change to using fundamental_types arena, etc.
    var group = pushStruct(&game_state.world_arena, EntityCollisionVolumeGroup);

    group.volume_count = 0;
    group.volumes = null;
    group.total_volume.offset_p = Vec3.splat(0);
    // TODO: Should this be negative?
    group.total_volume.dim = Vec3.splat(0);

    return group;
}

fn drawGroundChunk(
    game_state: *GameState,
    buffer: *const Bitmap,
    chunk_p: *WorldPosition,
) void {
    // TODO: Maybe make random number generation more systemic
    // TODO: Look into wang hashing or some other spatial seed
    // generation thing
    var series = random.seed(
        @intCast(139 * chunk_p.chunk_x +
            593 * chunk_p.chunk_y +
            329 * chunk_p.chunk_z),
    );

    const width: f32 = @floatFromInt(buffer.width);
    const height: f32 = @floatFromInt(buffer.height);

    for (0..1000) |_| {
        var stamp: *Bitmap = undefined;

        if (random.choice(&series, 2) > 0) {
            stamp = &game_state.grass[random.choice(&series, game_state.grass.len)];
        } else {
            stamp = &game_state.stone[random.choice(&series, game_state.stone.len)];
        }

        const offset = Vec2.init(
            width * random.unilateral(&series),
            height * random.unilateral(&series),
        );

        const bitmap_center = Vec2.scale(
            &Vec2.fromInt(stamp.width, stamp.height),
            0.5,
        );

        var p = Vec2.sub(&offset, &bitmap_center);

        drawBitmap(buffer, stamp, p.x(), p.y(), 1);
    }

    for (0..1000) |_| {
        const stamp = &game_state.tuft[random.choice(&series, game_state.tuft.len)];

        const offset = Vec2.init(
            width * random.unilateral(&series),
            height * random.unilateral(&series),
        );

        const bitmap_center = Vec2.scale(
            &Vec2.fromInt(stamp.width, stamp.height),
            0.5,
        );

        var p = Vec2.sub(&offset, &bitmap_center);

        drawBitmap(buffer, stamp, p.x(), p.y(), 1);
    }
}

fn makeEmptyBitmap(arena: *MemoryArena, width: i32, height: i32) Bitmap {
    var result: Bitmap = undefined;

    result.width = width;
    result.height = height;
    result.pitch = result.width * platform.BITMAP_BYTES_PER_PIXEL;
    const total_bitmap_size: u32 = @intCast(width * height * platform.BITMAP_BYTES_PER_PIXEL);
    result.memory = @ptrCast(pushSize(arena, total_bitmap_size));
    zeroSize(total_bitmap_size, result.memory);

    return result;
}

// GAME NEEDS FOUR THINGS
// - timing
// - controller/keyboard input
// - bitmap buffer
// - sound buffer
pub export fn updateAndRender(
    thread: *platform.ThreadContext,
    memory: *platform.GameMemory,
    input: *platform.GameInput,
    buffer: *platform.GameOffscreenBuffer,
) void {
    assert(@sizeOf(@TypeOf(input.controllers[0].buttons.map)) ==
        @sizeOf(platform.GameButtonState) * input.controllers[0].buttons.array.len);
    assert(@sizeOf(GameState) <= memory.permanent_storage_size);

    var game_state: *GameState = @alignCast(@ptrCast(memory.permanent_storage));

    if (!memory.is_initialized) {
        const tiles_per_width = 17;
        const tiles_per_height = 9;

        // TODO: Can we just use Zig's own arena allocator?
        // TODO: Let's start partitioning our memory space
        initializeArena(
            &game_state.world_arena,
            memory.permanent_storage_size - @sizeOf(GameState),
            memory.permanent_storage + @sizeOf(GameState),
        );

        // NOTE: Reserve entity slot 0 as the null entity
        _ = addLowEntity(game_state, .none, &world.nullPosition());

        game_state.world = pushStruct(&game_state.world_arena, World);
        const game_world = game_state.world.?;
        world.initializeWorld(game_world, 1.4, 3.0);

        const tile_side_in_pixels: i32 = 60;
        game_state.meters_to_pixels =
            @as(f32, @floatFromInt(tile_side_in_pixels)) /
            game_world.tile_side_in_meters;

        game_state.null_collision = makeNullCollision(game_state);
        game_state.sword_collision = makeSimpleGroundedCollision(game_state, 1, 0.5, 0.1);

        game_state.stair_collision = makeSimpleGroundedCollision(
            game_state,
            game_world.tile_side_in_meters,
            2 * game_world.tile_side_in_meters,
            1.1 * game_world.tile_depth_in_meters,
        );

        game_state.player_collision = makeSimpleGroundedCollision(game_state, 1, 0.5, 1.2);
        game_state.monster_collision = makeSimpleGroundedCollision(game_state, 1, 0.5, 0.5);
        game_state.familiar_collision = makeSimpleGroundedCollision(game_state, 1, 0.5, 0.5);

        game_state.wall_collision = makeSimpleGroundedCollision(
            game_state,
            game_world.tile_side_in_meters,
            game_world.tile_side_in_meters,
            game_world.tile_depth_in_meters,
        );

        game_state.standard_room_collision = makeSimpleGroundedCollision(
            game_state,
            tiles_per_width * game_world.tile_side_in_meters,
            tiles_per_height * game_world.tile_side_in_meters,
            0.9 * game_world.tile_depth_in_meters,
        );

        game_state.grass[0] =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test2/grass00.bmp");
        game_state.grass[1] =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test2/grass01.bmp");

        game_state.stone[0] =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test2/ground00.bmp");
        game_state.stone[1] =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test2/ground01.bmp");
        game_state.stone[2] =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test2/ground02.bmp");
        game_state.stone[3] =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test2/ground03.bmp");

        game_state.tuft[0] =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test2/tuft00.bmp");
        game_state.tuft[1] =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test2/tuft01.bmp");
        game_state.tuft[2] =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test2/tuft02.bmp");

        game_state.backdrop =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_background.bmp");
        game_state.shadow =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_hero_shadow.bmp");
        game_state.tree =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test2/tree00.bmp");
        game_state.stairwell =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test2/rock02.bmp");
        game_state.sword =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test2/rock03.bmp");

        var bitmaps = &game_state.hero_bitmaps;
        bitmaps[0].head =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_hero_right_head.bmp");
        bitmaps[0].cape =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_hero_right_cape.bmp");
        bitmaps[0].torso =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_hero_right_torso.bmp");
        bitmaps[0].alignment = .{ .v = .{ 72, 182 } };

        bitmaps[1].head =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_hero_back_head.bmp");
        bitmaps[1].cape =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_hero_back_cape.bmp");
        bitmaps[1].torso =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_hero_back_torso.bmp");
        bitmaps[1].alignment = .{ .v = .{ 72, 182 } };

        bitmaps[2].head =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_hero_left_head.bmp");
        bitmaps[2].cape =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_hero_left_cape.bmp");
        bitmaps[2].torso =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_hero_left_torso.bmp");
        bitmaps[2].alignment = .{ .v = .{ 72, 182 } };

        bitmaps[3].head =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_hero_front_head.bmp");
        bitmaps[3].cape =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_hero_front_cape.bmp");
        bitmaps[3].torso =
            debugLoadBmp(thread, memory.debugPlatformReadEntireFile, "data/test/test_hero_front_torso.bmp");
        bitmaps[3].alignment = .{ .v = .{ 72, 182 } };

        var series = random.seed(0);

        const screen_base_x: i32 = 0;
        const screen_base_y: i32 = 0;
        const screen_base_z: i32 = 0;
        var screen_x: i32 = screen_base_x;
        var screen_y: i32 = screen_base_y;
        var abs_tile_z: i32 = screen_base_z;

        // TODO: Replace with real world generation
        var door_left = false;
        var door_right = false;
        var door_top = false;
        var door_bottom = false;
        var door_up = false;
        var door_down = false;

        for (0..2000) |_| {
            var door_direction: usize = undefined;

            door_direction = random.choice(&series, 2);
            //door_direction = random.choice(
            //    &series,
            //    if (door_up or door_down) 2 else 3,
            //);

            var created_z_door = false;

            if (door_direction == 2) {
                created_z_door = true;

                if (abs_tile_z == screen_base_z) {
                    door_up = true;
                } else {
                    door_down = true;
                }
            } else if (door_direction == 1) {
                door_right = true;
            } else {
                door_top = true;
            }

            _ = addStandardRoom(
                game_state,
                screen_x * tiles_per_width + tiles_per_width / 2,
                screen_y * tiles_per_height + tiles_per_height / 2,
                abs_tile_z,
            );

            for (0..tiles_per_height) |tile_y| {
                for (0..tiles_per_width) |tile_x| {
                    const abs_tile_x = screen_x * tiles_per_width +
                        @as(i32, @intCast(tile_x));
                    const abs_tile_y = screen_y * tiles_per_height +
                        @as(i32, @intCast(tile_y));

                    var should_be_door = false;

                    if (tile_x == 0 and (!door_left or (tile_y != tiles_per_height / 2))) {
                        should_be_door = true;
                    }

                    if (tile_x == (tiles_per_width - 1) and
                        (!door_right or (tile_y != tiles_per_height / 2)))
                    {
                        should_be_door = true;
                    }

                    if (tile_y == 0 and (!door_bottom or (tile_x != tiles_per_width / 2))) {
                        should_be_door = true;
                    }

                    if (tile_y == (tiles_per_height - 1) and
                        (!door_top or tile_x != (tiles_per_width / 2)))
                    {
                        should_be_door = true;
                    }

                    if (should_be_door) {
                        _ = addWall(game_state, abs_tile_x, abs_tile_y, abs_tile_z);
                    } else if (created_z_door) {
                        if (tile_x == 10 and tile_y == 5) {
                            _ = addStair(
                                game_state,
                                abs_tile_x,
                                abs_tile_y,
                                if (door_down) abs_tile_z - 1 else abs_tile_z,
                            );
                        }
                    }
                }
            }

            door_left = door_right;
            door_bottom = door_top;

            if (created_z_door) {
                door_down = !door_down;
                door_up = !door_up;
            } else {
                door_up = false;
                door_down = false;
            }

            door_right = false;
            door_top = false;

            if (door_direction == 2) {
                if (abs_tile_z == screen_base_z)
                    abs_tile_z = screen_base_z + 1
                else
                    abs_tile_z = screen_base_z;
            } else if (door_direction == 1) {
                screen_x += 1;
            } else {
                screen_y += 1;
            }
        }

        //while (game_state.low_entity_count < game_state.low_entities.len - 16) {
        //    const coordinate: u32 = @intCast(1024 + game_state.low_entity_count);
        //    _ = addWall(game_state, coordinate, coordinate, coordinate);
        //}

        const camera_tile_x = screen_base_x * tiles_per_width + 17 / 2;
        const camera_tile_y = screen_base_y * tiles_per_height + 9 / 2;
        const camera_tile_z = screen_base_z;

        const new_camera_p = world.chunkPosFromTilePos(
            game_world,
            camera_tile_x,
            camera_tile_y,
            camera_tile_z,
            Vec3.splat(0),
        );

        game_state.camera_p = new_camera_p;

        _ = addMonster(
            game_state,
            camera_tile_x - 3,
            camera_tile_y + 2,
            camera_tile_z,
        );

        for (0..1) |_| {
            const familiar_offset_x = random.i32Between(&series, -7, 7);
            const familiar_offset_y = random.i32Between(&series, -3, -1);

            if (familiar_offset_x != 0 or familiar_offset_y != 0) {
                _ = addFamiliar(
                    game_state,
                    camera_tile_x + familiar_offset_x,
                    camera_tile_y + familiar_offset_y,
                    camera_tile_z,
                );
            }
        }

        const screen_width = @as(f32, @floatFromInt(buffer.width));
        const screen_height = @as(f32, @floatFromInt(buffer.height));
        //const max_z_scale = 0.5;
        const ground_overscan = 1.5;
        const ground_buffer_width: i32 = @intFromFloat(@round(ground_overscan * screen_width));
        const ground_buffer_height: i32 = @intFromFloat(@round(ground_overscan * screen_height));

        game_state.ground_buffer = makeEmptyBitmap(
            &game_state.world_arena,
            ground_buffer_width,
            ground_buffer_height,
        );

        game_state.ground_buffer_p = game_state.camera_p;

        drawGroundChunk(
            game_state,
            &game_state.ground_buffer,
            &game_state.ground_buffer_p,
        );

        memory.is_initialized = true;
    }

    const game_world = game_state.world.?;

    const meters_to_pixels = game_state.meters_to_pixels;

    //
    // NOTE: Movement
    //

    for (0..input.controllers.len) |controller_index| {
        const controller: *platform.GameControllerInput =
            try platform.getController(input, controller_index);

        var hero = &game_state.controlled_heroes[controller_index];

        if (hero.entity_index == 0) {
            if (controller.buttons.map.start.ended_down) {
                hero.* = .{};
                hero.entity_index = addPlayer(game_state).low_index;
            }
        } else {
            hero.dz = 0;
            hero.ddp = Vec2.splat(0);
            hero.d_sword = Vec2.splat(0);

            if (controller.is_analog) {
                // NOTE: Use analog movement tuning
                hero.ddp = Vec2.init(controller.stick_average_x, controller.stick_average_y);
            } else {
                // NOTE: Use digital movement tuning

                if (controller.buttons.map.move_up.ended_down) {
                    hero.ddp.v[1] = 1.0;
                }

                if (controller.buttons.map.move_down.ended_down) {
                    hero.ddp.v[1] = -1.0;
                }

                if (controller.buttons.map.move_left.ended_down) {
                    hero.ddp.v[0] = -1.0;
                }

                if (controller.buttons.map.move_right.ended_down) {
                    hero.ddp.v[0] = 1.0;
                }
            }

            if (controller.buttons.map.start.ended_down) {
                hero.dz = 3.0;
            }

            if (controller.buttons.map.action_up.ended_down) {
                hero.d_sword = Vec2.init(0, 1);
            }

            if (controller.buttons.map.action_down.ended_down) {
                hero.d_sword = Vec2.init(0, -1);
            }

            if (controller.buttons.map.action_left.ended_down) {
                hero.d_sword = Vec2.init(-1, 0);
            }

            if (controller.buttons.map.action_right.ended_down) {
                hero.d_sword = Vec2.init(1, 0);
            }
        }
    }

    // TODO: Dim is chosen randomly
    const tile_span_x = 17 * 3;
    const tile_span_y = 9 * 3;
    const tile_span_z = 1;
    const camera_bounds = Rectangle3.centerDim(&Vec3.splat(0), &Vec3.scale(
        &Vec3.init(tile_span_x, tile_span_y, tile_span_z),
        game_world.tile_side_in_meters,
    ));

    var sim_arena: MemoryArena = undefined;
    initializeArena(&sim_arena, memory.transient_storage_size, memory.transient_storage);

    var region = sim.beginSim(
        &sim_arena,
        game_state,
        game_world,
        game_state.camera_p,
        camera_bounds,
        input.dt_for_frame,
    );

    //
    // NOTE: Render
    //

    const draw_buffer = &Bitmap{
        .width = buffer.width,
        .height = buffer.height,
        .pitch = buffer.pitch,
        .memory = @ptrCast(buffer.memory),
    };

    drawRectangle(
        draw_buffer,
        Vec2.splat(0),
        Vec2.fromInt(draw_buffer.width, draw_buffer.height),
        0.5,
        0.5,
        0.5,
    );

    const screen_center_x = 0.5 * @as(f32, @floatFromInt(draw_buffer.width));
    const screen_center_y = 0.5 * @as(f32, @floatFromInt(draw_buffer.height));

    var ground = Vec2.init(
        screen_center_x - 0.5 * @as(f32, @floatFromInt(game_state.ground_buffer.width)),
        screen_center_y - 0.5 * @as(f32, @floatFromInt(game_state.ground_buffer.height)),
    );

    var delta = world.subtract(game_world, &game_state.ground_buffer_p, &game_state.camera_p);
    delta.v[1] = -delta.v[1];
    const delta_xy = Vec2.scale(&delta.xy(), game_state.meters_to_pixels);
    ground = Vec2.add(&ground, &delta_xy);

    drawBitmap(
        draw_buffer,
        &game_state.ground_buffer,
        ground.x(),
        ground.y(),
        1,
    );

    // TODO: Move this out into the zigmade_entity
    var piece_group: EntityVisiblePieceGroup = undefined;
    piece_group.game_state = game_state;

    for (0..region.entity_count) |index| {
        var entity = &region.entities[index];

        if (entity.updatable) {
            piece_group.piece_count = 0;
            const dt = input.dt_for_frame;

            // TODO: This is incorrect, should be computed after update
            var shadow_alpha = 1.0 - 0.5 * entity.p.z();

            if (shadow_alpha < 0.0) {
                shadow_alpha = 0.0;
            }

            var move_spec = ety.defaultMoveSpec();
            var ddp = Vec3.splat(0);

            var hero_bitmaps = game_state.hero_bitmaps[entity.facing_direction];

            switch (entity.type) {
                .hero => {
                    // TODO: Now that we have some real usage examples, let's
                    // solidify the positioning system
                    for (0..game_state.controlled_heroes.len) |control_index| {
                        const hero = &game_state.controlled_heroes[control_index];

                        if (entity.storage_index == hero.entity_index) {
                            if (hero.dz != 0) {
                                entity.dp.v[2] = hero.dz;
                            }

                            move_spec = .{
                                .unit_max_acc_vector = true,
                                .speed = 50,
                                .drag = 8,
                            };

                            ddp = Vec3.init(hero.ddp.x(), hero.ddp.y(), 0);

                            if (hero.d_sword.x() != 0 or hero.d_sword.y() != 0) {
                                switch (entity.sword) {
                                    .ptr => {
                                        const sword = entity.sword.ptr;

                                        if (sword.flags.non_spatial) {
                                            sword.distance_limit = 5;

                                            var dp = Vec3.scale(
                                                &Vec3.init(hero.d_sword.x(), hero.d_sword.y(), 0),
                                                5,
                                            );

                                            dp = Vec3.add(&entity.dp, &dp);

                                            ety.makeEntitySpatial(sword, entity.p, dp);

                                            addCollisionRule(
                                                game_state,
                                                sword.storage_index,
                                                entity.storage_index,
                                                false,
                                            );
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }
                    }

                    // TODO: z
                    pushBitmap(
                        &piece_group,
                        &game_state.shadow,
                        Vec2.splat(0),
                        0,
                        hero_bitmaps.alignment,
                        shadow_alpha,
                        0,
                    );
                    pushBitmap(
                        &piece_group,
                        &hero_bitmaps.torso,
                        Vec2.splat(0),
                        0,
                        hero_bitmaps.alignment,
                        1,
                        1,
                    );
                    pushBitmap(
                        &piece_group,
                        &hero_bitmaps.cape,
                        Vec2.splat(0),
                        0,
                        hero_bitmaps.alignment,
                        1,
                        1,
                    );
                    pushBitmap(
                        &piece_group,
                        &hero_bitmaps.head,
                        Vec2.splat(0),
                        0,
                        hero_bitmaps.alignment,
                        1,
                        1,
                    );

                    drawHitPoints(entity, &piece_group);
                },
                .wall => {
                    pushBitmap(
                        &piece_group,
                        &game_state.tree,
                        Vec2.splat(0),
                        0,
                        Vec2.init(40, 80),
                        1,
                        1,
                    );
                },
                .stairwell => {
                    pushRect(
                        &piece_group,
                        Vec2.splat(0),
                        0,
                        entity.walkable_dim,
                        Vec4.init(1, 0.5, 0, 1),
                        0,
                    );
                    pushRect(
                        &piece_group,
                        Vec2.splat(0),
                        entity.walkable_height,
                        entity.walkable_dim,
                        Vec4.init(1, 1, 0, 1),
                        0,
                    );
                },
                .sword => {
                    move_spec = .{
                        .unit_max_acc_vector = false,
                        .speed = 0,
                        .drag = 0,
                    };

                    // TODO: IMPORTANT: Add the ability in collision routines to understand
                    // movement limit for an entity and then update this routine to use this
                    // to know when to remove the sword
                    //
                    // TODO: Need to handle the fact that distance_traveled might
                    // not have enough distance for the total entity move
                    // for the frame

                    if (entity.distance_limit == 0) {
                        clearCollisionRulesFor(game_state, entity.storage_index);
                        ety.makeEntityNonSpatial(entity);
                    }

                    pushBitmap(&piece_group, &game_state.shadow, Vec2.splat(0), 0, hero_bitmaps.alignment, shadow_alpha, 0);
                    pushBitmap(&piece_group, &game_state.sword, Vec2.splat(0), 0, Vec2.init(29, 10), 1, 1);
                },
                .familiar => {
                    var maybe_closest_hero: ?*Entity = null;
                    var closest_hero_d_sq = math.square(10); // NOTE: Ten meter max search

                    if (false) {
                        // TODO: Make spatial queries easy for things
                        for (0..region.entity_count) |test_index| {
                            const test_entity = &region.entities[test_index];

                            if (test_entity.type == .hero) {
                                const diff = Vec3.sub(&test_entity.p, &entity.p);
                                const test_d_sq = Vec3.lengthSquared(&diff);

                                if (closest_hero_d_sq > test_d_sq) {
                                    maybe_closest_hero = test_entity;
                                    closest_hero_d_sq = test_d_sq;
                                }
                            }
                        }
                    }

                    if (maybe_closest_hero) |closest_hero| {
                        if (closest_hero_d_sq > math.square(3)) {
                            const acceleration = 0.5;
                            const one_over_length = acceleration / @sqrt(closest_hero_d_sq);

                            const diff = Vec3.sub(&closest_hero.p, &entity.p);
                            ddp = Vec3.scale(&diff, one_over_length);
                        }
                    }

                    move_spec = .{
                        .unit_max_acc_vector = true,
                        .speed = 50,
                        .drag = 8,
                    };

                    entity.t_bob += dt;

                    if (entity.t_bob > 2 * std.math.pi) {
                        entity.t_bob -= 2 * std.math.pi;
                    }

                    const bob_sin = @sin(2 * entity.t_bob);
                    pushBitmap(&piece_group, &game_state.shadow, Vec2.splat(0), 0, hero_bitmaps.alignment, 0.5 * shadow_alpha + 0.2 * bob_sin, 0);
                    pushBitmap(&piece_group, &hero_bitmaps.head, Vec2.splat(0), 0.25 * bob_sin, hero_bitmaps.alignment, 1, 1);
                },
                .monster => {
                    pushBitmap(&piece_group, &game_state.shadow, Vec2.splat(0), 0, hero_bitmaps.alignment, shadow_alpha, 0);
                    pushBitmap(&piece_group, &hero_bitmaps.torso, Vec2.splat(0), 0, hero_bitmaps.alignment, 1, 1);
                    drawHitPoints(entity, &piece_group);
                },
                .space => {
                    if (false) {
                        for (0..entity.collision.volume_count) |volume_index| {
                            const volume = &entity.collision.volumes.?[volume_index];

                            pushRectOutline(
                                &piece_group,
                                volume.offset_p.xy(),
                                0,
                                volume.dim.xy(),
                                Vec4.init(0, 0.5, 1, 1),
                                0,
                            );
                        }
                    }
                },
                else => {
                    invalidCodePath();
                },
            }

            if (!entity.flags.non_spatial and entity.flags.movable) {
                sim.moveEntity(game_state, region, entity, input.dt_for_frame, &move_spec, ddp);
            }

            // NOTE: With Casey's implementation, there will be one iteration of the game
            // loop when a sword has transitioned from spatial to non_spatial during which
            // a draw attempt will be made without this check for non-spatialness in place.
            // This makes it clear why avoiding use of a non spatial entity's position is
            // important. An attempt to draw at that position in this case will create an
            // integer part of floating point value out of bounds panic.
            if (!entity.flags.non_spatial) {
                for (0..piece_group.piece_count) |piece_index| {
                    const piece = piece_group.pieces[piece_index];
                    const entity_base_p = sim.getEntityGroundPoint(entity);
                    const z_fudge = 1.0 + 0.1 * (entity_base_p.z() + piece.offset_z);

                    const eg_x = screen_center_x + meters_to_pixels * z_fudge * entity_base_p.x();
                    const eg_y = screen_center_y - meters_to_pixels * z_fudge * entity_base_p.y();
                    const entity_z = -meters_to_pixels * entity_base_p.z();

                    const center = Vec2.init(
                        eg_x + piece.offset.x(),
                        eg_y + piece.offset.y() + piece.entity_zc * entity_z,
                    );

                    if (piece.bitmap) |bitmap| {
                        drawBitmap(draw_buffer, bitmap, center.x(), center.y(), piece.a);
                    } else {
                        const half_dim = Vec2.scale(&piece.dim, 0.5 * meters_to_pixels);

                        drawRectangle(
                            draw_buffer,
                            Vec2.sub(&center, &half_dim),
                            Vec2.add(&center, &half_dim),
                            piece.r,
                            piece.g,
                            piece.b,
                        );
                    }
                }
            }
        }
    }

    var world_origin: WorldPosition = .{};
    const diff = world.subtract(region.world, &world_origin, &region.origin);

    drawRectangle(
        draw_buffer,
        Vec2.init(diff.x(), diff.y()),
        Vec2.init(10, 10),
        1,
        1,
        0,
    );

    sim.endSim(region, game_state);
}

// NOTE: At the moment, this must be a very fast function
// It cannot be greater than ~1ms
// TODO: Reduce the pressure on this function's performance
// by measuring it or asking about it, etc.
pub export fn getSoundSamples(
    thread: *platform.ThreadContext,
    memory: *platform.GameMemory,
    sound_buffer: *platform.GameSoundBuffer,
) void {
    _ = thread;
    const game_state: *GameState = @as(
        *GameState,
        @alignCast(@ptrCast(memory.permanent_storage)),
    );

    try gameOutputSound(
        sound_buffer,
        game_state,
    );
}
