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
const eventing = @import("./eventing.zig");

const fd_t = os.fd_t;
const Address = net.Address;
const EventFlags = eventing.EventFlags;
const Eventer = eventing.EventerTemplate(anyerror, struct {}, struct {});

const global = struct {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var stdout : fd_t = undefined;
    var stdin : fd_t = undefined;
    var sockfd : fd_t = undefined;
    var buffer : [8192]u8 = undefined;
};

fn usage() void {
    std.debug.warn("Usage: nc [-l PORT]\n", .{});
    std.debug.warn("       nc [-z] HOST PORT\n", .{});
    std.debug.warn("    -z     Scan for open port without sending data\n", .{});
}

pub fn main() anyerror!u8 {
    global.stdout = std.io.getStdOut().handle;
    global.stdin = std.io.getStdIn().handle;

    var args = try std.process.argsAlloc(&global.arena.allocator);
    if (args.len <= 1) {
        usage();
        return 1;
    }
    args = args[1..];

    var optionalListenPort : ?u16 = null;
    var portScan = false;
    {
        var newArgsLen : usize = 0;
        defer args = args[0..newArgsLen];
        var i : usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (!std.mem.startsWith(u8, arg, "-")) {
                args[newArgsLen] = arg;
                newArgsLen += 1;
            } else if (std.mem.eql(u8, arg, "-l")) {
                optionalListenPort = common.parsePort(common.getOptArg(args, &i) catch return 1) catch return 1;
            } else if (std.mem.eql(u8, arg, "-z")) {
                portScan = true;
            } else {
                std.debug.warn("Error: unknown command-line option '{}'\n", .{arg});
                return 1;
            }
        }
    }

    global.sockfd = initSock: {
        if (optionalListenPort) |listenPort| {
            if (args.len != 0) {
                usage();
                return 1;
            }
            if (portScan) {
                std.debug.warn("Error: '-z' (port scan) is not compatible with '-l PORT'\n", .{});
                return 1;
            }
            var addr = Address.initIp4([4]u8{0,0,0,0}, listenPort);
            const listenFd = try os.socket(addr.any.family, os.SOCK_STREAM, os.IPPROTO_TCP);
            defer os.close(listenFd);
            if (std.builtin.os.tag != .windows) {
                try os.setsockopt(listenFd, os.SOL_SOCKET, os.SO_REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            }
            try os.bind(listenFd, &addr.any, addr.getOsSockLen());
            try os.listen(listenFd, 1);
            std.debug.warn("[NC] listening on {}...\n", .{addr});
            var clientAddr : Address = undefined;
            var clientAddrLen : os.socklen_t = @sizeOf(@TypeOf(clientAddr));
            const clientFd = try os.accept(listenFd, &clientAddr.any, &clientAddrLen, 0);
            std.debug.warn("[NC] accepted client {}\n", .{clientAddr});
            break :initSock clientFd;
        } else {
            if (args.len != 2) {
                usage();
                return 1;
            }
            const hostString = args[0];
            const portString = args[1];
            const port = common.parsePort(portString) catch return 1;
            const addr = Address.parseIp4(hostString, port) catch |e| {
                std.debug.warn("Error: failed to parse '{}' as an IPv4 address: {}\n", .{hostString, e});
                return 1;
            };
            std.debug.warn("[NC] connecting to {}...\n", .{addr});
            // tcpConnectToHost is not working
            //break :initSock net.tcpConnectToHost(&global.arena.allocator, "localhost", 9282)).handle;
            const sockFile = try net.tcpConnectToAddress(addr);
            std.debug.warn("[NC] connected\n", .{});
            if (portScan) {
                try common.shutdown(sockFile.handle);
                os.close(sockFile.handle);
                return 0;
            }
            break :initSock sockFile.handle;
        }
    };

    var eventer = try Eventer.init(.{});
    var sockCallback = Eventer.Callback {
        .func = onSockData,
        .data = .{},
    };
    try eventer.add(global.sockfd, EventFlags.read, &sockCallback);

    var stdinCallback = Eventer.Callback {
        .func = onStdinData,
        .data = .{},
    };
    eventer.add(global.stdin, EventFlags.read, &stdinCallback) catch |e| switch (e) {
        error.FileDescriptorIncompatibleWithEpoll => {
            std.debug.warn("[NC] stdin appears to be closed, will ignore it\n", .{});
        },
        else => return e,
    };
    try eventer.loop();
    return 0;
}

fn sockDisconnected() noreturn {
    // we can't shutdown stdin, so the only thing to do once
    // the socket is disconnected is to exit
    os.exit(0); // nothing else we can do
}

fn onSockData(eventer: *Eventer, callback: *Eventer.Callback) anyerror!void {
    // TODO: I should use the sendfile syscall if available
    const length = os.read(global.sockfd, &global.buffer) catch |e| {
        std.debug.warn("[NC] s={} read failed: {}\n", .{global.sockfd, e});
        sockDisconnected();
    };
    if (length == 0) {
        std.debug.warn("[NC] s={} disconnected\n", .{global.sockfd});
        sockDisconnected();
    }
    try common.writeFull(global.stdout, global.buffer[0..length]);
}

fn stdinClosed(eventer: *Eventer) !void {
    eventer.remove(global.stdin);
    os.close(global.stdin); // TODO: I don't have to close stdin...should I?
    try common.shutdown(global.sockfd);
}

fn onStdinData(eventer: *Eventer, callback: *Eventer.Callback) anyerror!void {
    // TODO: I should use the sendfile syscall if available
    const length = os.read(global.stdin, &global.buffer) catch |e| {
        std.debug.warn("[NC] stdin read failed: {}\n", .{e});
        try stdinClosed(eventer);
        return;
    };
    if (length == 0) {
        std.debug.warn("[NC] stdin EOF\n", .{});
        try stdinClosed(eventer);
        return;
    }
    try common.sendfull(global.sockfd, global.buffer[0..length], 0);
}
