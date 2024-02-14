const std = @import("std");
const Builder = std.build.Builder;
const Step = std.build.Step;
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //addTool(b, target, optimize, "config-server", "config-server.zig");
    //addTool(b, target, optimize, "reverse-tunnel-client", "reverse-tunnel-client.zig");
    addTool(b, target, optimize, "double-server", "double-server.zig");
    addTool(b, target, optimize, "punch-client-forwarder", "punch-client-forwarder.zig");
    addTool(b, target, optimize, "punch-server-initiator", "punch-server-initiator.zig");
    addTool(b, target, optimize, "nc", "nc.zig");
    addTool(b, target, optimize, "socat", "socat.zig");
    addTool(b, target, optimize, "restarter", "restarter.zig");
}

fn addTool(
    b: *Builder,
    target: CrossTarget,
    optimize: std.builtin.Mode,
    comptime name: []const u8,
    src: []const u8,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = .{ .path = src },
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);
    b.step(name, "").dependOn(&install.step);

    const run_cmd = b.addRunArtifact(exe);
    b.step("run-" ++ name, "").dependOn(&run_cmd.step);
}
