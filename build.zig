const std = @import("std");
const Builder = std.build.Builder;
const Step = std.build.Step;
const CrossTarget = std.zig.CrossTarget;
const Mode = std.builtin.Mode;

fn addTool(b: *Builder, run_step: *Step, target: CrossTarget, mode: Mode,
    name: []const u8, src: []const u8) void {

    const exe = b.addExecutable(name, src);
    exe.single_threaded = true;
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    run_step.dependOn(&run_cmd.step);
}

pub fn build(b: *Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const run_step = b.step("run", "Run the app");
    //addTool(b, run_step, target, mode, "config-server", "config-server.zig");
    //addTool(b, run_step, target, mode, "reverse-tunnel-client", "reverse-tunnel-client.zig");
    addTool(b, run_step, target, mode, "double-server", "double-server.zig");
    addTool(b, run_step, target, mode, "punch-client-forwarder", "punch-client-forwarder.zig");
    addTool(b, run_step, target, mode, "punch-server-initiator", "punch-server-initiator.zig");
    addTool(b, run_step, target, mode, "nc", "nc.zig");
    addTool(b, run_step, target, mode, "restarter", "restarter.zig");
}
