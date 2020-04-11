const std = @import("std");
const mem = std.mem;
const os = std.os;
const net = std.net;

const logging = @import("./logging.zig");
const common = @import("./common.zig");
const netext = @import("./netext.zig");
const timing = @import("./timing.zig");
const eventing = @import("./eventing.zig");
const punch = @import("./punch.zig");
const proxy = @import("./proxy.zig");

const log = logging.log;
const fd_t = os.fd_t;
const Address = net.Address;
const delaySeconds = common.delaySeconds;
const Timestamp = timing.Timestamp;
const Timer = timing.Timer;
const EventFlags = eventing.EventFlags;
const PunchRecvState = punch.util.PunchRecvState;
const Proxy = proxy.Proxy;
const HostAndProxy = proxy.HostAndProxy;

const EventError = error {
    PunchSocketDisconnect,
    RawSocketDisconnect,
};
const Eventer = eventing.EventerTemplate(EventError, struct {
    punchFd: fd_t,
    rawFd: fd_t,
    punchRecvState: *PunchRecvState,
    gotCloseTunnel: *bool,
}, struct {
    fd: fd_t,
});

const global = struct {
    var ignoreSigaction : os.Sigaction = undefined;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var rawForwardAddr : Address = undefined;
    var buffer : [8192]u8 = undefined;
};


fn setupSignals() void {
    global.ignoreSigaction.sigaction = os.SIG_IGN;
    std.mem.set(u32, &global.ignoreSigaction.mask, 0);
    global.ignoreSigaction.flags = 0;
    os.sigaction(os.SIGPIPE, &global.ignoreSigaction, null);
}

fn usage() void {
    std.debug.warn("Usage: punch-client-forwarder PUNCH_SERVER PUNCH_PORT FORWARD_HOST FORWARD_PORT\n", .{});
    std.debug.warn("\n", .{});
    std.debug.warn("enable proxy with http://PROXY_HOST:PROXY_PORT/PUNCH_SERVER\n", .{});
}
pub fn main() anyerror!u8 {
    setupSignals();

    const args = try std.process.argsAlloc(&global.arena.allocator);
    if (args.len <= 1) {
        usage();
        return 1;
    }
    args = args[1..];
    if (args.len != 4) {
        usage();
        return 1;
    }
    const punchConnectSpec = args[0];
    const punchPort        = common.parsePort(args[1]) catch return 1;
    const rawForwardString = args[2];
    const rawForwardPort   = common.parsePort(args[3]) catch return 1;

    const punchHostAndProxy = proxy.parseProxy(punchConnectSpec) catch |e| {
        log("Error: invalid connect specifier '{}': {}", .{punchConnectSpec, e});
        return 1;
    };

    global.rawForwardAddr = common.parseIp4(rawForwardString, rawForwardPort) catch return 1;

    var connectThrottler = makeThrottler("connect throttler: ");
    while (true) {
        connectThrottler.throttle();
        switch (sequenceConnectToPunchClient(&punchHostAndProxy, punchPort)) {
            error.PunchSocketDisconnect => {},
        }
    }
}

fn makeThrottler(logPrefix: []const u8) timing.Throttler {
    return (timing.makeThrottler {
        .logPrefix = logPrefix,
        .desiredSleepMillis = 15000,
        .slowRateMillis = 500,
    }).create();
}

fn sequenceConnectToPunchClient(punchHostAndProxy: *const HostAndProxy, punchPort: u16) error {
    PunchSocketDisconnect,
} {
    log("connecting to punch server {}{}:{}...", .{punchHostAndProxy.proxy, punchHostAndProxy.host, punchPort});
    const punchFd = netext.proxyConnect(&punchHostAndProxy.proxy, punchHostAndProxy.host, punchPort) catch |e| switch (e) {
        error.Retry => return error.PunchSocketDisconnect,
    };
    defer common.shutdownclose(punchFd);
    log("connected to punch server", .{});

    punch.util.doHandshake(punchFd, .forwarder, 10000) catch |e| switch (e) {
        error.PunchSocketDisconnect
        ,error.BadPunchHandshake
        => return error.PunchSocketDisconnect,
    };

    var heartbeatTimer = Timer.init(15000);
    var waitOpenTunnelThrottler = makeThrottler("wait for OpenTunnel: ");
    while (true) {
        waitOpenTunnelThrottler.throttle();
        log("waiting for OpenTunnel...", .{});
        waitForOpenTunnelMessage(punchFd, &heartbeatTimer) catch |e| switch (e) {
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
        };
        var punchRecvState : PunchRecvState = PunchRecvState.Initial;
        var gotCloseTunnel = false;

        switch (sequenceConnectRawClient(punchFd, &heartbeatTimer, &punchRecvState, &gotCloseTunnel)) {
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
            error.RawSocketDisconnect => {
                try punch.util.closeTunnel(punchFd, &punchRecvState, &gotCloseTunnel, &global.buffer);
                continue;
            },
        }
    }
}

fn sequenceConnectRawClient(punchFd: fd_t, heartbeatTimer: *Timer, punchRecvState: *PunchRecvState, gotCloseTunnel: *bool) error {
    PunchSocketDisconnect,
    RawSocketDisconnect,
} {
    const rawFd = netext.socket(global.rawForwardAddr.any.family, os.SOCK_STREAM , os.IPPROTO_TCP) catch |e| switch (e) {
        error.Retry => return error.RawSocketDisconnect,
    };
    defer os.close(rawFd);

    log("s={} connecting raw to {}", .{rawFd, global.rawForwardAddr});
    netext.connect(rawFd, &global.rawForwardAddr) catch |e| switch (e) {
        error.Retry => return error.RawSocketDisconnect,
    };
    defer common.shutdown(rawFd) catch |e| {
        log("WARNING: shutdown raw s={} failed with {}", .{rawFd, e});
    };
    log("s={} raw side connected", .{rawFd});

    var eventingThrottler = makeThrottler("eventing throttler: ");
    while (true) {
        eventingThrottler.throttle();
        switch (sequenceForwardingLoop(punchFd, heartbeatTimer, punchRecvState, gotCloseTunnel, rawFd)) {
            error.EpollError => continue,
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
            error.RawSocketDisconnect => return error.RawSocketDisconnect,
        }
    }
}

fn waitForOpenTunnelMessage(punchFd: fd_t, heartbeatTimer: *Timer) !void {
    while (true) {
        const sleepMillis = punch.util.serviceHeartbeat(punchFd, heartbeatTimer, false) catch |e| switch (e) {
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
        };
        var buf: [1]u8 = undefined;
        const gotMessage = netext.recvfullTimeout(punchFd, &buf, sleepMillis) catch |e| switch (e) {
            error.Disconnected => return error.PunchSocketDisconnect,
            error.Retry => {
                // we can do this because we are only receiving 1-byte
                delaySeconds(1, "before calling recv again...");
                continue;
            },
        };
        if (gotMessage) {
            if (buf[0] == punch.proto.TwoWayMessage.Heartbeat) {
                //log("[DEBUG] got heartbeat", .{});
            } else if(buf[0] == punch.proto.InitiatorMessage.OpenTunnel) {
                log("got OpenTunnel message", .{});
                return;
            } else {
                log("got unexpected punch message {}, will disconnect", .{buf[0]});
                return error.PunchSocketDisconnect;
            }
        }
    }
}

// Note: !noreturn would be better in this case (see https://github.com/ziglang/zig/issues/3461)
fn sequenceForwardingLoop(punchFd: fd_t, heartbeatTimer: *Timer, punchRecvState: *PunchRecvState,
    gotCloseTunnel: *bool, rawFd: fd_t) error {
    EpollError,
    PunchSocketDisconnect,
    RawSocketDisconnect,
} {
    var eventer = common.eventerInit(Eventer, Eventer.EventerDataAlias {
        .punchFd = punchFd,
        .rawFd = rawFd,
        .punchRecvState = punchRecvState,
        .gotCloseTunnel = gotCloseTunnel,
    }) catch |e| switch (e) {
        error.Retry => return error.EpollError,
    };
    defer eventer.deinit();

    var punchCallback = Eventer.Callback {
        .func = onPunchData,
        .data = .{.fd = punchFd},
    };
    common.eventerAdd(Eventer, &eventer, punchFd, EventFlags.read, &punchCallback) catch |e| switch (e) {
        error.Retry => return error.EpollError,
    };
    defer eventer.remove(punchFd);

    var rawCallback = Eventer.Callback {
        .func = onRawData,
        .data = .{.fd = rawFd},
    };
    common.eventerAdd(Eventer, &eventer, rawFd, EventFlags.read, &rawCallback) catch |e| switch (e) {
        error.Retry => return error.EpollError,
    };
    defer eventer.remove(rawFd);

    while (true) {
        const sleepMillis = punch.util.serviceHeartbeat(punchFd, heartbeatTimer, false) catch |e| switch (e) {
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
        };
        //log("[DEBUG] waiting for events (sleep {} ms)...", .{sleepMillis});
        _ = eventer.handleEvents(sleepMillis) catch |e| switch (e) {
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
            error.RawSocketDisconnect => return error.RawSocketDisconnect,
        };
    }
}

fn onRawData(eventer: *Eventer, callback: *Eventer.Callback) EventError!void {
    std.debug.assert(callback.data.fd == eventer.data.rawFd);
    punch.util.forwardRawToPunch(callback.data.fd, eventer.data.punchFd, &global.buffer) catch |e| switch (e) {
        error.RawSocketDisconnect => return error.RawSocketDisconnect,
        error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
    };
}

fn onPunchData(eventer: *Eventer, callback: *Eventer.Callback) EventError!void {
    const len = netext.read(callback.data.fd, &global.buffer) catch |e| switch (e) {
        error.Retry => {
            delaySeconds(1, "before trying to read punch socket again...");
            return;
        },
        error.Disconnected => return error.PunchSocketDisconnect,
    };
    if (len == 0) {
        log("punch socket disconnected (read returned 0)", .{});
        return error.PunchSocketDisconnect;
    }
    var data = global.buffer[0..len];
    while (data.len > 0) {
        const action = punch.util.parsePunchToNextAction(eventer.data.punchRecvState, &data) catch |e| switch (e) {
            error.InvalidPunchMessage => {
                log("received unexpected punch message {}", .{data[0]});
                // socket will be shutdown in a defer
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
                // socket will be shutdown in a defer
                return error.PunchSocketDisconnect;
            },
            .CloseTunnel => {
                log("received CloseTunnel message", .{});
                eventer.data.gotCloseTunnel.* = true;
                return error.RawSocketDisconnect;
            },
            .ForwardData => |forwardAction| {
                //log("[VERBOSE] forwarding {} bytes to raw socket...", .{forwardAction.data.len});
                netext.send(eventer.data.rawFd, forwardAction.data, 0) catch |e| switch (e) {
                    error.Disconnected, error.Retry => {
                        log("s={} send failed on raw socket", .{eventer.data.rawFd});
                        return error.RawSocketDisconnect;
                    },
                };
            },
        }
    }
}
