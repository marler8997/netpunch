// a simple version of netcat for testing
// this is created so we have a common implementation for things like "CLOSE ON EOF"
//
// TODO: is it worth it to support the sendfile syscall variation?
//       maybe not since it will make this more complicated and its
//       main purpose is just for testing
//
const std = @import("std");
const mem = std.mem;
const os = std.os;
const net = std.net;

const common = @import("./common.zig");
const logging = @import("./logging.zig");
const timing = @import("./timing.zig");
const eventing = @import("./eventing.zig");
const netext = @import("./netext.zig");
const proxy = @import("./proxy.zig");

const fd_t = os.fd_t;
const Address = net.Address;
const log = logging.log;
const EventFlags = eventing.EventFlags;
const EventError = error { Disconnect };
const Eventer = eventing.EventerTemplate(EventError, struct {}, struct {
    inOut: InOut,
});
const Proxy = proxy.Proxy;

const global = struct {
    var addr1String: []const u8 = undefined;
    var addr2String: []const u8 = undefined;
    var addr1 : Addr = undefined;
    var addr2 : Addr = undefined;
    var eventer : Eventer = undefined;
    var buffer : [8192]u8 = undefined;
};

fn peelTo(strRef: *[]const u8, to: u8) ?[]const u8 {
    var str = strRef.*;
    for (str) |c, i| {
        if (c == to) {
            strRef.* = str[i+1..];
            return str[0..i];
        }
    }
    return null;
}

var noThrottle = false;
fn makeThrottler(logPrefix: []const u8) timing.Throttler {
    return if (noThrottle) (timing.makeThrottler {
        .logPrefix = logPrefix,
        .desiredSleepMillis = 0,
        .slowRateMillis = 0,
    }).create() else (timing.makeThrottler {
        .logPrefix = logPrefix,
        .desiredSleepMillis = 15000,
        .slowRateMillis = 500,
    }).create();
}

const ConnectPrep = union(enum) {
    None,
    TcpListen: TcpListen,

    pub const TcpListen = struct {
        listenFd: fd_t,
    };
};

const Addr = union(enum) {
    TcpConnect: TcpConnect,
    ProxyConnect: ProxyConnect,
    TcpListen: TcpListen,

    pub fn parse(spec: []const u8) !Addr {
        var rest = spec;
        const specType = peelTo(&rest, ':') orelse {
            std.debug.warn("Error: address '{}' missing ':' to delimit type\n", .{spec});
            return error.ParseAddrFailed;
        };
        if (mem.eql(u8, specType, "tcp-connect"))
            return Addr { .TcpConnect = try TcpConnect.parse(rest) };
        if (mem.eql(u8, specType, "proxy-connect"))
            return Addr { .ProxyConnect = try ProxyConnect.parse(rest) };
        if (mem.eql(u8, specType, "tcp-listen"))
            return Addr { .TcpListen = try TcpListen.parse(rest) };

        std.debug.warn("Error: unknown address-specifier type '{}'\n", .{specType});
        return error.ParseAddrFailed;
    }
    pub fn prepareConnect(self: *const Addr) !ConnectPrep {
        switch (self.*) {
            .TcpConnect => |a| return a.prepareConnect(),
            .ProxyConnect => |a| return a.prepareConnect(),
            .TcpListen => |a| return a.prepareConnect(),
        }
    }
    pub fn unprepareConnect(self: *const Addr, prep: *const ConnectPrep) void {
        switch (self.*) {
            .TcpConnect => |a| return a.unprepareConnect(prep),
            .ProxyConnect => |a| return a.unprepareConnect(prep),
            .TcpListen => |a| return a.unprepareConnect(prep),
        }
    }

    pub fn connect(self: *const Addr, prep: *const ConnectPrep) !InOut {
        switch (self.*) {
            .TcpConnect => |a| return a.connect(prep),
            .ProxyConnect => |a| return a.connect(prep),
            .TcpListen => |a| return a.connect(prep),
        }
    }
    pub fn connectSqueezeErrors(self: *const Addr, prep: *const ConnectPrep) !InOut {
        return self.connect(prep) catch |e| switch (e) {
            error.Retry => return error.Retry,
            error.RetryConnect => return error.RetryConnect,
            error.AddressInUse
            ,error.AddressNotAvailable
            ,error.SystemResources
            ,error.ConnectionRefused
            ,error.NetworkUnreachable
            ,error.PermissionDenied
            ,error.ConnectionTimedOut
            ,error.WouldBlock
            ,error.FileNotFound
            ,error.ProcessFdQuotaExceeded
            ,error.SystemFdQuotaExceeded
            => {
                log("connect failed with {}", .{e});
                return error.Retry;
            },
            error.AddressFamilyNotSupported
            ,error.SocketTypeNotSupported
            ,error.ProtocolFamilyNotAvailable
            ,error.ProtocolNotSupported
            ,error.Unexpected
            ,error.DnsAndIPv6NotSupported
            => std.debug.panic("FATAL ERROR: connect failed with {}", .{e}),
        };
    }
    pub fn disconnect(self: *const Addr, inOut: InOut) void {
        switch (self.*) {
            .TcpConnect => |a| return a.disconnect(inOut),
            .ProxyConnect => |a| return a.disconnect(inOut),
            .TcpListen => |a| return a.disconnect(inOut),
        }
    }

    pub fn eventerAdd(self: *const Addr, prep: *const ConnectPrep, callback: *Eventer.Callback) !void {
        switch (self.*) {
            .TcpConnect => |a| return a.eventerAdd(prep, callback),
            .ProxyConnect => |a| return a.eventerAdd(prep, callback),
            .TcpListen => |a| return a.eventerAdd(prep, callback),
        }
    }
    pub fn eventerRemove(self: *const Addr, prep: *const ConnectPrep) void {
        switch (self.*) {
            .TcpConnect => |a| return a.eventerRemove(prep),
            .ProxyConnect => |a| return a.eventerRemove(prep),
            .TcpListen => |a| return a.eventerRemove(prep),
        }
    }

    pub const TcpConnect = struct {
        host: []const u8,
        port: u16,
        pub fn parse(spec: []const u8) !TcpConnect {
            var rest = spec;
            const host = peelTo(&rest, ':') orelse {
                std.debug.warn("Error: 'tcp-connect:{}' missing ':' to delimit host\n", .{spec});
                return error.ParseAddrFailed;
            };
            const port = try common.parsePort(rest);
            return TcpConnect {
                .host = host,
                .port = port,
            };
        }
        pub fn prepareConnect(self: *const TcpConnect) !ConnectPrep {
            return ConnectPrep.None;
        }
        pub fn unprepareConnect(self: *const TcpConnect, prep: *const ConnectPrep) void {
        }
        pub fn connect(self: *const TcpConnect, prep: *const ConnectPrep) !InOut {
            const sockfd = try common.connectHost(self.host, self.port);
            return InOut { .in = sockfd, .out = sockfd };
        }
        pub fn disconnect(self: *const TcpConnect, inOut: InOut) void {
            std.debug.assert(inOut.in == inOut.out);
            common.shutdownclose(inOut.in);
        }
        pub fn eventerAdd(self: *const TcpConnect, prep: *const ConnectPrep, callback: *Eventer.Callback) !void {
        }
        pub fn eventerRemove(self: *const TcpConnect, prep: *const ConnectPrep) void {
        }
    };
    pub const ProxyConnect = struct {
        httpProxy: Proxy,
        targetHost: []const u8,
        targetPort: u16,
        pub fn parse(spec: []const u8) !ProxyConnect {
            var rest = spec;
            const proxyHost = peelTo(&rest, ':') orelse {
                std.debug.warn("Error: 'proxy-connect:{}' missing ':' to delimit proxy-host\n", .{spec});
                return error.ParseAddrFailed;
            };
            const proxyPort = try common.parsePort(peelTo(&rest, ':') orelse {
                std.debug.warn("Error: 'proxy-connect:{}' missing 2nd ':' to delimit proxy-port\n", .{spec});
                return error.ParseAddrFailed;
            });
            const targetHost = peelTo(&rest, ':') orelse {
                std.debug.warn("Error: 'proxy-connect:{}' missing the 3rd ':' to delimit host\n", .{spec});
                return error.ParseAddrFailed;
            };
            const targetPort = try common.parsePort(rest);
            return ProxyConnect {
                .httpProxy = Proxy { .Http = .{ .host = proxyHost, .port = proxyPort } },
                .targetHost = targetHost,
                .targetPort = targetPort,
            };
        }
        pub fn prepareConnect(self: *const ProxyConnect) !ConnectPrep {
            return ConnectPrep.None;
        }
        pub fn unprepareConnect(self: *const ProxyConnect, prep: *const ConnectPrep) void {
        }
        pub fn connect(self: *const ProxyConnect, prep: *const ConnectPrep) !InOut {
            const sockfd = try netext.proxyConnect(&self.httpProxy, self.targetHost, self.targetPort);
            return InOut { .in = sockfd, .out = sockfd };
        }
        pub fn disconnect(self: *const ProxyConnect, inOut: InOut) void {
            std.debug.assert(inOut.in == inOut.out);
            common.shutdownclose(inOut.in);
        }
        pub fn eventerAdd(self: *const ProxyConnect, prep: *const ConnectPrep, callback: *Eventer.Callback) !void {
        }
        pub fn eventerRemove(self: *const ProxyConnect, prep: *const ConnectPrep) void {
        }
    };
    pub const TcpListen = struct {
        port: u16,
        //listenAddr: ?Address,
        pub fn parse(spec: []const u8) !TcpListen {
            var rest = spec;
            const port = try common.parsePort(rest);
            return TcpListen {
                .port = port,
            };
        }
        pub fn prepareConnect(self: *const TcpListen) !ConnectPrep {
            var listenAddr = Address.initIp4([4]u8{0,0,0,0}, self.port);
            const listenFd = netext.makeListenSock(&listenAddr, 1) catch |e| switch (e) {
                error.Retry => return error.RetryPrepareConnect,
            };
            return ConnectPrep { .TcpListen = .{ .listenFd = listenFd } };
        }
        fn getListenFd(prep: *const ConnectPrep) fd_t {
            return switch (prep.*) {
                .TcpListen => |p| p.listenFd,
                else => @panic("code bug: connect prep type is wrong"),
            };
        }
        pub fn unprepareConnect(self: *const TcpListen, prep: *const ConnectPrep) void {
            os.close(getListenFd(prep));
        }
        pub fn connect(self: *const TcpListen, prep: *const ConnectPrep) !InOut {
            const listenFd = getListenFd(prep);
            var clientAddr : Address = undefined;
            var clientAddrLen : os.socklen_t = @sizeOf(@TypeOf(clientAddr));
            const clientFd = netext.accept(listenFd, &clientAddr.any, &clientAddrLen, 0) catch |e| switch (e) {
                error.ClientDropped, error.Retry => return error.RetryConnect,
            };
            log("accepted client from {}", .{clientAddr});
            return InOut { .in = clientFd, .out = clientFd };
        }
        pub fn disconnect(self: *const TcpListen, inOut: InOut) void {
            std.debug.assert(inOut.in == inOut.out);
            common.shutdownclose(inOut.in);
        }
        pub fn eventerAdd(self: *const TcpListen, prep: *const ConnectPrep, callback: *Eventer.Callback) !void {
            const listenFd = getListenFd(prep);
            callback.* = Eventer.Callback {
                .func = onAccept,
                .data = .{ .inOut = InOut {.in = listenFd, .out = undefined } },
            };
            common.eventerAdd(Eventer, &global.eventer, listenFd, EventFlags.read, callback) catch |e| switch (e) {
                error.Retry => return error.EpollError,
            };
        }
        pub fn eventerRemove(self: *const TcpListen, prep: *const ConnectPrep) void {
            global.eventer.remove(getListenFd(prep));
        }
    };
};

const InOut = struct { in: fd_t, out: fd_t };

fn usage() void {
    std.debug.warn("Usage: socat ADDRESS1 ADDRESS2\n", .{});
    std.debug.warn("Address Specifiers:\n", .{});
    std.debug.warn("    tcp-connect:<host>:<port>\n", .{});
    std.debug.warn("    tcp-listen:<port>[,<listen-addr>]\n", .{});
    std.debug.warn("    proxy-connect:<proxy-host>:<proxy-port>:<host>:<port>\n", .{});
}

pub fn main() anyerror!u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var args = try std.process.argsAlloc(&arena.allocator);
    if (args.len <= 1) {
        usage();
        return 1;
    }
    args = args[1..];

    {
        var newArgsLen : usize = 0;
        defer args = args[0..newArgsLen];
        var i : usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (!std.mem.startsWith(u8, arg, "-")) {
                args[newArgsLen] = arg;
                newArgsLen += 1;
            } else if (std.mem.eql(u8, arg, "--no-throttle")) {
                noThrottle = true;
            } else {
                std.debug.warn("Error: unknown command-line option '{}'\n", .{arg});
                return 1;
            }
        }
    }

    if (args.len != 2) {
        std.debug.warn("Error: expected 2 command-line arguments but got {}\n", .{args.len});
        return 1;
    }

    global.addr1String = args[0];
    global.addr2String = args[1];

    global.addr1 = Addr.parse(global.addr1String) catch return 1;
    global.addr2 = Addr.parse(global.addr2String) catch return 1;

    global.eventer = try Eventer.init(.{});
    defer global.eventer.deinit();

    var prepareConnectThrottler = makeThrottler("addr1 prepare connect: ");
    while (true) {
        prepareConnectThrottler.throttle();
        const addr1Prep = global.addr1.prepareConnect() catch |e| switch (e) {
            error.RetryPrepareConnect => continue,
            //error.Retry => continue,
        };
        defer addr1.unprepareConnect(&addr1Prep);
        switch (sequenceConnectAddr1(&addr1Prep)) {
            //error.Disconnect => continue,
        }
    }
}

fn sequenceConnectAddr1(addr1Prep: *const ConnectPrep) error { } {
    var connectThrottler = makeThrottler("addr1 connect: ");
    while (true) {
        connectThrottler.throttle();
        log("connecting to {}...", .{global.addr1String});
        const addr1InOut = global.addr1.connectSqueezeErrors(addr1Prep) catch |e| switch (e) {
            error.RetryConnect, error.Retry => continue,
        };
        defer global.addr1.disconnect(addr1InOut);
        log("connected to {} (in={} out={})", .{global.addr1String, addr1InOut.in, addr1InOut.out});
        switch (sequencePrepareAddr2(addr1Prep, addr1InOut)) {
            error.Disconnect => continue,
        }
    }
}

fn sequencePrepareAddr2(addr1Prep: *const ConnectPrep, addr1InOut: InOut) error{ Disconnect } {
    var attempt : u16 = 0;
    var prepareThrottler = makeThrottler("addr2 prepare connect: ");
    while (true) {
        attempt += 1;
        if (attempt >= 10) {
            log("failed {} attempts to prepare address 2, disconnecting...", .{attempt});
            return error.Disconnect;
        }
        prepareThrottler.throttle();
        const addr2Prep = global.addr2.prepareConnect() catch |e| switch (e) {
            error.RetryPrepareConnect => continue,
        };
        defer global.addr2.unprepareConnect(&addr2Prep);
        switch (sequenceConnectAddr2(addr1Prep, addr1InOut, &addr2Prep)) {
            error.Disconnect => return error.Disconnect,
        }
    }
}

fn sequenceConnectAddr2(addr1Prep: *const ConnectPrep, addr1InOut: InOut, addr2Prep: *const ConnectPrep) error{ Disconnect } {
    var attempt : u16 = 0;
    var connectThrottler = makeThrottler("addr2 connect: ");
    while (true) {
        attempt += 1;
        if (attempt >= 10) {
            log("failed {} attempts to connect to address 2, disconnecting...", .{attempt});
            return error.Disconnect;
        }
        connectThrottler.throttle();
        log("connecting to {}...", .{global.addr2String});
        const addr2InOut = global.addr2.connectSqueezeErrors(addr2Prep) catch |e| switch (e) {
            error.Retry, error.RetryConnect => continue,
        };
        log("connected to {} (in={} out={})", .{global.addr2String, addr2InOut.in, addr2InOut.out});
        defer global.addr2.disconnect(addr2InOut);
        switch (sequenceSetupEventing(addr1Prep, addr1InOut, addr2InOut, addr2Prep)) {
            error.Disconnect => return error.Disconnect,
        }
    }
}

fn sequenceSetupEventing(addr1Prep: *const ConnectPrep, addr1InOut: InOut, addr2InOut: InOut, addr2Prep: *const ConnectPrep) error{ Disconnect } {
    var eventingThrottler = makeThrottler("setup eventing: ");
    while (true) {
        eventingThrottler.throttle();
        switch (sequenceForwardLoop(addr1Prep, addr1InOut, addr2InOut, addr2Prep)) {
            error.EpollError => continue,
            error.Disconnect => return error.Disconnect,
        }
    }
}

fn sequenceForwardLoop(addr1Prep: *const ConnectPrep, addr1InOut: InOut, addr2InOut: InOut, addr2Prep: *const ConnectPrep) error { EpollError, Disconnect } {
    var addr1Callback = Eventer.Callback {
        .func = onAddr1Read,
        .data = .{ .inOut = InOut {.in = addr1InOut.in, .out = addr2InOut.out } },
    };
    common.eventerAdd(Eventer, &global.eventer, addr1InOut.in, EventFlags.read, &addr1Callback) catch |e| switch (e) {
        error.Retry => return error.EpollError,
    };
    defer global.eventer.remove(addr1InOut.in);

    var addr2Callback = Eventer.Callback {
        .func = onAddr2Read,
        .data = .{ .inOut = InOut {.in = addr2InOut.in, .out = addr1InOut.out } },
    };
    common.eventerAdd(Eventer, &global.eventer, addr2InOut.in, EventFlags.read, &addr2Callback) catch |e| switch (e) {
        error.Retry => return error.EpollError,
    };
    defer global.eventer.remove(addr2InOut.in);

    var addr1PrepCallback : Eventer.Callback = undefined;
    global.addr1.eventerAdd(addr1Prep, &addr1PrepCallback) catch |e| switch (e) {
        error.EpollError => return error.EpollError,
    };
    defer global.addr1.eventerRemove(addr1Prep);

    var addr2PrepCallback : Eventer.Callback = undefined;
    global.addr2.eventerAdd(addr2Prep, &addr2PrepCallback) catch |e| switch (e) {
        error.EpollError => return error.EpollError,
    };
    defer global.addr2.eventerRemove(addr2Prep);

    while (true) {
        global.eventer.handleEventsNoTimeout() catch |e| switch (e) {
            error.Disconnect => return error.Disconnect,
        };
    }
}

fn onAddr1Read(eventer: *Eventer, callback: *Eventer.Callback) EventError!void {
    return onRead(true, callback);
}
fn onAddr2Read(eventer: *Eventer, callback: *Eventer.Callback) EventError!void {
    return try onRead(false, callback);
}

fn onRead(isAddr1Read: bool, callback: *Eventer.Callback) EventError!void {
    // TODO: I should use the sendfile syscall if available
    const length = os.read(callback.data.inOut.in, &global.buffer) catch |e| {
        log("read failed: {}", .{e});
        return error.Disconnect;
    };
    if (length == 0) {
        log("read fd={} returned 0", .{callback.data.inOut.in});
        return error.Disconnect;
    }
    common.writeFull(callback.data.inOut.out, global.buffer[0..length]) catch |e| {
    };
    const dirString : []const u8 = if (isAddr1Read) ">>>" else "<<<";
    //log("[VERBOSE] {} {} bytes", .{dirString, length});
}

fn onAccept(eventer: *Eventer, callback: *Eventer.Callback) EventError!void {
    var addr : Address = undefined;
    var addrLen : os.socklen_t = @sizeOf(Address);
    const fd = netext.accept(callback.data.inOut.in, &addr.any, &addrLen, 0) catch |e| switch (e) {
        error.Retry, error.ClientDropped => return,
    };
    log("s={} already have client, dropping client s={} from {}", .{callback.data.inOut.in, fd, addr});
    common.shutdownclose(fd);
}
