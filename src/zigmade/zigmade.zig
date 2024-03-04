const std = @import("std");
const assert = std.debug.assert;

pub inline fn Kilobytes(comptime value: comptime_int) comptime_int {
    return (1024 * value);
}

pub inline fn Megabytes(comptime value: comptime_int) comptime_int {
    return Kilobytes(value) * 1024;
}

pub inline fn Gigabytes(comptime value: comptime_int) comptime_int {
    return Megabytes(value) * 1024;
}

pub inline fn Terabytes(comptime value: comptime_int) comptime_int {
    return Gigabytes(value) * 1024;
}

// TODO: Services that the platform layer provides to the game

// NOTE: Services that the game provides to the platform layer
// maybe expand in the future - sound on separate thread

// TODO: rendering will become a three-tiered abstraction
pub const GameOffscreenBuffer = struct {
    memory: ?*void = undefined,
    width: i32,
    height: i32,
    pitch: i32,
};

pub const GameSoundBuffer = struct {
    samples: [*]i16 = undefined,
    samples_per_second: i32,
    sample_count: i32,
};

pub const GameButtonState = extern struct {
    half_transition_count: i32,
    ended_down: bool,
};

// TODO: maybe there's a better way to represent button state
// in the controller since fields may not be nameless in Zig
pub const GameControllerInput = struct {
    is_analog: bool,
    start_x: f32,
    start_y: f32,
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    end_x: f32,
    end_y: f32,
    buttons: extern union {
        array: [6]GameButtonState,
        map: extern struct {
            up: GameButtonState,
            down: GameButtonState,
            left: GameButtonState,
            right: GameButtonState,
            left_shoulder: GameButtonState,
            right_shoulder: GameButtonState,
        },
    },
};

pub const GameInput = struct {
    // TODO: Insert clock value here
    controllers: [4]GameControllerInput,
};

pub const GameMemory = struct {
    is_initialized: bool = false,
    permanent_storage_size: u64,
    // NOTE: Required to be cleared to zero at startup
    permanent_storage: [*]u8 = undefined,
    transient_storage_size: u64,
    transient_storage: [*]u8 = undefined,
};

const GameState = struct {
    blue_offset: i32,
    green_offset: i32,
    tone_hertz: i32,
};

fn game_output_sound(
    sound_buffer: *GameSoundBuffer,
    tone_hertz: i32,
) !void {
    const t_sine = struct {
        var value: f32 = undefined;
    };

    const tone_volume: i16 = 3_000;
    var wave_period = @divTrunc(sound_buffer.samples_per_second, tone_hertz);
    var sample_out: [*]i16 = sound_buffer.samples;

    for (0..@as(usize, @intCast(sound_buffer.sample_count))) |i| {
        var sine_value: f32 = std.math.sin(t_sine.value);
        var sample_value: i16 = @as(i16, @intFromFloat(
            sine_value * @as(
                f32,
                @floatFromInt(tone_volume),
            ),
        ));

        sample_out[2 * i] = sample_value;
        sample_out[2 * i + 1] = sample_value;

        t_sine.value +=
            2.0 *
            std.math.pi *
            1.0 /
            @as(f32, @floatFromInt(wave_period));
    }
}

fn render_weird_gradient(
    buffer: *GameOffscreenBuffer,
    blue_offset: i32,
    green_offset: i32,
) !void {
    var row: [*]u8 = @alignCast(@ptrCast(buffer.memory));

    for (0..@intCast(buffer.height)) |y| {
        var pixel: [*]u32 = @ptrCast(@alignCast(row));

        for (0..@intCast(buffer.width)) |x| {
            var blue: u32 = @as(u8, @truncate(x + @as(
                u32,
                @bitCast(blue_offset),
            )));
            var green: u32 = @as(u8, @truncate(y + @as(
                u32,
                @bitCast(green_offset),
            )));

            pixel[x] = (green << 8) | blue;
        }

        row += @as(usize, @intCast(buffer.pitch));
    }
}

// GAME NEEDS FOUR THINGS
// - timing
// - controller/keyboard input
// - bitmap buffer
// - sound buffer
pub fn game_update_and_render(
    memory: *GameMemory,
    input: *GameInput,
    offscreen_buffer: *GameOffscreenBuffer,
    sound_buffer: *GameSoundBuffer,
) !void {
    assert(@sizeOf(GameMemory) <= memory.permanent_storage_size);

    var game_state: *GameState = @as(
        *GameState,
        @alignCast(@ptrCast(memory.permanent_storage)),
    );

    if (!memory.is_initialized) {
        game_state.tone_hertz = 256;

        // TODO: This may be more appropriate to do in the platform layer
        memory.is_initialized = true;
    }

    var input_0: *GameControllerInput = &input.controllers[0];

    if (input_0.is_analog) {
        // NOTE: Use analog movement tuning
        game_state.blue_offset += @as(i32, @intFromFloat(
            4.0 * (input_0.end_x),
        ));
        game_state.tone_hertz = 256 +
            @as(i32, @intFromFloat(128.0 *
            (input_0.end_y)));
    } else {
        // NOTE: Use digital movement tuning
    }

    if (input_0.buttons.map.down.ended_down) {
        game_state.green_offset += 1;
    }

    // TODO: Allow sample offsets here for more robust platform options
    try game_output_sound(
        sound_buffer,
        game_state.tone_hertz,
    );
    try render_weird_gradient(
        offscreen_buffer,
        game_state.blue_offset,
        game_state.green_offset,
    );
}
