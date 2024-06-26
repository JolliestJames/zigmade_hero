const std = @import("std");
const assert = std.debug.assert;
const game = @import("zigmade.zig");
const math = @import("zigmade_math.zig");
const world = @import("zigmade_world.zig");
const ety = @import("zigmade_entity.zig");

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Rectangle2 = math.Rectangle2;
const Rectangle3 = math.Rectangle3;
const MemoryArena = game.MemoryArena;
const LowEntity = game.LowEntity;
const GameState = game.GameState;
const PairwiseCollisionRule = game.PairwiseCollisionRule;
const World = world.World;
const WorldPosition = world.WorldPosition;

pub const HIT_POINT_SUB_COUNT = 4;

const HitPoint = struct {
    // TODO: Bake this down into one variable (packed struct?)
    flags: u8,
    filled_amount: u8,
};

pub const MoveSpec = struct {
    unit_max_acc_vector: bool,
    speed: f32,
    drag: f32,
};

pub const EntityType = enum {
    none,
    space,
    hero,
    wall,
    familiar,
    monster,
    sword,
    stairwell,
};

const EntityReferenceTag = enum {
    ptr,
    index,
};

const EntityReference = union(EntityReferenceTag) {
    ptr: *Entity,
    index: u32,
};

const EntityFlags = packed struct(u32) {
    // TODO: Does it make more sense for this flag to be non_colliding?
    // TODO: collides and z_supported can probably be removed soon
    collides: bool = false,
    non_spatial: bool = false,
    movable: bool = false,
    simming: bool = false,
    z_supported: bool = false,
    traversable: bool = false,
    _padding: u26 = 0,
};

pub const EntityCollisionVolume = struct {
    offset_p: Vec3 = Vec3.splat(0),
    dim: Vec3 = Vec3.splat(0),
};

pub const EntityCollisionVolumeGroup = struct {
    total_volume: EntityCollisionVolume,
    // NOTE: volume_count is always expected to be greater
    // than zero if the entity has any volume
    // In the future, this could be compressed if necessary
    // to say that the volume_count can be zero if the
    // total_volume should be used as the only collision
    // volume for the entity
    volume_count: u32,
    volumes: ?[*]EntityCollisionVolume,
};

pub const Entity = struct {
    // NOTE: These are only for the sim region
    storage_index: u32 = 0,
    updatable: bool = false,
    type: EntityType = .none,
    flags: EntityFlags = .{},
    p: Vec3 = Vec3.splat(0),
    dp: Vec3 = Vec3.splat(0),
    distance_limit: f32 = 0,
    collision: *EntityCollisionVolumeGroup = undefined,
    facing_direction: u32 = 0,
    t_bob: f32 = 0,
    d_abs_tile_z: i32 = 0,
    // TODO: Should hit points themselves be entities?
    hit_point_max: u32 = 0,
    hit_points: [16]HitPoint = undefined,
    sword: EntityReference = .{ .index = 0 },
    // TODO: Only for stairwells
    walkable_dim: Vec2 = Vec2.splat(0),
    walkable_height: f32 = 0,
    // TODO: Generation index so we know how "up to date" this entity is
};

const SimEntityHash = struct {
    ptr: ?*Entity,
    index: u32,
};

pub const SimRegion = struct {
    // TODO: Need a hash table to map stored entity indices to
    // sim entities
    world: *World,
    max_entity_radius: f32,
    max_entity_velocity: f32,
    origin: WorldPosition,
    bounds: Rectangle3,
    updatable_bounds: Rectangle3,
    max_entity_count: u32,
    entity_count: u32,
    entities: [*]Entity,
    // TODO: Do we really want a hash for this?
    // NOTE: Must be a power of two
    hash: [4096]SimEntityHash,
};

fn getHashFromStorageIndex(region: *SimRegion, storage_index: u32) *SimEntityHash {
    assert(storage_index > 0);

    var result: *SimEntityHash = undefined;

    const hash_value: usize = storage_index;

    for (0..region.hash.len) |offset| {
        const hash_mask = region.hash.len - 1;
        const hash_index = (hash_value + offset) & hash_mask;
        const entry = &region.hash[hash_index];

        if (entry.index == 0 or entry.index == storage_index) {
            result = entry;
            break;
        }
    }

    return result;
}

inline fn getEntityByStorageIndex(
    region: *SimRegion,
    storage_index: u32,
) ?*Entity {
    const entry = getHashFromStorageIndex(region, storage_index);
    const result = entry.ptr;
    return result;
}

inline fn loadEntityReference(
    game_state: *GameState,
    region: *SimRegion,
    ref: *EntityReference,
) void {
    switch (ref.*) {
        .index => {
            if (ref.index > 0) {
                var entry = getHashFromStorageIndex(region, ref.index);

                if (entry.ptr == null) {
                    entry.index = ref.index;
                    const low = game.getLowEntity(game_state, ref.index);
                    var p = getSimSpaceP(region, low);
                    entry.ptr = addEntity(game_state, region, ref.index, low, &p);
                }

                ref.* = .{ .ptr = entry.ptr.? };
            }
        },
        else => {},
    }
}

inline fn storeEntityReference(ref: *EntityReference) void {
    switch (ref.*) {
        .ptr => {
            const copy = ref.ptr;
            ref.* = .{ .index = copy.storage_index };
        },
        else => {},
    }
}

fn addEntityRaw(
    game_state: *GameState,
    region: *SimRegion,
    storage_index: u32,
    maybe_source: ?*LowEntity,
) ?*Entity {
    assert(storage_index > 0);

    var maybe_entity: ?*Entity = null;

    var entry = getHashFromStorageIndex(region, storage_index);

    if (entry.ptr == null) {
        if (region.entity_count < region.max_entity_count) {
            var entity = &region.entities[region.entity_count];
            region.entity_count += 1;

            entry = getHashFromStorageIndex(region, storage_index);

            entry.index = storage_index;
            entry.ptr = entity;

            if (maybe_source) |source| {
                // TODO: This should really be a decompression step, not a copy
                entity.* = source.sim;

                loadEntityReference(game_state, region, &entity.sword);

                assert(!source.sim.flags.simming);
                source.sim.flags.simming = true;
            }

            entity.storage_index = storage_index;
            entity.updatable = false;
            maybe_entity = entity;
        } else unreachable;
    }

    return maybe_entity;
}

inline fn getSimSpaceP(
    sim_region: *SimRegion,
    maybe_stored: ?*LowEntity,
) Vec3 {
    // NOTE: Map entity into camera space
    // TODO: Do we want to set this to signaling NAN in
    // debug to make sure nobody ever uses the position
    // of a nonspatial entity?
    var result = ety.invalidPos();

    if (maybe_stored) |stored| {
        if (!stored.sim.flags.non_spatial) {
            result = world.subtract(sim_region.world, &stored.p, &sim_region.origin);
        }
    }

    return result;
}

pub inline fn entityOverlaps(
    pos: Vec3,
    volume: EntityCollisionVolume,
    rect: Rectangle3,
) bool {
    const grown = Rectangle3.addRadius(
        &rect,
        &Vec3.scale(&volume.dim, 0.5),
    );

    const result = Rectangle3.isInRectangle(
        &grown,
        &Vec3.add(&pos, &volume.offset_p),
    );

    return result;
}

fn addEntity(
    game_state: *GameState,
    sim_region: *SimRegion,
    storage_index: u32,
    source: ?*LowEntity,
    maybe_sim_pos: ?*Vec3,
) ?*Entity {
    var maybe_dest = addEntityRaw(game_state, sim_region, storage_index, source);

    if (maybe_dest) |dest| {
        if (maybe_sim_pos) |sim_pos| {
            dest.p = sim_pos.*;

            dest.updatable = entityOverlaps(
                dest.p,
                dest.collision.total_volume,
                sim_region.updatable_bounds,
            );
        } else {
            dest.p = getSimSpaceP(sim_region, source);
        }

        maybe_dest = dest;
    }

    return maybe_dest;
}

pub fn beginSim(
    arena: *MemoryArena,
    game_state: *GameState,
    game_world: *World,
    origin: WorldPosition,
    bounds: Rectangle3,
    dt: f32,
) *SimRegion {
    // TODO: If entities are stored in the world, we wouldn't need game state here

    var sim_region = game.pushStruct(arena, SimRegion);
    game.zeroStruct(@TypeOf(sim_region.hash), &sim_region.hash);

    // TODO: Try to enforce these more rigorously
    // TODO: Perhaps try a dual system where we support
    // entities larger than the max entity radius by adding
    // them multiple times to the spatial partition?
    sim_region.max_entity_radius = 5;
    sim_region.max_entity_velocity = 30;

    const update_safety_margin: f32 = sim_region.max_entity_radius +
        dt * sim_region.max_entity_velocity;

    const update_safety_margin_z: f32 = 1;

    sim_region.world = game_world;
    sim_region.origin = origin;
    sim_region.updatable_bounds = Rectangle3.addRadius(
        &bounds,
        &Vec3.splat(sim_region.max_entity_radius),
    );

    sim_region.bounds = Rectangle3.addRadius(
        &sim_region.updatable_bounds,
        &Vec3.init(
            update_safety_margin,
            update_safety_margin,
            update_safety_margin_z,
        ),
    );

    // TODO: need to be more specific about entity counts
    sim_region.max_entity_count = 1024;
    sim_region.entity_count = 0;

    sim_region.entities = game.pushArray(arena, sim_region.max_entity_count, Entity);

    const min_corner = Rectangle3.getMinCorner(&sim_region.bounds);
    const max_corner = Rectangle3.getMaxCorner(&sim_region.bounds);

    const min_chunk_p = world.mapIntoChunkSpace(
        game_world,
        sim_region.origin,
        min_corner,
    );

    const max_chunk_p = world.mapIntoChunkSpace(
        game_world,
        sim_region.origin,
        max_corner,
    );

    var chunk_z = min_chunk_p.chunk_z;

    while (chunk_z <= max_chunk_p.chunk_z) : (chunk_z += 1) {
        var chunk_y = min_chunk_p.chunk_y;

        while (chunk_y <= max_chunk_p.chunk_y) : (chunk_y += 1) {
            var chunk_x = min_chunk_p.chunk_x;

            while (chunk_x <= max_chunk_p.chunk_x) : (chunk_x += 1) {
                const chunk = world.getWorldChunk(
                    game_world,
                    chunk_x,
                    chunk_y,
                    chunk_z,
                    null,
                );

                if (chunk) |c| {
                    var block: ?*world.WorldEntityBlock = &c.first_block;

                    while (block) |b| : (block = b.next) {
                        for (0..b.entity_count) |entity_index| {
                            const low_index = b.low_entity_index[entity_index];
                            const low = &game_state.low_entities[low_index];

                            if (!low.sim.flags.non_spatial) {
                                var sim_space_p = getSimSpaceP(sim_region, low);

                                if (entityOverlaps(
                                    sim_space_p,
                                    low.sim.collision.total_volume,
                                    sim_region.bounds,
                                )) {
                                    _ = addEntity(game_state, sim_region, low_index, low, &sim_space_p);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return sim_region;
}

pub fn endSim(
    region: *SimRegion,
    game_state: *GameState,
) void {
    // TODO: Maybe don't take a game state here, low entities should be stored in the world?

    if (game_state.world) |game_world| {
        for (0..region.entity_count) |index| {
            const entity = &region.entities[index];

            var stored = &game_state.low_entities[entity.storage_index];

            assert(stored.sim.flags.simming);
            stored.sim = entity.*;
            assert(!stored.sim.flags.simming);

            storeEntityReference(&stored.sim.sword);

            // TODO: Save state back to the stored entity, once high entities
            // do state decompression, etc.

            var new_p = if (entity.flags.non_spatial)
                world.nullPosition()
            else
                world.mapIntoChunkSpace(game_world, region.origin, entity.p);

            world.changeEntityLocation(
                &game_state.world_arena,
                game_world,
                entity.storage_index,
                &game_state.low_entities[entity.storage_index],
                &new_p,
            );

            if (entity.storage_index == game_state.camera_entity_index) {
                var new_camera_p = game_state.camera_p;

                new_camera_p.chunk_z = stored.p.chunk_z;

                if (false) {
                    if (stored.pos.x > (9.0 * game_world.tile_side_in_meters)) {
                        new_camera_p.abs_tile_x +%= 17;
                    }

                    if (stored.pos.x < -(9.0 * game_world.tile_side_in_meters)) {
                        new_camera_p.abs_tile_x -%= 17;
                    }

                    if (stored.pos.y > (5.0 * game_world.tile_side_in_meters)) {
                        new_camera_p.abs_tile_y +%= 9;
                    }

                    if (stored.pos.y < -(5.0 * game_world.tile_side_in_meters)) {
                        new_camera_p.abs_tile_y -%= 9;
                    }
                } else {
                    const z_offset = new_camera_p.offset_.z();
                    new_camera_p = stored.p;
                    new_camera_p.offset_.v[2] = z_offset;
                }

                game_state.camera_p = new_camera_p;
            }
        }
    }
}

const TestWall = struct {
    x: f32,
    rel_x: f32,
    rel_y: f32,
    dx: f32,
    dy: f32,
    min_y: f32,
    max_y: f32,
    normal: Vec3,

    fn init(
        x: f32,
        rel_x: f32,
        rel_y: f32,
        dx: f32,
        dy: f32,
        min_y: f32,
        max_y: f32,
        normal: Vec3,
    ) TestWall {
        return .{
            .x = x,
            .rel_x = rel_x,
            .rel_y = rel_y,
            .dx = dx,
            .dy = dy,
            .min_y = min_y,
            .max_y = max_y,
            .normal = normal,
        };
    }
};

fn testWall(
    wall: f32,
    rel_x: f32,
    rel_y: f32,
    player_delta_x: f32,
    player_delta_y: f32,
    t_min: *f32,
    min_y: f32,
    max_y: f32,
) bool {
    var hit = false;
    const t_epsilon = 0.001;

    if (player_delta_x != 0.0) {
        const t_result = (wall - rel_x) / player_delta_x;
        const y = rel_y + t_result * player_delta_y;

        if (t_result >= 0.0 and t_min.* > t_result) {
            if (y >= min_y and y <= max_y) {
                t_min.* = @max(0.0, t_result - t_epsilon);
                hit = true;
            }
        }
    }

    return hit;
}

fn canCollide(
    game_state: *GameState,
    entity_a: *Entity,
    entity_b: *Entity,
) bool {
    var result = false;

    var a = entity_a;
    var b = entity_b;

    if (a != b) {
        if (a.storage_index > b.storage_index) {
            const temp = a;
            a = b;
            b = temp;
        }

        if (a.flags.collides and
            b.flags.collides)
        {
            if (!a.flags.non_spatial and
                !b.flags.non_spatial)
            {
                // TODO: Property-based logic goes here
                result = true;
            }

            // TODO: BETTER HASH FUNCTION
            const bucket = a.storage_index & (game_state.collision_rule_hash.len - 1);
            var maybe_rule = game_state.collision_rule_hash[bucket];

            while (maybe_rule) |rule| : (maybe_rule = rule.next_in_hash) {
                if (rule.storage_index_a == a.storage_index and
                    rule.storage_index_b == b.storage_index)
                {
                    result = rule.can_collide;
                    break;
                }
            }
        }
    }

    return result;
}

fn handleCollision(
    game_state: *GameState,
    entity: *Entity,
    hit: *Entity,
) bool {
    var stops_on_collision = false;

    if (entity.type == .sword) {
        game.addCollisionRule(
            game_state,
            entity.storage_index,
            hit.storage_index,
            false,
        );

        stops_on_collision = false;
    } else {
        stops_on_collision = true;
    }

    var a = entity;
    var b = hit;

    if (@intFromEnum(a.type) > @intFromEnum(b.type)) {
        const temp = a;
        a = b;
        b = temp;
    }

    if (a.type == .monster and b.type == .sword) {
        if (a.hit_point_max > 0) {
            a.hit_point_max -%= 1;
        }
    }

    // TODO: stairs
    //high.abs_tile_z += @bitCast(hit_low.d_abs_tile_z);

    // TODO: Real "stops on collision"
    return stops_on_collision;
}

fn canOverlap(
    _: *GameState,
    mover: *Entity,
    region: *Entity,
) bool {
    var result = false;

    if (mover != region) {
        if (region.type == .stairwell) {
            result = true;
        }
    }

    return result;
}

inline fn getStairGround(entity: *Entity, at_ground_point: Vec3) f32 {
    assert(entity.type == .stairwell);

    const region_rect = Rectangle2.centerDim(&entity.p.xy(), &entity.walkable_dim);

    const bary = Vec2.clamp01(&Rectangle2.getBarycentric(
        &region_rect,
        &at_ground_point.xy(),
    ));

    const result = entity.p.z() + bary.y() * entity.walkable_height;

    return result;
}

pub inline fn getEntityGroundPointFromP(_: *Entity, for_entity_p: Vec3) Vec3 {
    const result = for_entity_p;

    return result;
}

pub inline fn getEntityGroundPoint(entity: *Entity) Vec3 {
    const result = getEntityGroundPointFromP(entity, entity.p);

    return result;
}

fn handleOverlap(
    _: *GameState,
    mover: *Entity,
    region: *Entity,
    _: f32,
    ground: *f32,
) void {
    if (region.type == .stairwell) {
        ground.* = getStairGround(
            region,
            getEntityGroundPoint(mover),
        );
    }
}

pub fn speculativeCollide(
    mover: *Entity,
    region: *Entity,
    test_p: Vec3,
) bool {
    var result = true;

    if (region.type == .stairwell) {

        // TODO: Needs work
        const step_height = 0.1;

        // const ground_diff = getEntityGroundPoint(mover).z() - ground;
        // result = (@abs(ground_diff) > step_height) or
        //     (bary.y() > 0.1 and bary.y() < 0.9);

        const mover_ground_point = getEntityGroundPointFromP(mover, test_p);
        const ground = getStairGround(region, mover_ground_point);

        result = @abs(mover_ground_point.z() - ground) > step_height;
    }

    return result;
}

fn entitiesOverlap(
    entity: *Entity,
    test_entity: *Entity,
    epsilon: Vec3,
) bool {
    var result = false;

    for (0..entity.collision.volume_count) |volume_index| {
        if (result) break;

        var volume = &entity.collision.volumes.?[volume_index];

        for (0..test_entity.collision.volume_count) |test_volume_index| {
            if (result) break;

            var test_volume = &test_entity.collision.volumes.?[test_volume_index];

            const entity_rect = Rectangle3.centerDim(
                &Vec3.add(&entity.p, &volume.offset_p),
                &Vec3.add(&volume.dim, &epsilon),
            );

            const test_entity_rect = Rectangle3.centerDim(
                &Vec3.add(&test_entity.p, &test_volume.offset_p),
                &test_volume.dim,
            );

            result = Rectangle3.rectanglesIntersect(
                &entity_rect,
                &test_entity_rect,
            );
        }
    }

    return result;
}

pub fn moveEntity(
    game_state: *GameState,
    region: *SimRegion,
    entity: *Entity,
    dt: f32,
    move_spec: *MoveSpec,
    dd_pos: Vec3,
) void {
    assert(!entity.flags.non_spatial);

    var acceleration = dd_pos;

    if (move_spec.unit_max_acc_vector) {
        const acc_length = Vec3.lengthSquared(&acceleration);

        if (acc_length > 1.0) {
            acceleration = Vec3.scale(&acceleration, 1.0 / @sqrt(acc_length));
        }
    }

    acceleration = Vec3.scale(&acceleration, move_spec.speed);

    // TODO: ODE here
    var drag = Vec3.scale(&entity.dp, -move_spec.drag);
    drag.v[2] = 0;
    acceleration = Vec3.add(&acceleration, &drag);

    if (!entity.flags.z_supported) {
        acceleration = Vec3.add(&acceleration, &Vec3.init(0, 0, -9.8));
    }

    var player_d = Vec3.add(
        &Vec3.scale(&acceleration, 0.5 * math.square(dt)),
        &Vec3.scale(&entity.dp, dt),
    );

    entity.dp = Vec3.add(
        &Vec3.scale(&acceleration, dt),
        &entity.dp,
    );

    // TODO: Upgrade physical motion routines to handle capping
    // max velocity?
    assert(Vec3.lengthSquared(&entity.dp) <=
        math.square(region.max_entity_velocity));

    var distance_remaining = entity.distance_limit;

    if (distance_remaining == 0) {
        // TODO: Do we want to formalize this number?
        distance_remaining = 10000;
    }

    for (0..4) |_| {
        var t_min: f32 = 1;
        var t_max: f32 = 0;

        const player_delta_length = Vec3.length(&player_d);

        // TODO: What do we want to do for epsilons here?
        // Think this through for the final collision code
        if (player_delta_length > 0) {
            if (player_delta_length > distance_remaining) {
                t_min = distance_remaining / player_delta_length;
            }

            var wall_normal_min = Vec3.splat(0);
            var wall_normal_max = Vec3.splat(0);
            var hit_entity_min: ?*Entity = null;
            var hit_entity_max: ?*Entity = null;

            const desired_position = Vec3.add(&entity.p, &player_d);

            // NOTE: This is just an optimization to avoid entering the
            // loop in the case where the test entity is non spatial
            if (!entity.flags.non_spatial) {
                // TODO: Spatial partition here!
                for (0..region.entity_count) |high_index| {
                    const test_entity = &region.entities[high_index];

                    // TODO: Robustness
                    const overlap_epsilon = 0.001;

                    if ((test_entity.flags.traversable and
                        entitiesOverlap(entity, test_entity, Vec3.splat(overlap_epsilon))) or
                        canCollide(game_state, entity, test_entity))
                    {
                        for (0..entity.collision.volume_count) |volume_index| {
                            var volume = &entity.collision.volumes.?[volume_index];

                            for (0..test_entity.collision.volume_count) |test_volume_index| {
                                var test_volume = &test_entity.collision.volumes.?[test_volume_index];

                                const minkowski_diameter = Vec3.init(
                                    test_volume.dim.x() + volume.dim.x(),
                                    test_volume.dim.y() + volume.dim.y(),
                                    test_volume.dim.z() + volume.dim.z(),
                                );

                                const min_c = Vec3.scale(&minkowski_diameter, -0.5);
                                const max_c = Vec3.scale(&minkowski_diameter, 0.5);

                                const rel = Vec3.sub(
                                    &Vec3.add(&entity.p, &volume.offset_p),
                                    &Vec3.add(&test_entity.p, &test_volume.offset_p),
                                );

                                // TODO: Do we want an open inclusion at the max corner?
                                if (rel.z() >= min_c.z() and rel.z() < max_c.z()) {
                                    const walls = [_]TestWall{
                                        TestWall.init(
                                            min_c.x(),
                                            rel.x(),
                                            rel.y(),
                                            player_d.x(),
                                            player_d.y(),
                                            min_c.y(),
                                            max_c.y(),
                                            Vec3.init(-1, 0, 0),
                                        ),
                                        TestWall.init(
                                            max_c.x(),
                                            rel.x(),
                                            rel.y(),
                                            player_d.x(),
                                            player_d.y(),
                                            min_c.y(),
                                            max_c.y(),
                                            Vec3.init(1, 0, 0),
                                        ),
                                        TestWall.init(
                                            min_c.y(),
                                            rel.y(),
                                            rel.x(),
                                            player_d.y(),
                                            player_d.x(),
                                            min_c.x(),
                                            max_c.x(),
                                            Vec3.init(0, -1, 0),
                                        ),
                                        TestWall.init(
                                            max_c.y(),
                                            rel.y(),
                                            rel.x(),
                                            player_d.y(),
                                            player_d.x(),
                                            min_c.x(),
                                            max_c.x(),
                                            Vec3.init(0, 1, 0),
                                        ),
                                    };

                                    if (test_entity.flags.traversable) {
                                        var t_max_test: f32 = t_max;
                                        var hit_this = false;
                                        var test_wall_normal = Vec3.splat(0);

                                        for (0..walls.len) |wall_index| {
                                            const wall = walls[wall_index];
                                            const t_epsilon = 0.001;

                                            if (wall.dx != 0.0) {
                                                const t_result = (wall.x - wall.rel_x) / wall.dx;
                                                const y = wall.rel_y + t_result * wall.dy;

                                                if (t_result >= 0.0 and t_max_test < t_result) {
                                                    if (y >= wall.min_y and y <= wall.max_y) {
                                                        t_max_test = @max(0, t_result - t_epsilon);
                                                        test_wall_normal = wall.normal;
                                                        hit_this = true;
                                                    }
                                                }
                                            }
                                        }

                                        if (hit_this) {
                                            t_max = t_max_test;
                                            wall_normal_max = test_wall_normal;
                                            hit_entity_max = test_entity;
                                        }
                                    } else {
                                        var t_min_test = t_min;
                                        var hit_this = false;
                                        var test_wall_normal = Vec3.splat(0);

                                        for (0..walls.len) |wall_index| {
                                            const wall = walls[wall_index];
                                            const t_epsilon = 0.001;

                                            if (wall.dx != 0.0) {
                                                const t_result = (wall.x - wall.rel_x) / wall.dx;
                                                const y = wall.rel_y + t_result * wall.dy;

                                                if (t_result >= 0.0 and t_min_test > t_result) {
                                                    if (y >= wall.min_y and y <= wall.max_y) {
                                                        t_min_test = @max(0.0, t_result - t_epsilon);
                                                        test_wall_normal = wall.normal;
                                                        hit_this = true;
                                                    }
                                                }
                                            }
                                        }

                                        // TODO: We need a concept of stepping onto vs stepping off
                                        // of here so that we can prevent you from _leaving_
                                        // stairs intead of just preventing you from getting onto them
                                        if (hit_this) {
                                            const test_p = Vec3.add(
                                                &entity.p,
                                                &Vec3.scale(&player_d, t_min_test),
                                            );

                                            if (speculativeCollide(entity, test_entity, test_p)) {
                                                t_min = t_min_test;
                                                wall_normal_min = test_wall_normal;
                                                hit_entity_min = test_entity;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            var wall_normal = Vec3.splat(0);
            var hit_entity: ?*Entity = null;
            var t_stop: f32 = undefined;

            if (t_min < t_max) {
                t_stop = t_min;
                hit_entity = hit_entity_min;
                wall_normal = wall_normal_min;
            } else {
                t_stop = t_max;
                hit_entity = hit_entity_max;
                wall_normal = wall_normal_max;
            }

            entity.p = Vec3.add(
                &entity.p,
                &Vec3.scale(&player_d, t_stop),
            );

            distance_remaining -= t_stop * player_delta_length;

            if (hit_entity) |hit| {
                player_d = Vec3.sub(&desired_position, &entity.p);

                const stops_on_collision = handleCollision(game_state, entity, hit);

                if (stops_on_collision) {
                    const p_product = 1 * Vec3.inner(&player_d, &wall_normal);
                    const p_magnitude = Vec3.scale(&wall_normal, p_product);
                    player_d = Vec3.sub(&player_d, &p_magnitude);

                    const d_product = 1 * Vec3.inner(&entity.dp, &wall_normal);
                    const d_magnitude = Vec3.scale(&wall_normal, d_product);
                    entity.dp = Vec3.sub(&entity.dp, &d_magnitude);
                }
            } else break;
        } else break;
    }

    var ground: f32 = 0;

    // NOTE: Handle events based on area overlapping
    // TODO: Handle overlapping precisely by moving it into the collision loop?
    {
        // TODO: Spatial partition here!
        for (0..region.entity_count) |high_index| {
            const test_entity = &region.entities[high_index];

            if (canOverlap(game_state, entity, test_entity) and
                entitiesOverlap(entity, test_entity, Vec3.splat(0)))
            {
                handleOverlap(game_state, entity, test_entity, dt, &ground);
            }
        }
    }

    ground += entity.p.z() - getEntityGroundPoint(entity).z();

    // TODO: This has to become real height handling
    if (entity.p.z() <= ground or
        (entity.flags.z_supported and
        entity.dp.z() == 0))
    {
        entity.p.v[2] = ground;
        entity.dp.v[2] = 0;
        entity.flags.z_supported = true;
    } else {
        entity.flags.z_supported = false;
    }

    if (entity.distance_limit != 0) {
        entity.distance_limit = distance_remaining;
    }

    // TODO: Change to using the acceleration vector
    if (entity.dp.x() == 0.0 and entity.dp.y() == 0.0) {
        // Leave facing_direction alone
    } else if (@abs(entity.dp.x()) > @abs(entity.dp.y())) {
        if (entity.dp.x() > 0) {
            entity.facing_direction = 0;
        } else {
            entity.facing_direction = 2;
        }
    } else if (@abs(entity.dp.x()) < @abs(entity.dp.y())) {
        if (entity.dp.y() > 0) {
            entity.facing_direction = 1;
        } else {
            entity.facing_direction = 3;
        }
    }
}
