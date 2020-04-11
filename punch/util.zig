const std = @import("std");
const os = std.os;

const logging = @import("../logging.zig");
const common = @import("../common.zig");
const timing = @import("../timing.zig");
const punch = @import("../punch.zig");
const proto = punch.proto;
const netext = @import("../netext.zig");

const assert = std.debug.assert;
const fd_t = os.fd_t;
const log = logging.log;
const Timestamp = timing.Timestamp;
const Timer = timing.Timer;

pub fn doHandshake(punchFd: fd_t, myRole: proto.Role, recvTimeoutMillis: u32) !void {
    var expectRole : punch.proto.Role = undefined;
    var handshakeToSend : []const u8 = undefined;
    switch (myRole) {
        .initiator => {
            expectRole = .forwarder;
            handshakeToSend = &punch.proto.initiatorHandshake;
        },
        .forwarder => {
            expectRole = .initiator;
            handshakeToSend = &punch.proto.forwarderHandshake;
        },
    }

    netext.send(punchFd, handshakeToSend, 0) catch |e| switch (e) {
        error.Disconnected,error.Retry => {
            log("failed to send punch handshake", .{});
            return error.PunchSocketDisconnect;
        },
    };

    var handshake: [punch.proto.magic.len + 1]u8 = undefined;
    const gotHandshake = netext.recvfullTimeout(punchFd, &handshake, recvTimeoutMillis) catch |e| switch (e) {
        error.Disconnected,error.Retry => {
            log("failed to receive punch handshake", .{});
            return error.PunchSocketDisconnect;
        },
    };
    if (!gotHandshake) {
        log("timed out waiting for punch handshake", .{});
        return error.BadPunchHandshake;
    }
    const magic = handshake[0..punch.proto.magic.len];
    if (!std.mem.eql(u8, magic, &punch.proto.magic)) {
        log("got punch connection but received invalid magic value {x}", .{magic});
        return error.BadPunchHandshake;
    }
    const role = handshake[punch.proto.magic.len];
    if (role != @enumToInt(expectRole)) {
        log("received punch role {} but expected {} ({})", .{role, expectRole, @enumToInt(expectRole)});
        return error.BadPunchHandshake;
    }
}

pub fn serviceHeartbeat(punchFd: fd_t, heartbeatTimer: *Timer, verboseHeartbeats: bool) !u32 {
    switch (heartbeatTimer.check()) {
        .Expired => {
            if (verboseHeartbeats) {
                log("[VERBOSE] sending heartbeat...", .{});
            }
            punch.util.sendHeartbeat(punchFd) catch |e| switch (e) {
                error.Disconnected, error.Retry => return error.PunchSocketDisconnect,
            };
            return heartbeatTimer.durationMillis;
        },
        .Wait => |millis| return millis,
    }
}

pub fn sendHeartbeat(punchFd: fd_t) !void {
    const msg = [1]u8 {proto.TwoWayMessage.Heartbeat};
    try netext.send(punchFd, &msg, 0);
}
pub fn sendCloseTunnel(punchFd: fd_t) !void {
    const msg = [1]u8 {proto.TwoWayMessage.CloseTunnel};
    try netext.send(punchFd, &msg, 0);
}
pub fn sendOpenTunnel(punchFd: fd_t) !void {
    const msg = [1]u8 {proto.InitiatorMessage.OpenTunnel};
    try netext.send(punchFd, &msg, 0);
}

pub fn waitForCloseTunnel(punchFd: fd_t, punchRecvState: *PunchRecvState, buffer: []u8, timeoutMillis: i32) !void {
    var failedAttempts : u16 = 0;
    const maxFailedAttempts = 5;
    while (true) {
        if (failedAttempts >= maxFailedAttempts) {
            log("failed to read from punch socket after {} attempts", .{failedAttempts});
            return error.PunchSocketDisconnect;
        }
        const isReadable = common.waitReadableTimeout(punchFd, timeoutMillis) catch |e| switch (e) {
            error.Retry => {
                failedAttempts += 1;
                continue;
            },
        };
        if (!isReadable)
            return error.PunchSocketDisconnect;

        const len = netext.read(punchFd, buffer) catch |e| switch (e) {
            error.Retry => {
                failedAttempts += 1;
                continue;
            },
            error.Disconnected => return error.PunchSocketDisconnect,
        };
        if (len == 0) {
            log("punch socket disconnected (read returned 0)", .{});
            return error.PunchSocketDisconnect;
        }
        var data = buffer[0..len];
        while (data.len > 0) {
            const action = punch.util.parsePunchToNextAction(punchRecvState, &data) catch |e| switch (e) {
                error.InvalidPunchMessage => {
                    log("received unexpected punch message {}", .{data[0]});
                    return error.PunchSocketDisconnect;
                },
            };
            switch (action) {
                .None => {
                    std.debug.assert(data.len == 0);
                    break;
                },
                .OpenTunnel => {
                    log("WARNING: received OpenTunnel message when a tunnel is already open", .{});
                    return error.PunchSocketDisconnect;
                },
                .CloseTunnel => {
                    log("received CloseTunnel message", .{});
                    return;
                },
                .ForwardData => |forwardAction| {
                    log("ignore {} bytes of forwarding data", .{forwardAction.data.len});
                },
            }
        }
    }
}
pub fn closeTunnel(punchFd: fd_t, punchRecvState: *PunchRecvState, gotCloseTunnel: *bool, buffer: []u8) !void {
    log("sending CloseTunnel...", .{});
    punch.util.sendCloseTunnel(punchFd) catch |e| switch (e) {
        error.Disconnected, error.Retry => return error.PunchSocketDisconnect,
    };
    if (!gotCloseTunnel.*) {
        punch.util.waitForCloseTunnel(punchFd, punchRecvState, buffer, 8000) catch |e| switch (e) {
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
        };
        gotCloseTunnel.* = true;
    }
}

pub fn forwardRawToPunch(rawFd: fd_t, punchFd: fd_t, buffer: []u8) !void {
    // NOTE: can't use the sendfile syscall because I need to
    //       convert raw data to the punch-data packets
    //       I could make this work if I opened a new raw connection instead
    //       of sending data through the punch protocol
    //       But the punch protocol isn't meant for alot of data, it's meant
    //       to facilate things like manual SSH session to start other sessions.

    // receive at an offset to save room for the punch data command prefix
    // offset 64 to give the best chance for aligned data copy
    const length = netext.read(rawFd, buffer[64..]) catch |e| switch (e) {
        error.Disconnected, error.Retry => {
            log("s={} read on raw socket failed", .{rawFd});
            common.shutdown(rawFd) catch {};
            return error.RawSocketDisconnect;
        },
    };
    if (length == 0) {
        log("s={} raw socket disconnected (read returned 0)", .{rawFd});
        return error.RawSocketDisconnect;
    }

    buffer[55] = proto.TwoWayMessage.Data;
    // std.mem.writeIntSliceBig doesn't seem to be working
    //std.mem.writeIntSliceBig(u64, buffer[56..], length);
    writeU64Big(buffer[56..].ptr, length);
    log("[VERBOSE] fowarding {} bytes to punch socket...", .{length});
    netext.send(punchFd, buffer[55.. 64 + length], 0) catch |e| switch (e) {
        error.Disconnected, error.Retry => {
            log("s={} send failed on punch socket", .{punchFd});
            return error.PunchSocketDisconnect;
        },
    };
}

fn writeU64Big(buf: [*]u8, value: u64) void {
    buf[0] = @truncate(u8, value >> 56);
    buf[1] = @truncate(u8, value >> 48);
    buf[2] = @truncate(u8, value >> 40);
    buf[3] = @truncate(u8, value >> 32);
    buf[4] = @truncate(u8, value >> 24);
    buf[5] = @truncate(u8, value >> 16);
    buf[6] = @truncate(u8, value >>  8);
    buf[7] = @truncate(u8, value >>  0);
}

pub const PunchRecvState = union(enum) {
    Initial: void,
    Data: Data,

    pub const Data = struct {
        lenBytesLeft: u8,
        dataLeft: u64,
    };
};
// tells the caller what to do
const PunchAction = union(enum) {
    None: void,
    OpenTunnel: void,
    CloseTunnel: void,
    ForwardData: ForwardData,

    pub const ForwardData = struct {
        data: []const u8,
    };
};

pub fn parsePunchToNextAction(state: *PunchRecvState, data: *[]const u8) !PunchAction {
    assert(data.*.len > 0);
    //std.debug.warn("[DEBUG] parsing {}-bytes...\n", .{data.*.len});
    while (true) {
        switch (try parsePunchMessage(state, data)) {
            .None => if (data.*.len == 0) return PunchAction.None,
            else => |action| return action,
        }
    }
}

fn parsePunchMessage(state: *PunchRecvState, data: *[]const u8) !PunchAction {
    switch (state.*) {
        .Initial => {
            const msgType = data.*[0];
            data.* = data.*[1..];
            if (msgType == proto.TwoWayMessage.Heartbeat)
                return PunchAction.None;
            if (msgType == proto.TwoWayMessage.CloseTunnel)
                return PunchAction.CloseTunnel;
            if (msgType == proto.InitiatorMessage.OpenTunnel)
                return PunchAction.OpenTunnel;
            if (msgType == proto.TwoWayMessage.Data) {
                state.* = PunchRecvState { .Data = .{
                    .lenBytesLeft = 8,
                    .dataLeft = 0,
                }};
                return try parsePunchDataMessage(state, data);
            }
            // rewind data so caller can see the invalid byte
            data.* = (data.ptr - 1)[0 .. data.*.len + 1];
            return error.InvalidPunchMessage;
        },
        .Data => return try parsePunchDataMessage(state, data),
    }
}

fn parsePunchDataMessage(state: *PunchRecvState, data: *[]const u8) !PunchAction {
    switch (state.*) { .Data=>{}, else => assert(false), }

    while (state.Data.lenBytesLeft > 0) : (state.Data.lenBytesLeft -= 1) {
        if (data.*.len == 0)
            return PunchAction.None;

        state.Data.dataLeft <<= 8;
        state.Data.dataLeft |= data.*[0];
        data.* = data.*[1..];
    }
    if (state.Data.dataLeft == 0) {
        state.* = PunchRecvState.Initial;
        return PunchAction.None;
    }
    if (data.*.len == 0)
        return PunchAction.None;
    if (data.*.len >= state.Data.dataLeft) {
        var forwardData = data.*[0..state.Data.dataLeft];
        data.* = data.*[state.Data.dataLeft..];
        state.* = PunchRecvState.Initial;
        return PunchAction { .ForwardData = .{ .data = forwardData } };
    }
    state.Data.dataLeft -= data.*.len;
    var forwardData = data.*;
    data.* = data.*[data.*.len..];
    return PunchAction { .ForwardData = .{ .data = forwardData } };
}


const ParserTest = struct {
    data: []const u8,
    actions: []const PunchAction,
};

fn testParser(t: *const ParserTest, chunkLen: usize) !void {
    var expectedActionIndex : usize = 0;
    var expectedForwardDataOffset : usize = 0;
    var state : PunchRecvState = PunchRecvState.Initial;
    var data = t.data;
    while (data.len > 0) {
        const nextLen = if (data.len < chunkLen)
            data.len else chunkLen;
        var nextChunk = data[0..nextLen];
        const action = try parsePunchToNextAction(&state, &nextChunk);
        std.debug.warn("action {}\n", .{action});
        switch (action) {
            .None => std.debug.assert(nextChunk.len == 0),
            .OpenTunnel => {
                switch (t.actions[expectedActionIndex]) {
                    .OpenTunnel => {},
                    else => std.debug.assert(false),
                }
                expectedActionIndex += 1;
            },
            .CloseTunnel => {
                switch (t.actions[expectedActionIndex]) {
                    .CloseTunnel => {},
                    else => std.debug.assert(false),
                }
                expectedActionIndex += 1;
            },
            .ForwardData => |actualForward| {
                std.debug.assert(actualForward.data.len > 0);
                switch (t.actions[expectedActionIndex]) {
                    .ForwardData => |expectedForward| {
                        const expected = expectedForward.data[expectedForwardDataOffset..];
                        //std.debug.warn("[DEBUG] verifying {} bytes {x}\n", .{actualForward.data.len, actualForward.data});
                        std.debug.assert(std.mem.startsWith(u8, expected, actualForward.data));
                        expectedForwardDataOffset += actualForward.data.len;
                        if (expectedForwardDataOffset == expectedForward.data.len) {
                            expectedActionIndex += 1;
                            expectedForwardDataOffset = 0;
                        }
                    },
                    else => std.debug.assert(false),
                }
            },
        }
        std.debug.assert(nextLen > nextChunk.len);
        data = data[nextLen - nextChunk.len..];
    }
    std.debug.assert(expectedActionIndex == t.actions.len);
}

test "parsePunchMessage" {
    const tests = [_]ParserTest {
        ParserTest {
            .data = &[_]u8 {
                proto.TwoWayMessage.Heartbeat,
                proto.InitiatorMessage.OpenTunnel,
                proto.TwoWayMessage.Heartbeat,
                proto.TwoWayMessage.Heartbeat,
                proto.TwoWayMessage.CloseTunnel,
                proto.TwoWayMessage.Heartbeat,
                proto.TwoWayMessage.Heartbeat,
            },
            .actions = &[_]PunchAction {
                PunchAction.OpenTunnel,
                PunchAction.CloseTunnel,
            },
        },
        ParserTest {
            .data = &[_]u8 {
                proto.TwoWayMessage.Heartbeat,
                proto.TwoWayMessage.Heartbeat,
                proto.TwoWayMessage.Data,
                0,0,0,0,0,0,0,0,
                proto.TwoWayMessage.Heartbeat,
                proto.TwoWayMessage.Data,
                0,0,0,0,0,0,0,1,
                0xac,
                proto.TwoWayMessage.Data,
                0,0,0,0,0,0,0,0,
                proto.TwoWayMessage.Heartbeat,
                proto.TwoWayMessage.Data,
                0,0,0,0,0,0,0,10,
                0x12,0x34,0x45,0x67,0x89,0xab,0xcd,0xef,0x0a,0xf4,
            },
            .actions = &[_]PunchAction {
                PunchAction { .ForwardData = .{ .data = &[_]u8{0xac} }},
                PunchAction { .ForwardData = .{ .data = &[_]u8{0x12,0x34,0x45,0x67,0x89,0xab,0xcd,0xef,0x0a,0xf4} }},
            },
        },
    };
    for (tests) |t| {
        var i : usize = 1;
        while (i <= t.data.len) : (i += 1) {
            try testParser(&t, i);
        }
    }

    {
        var state : PunchRecvState = PunchRecvState.Initial;
        {
            var data = ([_]u8 {proto.TwoWayMessage.Heartbeat})[0..];
            switch (try parsePunchMessage(&state, &data)) {
                .None => {},
                else => assert(false),
            }
            assert(data.len == 0);
        }
        {
            var data = ([_]u8 {proto.TwoWayMessage.CloseTunnel})[0..];
            switch (try parsePunchMessage(&state, &data)) {
                .CloseTunnel => {},
                else => assert(false),
            }
            assert(data.len == 0);
        }
        {
            var data = ([_]u8 {proto.InitiatorMessage.OpenTunnel})[0..];
            switch (try parsePunchMessage(&state, &data)) {
                .OpenTunnel => {},
                else => assert(false),
            }
            assert(data.len == 0);
        }
        blk: {
            var data = ([_]u8 {10})[0..];
            _ = parsePunchMessage(&state, &data) catch |e| {
                assert(e == error.InvalidPunchMessage);
                break :blk;
            };
            assert(false);
        }
        {
            var data = ([_]u8 {proto.TwoWayMessage.Data,0,0,0,0,0,0,0,0})[0..];
            switch (try parsePunchMessage(&state, &data)) {
                .None => {},
                else => assert(false),
            }
            assert(data.len == 0);
        }
        {
            var data = ([_]u8 {proto.TwoWayMessage.Data,0,0,0,0,0,0,0,1,0xa3})[0..];
            switch (try parsePunchMessage(&state, &data)) {
                .ForwardData => |forwardData| assert(std.mem.eql(u8, &[_]u8 {0xa3}, forwardData.data)),
                else => assert(false),
            }
            assert(data.len == 0);
        }
    }
}
