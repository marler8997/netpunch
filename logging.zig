const std = @import("std");

pub fn logTimestamp() void {
    std.debug.print("{}: ", .{std.time.milliTimestamp()});
}
pub fn log(comptime fmt: []const u8, args: anytype) void {
    logTimestamp();
    std.debug.print(fmt ++ "\n", args);
}
