const std = @import("std");

pub fn log(comptime fmt: []const u8, args: var) void {
    std.debug.warn("{}: ", .{std.time.milliTimestamp()});
    std.debug.warn(fmt ++ "\n", args);
}
