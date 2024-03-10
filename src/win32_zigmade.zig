//
// TODO:
// - Saved game locations
// - Getting a handle to our own exe
// - Asset loading path
// - Threading
// - Raw input
// - Sleep/timeBeginPeriod
// - ClipCursor() for multimonitor support
// - Fullscreen support
// - WM_SETCURSOR to control cursor visibilty
// - QueryCancelAutoplay
// - WM_ACTIVATEAPP for when we are not the active application
// - Blit speed improvements with BitBlt
// - Hardware acceleration (OpenGL/Direct3D/Both)
// - GetKeyboardLayout for French keyboards/intnl WASD support
//

const std = @import("std");
const zigmade = @import("zigmade/zigmade.zig");

const WINAPI = std.os.windows.WINAPI;
const DEBUG_WALL_CLOCK = @import("options").DEBUG_WALL_CLOCK;
const INTERNAL = @import("builtin").mode == std.builtin.Mode.Debug;

const win32 = struct {
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").graphics.gdi;
    usingnamespace @import("win32").media;
    usingnamespace @import("win32").media.audio;
    usingnamespace @import("win32").media.audio.direct_sound;
    usingnamespace @import("win32").storage.file_system;
    usingnamespace @import("win32").system;
    usingnamespace @import("win32").system.com;
    usingnamespace @import("win32").system.diagnostics.debug;
    usingnamespace @import("win32").system.memory;
    usingnamespace @import("win32").system.performance;
    usingnamespace @import("win32").system.library_loader;
    usingnamespace @import("win32").system.threading;
    usingnamespace @import("win32").ui.input.keyboard_and_mouse;
    usingnamespace @import("win32").ui.input.xbox_controller;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").zig;
};

const BackBuffer = struct {
    memory: ?*anyopaque = undefined,
    info: win32.BITMAPINFO,
    width: i32,
    height: i32,
    pitch: i32,
    bytes_per_pixel: i32 = 4,
};

// TODO: Use globals for now
var global_running: bool = false;
var global_back_buffer: BackBuffer = undefined;
var global_secondary_buffer: *win32.IDirectSoundBuffer = undefined;
var global_perf_count_frequency: i64 = undefined;

const WindowDimension = struct {
    width: i32,
    height: i32,
};

const XInputGetState = struct {
    var call: *const fn (
        user_index: u32,
        state: ?*win32.XINPUT_STATE,
    ) callconv(WINAPI) isize = undefined;

    fn stub(_: u32, _: ?*win32.XINPUT_STATE) callconv(WINAPI) isize {
        return (@intFromEnum(win32.ERROR_DEVICE_NOT_CONNECTED));
    }
};

const XInputSetState = struct {
    var call: *const fn (
        user_index: u32,
        vibration: ?*win32.XINPUT_VIBRATION,
    ) callconv(WINAPI) isize = undefined;

    fn stub(_: u32, _: ?*win32.XINPUT_VIBRATION) callconv(WINAPI) isize {
        return (@intFromEnum(win32.ERROR_DEVICE_NOT_CONNECTED));
    }
};

fn debug_platform_read_entire_file(file_name: [*:0]const u8) zigmade.DebugReadFileResult {
    var result: zigmade.DebugReadFileResult = undefined;

    var handle = win32.CreateFileA(
        file_name,
        win32.FILE_GENERIC_READ,
        win32.FILE_SHARE_READ,
        null,
        win32.OPEN_EXISTING,
        win32.FILE_FLAGS_AND_ATTRIBUTES{},
        null,
    );

    if (handle != win32.INVALID_HANDLE_VALUE) {
        var file_size: win32.LARGE_INTEGER = undefined;

        if (win32.GetFileSizeEx(handle, &file_size) > 0) {
            var file_size32 = zigmade.safe_truncate_u64(@as(u64, @intCast(file_size.QuadPart)));

            result.contents = win32.VirtualAlloc(
                null,
                file_size32,
                win32.VIRTUAL_ALLOCATION_TYPE{ .RESERVE = 1, .COMMIT = 1 },
                win32.PAGE_READWRITE,
            );

            if (result.contents) |contents| {
                var bytes_read: u32 = undefined;

                if (win32.ReadFile(
                    handle,
                    contents,
                    file_size32,
                    &bytes_read,
                    null,
                ) > 0 and file_size32 == bytes_read) {
                    // NOTE: File read successfully
                    result.size = file_size32;
                } else {
                    // TODO: Logging
                    debug_platform_free_file_memory(result.contents);
                    result.contents = null;
                }
            } else {
                // TODO: Logging
            }
        } else {
            // TODO: Logging
        }

        _ = win32.CloseHandle(handle);
    } else {
        // TODO: Logging
    }

    return result;
}

fn debug_platform_free_file_memory(maybe_memory: ?*anyopaque) void {
    if (maybe_memory) |memory| {
        _ = win32.VirtualFree(memory, 0, win32.MEM_RELEASE);
    }
}

fn debug_platform_write_entire_file(
    file_name: [*:0]const u8,
    memory_size: u32,
    memory: ?*anyopaque,
) bool {
    var result = false;

    var handle = win32.CreateFileA(
        file_name,
        win32.FILE_GENERIC_WRITE,
        win32.FILE_SHARE_NONE,
        null,
        win32.CREATE_ALWAYS,
        win32.FILE_FLAGS_AND_ATTRIBUTES{},
        null,
    );

    if (handle != win32.INVALID_HANDLE_VALUE) {
        var bytes_written: u32 = undefined;

        if (win32.WriteFile(
            handle,
            memory,
            memory_size,
            &bytes_written,
            null,
        ) > 0) {
            // NOTE: File written successfully
            result = (bytes_written == memory_size);
        } else {
            // TODO: Logging
        }

        _ = win32.CloseHandle(handle);
    } else {
        // TODO: Logging
    }

    return result;
}

const win32_platform = zigmade.Platform{
    .debug_platform_read_entire_file = debug_platform_read_entire_file,
    .debug_platform_free_file_memory = debug_platform_free_file_memory,
    .debug_platform_write_entire_file = debug_platform_write_entire_file,
};

var direct_sound_create: *const fn (
    guid_device: ?*const win32.Guid,
    pp_ds: ?*?*win32.IDirectSound,
    unknown_outer: ?*win32.IUnknown,
) callconv(WINAPI) win32.HRESULT = undefined;

fn win32_load_x_input() !void {
    if (win32.LoadLibraryA(win32.XINPUT_DLL)) |x_input_library| {
        if (win32.GetProcAddress(
            x_input_library,
            "XInputGetState",
        )) |x_input_get_state| {
            XInputGetState.call = @as(
                @TypeOf(XInputGetState.call),
                @ptrCast(x_input_get_state),
            );
        } else {
            XInputGetState.call = XInputGetState.stub;
        }

        if (win32.GetProcAddress(
            x_input_library,
            "XInputSetState",
        )) |x_input_set_state| {
            XInputSetState.call = @as(
                @TypeOf(XInputSetState.call),
                @ptrCast(x_input_set_state),
            );
        } else {
            XInputSetState.call = XInputSetState.stub;
        }

        // TODO: diagnostic
    } else {
        // TODO: diagnostic
    }
}

fn win32_init_direct_sound(
    window: win32.HWND,
    samples_per_second: i32,
    buffer_size: i32,
) !void {
    if (win32.LoadLibraryA("dsound.dll")) |direct_sound_library| {
        if (win32.GetProcAddress(
            direct_sound_library,
            "DirectSoundCreate",
        )) |direct_sound_create_address| {
            direct_sound_create = @as(
                @TypeOf(direct_sound_create),
                @ptrCast(direct_sound_create_address),
            );

            var maybe_direct_sound: ?*win32.IDirectSound = undefined;

            if (win32.SUCCEEDED(direct_sound_create(
                null,
                &maybe_direct_sound,
                null,
            ))) {
                var direct_sound = maybe_direct_sound.?;

                var wave_format = std.mem.zeroInit(win32.WAVEFORMATEX, .{});
                wave_format.wFormatTag = win32.WAVE_FORMAT_PCM;
                wave_format.nChannels = 2;
                wave_format.nSamplesPerSec = @intCast(samples_per_second);
                wave_format.wBitsPerSample = 16;
                wave_format.nBlockAlign = (wave_format.nChannels * wave_format.wBitsPerSample) / 8;
                wave_format.nAvgBytesPerSec = wave_format.nSamplesPerSec * wave_format.nBlockAlign;
                wave_format.cbSize = 0;

                if (win32.SUCCEEDED(direct_sound.vtable.SetCooperativeLevel(
                    direct_sound,
                    window,
                    win32.DSSCL_PRIORITY,
                ))) {
                    var buffer_description = std.mem.zeroInit(win32.DSBUFFERDESC, .{});
                    buffer_description.dwSize = @sizeOf(@TypeOf(buffer_description));
                    buffer_description.dwFlags = win32.DSBCAPS_PRIMARYBUFFER;
                    var maybe_primary_buffer: ?*win32.IDirectSoundBuffer = undefined;

                    if (win32.SUCCEEDED(direct_sound.vtable.CreateSoundBuffer(
                        direct_sound,
                        &buffer_description,
                        &maybe_primary_buffer,
                        null,
                    ))) {
                        var primary_buffer = maybe_primary_buffer.?;

                        if (win32.SUCCEEDED(primary_buffer.vtable.SetFormat(
                            primary_buffer,
                            &wave_format,
                        ))) {
                            std.debug.print("Primary buffer format set.\n", .{});
                        } else {
                            // TODO: diagnostic
                        }
                    } else {
                        // TODO: diagnostic
                    }
                } else {
                    // TODO: diagnostic
                }

                var buffer_description = std.mem.zeroInit(win32.DSBUFFERDESC, .{});
                buffer_description.dwSize = @sizeOf(win32.DSBUFFERDESC);
                buffer_description.dwFlags = 0;
                buffer_description.dwBufferBytes = @intCast(buffer_size);
                buffer_description.lpwfxFormat = &wave_format;
                var maybe_secondary_buffer: ?*win32.IDirectSoundBuffer = undefined;

                if (win32.SUCCEEDED(direct_sound.vtable.CreateSoundBuffer(
                    direct_sound,
                    &buffer_description,
                    &maybe_secondary_buffer,
                    null,
                ))) {
                    global_secondary_buffer = maybe_secondary_buffer.?;
                    std.debug.print("Secondary buffer format created.\n", .{});
                } else {
                    // TODO: diagnostic
                }
            } else {
                // TODO: diagnostic
            }
        }
    } else {
        // TODO: diagnostic
    }
}

fn win32_get_window_dimension(window: win32.HWND) !WindowDimension {
    var result: WindowDimension = undefined;

    var client_rect: win32.RECT = undefined;
    _ = win32.GetClientRect(window, &client_rect);

    result.width = client_rect.right - client_rect.left;
    result.height = client_rect.bottom - client_rect.top;

    return (result);
}

fn win32_resize_dib_section(
    buffer: *BackBuffer,
    width: i32,
    height: i32,
) !void {
    // TODO: Maybe don't free first, free after, then free first if that fails
    if (buffer.memory != undefined) {
        _ = win32.VirtualFree(buffer.memory, 0, win32.MEM_RELEASE);
    }

    buffer.width = width;
    buffer.height = height;
    buffer.bytes_per_pixel = 4;

    buffer.info.bmiHeader.biSize = @sizeOf(@TypeOf(buffer.info.bmiHeader));
    buffer.info.bmiHeader.biWidth = buffer.width;
    buffer.info.bmiHeader.biHeight = -buffer.height;
    buffer.info.bmiHeader.biPlanes = 1;
    buffer.info.bmiHeader.biBitCount = 32;
    buffer.info.bmiHeader.biCompression = win32.BI_RGB;

    var bitmap_memory_size = buffer.bytes_per_pixel * (buffer.width * buffer.height);
    buffer.memory = win32.VirtualAlloc(
        null,
        @intCast(bitmap_memory_size),
        win32.VIRTUAL_ALLOCATION_TYPE{ .RESERVE = 1, .COMMIT = 1 },
        win32.PAGE_READWRITE,
    );

    buffer.pitch = width * buffer.bytes_per_pixel;

    // TODO: clear bitmap to black
}

fn win32_display_buffer_in_window(
    buffer: *BackBuffer,
    device_context: ?win32.HDC,
    window_width: i32,
    window_height: i32,
) !void {
    // TODO: Correct aspect ratio
    _ = win32.StretchDIBits(
        device_context,
        0,
        0,
        window_width,
        window_height,
        0,
        0,
        buffer.width,
        buffer.height,
        buffer.memory,
        &buffer.info,
        win32.DIB_RGB_COLORS,
        win32.SRCCOPY,
    );
}

fn win32_main_window_callback(
    window: win32.HWND,
    message: u32,
    w_param: win32.WPARAM,
    l_param: win32.LPARAM,
) callconv(WINAPI) win32.LRESULT {
    var result: win32.LRESULT = 0;

    switch (message) {
        win32.WM_CLOSE => {
            // TODO: Handle with a message to the user?
            global_running = false;
        },
        win32.WM_ACTIVATEAPP => {
            win32.OutputDebugStringA("WM_ACTIVATEAPP\n");
        },
        win32.WM_DESTROY => {
            // TODO: Handle as an error--recreate window?
            global_running = false;
        },
        win32.WM_SYSKEYDOWN,
        win32.WM_SYSKEYUP,
        win32.WM_KEYDOWN,
        win32.WM_KEYUP,
        => {
            std.debug.print("Keyboard input came in through a non-dispatch message!", .{});
            std.debug.assert(false);
        },
        win32.WM_PAINT => {
            var paint = std.mem.zeroInit(win32.PAINTSTRUCT, .{});
            var device_context = win32.BeginPaint(window, &paint);
            var dimension = try win32_get_window_dimension(window);
            try win32_display_buffer_in_window(
                &global_back_buffer,
                device_context,
                dimension.width,
                dimension.height,
            );

            _ = win32.EndPaint(window, &paint);
        },
        else => {
            result = win32.DefWindowProcW(window, message, w_param, l_param);
        },
    }

    return (result);
}

const Win32SoundOutput = struct {
    samples_per_second: i32,
    running_sample_index: u32,
    bytes_per_sample: i32,
    secondary_buffer_size: i32,
    latency_sample_count: i32,
};

fn win32_clear_buffer(sound_output: *Win32SoundOutput) !void {
    var region_1: ?*anyopaque = undefined;
    var region_1_size: u32 = undefined;
    var region_2: ?*anyopaque = undefined;
    var region_2_size: u32 = undefined;

    if (win32.SUCCEEDED(global_secondary_buffer.vtable.Lock(
        global_secondary_buffer,
        0,
        @as(u32, @intCast(sound_output.secondary_buffer_size)),
        &region_1,
        &region_1_size,
        &region_2,
        &region_2_size,
        0,
    ))) {
        if (region_1) |region| {
            var dest_sample: [*]i8 = @alignCast(@ptrCast(region));

            for (0..region_1_size) |i| {
                dest_sample[i] = 0;
            }
        }

        if (region_2) |region| {
            var dest_sample: [*]i8 = @alignCast(@ptrCast(region));

            for (0..region_2_size) |i| {
                dest_sample[i] = 0;
            }
        }

        _ = global_secondary_buffer.vtable.Unlock(
            global_secondary_buffer,
            region_1,
            region_1_size,
            region_2,
            region_2_size,
        );
    }
}

fn win32_fill_sound_buffer(
    sound_output: *Win32SoundOutput,
    byte_to_lock: u32,
    bytes_to_write: u32,
    source_buffer: *zigmade.GameSoundBuffer,
) !void {
    var region_1: ?*anyopaque = undefined;
    var region_1_size: u32 = undefined;
    var region_2: ?*anyopaque = undefined;
    var region_2_size: u32 = undefined;

    if (win32.SUCCEEDED(global_secondary_buffer.vtable.Lock(
        global_secondary_buffer,
        byte_to_lock,
        bytes_to_write,
        &region_1,
        &region_1_size,
        &region_2,
        &region_2_size,
        0,
    ))) {
        // TODO: assert that region size is valid
        if (region_1) |region| {
            var region_1_sample_count: u32 = region_1_size /
                @as(u32, @intCast(sound_output.bytes_per_sample));
            var dest_sample: [*]i16 = @alignCast(@ptrCast(region));
            var source_sample = source_buffer.samples;

            for (0..region_1_sample_count) |i| {
                dest_sample[i * 2] = source_sample[i * 2];
                dest_sample[i * 2 + 1] = source_sample[i * 2 + 1];

                sound_output.running_sample_index += 1;
            }
        }

        if (region_2) |region| {
            var region_2_sample_count: u32 = region_2_size /
                @as(u32, @intCast(sound_output.bytes_per_sample));
            var dest_sample: [*]i16 = @alignCast(@ptrCast(region));
            var source_sample = source_buffer.samples;

            for (0..region_2_sample_count) |i| {
                dest_sample[i * 2] = source_sample[i * 2];
                dest_sample[i * 2 + 1] = source_sample[i * 2 + 1];

                sound_output.running_sample_index += 1;
            }
        }

        _ = global_secondary_buffer.vtable.Unlock(
            global_secondary_buffer,
            region_1,
            region_1_size,
            region_2,
            region_2_size,
        );
    }
}

fn win32_process_keyboard_message(
    new_state: *zigmade.GameButtonState,
    is_down: bool,
) !void {
    std.debug.assert(new_state.ended_down != is_down);
    new_state.ended_down = is_down;
    new_state.half_transition_count += 1;
}

fn win32_process_x_input_digital_button(
    button_state: u32,
    old_state: *zigmade.GameButtonState,
    new_state: *zigmade.GameButtonState,
    button_bit: u32,
) !void {
    new_state.ended_down = ((button_state & button_bit) == button_bit);
    new_state.half_transition_count =
        if (old_state.ended_down != new_state.ended_down) 1 else 0;
}

fn win32_process_x_input_stick_value(
    value: i16,
    deadzone_threshold: i16,
) !f32 {
    var result: f32 = 0;

    if (value < -deadzone_threshold) {
        result = @as(f32, @floatFromInt(value + deadzone_threshold)) /
            (32768.0 - @as(f32, @floatFromInt(deadzone_threshold)));
    } else if (value > deadzone_threshold) {
        result = @as(f32, @floatFromInt(value - deadzone_threshold)) /
            (32767.0 - @as(f32, @floatFromInt(deadzone_threshold)));
    }

    return result;
}

fn win32_process_pending_messages(keyboard_controller: *zigmade.GameControllerInput) !void {
    var message: win32.MSG = undefined;

    while (win32.PeekMessageW(
        &message,
        null,
        0,
        0,
        win32.PM_REMOVE,
    ) > 0) {
        switch (message.message) {
            win32.WM_QUIT => global_running = false,
            win32.WM_SYSKEYDOWN,
            win32.WM_SYSKEYUP,
            win32.WM_KEYDOWN,
            win32.WM_KEYUP,
            => {
                var vk_code: win32.VIRTUAL_KEY = @enumFromInt(message.wParam);
                var was_down = (message.lParam & (1 << 30)) != 0;
                var is_down = (message.lParam & (1 << 31)) == 0;

                if (was_down != is_down) {
                    switch (vk_code) {
                        win32.VK_W => try win32_process_keyboard_message(
                            &keyboard_controller.buttons.map.move_up,
                            is_down,
                        ),

                        win32.VK_A => try win32_process_keyboard_message(
                            &keyboard_controller.buttons.map.move_left,
                            is_down,
                        ),

                        win32.VK_S => try win32_process_keyboard_message(
                            &keyboard_controller.buttons.map.move_down,
                            is_down,
                        ),
                        win32.VK_D => try win32_process_keyboard_message(
                            &keyboard_controller.buttons.map.move_right,
                            is_down,
                        ),
                        win32.VK_Q => try win32_process_keyboard_message(
                            &keyboard_controller.buttons.map.left_shoulder,
                            is_down,
                        ),
                        win32.VK_E => try win32_process_keyboard_message(
                            &keyboard_controller.buttons.map.right_shoulder,
                            is_down,
                        ),
                        win32.VK_UP => try win32_process_keyboard_message(
                            &keyboard_controller.buttons.map.action_up,
                            is_down,
                        ),
                        win32.VK_DOWN => try win32_process_keyboard_message(
                            &keyboard_controller.buttons.map.action_down,
                            is_down,
                        ),
                        win32.VK_LEFT => try win32_process_keyboard_message(
                            &keyboard_controller.buttons.map.action_left,
                            is_down,
                        ),
                        win32.VK_RIGHT => try win32_process_keyboard_message(
                            &keyboard_controller.buttons.map.action_right,
                            is_down,
                        ),
                        win32.VK_ESCAPE => try win32_process_keyboard_message(
                            &keyboard_controller.buttons.map.start,
                            is_down,
                        ),
                        win32.VK_SPACE => try win32_process_keyboard_message(
                            &keyboard_controller.buttons.map.back,
                            is_down,
                        ),
                        else => {},
                    }
                }

                var alt_key_was_down: bool = (message.lParam & (1 << 29)) != 0;
                if (vk_code == win32.VK_F4 and alt_key_was_down) {
                    global_running = false;
                }
            },
            else => {
                _ = win32.TranslateMessage(&message);
                _ = win32.DispatchMessageW(&message);
            },
        }
    }
}

inline fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );

    return (@as(u64, @intCast((high))) << 32) | @as(u64, @intCast(low));
}

inline fn win32_get_wall_clock() !win32.LARGE_INTEGER {
    var result: win32.LARGE_INTEGER = undefined;
    _ = win32.QueryPerformanceCounter(&result);
    return (result);
}

inline fn win32_get_seconds_elapsed(
    start: win32.LARGE_INTEGER,
    end: win32.LARGE_INTEGER,
) !f32 {
    return (@as(f32, @floatFromInt(end.QuadPart - start.QuadPart)) /
        @as(f32, @floatFromInt(global_perf_count_frequency)));
}

pub export fn wWinMain(
    instance: ?win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    _: [*:0]u16,
    _: u32,
) callconv(WINAPI) c_int {
    var perf_count_frequency_result: win32.LARGE_INTEGER = undefined;
    _ = win32.QueryPerformanceFrequency(&perf_count_frequency_result);
    global_perf_count_frequency = perf_count_frequency_result.QuadPart;

    // NOTE: Set Windows scheduler granularity to 1ms
    // so that Sleep() can be more granular
    const desired_scheduler_ms = 1;
    var sleep_is_granular = (win32.timeBeginPeriod(desired_scheduler_ms) == win32.TIMERR_NOERROR);

    try win32_load_x_input();

    var window_class = std.mem.zeroInit(win32.WNDCLASSW, .{});

    // TODO: would be nice to properly log when something goes wrong with these error union return types
    try win32_resize_dib_section(&global_back_buffer, 1280, 720);

    window_class.style = win32.WNDCLASS_STYLES{ .HREDRAW = 1, .VREDRAW = 1 };
    window_class.lpfnWndProc = @ptrCast(&win32_main_window_callback);
    window_class.hInstance = instance;
    // window_class.hIcon = ;
    window_class.lpszClassName = win32.L("HandmadeHeroWindowClass");

    // TODO: How do we reliably query this on Windows?
    comptime var monitor_refresh_hertz = 60;
    comptime var game_update_hertz = monitor_refresh_hertz / 2;
    var target_seconds_per_frame = 1.0 /
        @as(f32, @floatFromInt(game_update_hertz));

    if (win32.RegisterClassW(&window_class) != 0) {
        var window_style = win32.WS_OVERLAPPEDWINDOW;
        window_style.VISIBLE = 1;

        if (win32.CreateWindowExW(
            win32.WINDOW_EX_STYLE{},
            window_class.lpszClassName,
            win32.L("Handmade Hero"),
            window_style,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            null,
            null,
            instance,
            null,
        )) |window| {
            if (win32.GetDC(window)) |device_context| {
                var sound_output: Win32SoundOutput =
                    std.mem.zeroInit(Win32SoundOutput, .{});

                sound_output.samples_per_second = 48_000;
                sound_output.bytes_per_sample = @sizeOf(i16) * 2;
                sound_output.secondary_buffer_size =
                    sound_output.samples_per_second *
                    sound_output.bytes_per_sample;
                sound_output.latency_sample_count = @divTrunc(
                    sound_output.samples_per_second,
                    15,
                );

                try win32_init_direct_sound(
                    window,
                    sound_output.samples_per_second,
                    sound_output.secondary_buffer_size,
                );

                try win32_clear_buffer(&sound_output);

                _ = global_secondary_buffer.vtable.Play(
                    global_secondary_buffer,
                    0,
                    0,
                    win32.DSBPLAY_LOOPING,
                );

                global_running = true;

                // TODO: pool with bitmap VirtualAlloc
                var samples = win32.VirtualAlloc(
                    null,
                    @as(usize, @intCast(sound_output.secondary_buffer_size)),
                    win32.VIRTUAL_ALLOCATION_TYPE{ .RESERVE = 1, .COMMIT = 1 },
                    win32.PAGE_READWRITE,
                );

                var base_address: ?*anyopaque =
                    if (INTERNAL)
                    @ptrFromInt(zigmade.Terabytes(2))
                else
                    null;

                var game_memory: zigmade.GameMemory = undefined;
                game_memory.permanent_storage_size = zigmade.Megabytes(64);
                game_memory.transient_storage_size = zigmade.Gigabytes(4);

                // TODO: Handle various memory footprints using system metrics
                var total_size = game_memory.permanent_storage_size +
                    game_memory.transient_storage_size;

                game_memory.permanent_storage = @as([*]u8, @ptrCast(win32.VirtualAlloc(
                    base_address,
                    @as(usize, @intCast(total_size)),
                    win32.VIRTUAL_ALLOCATION_TYPE{ .RESERVE = 1, .COMMIT = 1 },
                    win32.PAGE_READWRITE,
                )));
                game_memory.transient_storage = game_memory.permanent_storage +
                    game_memory.permanent_storage_size;

                if (samples != undefined and
                    game_memory.permanent_storage != undefined and
                    game_memory.transient_storage != undefined)
                {
                    var inputs: [2]zigmade.GameInput = undefined;
                    var new_input = &inputs[0];
                    var old_input = &inputs[1];

                    var last_counter = try win32_get_wall_clock();
                    var last_cycle_count = rdtsc();

                    while (global_running) {
                        // TODO: Zeroing "macro" with comptime
                        // TODO: We can't zero everything because the up/down state will be wrong
                        // NOTE: Index 0 belongs to keyboard
                        var old_keyboard_controller: *zigmade.GameControllerInput =
                            try zigmade.get_controller(old_input, 0);
                        var new_keyboard_controller: *zigmade.GameControllerInput =
                            try zigmade.get_controller(new_input, 0);
                        new_keyboard_controller.* =
                            std.mem.zeroInit(zigmade.GameControllerInput, .{});
                        new_keyboard_controller.is_connected = true;

                        for (0..new_keyboard_controller.buttons.array.len) |button_index| {
                            new_keyboard_controller.buttons.array[button_index].ended_down =
                                old_keyboard_controller.buttons.array[button_index].ended_down;
                        }

                        try win32_process_pending_messages(new_keyboard_controller);

                        // TODO: Need to not poll disconnected controllers
                        // to avoid xinput frame ratre hit on older libraries
                        // TODO: should we poll this more frequently?
                        var max_controller_count = win32.XUSER_MAX_COUNT;
                        if (max_controller_count > new_input.controllers.len - 1) {
                            max_controller_count = new_input.controllers.len - 1;
                        }

                        // NOTE: Indices 1..4 belong to gamepad
                        for (0..max_controller_count) |controller_index| {
                            var our_index = controller_index + 1;
                            var old_controller: *zigmade.GameControllerInput =
                                try zigmade.get_controller(old_input, our_index);
                            var new_controller: *zigmade.GameControllerInput =
                                try zigmade.get_controller(new_input, our_index);
                            var controller_state: win32.XINPUT_STATE = undefined;

                            if (XInputGetState.call(
                                @as(u32, @intCast(controller_index)),
                                &controller_state,
                            ) == @intFromEnum(win32.ERROR_SUCCESS)) {
                                new_controller.is_connected = true;

                                // NOTE: Controller is plugged in
                                // TODO: See if controller_state.dwPacketNumber increments too quickly
                                var pad: *win32.XINPUT_GAMEPAD = &controller_state.Gamepad;

                                // TODO: This is a square deadzone, check XInput to
                                // verify that the deadzone is round and show how to do
                                // round deadzone processing
                                new_controller.stick_average_x = try win32_process_x_input_stick_value(
                                    pad.sThumbLX,
                                    win32.XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE,
                                );
                                new_controller.stick_average_y = try win32_process_x_input_stick_value(
                                    pad.sThumbLY,
                                    win32.XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE,
                                );

                                if ((new_controller.stick_average_x != 0.0) or
                                    (new_controller.stick_average_y != 0.0))
                                {
                                    new_controller.is_analog = true;
                                }

                                if ((pad.wButtons & win32.XINPUT_GAMEPAD_DPAD_UP) > 0) {
                                    new_controller.stick_average_y = 1.0;
                                    new_controller.is_analog = false;
                                }

                                if ((pad.wButtons & win32.XINPUT_GAMEPAD_DPAD_DOWN) > 0) {
                                    new_controller.stick_average_y = -1.0;
                                    new_controller.is_analog = false;
                                }

                                if ((pad.wButtons & win32.XINPUT_GAMEPAD_DPAD_LEFT) > 0) {
                                    new_controller.stick_average_x = -1.0;
                                    new_controller.is_analog = false;
                                }

                                if ((pad.wButtons & win32.XINPUT_GAMEPAD_DPAD_RIGHT) > 0) {
                                    new_controller.stick_average_x = 1.0;
                                    new_controller.is_analog = false;
                                }

                                var threshold: f32 = 0.5;
                                try win32_process_x_input_digital_button(
                                    if (new_controller.stick_average_x < -threshold)
                                        1
                                    else
                                        0,
                                    &old_controller.buttons.map.move_left,
                                    &new_controller.buttons.map.move_left,
                                    1,
                                );
                                try win32_process_x_input_digital_button(
                                    if (new_controller.stick_average_x > threshold)
                                        1
                                    else
                                        0,
                                    &old_controller.buttons.map.move_right,
                                    &new_controller.buttons.map.move_right,
                                    1,
                                );
                                try win32_process_x_input_digital_button(
                                    if (new_controller.stick_average_y < -threshold)
                                        1
                                    else
                                        0,
                                    &old_controller.buttons.map.move_down,
                                    &new_controller.buttons.map.move_down,
                                    1,
                                );
                                try win32_process_x_input_digital_button(
                                    if (new_controller.stick_average_y > threshold)
                                        1
                                    else
                                        0,
                                    &old_controller.buttons.map.move_up,
                                    &new_controller.buttons.map.move_up,
                                    1,
                                );

                                try win32_process_x_input_digital_button(
                                    pad.wButtons,
                                    &old_controller.buttons.map.action_down,
                                    &new_controller.buttons.map.action_down,
                                    win32.XINPUT_GAMEPAD_A,
                                );
                                try win32_process_x_input_digital_button(
                                    pad.wButtons,
                                    &old_controller.buttons.map.action_right,
                                    &new_controller.buttons.map.action_right,
                                    win32.XINPUT_GAMEPAD_B,
                                );
                                try win32_process_x_input_digital_button(
                                    pad.wButtons,
                                    &old_controller.buttons.map.action_left,
                                    &new_controller.buttons.map.action_left,
                                    win32.XINPUT_GAMEPAD_X,
                                );
                                try win32_process_x_input_digital_button(
                                    pad.wButtons,
                                    &old_controller.buttons.map.action_up,
                                    &new_controller.buttons.map.action_up,
                                    win32.XINPUT_GAMEPAD_Y,
                                );
                                try win32_process_x_input_digital_button(
                                    pad.wButtons,
                                    &old_controller.buttons.map.left_shoulder,
                                    &new_controller.buttons.map.left_shoulder,
                                    win32.XINPUT_GAMEPAD_LEFT_SHOULDER,
                                );
                                try win32_process_x_input_digital_button(
                                    pad.wButtons,
                                    &old_controller.buttons.map.right_shoulder,
                                    &new_controller.buttons.map.right_shoulder,
                                    win32.XINPUT_GAMEPAD_RIGHT_SHOULDER,
                                );
                                try win32_process_x_input_digital_button(
                                    pad.wButtons,
                                    &old_controller.buttons.map.start,
                                    &new_controller.buttons.map.start,
                                    win32.XINPUT_GAMEPAD_START,
                                );
                                try win32_process_x_input_digital_button(
                                    pad.wButtons,
                                    &old_controller.buttons.map.back,
                                    &new_controller.buttons.map.back,
                                    win32.XINPUT_GAMEPAD_BACK,
                                );

                                // var start = pad.wButtons & win32.XINPUT_GAMEPAD_START;
                                // var back = pad.wButtons & win32.XINPUT_GAMEPAD_BACK;
                            } else {
                                // NOTE: Controller is unavailable
                                new_controller.is_connected = false;
                            }
                        }

                        // var vibration: win32.XINPUT_VIBRATION = undefined;
                        // vibration.wLeftMotorSpeed = 60000;
                        // vibration.wRightMotorSpeed = 60000;
                        // _ = XInputSetState.call(0, &vibration);

                        // TODO: Make sure this is guarded entirely
                        var byte_to_lock: u32 = 0;
                        var target_cursor: u32 = 0;
                        var bytes_to_write: u32 = 0;
                        var play_cursor: u32 = 0;
                        var write_cursor: u32 = 0;
                        var sound_is_valid = false;

                        // TODO: tighten up sound logic so that we know where we should be writing
                        // to and can anticipate time spent in game update
                        // NOTE: Sounds skips on every new loop of the buffer (1 second), so the sine
                        // wave is not properly lining up on either side of the buffer similar to
                        // the bug Casey observed in episode 9
                        if (win32.SUCCEEDED(global_secondary_buffer.vtable.GetCurrentPosition(
                            global_secondary_buffer,
                            &play_cursor,
                            &write_cursor,
                        ))) {
                            // The remainder of the division of the # of bytes per sample
                            // divided by the entire buffer size tells us which byte to lock
                            // for continuing to write
                            byte_to_lock =
                                (sound_output.running_sample_index *
                                @as(u32, @intCast(sound_output.bytes_per_sample))) %
                                @as(u32, @intCast(sound_output.secondary_buffer_size));

                            // The target cursor is the remainder of the distance from the
                            // play cursor + total bytes divided by the entire buffer size
                            target_cursor =
                                (play_cursor +
                                (@as(u32, @intCast(sound_output.latency_sample_count)) *
                                @as(u32, @intCast(sound_output.bytes_per_sample)))) %
                                @as(u32, @intCast(sound_output.secondary_buffer_size));

                            if (byte_to_lock > target_cursor) {
                                bytes_to_write = @as(
                                    u32,
                                    @intCast(sound_output.secondary_buffer_size),
                                ) - byte_to_lock;
                                bytes_to_write += target_cursor;
                            } else {
                                bytes_to_write = target_cursor - byte_to_lock;
                            }

                            sound_is_valid = true;
                        }

                        // TODO: Sound is wrong now, because we haven't updated it
                        // to go with the new frame loop
                        var sound_buffer: zigmade.GameSoundBuffer =
                            std.mem.zeroInit(zigmade.GameSoundBuffer, .{});
                        sound_buffer.samples_per_second = sound_output.samples_per_second;
                        sound_buffer.sample_count = @divTrunc(
                            @as(i32, @intCast(bytes_to_write)),
                            sound_output.bytes_per_sample,
                        );
                        sound_buffer.samples = @alignCast(@ptrCast(samples));

                        var offscreen_buffer: zigmade.GameOffscreenBuffer =
                            std.mem.zeroInit(zigmade.GameOffscreenBuffer, .{});
                        offscreen_buffer.width = global_back_buffer.width;
                        offscreen_buffer.height = global_back_buffer.height;
                        offscreen_buffer.pitch = global_back_buffer.pitch;
                        offscreen_buffer.memory = @as(
                            ?*void,
                            @alignCast(@ptrCast(global_back_buffer.memory)),
                        );

                        try zigmade.game_update_and_render(
                            &win32_platform,
                            &game_memory,
                            new_input,
                            &offscreen_buffer,
                            &sound_buffer,
                        );

                        if (sound_is_valid) {
                            try win32_fill_sound_buffer(
                                &sound_output,
                                byte_to_lock,
                                bytes_to_write,
                                &sound_buffer,
                            );
                        }

                        var work_counter = try win32_get_wall_clock();
                        var work_seconds_elapsed = try win32_get_seconds_elapsed(
                            last_counter,
                            work_counter,
                        );

                        var seconds_elapsed_for_frame = work_seconds_elapsed;

                        // TODO: Not tested yet, probably buggy
                        if (seconds_elapsed_for_frame < target_seconds_per_frame) {
                            if (sleep_is_granular) {
                                var sleep_ms = @as(u32, @intFromFloat(1000.0 *
                                    (target_seconds_per_frame -
                                    seconds_elapsed_for_frame) -
                                    1.0));

                                if (sleep_ms > 0) {
                                    win32.Sleep(sleep_ms);
                                }
                            }

                            var test_seconds_elapsed_for_frame = try win32_get_seconds_elapsed(
                                last_counter,
                                try win32_get_wall_clock(),
                            );

                            std.debug.assert(test_seconds_elapsed_for_frame < target_seconds_per_frame);

                            while (seconds_elapsed_for_frame < target_seconds_per_frame) {
                                seconds_elapsed_for_frame = try win32_get_seconds_elapsed(
                                    last_counter,
                                    try win32_get_wall_clock(),
                                );
                            }
                        } else {
                            // TODO: Missed framerate
                            // TODO: logging
                        }

                        var dimension = try win32_get_window_dimension(window);

                        try win32_display_buffer_in_window(
                            &global_back_buffer,
                            device_context,
                            dimension.width,
                            dimension.height,
                        );

                        var temp = new_input;
                        new_input = old_input;
                        old_input = temp;
                        // TODO: should we clear these here?

                        var end_counter = try win32_get_wall_clock();
                        var ms_per_frame = 1000.0 * try win32_get_seconds_elapsed(
                            last_counter,
                            end_counter,
                        );

                        last_counter = end_counter;

                        var end_cycle_count = rdtsc();
                        var cycles_elapsed = end_cycle_count - last_cycle_count;
                        last_cycle_count = end_cycle_count;

                        if (DEBUG_WALL_CLOCK) {
                            var fps: f32 = 0.0;
                            //var fps = @as(f32, @floatFromInt(global_perf_count_frequency)) /
                            //    @as(f64, (@floatFromInt(counter_elapsed)));
                            var mega_cycles_per_frame = @as(f64, @floatFromInt(cycles_elapsed)) /
                                @as(f64, @floatFromInt(1000 * 1000));

                            // Trying to print floats with wsprintf does not appear to cause a problem
                            // Including sprintf perhaps not worth it since we can only see messages from
                            // std.debug.print() anyways
                            // Leaving this code here for posterity
                            var fps_buffer = [_]u8{0} ** 255;
                            var args = [_]f64{ ms_per_frame, fps, mega_cycles_per_frame };
                            _ = win32.wvsprintfA(
                                @as([*:0]u8, @ptrCast(&fps_buffer)),
                                ",%fms/f, %ff/s, %fmc/f\n",
                                @as(*i8, @ptrCast(&args)),
                            );
                            win32.OutputDebugStringA(@as(
                                [*:0]u8,
                                @ptrCast(&fps_buffer),
                            ));

                            std.debug.print("{d:6.2}ms/f, {d:6.2}f/s, {d:6.2}mc/f\n", .{
                                ms_per_frame,
                                fps,
                                mega_cycles_per_frame,
                            });
                        }
                    }
                } else {
                    // TODO: logging
                }
            } else {
                // TODO: logging
            }
        } else {
            // TODO: logging
        }
    } else {
        // TODO: logging
    }

    return (0);
}
