const std = @import("std");
const mem = std.mem;
const os = std.os;
const net = std.net;

const logging = @import("./logging.zig");
const common = @import("./common.zig");
const timing = @import("./timing.zig");
const eventing = @import("./eventing.zig");
const pool = @import("./pool.zig");
const Pool = pool.Pool;

const log = logging.log;
const fd_t = os.fd_t;
const Address = net.Address;
const Timestamp = timing.Timestamp;
const Timers = timing.TimersTemplate(struct {});
const EventFlags = eventing.EventFlags;

const Eventer = eventing.EventerTemplate(anyerror, struct {
    timers: *Timers
}, struct {
    fd: fd_t,
    addr: Address,
    connectAttempt: u32,
    timer: ?Timers.Callback,
    connectionId: u32,
});

fn getField(comptime structInfo: std.builtin.TypeInfo.Struct, name: []const u8) ?std.builtin.TypeInfo.StructField {
    for (structInfo.fields) |field| {
       if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

fn timerToEventerCallback(callback: *Timers.Callback) *Eventer.Callback {
    const basePtr = @ptrCast(*Eventer.Callback,
        @ptrCast([*]u8, callback) - (
              @byteOffsetOf(Eventer.Callback, "data")
            + @byteOffsetOf(getField(@typeInfo(Eventer.Callback).Struct, "data").?.field_type, "timer")
            //+ @byteOffsetOf(?Timers.Callback, "?")
    ));
    std.debug.assert(&(basePtr.data.timer.?) == callback);
    return basePtr;
}

const global = struct {
    var eventer : Eventer = undefined;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var configServerCallback : Eventer.Callback = undefined;
    // one more than 256 because we are using a 1-byte length for now
    var configRecvBuf : [257]u8 = undefined;
    var configRecvLen : usize = 0;

    // TODO: change from 1 to something else
    var hostPool = Pool(Eventer.Callback, 1).init(&arena.allocator);
};

fn usage() void {
    log("Usage: reverse-tunnel-client CONFIG_SERVER", .{});
}
pub fn main() anyerror!u8 {
    const args = try std.process.argsAlloc(&global.arena.allocator);
    if (args.len <= 1) {
        usage();
        return 1;
    }
    args = args[1..];
    if (args.len != 1) {
        usage();
        return 1;
    }
    const configServerString = args[0];
    if (std.builtin.os.tag == .windows)
        @compileError("how do I make a socket non-blocking on windows?");

    var timers = Timers.init();
    global.eventer = try Eventer.init(.{
        .timers = &timers,
    });
    global.configServerCallback = .{
        .func = invalidCallback,
        .data = .{
            .fd = -1, // set to -1 for sanity checking
            .addr = Address.parseIp4(configServerString, 9281) catch |e| {
                log("Error: failed to parse '{}' as an IPv4 address: {}", .{configServerString, e});
                return 1;
            },
            .connectAttempt = 0,
            .timer = null,
            .connectionId = undefined, // unused here on config-server
        },
    };
    try startConnect(&global.eventer, &global.configServerCallback);
    while (true) {
        const optionalTimeout = try timers.handleEvents();
        if (optionalTimeout) |timeout| {
            const millis = timing.timestampToMillis(timeout);
            //log("timeoutMillis {}", .{timeoutMillis});
            _ = try global.eventer.handleEvents(@intCast(u32, millis));
        } else {
            _ = try global.eventer.handleEventsNoTimeout();
        }
    }
}

fn invalidCallback(eventer: *Eventer, callback: *Eventer.Callback) !void {
    return error.InvalidCallback;
}

// assumption: callback has not been added to eventer yet
fn startConnect(eventer: *Eventer, callback: *Eventer.Callback) !void {
    std.debug.assert(callback.func == invalidCallback);
    std.debug.assert(callback.data.fd == -1);
    std.debug.assert(callback.data.timer == null);
    callback.data.connectAttempt += 1;
    callback.data.fd = try os.socket(callback.data.addr.any.family, os.SOCK_STREAM | os.SOCK_NONBLOCK, os.IPPROTO_TCP);
    log("s={} connecting to {} (attempt {})", .{callback.data.fd, callback.data.addr, callback.data.connectAttempt});
    common.connect(callback.data.fd, &callback.data.addr) catch |e| {
        if (e == error.WouldBlock) {
            callback.func = onConnecting;
            try eventer.add(callback.data.fd, EventFlags.write, callback);
        } else {
            log("connect failed with {}, will retry", .{e});
            try startConnectTimer(eventer, callback);
        }
        return;
    };
    log("s={} connected to {} (immediately)...", .{callback.data.fd, callback.data.addr});
    if (callback == &global.configServerCallback) {
        callback.func = onConfigData;
        global.configRecvLen = 0;
    } else {
        callback.func = onHostData;
    }
    try eventer.add(callback.data.fd, EventFlags.read, callback);
}

fn startConnectTimer(eventer: *Eventer, callback :*Eventer.Callback) !void {
    std.debug.assert(callback.data.fd == -1);
    std.debug.assert(callback.data.timer == null);
    const delaySeconds : Timestamp = init: {
        if (callback.data.connectAttempt <= 10)
            break :init 1;
        if (callback.data.connectAttempt <= 30)
            break :init 5;
        break :init 15;
    };
    callback.data.timer = Timers.Callback.init(
        timing.getNowTimestamp() + timing.secondsToTimestamp(delaySeconds),
        finishConnectTimer, .{});
    try eventer.data.timers.add(&callback.data.timer.?);
}
fn finishConnectTimer(timers: *Timers, timerCallback: *Timers.Callback) !void {
    const eventCallback = timerToEventerCallback(timerCallback);
    std.debug.assert(eventCallback.data.fd == -1);
    std.debug.assert(eventCallback.data.timer != null);
    //log("[DEBUG] finishConnect s={} addr={}", .{eventCallback.data.fd, eventCallback.data.addr});
    eventCallback.data.timer = null; // for sanity checking
    try startConnect(&global.eventer, eventCallback);
}

fn reconnect(eventer: *Eventer, callback: *Eventer.Callback) !void {
    std.debug.assert(callback.data.fd != -1);

    eventer.remove(callback.data.fd);
    os.close(callback.data.fd);
    if (callback.func != onConnecting)
        callback.data.connectAttempt = 0;
    callback.data.fd = -1; // used for sanity checking
    callback.func = invalidCallback; // used for sanity checking
    try startConnectTimer(eventer, callback);
}

fn onConnecting(eventer: *Eventer, callback: *Eventer.Callback) anyerror!void {
    std.debug.assert(callback.data.fd != -1);
    std.debug.assert(callback.data.timer == null);

    const sockError = try common.getsockerror(callback.data.fd);
    if (sockError != 0) {
        log("s={} socket error {}", .{callback.data.fd, sockError});
        try reconnect(eventer, callback);
        return;
    }
    log("s={} connected to {} (attempt {})", .{callback.data.fd, callback.data.addr, callback.data.connectAttempt});
    if (callback == &global.configServerCallback) {
        callback.func = onConfigData;
        global.configRecvLen = 0;
    } else {
        callback.func = onHostData;
    }
    try eventer.modify(callback.data.fd, EventFlags.read, callback);
}

fn onConfigData(eventer: *Eventer, callback: *Eventer.Callback) anyerror!void {
    std.debug.assert(callback == &global.configServerCallback);
    std.debug.assert(callback.data.fd != -1);
    std.debug.assert(callback.data.timer == null);

    if (global.configRecvLen == global.configRecvBuf.len) {
        log("s={} no more room left ({}) in config recv buffer", .{callback.data.fd, global.configRecvLen});
        try reconnect(eventer, callback);
        return;
    }
    const len = os.read(callback.data.fd, global.configRecvBuf[global.configRecvLen..]) catch |e| {
        log("s={} read on config-server failed: {}", .{callback.data.fd, e});
        try reconnect(eventer, callback);
        return;
    };
    if (len == 0) {
        log("s={} config-server closed connection (read returned 0)", .{callback.data.fd});
        try reconnect(eventer, callback);
        return;
    }
    log("s={} got {} bytes from config-server", .{callback.data.fd, len});
    global.configRecvLen += len;
    handleConfigMessages() catch |e| {
        if (e == error.InvalidMessage) {
            // error already logged
            try reconnect(eventer, callback);
            return;
        }
        return e;
    };
}
fn onHostData(eventer: *Eventer, callback: *Eventer.Callback) anyerror!void {
    return error.NotImplemented;
}

fn handleConfigMessages() !void {
    var next : usize = 0;
    while (true) {
        if (next >= global.configRecvLen)
            break; // need more data
        const msgLen = global.configRecvBuf[next];
        const msgOff = next + 1;
        const msgLimit = msgOff + msgLen;
        if (msgLimit > global.configRecvLen)
            break; // need more data
        try handleConfigMessage(global.configRecvBuf[msgOff..msgLimit]);
        next = msgLimit;
    }
    // shift everything to the left
    if (next > 0) {
        global.configRecvLen = global.configRecvLen - next;
        memcpyLowToHigh(&global.configRecvBuf, &global.configRecvBuf + next, global.configRecvLen);
    }
}

fn bigEndianDeserializeU32(ptr: [*]const u8) u32 {
    return
        @intCast(u32, ptr[0]) << 24 |
        @intCast(u32, ptr[1]) << 16 |
        @intCast(u32, ptr[2]) <<  8 |
        @intCast(u32, ptr[3]) <<  0 ;
}

fn handleConfigMessage(msg: []const u8) !void {
    if (msg.len == 0) {
        log("got heartbeat!", .{});
        return;
    }
    // add host
    if (msg[0] == 3) {
        if (msg.len != 11) {
            log("WARNING: msg 3 (add host) must be 7 bytes but got {}", .{msg.len});
            return error.InvalidMessage;
        }
        const connectionId = bigEndianDeserializeU32(msg.ptr + 1);
        var addrBytes : [4]u8 = undefined;
        const port : u16 = (@intCast(u16, msg[9]) << 8) | msg[10];
        mem.copy(u8, &addrBytes, msg[5..9]);
        const addr = Address.initIp4(addrBytes, port);
        try addHost(connectionId, &addr);
    } else {
        log("WARNING: unknown message type '{}'", .{msg[0]});
        return error.InvalidMessage;
    }
}



fn addHost(connectionId: u32, addr: *const Address) !void {
    {
        var range = global.hostPool.range();
        while (range.next()) |hostCallback| {
            if (hostCallback.data.connectionId == connectionId) {
                if (Address.eql(hostCallback.data.addr, addr.*)) {
                    log("host '{}' id {} already exists, s={}", .{addr, connectionId, hostCallback.data.fd});
                    return;
                }
                return error.notimpl;
            }
            log("[DEBUG] existing host s={} id={}", .{hostCallback.data.fd, hostCallback.data.connectionId});
        }
    }
    log("add host command for '{}'", .{addr});
    var newHost = try global.hostPool.create();
    errdefer global.hostPool.destroy(newHost);
    newHost.* = .{
        .func = invalidCallback,
        .data = .{
            .fd = -1, // set to -1 for sanity checking
            .addr = addr.*,
            .connectAttempt = 0,
            .timer = null,
            .connectionId = connectionId,
        },
    };
    try startConnect(&global.eventer, newHost);
}

// copy memory from src to dst, moving from low addresses to higher
fn memcpyLowToHigh(dst: [*]u8, src: [*]const u8, len: usize) void {
    var i : usize = 0;
    while (i < len) : (i += 1) {
        dst[i] = src[i];
    }
}
