const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;
const os = std.os;

const logging = @import("./logging.zig");
const timing = @import("./timing.zig");

const panic = std.debug.panic;
const log = logging.log;
const fd_t = os.fd_t;
const socket_t = os.socket_t;
const Address = std.net.Address;

// TODO: this should go somewhere else (i.e. std.algorithm in D)
pub fn skipOver(comptime T: type, haystack: *T, needle: []const u8) bool {
    if (mem.startsWith(u8, haystack.*, needle)) {
        haystack.* = haystack.*[needle.len..];
        return true;
    }
    return false;
}

pub fn delaySeconds(seconds: u32, msg: []const u8) void {
    log("waiting {} seconds {s}", .{seconds, msg});
    std.time.sleep(@intCast(u64, seconds) * std.time.ns_per_s);
}

pub fn makeListenSock(listenAddr: *Address) !socket_t {
    var flags : u32 = os.SOCK.STREAM;
    if (builtin.os.tag != .windows) {
        flags = flags | os.SOCK.NONBLOCK;
    }
    const sockfd = try os.socket(listenAddr.any.family, flags, os.IPPROTO.TCP);
    errdefer os.close(sockfd);
    if (builtin.os.tag != .windows) {
        try os.setsockopt(sockfd, os.SOL.SOCKET, os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    }
    os.bind(sockfd, &listenAddr.any, listenAddr.getOsSockLen()) catch |e| {
        std.debug.warn("bind to address '{}' failed: {}\n", .{listenAddr, e});
        return error.AlreadyReported;
    };
    os.listen(sockfd, 8) catch |e| {
        std.debug.warn("listen failed: {}\n", .{e});
        return error.AlreadyReported;
    };
    return sockfd;
}

pub fn getsockerror(sockfd: socket_t) !c_int {
    var errorCode : c_int = undefined;
    var resultLen : os.socklen_t = @sizeOf(c_int);
    switch (os.errno(os.linux.getsockopt(sockfd, os.SOL.SOCKET, os.SO.ERROR, @ptrCast([*]u8, &errorCode), &resultLen))) {
        0 => return errorCode,
        .EBADF => unreachable,
        .EFAULT => unreachable,
        .EINVAL => unreachable,
        .ENOPROTOOPT => unreachable,
        .ENOTSOCK => unreachable,
        else => |err| return os.unexpectedErrno(err),
    }
}

pub fn connect(sockfd: socket_t, addr: *const Address) os.ConnectError!void {
    return os.connect(sockfd, &addr.any, addr.getOsSockLen());
}
pub fn connectHost(host: []const u8, port: u16) !socket_t {
    // so far only ipv4 addresses supported
    if (Address.parseIp(host, port)) |addr| {
        const sockfd = try os.socket(addr.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);
        errdefer os.close(sockfd);
        try os.connect(sockfd, &addr.any, addr.getOsSockLen());
        return sockfd;
    } else |_| {
        // TODO: implement DNS
        return error.DnsNotSupported;
    }
}

const extern_windows = struct {
    pub extern "ws2_32" fn shutdown(
        s: socket_t,
        how: c_int
    ) callconv(.Stdcall) c_int;
    pub const SD_BOTH = 2;
};

// TODO: move to standard library
pub const ShutdownError = error{
    ConnectionAborted,

    /// Connection was reset by peer, application should close socket as it is no longer usable.
    ConnectionResetByPeer,

    BlockingOperationInProgress,

    /// Shutdown was passed an invalid "how" argument
    InvalidShutdownHow,

    /// The network subsystem has failed.
    NetworkSubsystemFailed,

    /// The socket is not connected (connection-oriented sockets only).
    SocketNotConnected,

    /// The file descriptor sockfd does not refer to a socket.
    FileDescriptorNotASocket,

    SystemResources
} || std.os.UnexpectedError;

pub fn shutdown(sockfd: socket_t) ShutdownError!void {
    if (builtin.os.tag == .windows) {
        const result = extern_windows.shutdown(sockfd, extern_windows.SD_BOTH);
        if (0 != result) switch (std.os.windows.ws2_32.WSAGetLastError()) {
            .WSAECONNABORTED => return error.ConnectionAborted,
            .WSAECONNRESET => return error.ConnectionResetByPeer,
            .WSAEINPROGRESS => return error.BlockingOperationInProgress,
            .WSAEINVAL => return error.InvalidShutdownHow,
            .WSAENETDOWN => return error.NetworkSubsystemFailed,
            .WSAENOTCONN => return error.SocketNotConnected,
            .WSAENOTSOCK => return error.FileDescriptorNotASocket,
            .WSANOTINITIALISED => unreachable,
            else => |err| return std.os.windows.unexpectedWSAError(err),
        };
    } else switch (os.errno(os.linux.shutdown(sockfd, os.SHUT.RDWR))) {
        .SUCCESS => return,
        .BADF => unreachable,
        .INVAL => return error.InvalidShutdownHow,
        .NOTCONN => return error.SocketNotConnected,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .NOBUFS => return error.SystemResources,
        else => |err| return os.unexpectedErrno(err),
    }
}

pub fn shutdownclose(sockfd: socket_t) void {
    shutdown(sockfd) catch { }; // ignore error
    os.close(sockfd);
}

pub fn sendfull(sockfd: socket_t, buf: []const u8, flags: u32) !void {
    var totalSent : usize = 0;
    while (totalSent < buf.len) {
        const lastSent = try os.send(sockfd, buf[totalSent..], flags);
        if (lastSent == 0)
            return error.SendReturnedZero;
        totalSent += lastSent;
    }
}

const WriteAllError = error { FdClosed } || std.os.WriteError;
const WriteAllErrorResult = struct {
    err: WriteAllError,
    wrote: usize,
};
pub fn tryWriteAll(fd: fd_t, buf: []const u8) ?WriteAllErrorResult {
    var total_wrote : usize = 0;
    while (total_wrote < buf.len) {
        const last_wrote = os.write(fd, buf[total_wrote..]) catch |e|
            return WriteAllErrorResult { .err = e, .wrote = total_wrote };
        if (last_wrote == 0)
            return WriteAllErrorResult { .err = error.FdClosed, .wrote = total_wrote };
        total_wrote += last_wrote;
    }
    return null;
}

fn waitGenericTimeout(fd: fd_t, timeoutMillis: i32, events: i16) !bool {
    var pollfds = [1]os.linux.pollfd {
        os.linux.pollfd { .fd = fd, .events = events, .revents = undefined },
    };
    const result = os.poll(&pollfds, timeoutMillis) catch |e| switch (e) {
        error.SystemResources
        ,error.NetworkSubsystemFailed
        => {
            log("poll function failed with {}", .{e});
            return error.Retry;
        },
        error.Unexpected
        => panic("poll function failed with {}", .{e}),
    };
    if (result == 0) return false; // timeout
    if (result == 1) return true; // socket is readable
    panic("poll function with only 1 fd returned {}", .{result});
}

// returns: true if readable, false on timeout
pub fn waitReadableTimeout(fd: fd_t, timeoutMillis: i32) !bool {
    return waitGenericTimeout(fd, timeoutMillis, os.POLL.IN);
}
pub fn waitReadable(fd: fd_t) !void {
    if (!try waitReadableTimeout(fd, -1))
        panic("poll function with infinite timeout returned 0", .{});
}

pub fn waitWriteableTimeout(fd: fd_t, timeoutMillis: i32) !bool {
    return waitGenericTimeout(fd, timeoutMillis, os.POLL.OUT);
}

pub fn recvfullTimeout(sockfd: socket_t, buf: []u8, timeoutMillis: u32) !bool {
    var newTimeoutMillis = timeoutMillis;
    var totalReceived : usize = 0;
    while (newTimeoutMillis > @intCast(u32, std.math.maxInt(i32))) {
        const received = try recvfullTimeoutHelper(sockfd, buf[totalReceived..], std.math.maxInt(i32));
        totalReceived += received;
        if (totalReceived == buf.len) return true;
        newTimeoutMillis -= std.math.maxInt(i32);
    }
    totalReceived += try recvfullTimeoutHelper(sockfd, buf[totalReceived..], @intCast(i32, newTimeoutMillis));
    return totalReceived == buf.len;
}
fn recvfullTimeoutHelper(sockfd: socket_t, buf: []u8, timeoutMillis: i32) !usize {
    std.debug.assert(timeoutMillis >= 0); // code bug otherwise
    var totalReceived : usize = 0;
    if (buf.len > 0) {
        const startTime = std.time.milliTimestamp();
        while (true) {
            const readable = try waitReadableTimeout(sockfd, timeoutMillis);
            if (!readable) break;
            const result = try os.read(sockfd, buf[totalReceived..]);
            if (result <= 0) break;
            totalReceived += result;
            if (totalReceived == buf.len) break;
            const elapsed = timing.timestampDiff(std.time.milliTimestamp(), startTime);
            if (elapsed > timeoutMillis) break;
        }
        return totalReceived;
    }
    return totalReceived;
}

pub fn getOptArg(args: anytype, i: *usize) !@TypeOf(args[0]) {
    i.* += 1;
    if (i.* >= args.len) {
        std.debug.warn("Error: option '{s}' requires an argument\n", .{args[i.* - 1]});
        return error.CommandLineOptionMissingArgument;
    }
    return args[i.*];
}

/// logs an error if it fails
pub fn parsePort(s: []const u8) !u16 {
    return std.fmt.parseInt(u16, s, 10) catch |e| {
        log("Error: failed to parse '{s}' as a port: {}", .{s, e});
        return error.InvalidPortString;
    };
}
/// logs an error if it fails
pub fn parseIp4(s: []const u8, port: u16) !Address {
    return Address.parseIp4(s, port) catch |e| {
        log("Error: failed to parse '{s}' as an IPv4 address: {}", .{s, e});
        return e;
    };
}

pub fn eventerAdd(comptime Eventer: type, eventer: *Eventer, fd: Eventer.Fd, flags: u32, callback: *Eventer.Callback) !void {
    eventer.add(fd, flags, callback) catch |e| switch (e) {
        error.SystemResources
        ,error.UserResourceLimitReached
        => {
            log("epoll add error {}", .{e});
            return error.Retry;
        },
        error.FileDescriptorAlreadyPresentInSet
        ,error.OperationCausesCircularLoop
        ,error.FileDescriptorNotRegistered
        ,error.FileDescriptorIncompatibleWithEpoll
        ,error.Unexpected
        => panic("epoll add failed with {}", .{e}),
    };
}

pub fn eventerInit(comptime Eventer: type, data: Eventer.Data) !Eventer {
    return Eventer.init(data) catch |e| switch (e) {
        error.ProcessFdQuotaExceeded
        ,error.SystemFdQuotaExceeded
        ,error.SystemResources
        => {
            log("epoll_create failed with {}", .{e});
            return error.Retry;
        },
        error.Unexpected
        => std.debug.panic("epoll_create failed with {}", .{e}),
    };
}
