// a simple version of netcat for testing
// this is created so we have a common implementation for things like "CLOSE ON EOF"
//
// TODO: is it worth it to support the sendfile syscall variation?
//       maybe not since it will make this more complicated and its
//       main purpose is just for testing
//
const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;
const os = std.os;
const net = std.net;

const common = @import("./common.zig");
const eventing = @import("./eventing.zig").default;

const fd_t = os.fd_t;
const Address = net.Address;
const EventFlags = eventing.EventFlags;
const Eventer = eventing.EventerTemplate(.{});

const global = struct {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    var stdout : fd_t = undefined;
    var stdin : fd_t = undefined;
    var sockfd : std.os.socket_t = undefined;
    var buffer : [8192]u8 = undefined;
};

fn usage() !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.writeAll(
        \\Usage: nc [-l PORT]
        \\       nc [-z] HOST PORT
        \\    -z     Scan for open port without sending data
        \\
    );
}

pub fn main() !u8 {
    global.stdout = std.io.getStdOut().handle;
    global.stdin = std.io.getStdIn().handle;

    var args = try std.process.argsAlloc(global.arena);
    if (args.len <= 1) {
        try usage();
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
                std.debug.print("Error: unknown command-line option '{s}'\n", .{arg});
                return 1;
            }
        }
    }

    global.sockfd = initSock: {
        if (optionalListenPort) |listenPort| {
            if (args.len != 0) {
                try usage();
                return 1;
            }
            if (portScan) {
                std.debug.print("Error: '-z' (port scan) is not compatible with '-l PORT'\n", .{});
                return 1;
            }
            var addr = Address.initIp4([4]u8{0,0,0,0}, listenPort);
            const listenFd = try os.socket(addr.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);
            defer os.close(listenFd);
            if (builtin.os.tag != .windows) {
                try os.setsockopt(listenFd, os.SOL.SOCKET, os.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            }
            try os.bind(listenFd, &addr.any, addr.getOsSockLen());
            try os.listen(listenFd, 1);
            std.debug.print("[NC] listening on {}...\n", .{addr});
            var clientAddr : Address = undefined;
            var clientAddrLen : os.socklen_t = @sizeOf(@TypeOf(clientAddr));
            const clientFd = try os.accept(listenFd, &clientAddr.any, &clientAddrLen, 0);
            std.debug.print("[NC] accepted client {}\n", .{clientAddr});
            break :initSock clientFd;
        } else {
            if (args.len != 2) {
                try usage();
                return 1;
            }
            const hostString = args[0];
            const portString = args[1];
            const port = common.parsePort(portString) catch return 1;
            const addr = Address.parseIp4(hostString, port) catch |e| {
                std.debug.print("Error: failed to parse '{s}' as an IPv4 address: {}\n", .{hostString, e});
                return 1;
            };
            std.debug.print("[NC] connecting to {}...\n", .{addr});
            // tcpConnectToHost is not working
            //break :initSock net.tcpConnectToHost(global.arena, "localhost", 9282)).handle;
            const sockFile = try net.tcpConnectToAddress(addr);
            std.debug.print("[NC] connected\n", .{});
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
            std.debug.print("[NC] stdin appears to be closed, will ignore it\n", .{});
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
    _ = eventer;
    _ = callback;
    // TODO: I should use the sendfile syscall if available
    const length = os.read(global.sockfd, &global.buffer) catch |e| {
        std.debug.print("[NC] s={} read failed: {}\n", .{global.sockfd, e});
        sockDisconnected();
    };
    if (length == 0) {
        std.debug.print("[NC] s={} disconnected\n", .{global.sockfd});
        sockDisconnected();
    }
    if (common.tryWriteAll(global.stdout, global.buffer[0..length])) |result| {
        std.debug.print("[NC] s={} write failed with {}, wrote {} bytes out of {}", .{global.sockfd, result.err, result.wrote, length});
        return error.StdoutClosed;
    }
}

fn stdinClosed(eventer: *Eventer) !void {
    eventer.remove(global.stdin);
    os.close(global.stdin); // TODO: I don't have to close stdin...should I?
    try common.shutdown(global.sockfd);
}

fn onStdinData(eventer: *Eventer, callback: *Eventer.Callback) anyerror!void {
    _ = callback;
    // TODO: I should use the sendfile syscall if available
    const length = os.read(global.stdin, &global.buffer) catch |e| {
        std.debug.print("[NC] stdin read failed: {}\n", .{e});
        try stdinClosed(eventer);
        return;
    };
    if (length == 0) {
        std.debug.print("[NC] stdin EOF\n", .{});
        try stdinClosed(eventer);
        return;
    }
    try common.sendfull(global.sockfd, global.buffer[0..length], 0);
}
