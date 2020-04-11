const std = @import("std");
const mem = std.mem;
const os = std.os;

const logging = @import("./logging.zig");
const timing = @import("./timing.zig");

const ChildProcess = std.ChildProcess;
const log = logging.log;

fn makeThrottler(logPrefix: []const u8) timing.Throttler {
    return (timing.makeThrottler {
        .logPrefix = logPrefix,
        .desiredSleepMillis = 10000,
        .slowRateMillis = 500,
    }).create();
}

const global = struct {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
};

fn usage() void {
    std.debug.warn("Usage: restarter PROGRAM ARGS\n", .{});
}

pub fn main() anyerror!u8 {
    var args = try std.process.argsAlloc(&global.arena.allocator);
    if (args.len <= 1) {
        usage();
        return 1;
    }
    args = args[1..];

    var throttler = makeThrottler("[restarter] throttle: ");
    while (true) {
        throttler.throttle();
        logging.logTimestamp();
        std.debug.warn("[restarter] starting: ", .{});
        printArgs(args);
        std.debug.warn("\n", .{});
        // TODO: is there a way to use an allocator that can free?
        var proc = try std.ChildProcess.init(args, &global.arena.allocator);
        defer proc.deinit();
        try proc.spawn();
        try waitForChild(proc);
    }
}

fn printArgs(argv: []const []const u8) void {
    var prefix : []const u8 = "";
    for (argv) |arg| {
        std.debug.warn("{}'{}'", .{prefix, arg});
        prefix = " ";
    }
}

fn waitForChild(proc: *ChildProcess) !void {
    // prottect from printing signals too fast
    var signalThrottler = (timing.makeThrottler {
        .logPrefix = "[restarter] signal throttler: ",
        .desiredSleepMillis = 10000,
        .slowRateMillis = 100,
    }).create();
    while (true) {
        signalThrottler.throttle();
        switch (try proc.spawnAndWait()) {
            .Exited => |code| {
                log("[restarter] child process exited with {}", .{code});
                return;
            },
            .Stopped => |sig| log("[restarter] child process has stopped ({})", .{sig}),
            .Signal => |sig| log("[restarter] child process signal ({})", .{sig}),
            .Unknown => |sig| log("[restarter] child process unknown ({})", .{sig}),
        }
    }
}