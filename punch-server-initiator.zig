//
// TODO: look at the delaySeconds where we retry accepting client
//       I should come up with a way to detect when the event loop
//       just starts churning with failed accept calls rather than
//       just delaying a second each time we get one
//
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

const fd_t = os.fd_t;
const Address = net.Address;
const log = logging.log;
const delaySeconds = common.delaySeconds;
const Timer = timing.Timer;
const EventFlags = eventing.EventFlags;
const PunchRecvState = punch.util.PunchRecvState;

const AcceptRawEventError = error {PunchSocketDisconnect};
const AcceptRawEventer = eventing.EventerTemplate(AcceptRawEventError, struct {
    punchRecvState: *PunchRecvState,
    acceptedRawClient: fd_t,
}, struct {
    fd: fd_t,
});

const ForwardingEventError = error {PunchSocketDisconnect, RawSocketDisconnect};
const ForwardingEventer = eventing.EventerTemplate(ForwardingEventError, struct {
    punchRecvState: *PunchRecvState,
    punchFd: fd_t,
    rawFd: fd_t,
    gotCloseTunnel: *bool,
}, struct {
    fd: fd_t,
});

const global = struct {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var rawListenAddr : Address = undefined;
    var listenFd : fd_t = undefined;
    var buffer : [8192]u8 = undefined;
};

fn makeThrottler(logPrefix: []const u8) timing.Throttler {
    return (timing.makeThrottler {
        .logPrefix = logPrefix,
        .desiredSleepMillis = 15000,
        .slowRateMillis = 500,
    }).create();
}

fn usage() void {
    log("Usage: punch-server-initiator PUNCH_LISTEN_ADDR PUNCH_PORT RAW_LISTEN_ADDR RAW_PORT", .{});
}
pub fn main() !u8 {
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
    const punchListenAddrString = args[0];
    const punchPort = common.parsePort(args[1]) catch return 1;
    const rawListenAddrString = args[2];
    const rawPort   = common.parsePort(args[3]) catch return 1;

    var punchListenAddr = common.parseIp4(punchListenAddrString, punchPort) catch return 1;
    global.rawListenAddr = common.parseIp4(rawListenAddrString, rawPort) catch return 1;

    var bindThrottler = makeThrottler("bind throttler: ");
    while (true) {
        bindThrottler.throttle();
        const punchListenFd = netext.makeListenSock(&punchListenAddr, 1) catch |e| switch (e) {
            error.Retry => continue,
        };
        log("created punch listen socket s={}", .{punchListenFd});
        defer os.close(punchListenFd);

        switch (sequenceAcceptPunchClient(punchListenFd)) {
            //error.RetryMakePunchListenSocket => continue,
        }
    }
}

fn sequenceAcceptPunchClient(punchListenFd: fd_t) error {} {
    var acceptPunchThrottler = makeThrottler("accept punch throttler: ");
    while (true) {
        acceptPunchThrottler.throttle();

        log("accepting punch client...", .{});
        var clientAddr : Address = undefined;
        var clientAddrLen : os.socklen_t = @sizeOf(@TypeOf(clientAddr));
        const punchFd = netext.accept4(punchListenFd, &clientAddr.any, &clientAddrLen, 0) catch |e| switch (e) {
            error.ClientDropped, error.Retry => continue,
        };
        defer common.shutdownclose(punchFd);
        log("s={} accepted punch client {}", .{punchFd, clientAddr});

        punch.util.doHandshake(punchFd, .initiator, 10000) catch |e| switch (e) {
            error.PunchSocketDisconnect
            ,error.BadPunchHandshake
            => continue,
        };

        var heartbeatTimer = Timer.init(15000);
        switch (sequenceSetupEventing(punchListenFd, punchFd, &heartbeatTimer)) {
            error.PunchSocketDisconnect => continue,
        }
    }
}

fn sequenceSetupEventing(punchListenFd: fd_t, punchFd: fd_t, heartbeatTimer: *Timer) error {
    PunchSocketDisconnect,
} {
    var eventingThrottler = makeThrottler("eventing throttler");
    while (true) {
        eventingThrottler.throttle();
        _ = punch.util.serviceHeartbeat(punchFd, heartbeatTimer) catch |e| switch (e) {
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
        };
        switch (sequenceAcceptRawClient(punchListenFd, punchFd, heartbeatTimer)) {
            error.EpollError
            ,error.CreateRawListenSocketFailed
            => continue,
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
        }
    }
}

fn sequenceAcceptRawClient(punchListenFd: fd_t, punchFd: fd_t, heartbeatTimer: *Timer) error {
    EpollError,
    CreateRawListenSocketFailed,
    PunchSocketDisconnect,
} {
    const epollfd = eventing.epoll_create1(0) catch |e| switch (e) {
        error.Retry => return error.EpollError,
    };
    defer os.close(epollfd);

    const rawListenFd = netext.makeListenSock(&global.rawListenAddr, 1) catch |e| switch (e) {
        error.Retry => return error.CreateRawListenSocketFailed,
    };
    defer os.close(rawListenFd);

    var punchRecvState : PunchRecvState = PunchRecvState.Initial;

    var acceptRawThrottler = makeThrottler("accept raw throttler: ");
    while (true) {
        acceptRawThrottler.throttle();
        const rawFd = waitForRawClient(epollfd, punchListenFd, punchFd, heartbeatTimer, &punchRecvState, rawListenFd) catch |e| switch (e) {
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
            error.EpollError => return error.EpollError,
        };

        punch.util.sendOpenTunnel(punchFd) catch |e| switch (e) {
            error.Disconnected, error.Retry => return error.PunchSocketDisconnect,
        };
        var gotCloseTunnel = false;

        switch (sequenceForwardingLoop(epollfd, punchListenFd, punchFd, heartbeatTimer, &punchRecvState, rawListenFd, rawFd, &gotCloseTunnel)) {
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
            error.EpollError => {
                try punch.util.closeTunnel(punchFd, &punchRecvState, &gotCloseTunnel, &global.buffer);
                return error.EpollError;
            },
            error.RawSocketDisconnect => {
                try punch.util.closeTunnel(punchFd, &punchRecvState, &gotCloseTunnel, &global.buffer);
                continue;
            },
        }
    }
}

fn waitForRawClient(epollfd: fd_t, punchListenFd: fd_t, punchFd: fd_t, heartbeatTimer: *Timer,
    punchRecvState: *PunchRecvState, rawListenFd: fd_t) !fd_t {

    var eventer = AcceptRawEventer.initEpoll(.{
        .punchRecvState = punchRecvState,
        .acceptedRawClient = -1,
    }, epollfd, false);
    defer eventer.deinit();

    var punchListenCallback = AcceptRawEventer.Callback {
        .func = onPunchAcceptAcceptRaw,
        .data = .{.fd = punchListenFd},
    };
    common.eventerAdd(AcceptRawEventer, &eventer, punchListenFd, EventFlags.read, &punchListenCallback) catch |e| switch (e) {
        error.Retry => return error.EpollError,
    };
    defer eventer.remove(punchListenFd);

    var punchCallback = AcceptRawEventer.Callback {
        .func = onPunchDataAcceptRaw,
        .data = .{.fd = punchFd},
    };
    common.eventerAdd(AcceptRawEventer, &eventer, punchFd, EventFlags.read, &punchCallback) catch |e| switch (e) {
        error.Retry => return error.EpollError,
    };
    defer eventer.remove(punchFd);

    var rawListenCallback = AcceptRawEventer.Callback {
        .func = onFirstRawAccept,
        .data = .{.fd = rawListenFd},
    };
    common.eventerAdd(AcceptRawEventer, &eventer, rawListenFd, EventFlags.read, &rawListenCallback) catch |e| switch (e) {
        error.Retry => return error.EpollError,
    };
    defer eventer.remove(rawListenFd);

    while (true) {
        const sleepMillis = punch.util.serviceHeartbeat(punchFd, heartbeatTimer) catch |e| switch (e) {
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
        };
        //log("[DEBUG] waiting for events (sleep {} ms)...", .{sleepMillis});
        _ = eventer.handleEvents(sleepMillis) catch |e| switch (e) {
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
        };
        if (eventer.data.acceptedRawClient != -1)
            return eventer.data.acceptedRawClient;
    }
}

fn sequenceForwardingLoop(epollfd: fd_t, punchListenFd: fd_t, punchFd: fd_t, heartbeatTimer: *Timer,
    punchRecvState: *PunchRecvState, rawListenFd: fd_t, rawFd: fd_t, gotCloseTunnel: *bool) error {
    EpollError,
    RawSocketDisconnect,
    PunchSocketDisconnect,
} {

    var eventer = ForwardingEventer.initEpoll(.{
        .punchRecvState = punchRecvState,
        .punchFd = punchFd,
        .rawFd = rawFd,
        .gotCloseTunnel = gotCloseTunnel,
    }, epollfd, false);
    defer eventer.deinit();

    var punchListenCallback = ForwardingEventer.Callback {
        .func = onPunchAcceptForwarding,
        .data = .{.fd = punchListenFd},
    };
    common.eventerAdd(ForwardingEventer, &eventer, punchListenFd, EventFlags.read, &punchListenCallback) catch |e| switch (e) {
        error.Retry => return error.EpollError,
    };
    defer eventer.remove(punchListenFd);

    var punchCallback = ForwardingEventer.Callback {
        .func = onPunchDataForwarding,
        .data = .{.fd = punchFd},
    };
    common.eventerAdd(ForwardingEventer, &eventer, punchFd, EventFlags.read, &punchCallback) catch |e| switch (e) {
        error.Retry => return error.EpollError,
    };
    defer eventer.remove(punchFd);

    var rawListenCallback = ForwardingEventer.Callback {
        .func = onRawAcceptForwarding,
        .data = .{.fd = rawListenFd},
    };
    common.eventerAdd(ForwardingEventer, &eventer, rawListenFd, EventFlags.read, &rawListenCallback) catch |e| switch (e) {
        error.Retry => return error.EpollError,
    };
    defer eventer.remove(rawListenFd);

    var rawCallback = ForwardingEventer.Callback {
        .func = onRawData,
        .data = .{.fd = rawFd},
    };
    common.eventerAdd(ForwardingEventer, &eventer, rawFd, EventFlags.read, &rawCallback) catch |e| switch (e) {
        error.Retry => return error.EpollError,
    };
    defer eventer.remove(rawFd);

    while (true) {
        const sleepMillis = punch.util.serviceHeartbeat(punchFd, heartbeatTimer) catch |e| switch (e) {
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
        };
        //log("[DEBUG] waiting for events (sleep {} ms)...", .{sleepMillis});
        _ = eventer.handleEvents(sleepMillis) catch |e| switch (e) {
            error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
            error.RawSocketDisconnect => return error.RawSocketDisconnect,
        };
    }
}

fn onPunchAcceptAcceptRaw(eventer: *AcceptRawEventer, callback: *AcceptRawEventer.Callback) AcceptRawEventError!void {
    dropClient(callback.data.fd, true);
}
fn onPunchAcceptForwarding(eventer: *ForwardingEventer, callback: *ForwardingEventer.Callback) ForwardingEventError!void {
    dropClient(callback.data.fd, true);
}
fn onRawAcceptForwarding(eventer: *ForwardingEventer, callback: *ForwardingEventer.Callback) ForwardingEventError!void {
    dropClient(callback.data.fd, false);
}
fn dropClient(listenFd: fd_t, isPunch: bool) void {
    var addr : Address = undefined;
    var addrLen : os.socklen_t = @sizeOf(Address);
    const fd = netext.accept4(listenFd, &addr.any, &addrLen, 0) catch |e| switch (e) {
        error.ClientDropped => return,
        error.Retry => {
            delaySeconds(1, "before calling accept again...");
            return;
        },
    };
    log("got another {} client s={} from {}, closing it...", .{
        if (isPunch) "punch"[0..] else "raw"[0..], fd, addr});
    common.shutdownclose(fd);
}

fn onFirstRawAccept(eventer: *AcceptRawEventer, callback: *AcceptRawEventer.Callback) AcceptRawEventError!void {
    std.debug.assert(eventer.data.acceptedRawClient == -1);

    var addr : Address = undefined;
    var addrLen : os.socklen_t = @sizeOf(Address);
    const rawFd = netext.accept4(callback.data.fd, &addr.any, &addrLen, 0) catch |e| switch (e) {
        error.ClientDropped => return,
        error.Retry => {
            delaySeconds(1, "before accepting raw client again...");
            return;
        },
    };
    errdefer common.shutdownclose(rawFd);
    log("accepted raw client s={} from {}", .{rawFd, addr});
    eventer.data.acceptedRawClient = rawFd; // signals the eventer loop that we have accept a raw client
}

fn onRawData(eventer: *ForwardingEventer, callback: *ForwardingEventer.Callback) ForwardingEventError!void {
    punch.util.forwardRawToPunch(callback.data.fd, eventer.data.punchFd, &global.buffer) catch |e| switch (e) {
        error.RawSocketDisconnect => return error.RawSocketDisconnect,
        error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
    };
}

fn onPunchDataAcceptRaw(eventer: *AcceptRawEventer, callback: *AcceptRawEventer.Callback) AcceptRawEventError!void {
    var gotCloseTunnel = false;
    onPunchData(AcceptRawEventer, eventer, callback.data.fd) catch |e| switch (e) {
        error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
    };
}
fn onPunchDataForwarding(eventer: *ForwardingEventer, callback: *ForwardingEventer.Callback) ForwardingEventError!void {
    onPunchData(ForwardingEventer, eventer, callback.data.fd) catch |e| switch (e) {
        error.PunchSocketDisconnect => return error.PunchSocketDisconnect,
        error.RawSocketDisconnect => return error.RawSocketDisconnect,
    };
}
fn onPunchData(comptime Eventer: type, eventer: *Eventer, punchFd: fd_t) !void {
    const len = netext.read(punchFd, &global.buffer) catch |e| switch (e) {
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
    //log("[DEBUG] received {}-bytes of punch data", .{data.len});
    while (data.len > 0) {
        const action = punch.util.parsePunchToNextAction(eventer.data.punchRecvState, &data) catch |e| switch (e) {
            error.InvalidPunchMessage => {
                log("received unexpected punch message {}", .{data[0]});
                return error.PunchSocketDisconnect;
            },
        };
        //log("[DEBUG] action {} data.len {}", .{action, data.len});
        switch (action) {
            .None => {
                std.debug.assert(data.len == 0);
                break;
            },
            .OpenTunnel => {
                log("WARNING: received OpenTunnel message from the forwarder", .{});
                return error.PunchSocketDisconnect;
            },
            .CloseTunnel => {
                if (Eventer == AcceptRawEventer) {
                    log("WARNING: got CloseTunnel message but the tunnel is not open", .{});
                    return error.PunchSocketDisconnect;
                } else {
                    log("received CloseTunnel message", .{});
                    eventer.data.gotCloseTunnel.* = true;
                    return error.RawSocketDisconnect;
                }
            },
            .ForwardData => |forwardAction| {
                if (Eventer == AcceptRawEventer) {
                    log("WARNING: got ForwardData message but the tunnel is not open", .{});
                    return error.PunchSocketDisconnect;
                } else {
                    log("[VERBOSE] forwarding {} bytes to raw socket s={}", .{forwardAction.data.len, eventer.data.rawFd});
                    netext.send(eventer.data.rawFd, forwardAction.data, 0) catch |e| switch (e) {
                        error.Disconnected, error.Retry => {
                            log("s={} send failed on raw socket", .{eventer.data.rawFd});
                            return error.RawSocketDisconnect;
                        },
                    };
                }
            },
        }
    }
}
