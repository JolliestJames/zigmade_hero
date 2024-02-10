const std = @import("std");

const WINAPI = std.os.windows.WINAPI;
const DWORD = std.os.windows.DWORD;

const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").ui.windows_and_messaging;
};

pub export fn wWinMain(
    _: ?win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    _: [*:0]u16,
    _: u32,
) callconv(WINAPI) c_int {
    _ = win32.MessageBoxA(
        null,
        "This is Handmade Hero (in Zig).",
        "Handmade Hero",
        @enumFromInt(@intFromEnum(win32.MB_OK)|@intFromEnum(win32.MB_ICONINFORMATION)),
    );

    return (0);
}
