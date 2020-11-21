///
/// network functions that both log errors and return actionable error codes
///
const std = @import("std");
const os = std.os;
const net = std.net;

const fd_t = os.fd_t;
const Address = net.Address;

const logging = @import("./logging.zig");
const common = @import("./common.zig");
const proxy = @import("./proxy.zig");

const panic = std.debug.panic;
const log = logging.log;
const Proxy = proxy.Proxy;

/// logs errors and returns either fatal or retry
pub fn socket(domain: u32, socketType: u32, proto: u32) !fd_t {
    return os.socket(domain, socketType, proto) catch |e| switch (e) {
        error.ProcessFdQuotaExceeded
        ,error.SystemFdQuotaExceeded
        ,error.SystemResources
        => {
            log("WARNING: socket function error: {}", .{e});
            return error.Retry;
        },
        error.PermissionDenied
        ,error.AddressFamilyNotSupported
        ,error.SocketTypeNotSupported
        ,error.ProtocolFamilyNotAvailable
        ,error.ProtocolNotSupported
        ,error.Unexpected
        => panic("socket function failed with: {}", .{e}),
    };
}

pub fn connect(sockfd: fd_t, addr: *const Address) !void {
    return common.connect(sockfd, addr) catch |e| switch (e) {
        error.AddressNotAvailable
        ,error.AddressInUse
        ,error.ConnectionRefused
        ,error.ConnectionTimedOut
        ,error.NetworkUnreachable
        ,error.SystemResources
        ,error.WouldBlock
        => {
            log("WARNING: connect function returned error: {}", .{e});
            return error.Retry;
        },
        error.PermissionDenied
        ,error.AddressFamilyNotSupported
        ,error.Unexpected
        ,error.FileNotFound
        => panic("connect function failed with: {}", .{e}),
    };
}

pub fn proxyConnect(prox: *const Proxy, host: []const u8, port: u16) !fd_t {
    return prox.connectHost(host, port) catch |e| switch (e) {
        error.AddressNotAvailable
        ,error.AddressInUse
        ,error.ConnectionRefused
        ,error.ConnectionTimedOut
        ,error.NetworkUnreachable
        ,error.SystemResources
        ,error.ProcessFdQuotaExceeded
        ,error.SystemFdQuotaExceeded
        ,error.WouldBlock
        ,error.SendReturnedZero
        ,error.ConnectionResetByPeer
        ,error.MessageTooBig
        ,error.BrokenPipe
        ,error.InputOutput
        ,error.NotOpenForReading
        ,error.OperationAborted
        ,error.HttpProxyDisconnectedDurringReply
        ,error.HttpProxyUnexpectedReply
        => {
            log("WARNING: proxy connectHost returned error: {}", .{e});
            return error.Retry;
        },
        error.AccessDenied
        ,error.PermissionDenied
        ,error.AddressFamilyNotSupported
        ,error.Unexpected
        ,error.FileDescriptorNotASocket
        ,error.FileNotFound
        ,error.ProtocolFamilyNotAvailable
        ,error.ProtocolNotSupported
        ,error.DnsAndIPv6NotSupported
        ,error.IsDir
        ,error.FastOpenAlreadyInProgress // this is from sendto, EALREADY, not sure what it means
        ,error.SocketTypeNotSupported
        => panic("proxy connectHost failed with: {}", .{e}),
    };
}

pub fn send(sockfd: fd_t, buf: []const u8, flags: u32) !void {
    common.sendfull(sockfd, buf, flags) catch |e| switch (e) {
        error.ConnectionResetByPeer
        ,error.BrokenPipe
        => {
            log("send function error: {}", .{e});
            return error.Disconnected;
        },
        error.WouldBlock
        ,error.MessageTooBig
        ,error.SystemResources
        ,error.SendReturnedZero
        => {
            log("WARNING: send function error: {}", .{e});
            return error.Retry;
        },
        error.AccessDenied
        ,error.FastOpenAlreadyInProgress // don't know what this is
        ,error.FileDescriptorNotASocket
        ,error.Unexpected
        => panic("send function failed with: {}", .{e}),
    };
}

pub fn read(fd: fd_t, buf: []u8) !usize {
    return os.read(fd, buf) catch |e| switch (e) {
        error.BrokenPipe
        ,error.ConnectionResetByPeer
        ,error.ConnectionTimedOut
        ,error.InputOutput
        ,error.NotOpenForReading
        => {
            log("read function disconnect error: {}", .{e});
            return error.Disconnected;
        },
        error.WouldBlock
        ,error.SystemResources
        ,error.OperationAborted
        => {
            log("WARNING: read function retry error: {}", .{e});
            return error.Retry;
        },
        error.IsDir
        ,error.Unexpected
        ,error.AccessDenied
        => panic("read function failed with: {}", .{e}),
    };
}

pub fn recvfullTimeout(sockfd: fd_t, buf: []u8, timeoutMillis: u32) !bool {
    return common.recvfullTimeout(sockfd, buf, timeoutMillis) catch |e| switch (e) {
        error.BrokenPipe
        ,error.ConnectionResetByPeer
        ,error.ConnectionTimedOut
        ,error.InputOutput
        ,error.NotOpenForReading
        => {
            log("read function disconnect error: {}", .{e});
            return error.Disconnected;
        },
        error.Retry => return error.Retry, // already logged
        error.WouldBlock
        ,error.SystemResources
        ,error.OperationAborted
        => {
            log("WARNING: read function retry error: {}", .{e});
            return error.Retry;
        },
        error.IsDir
        ,error.Unexpected
        ,error.AccessDenied
        => panic("read function failed with: {}", .{e}),
    };
}

pub fn setsockopt(sockfd: fd_t, level: u32, optname: u32, opt: []const u8) !void {
    os.setsockopt(sockfd, level, optname, opt) catch |e| switch (e) {
        error.SystemResources
        ,error.NetworkSubsystemFailed
        => {
            log("WARNING: setsockopt function error: {}", .{e});
            return error.Retry;
        },
        error.InvalidProtocolOption
        ,error.FileDescriptorNotASocket
        ,error.TimeoutTooBig
        ,error.AlreadyConnected
        ,error.SocketNotBound
        ,error.Unexpected
        => panic("setsockopt function fatal with: {}", .{e}),
    };
}

pub fn bind(sockfd: fd_t, addr: *const os.sockaddr, len: os.socklen_t) !void {
    os.bind(sockfd, addr, len) catch |e| switch (e) {
        error.SystemResources
        ,error.AddressInUse
        ,error.AddressNotAvailable
        ,error.NetworkSubsystemFailed
        => {
            log("WARNING: bind function error: {}", .{e});
            return error.Retry;
        },
        error.AccessDenied
        ,error.AlreadyBound
        ,error.Unexpected
        ,error.FileNotFound
        ,error.FileDescriptorNotASocket
        ,error.NotDir
        ,error.ReadOnlyFileSystem
        ,error.SymLinkLoop
        ,error.NameTooLong
        => panic("bind function failed with: {}", .{e}),
    };
}

pub fn listen(sockfd: fd_t, backlog: u31) !void {
    os.listen(sockfd, backlog) catch |e| switch (e) {
        error.AddressInUse
        ,error.NetworkSubsystemFailed
        ,error.SystemResources
        => {
            log("WARNING: listen function error: {}", .{e});
            return error.Retry;
        },
        error.OperationNotSupported
        ,error.AlreadyConnected
        ,error.FileDescriptorNotASocket
        ,error.SocketNotBound
        ,error.Unexpected
        => panic("listen function failed with: {}", .{e}),
    };
}

pub fn makeListenSock(addr: *std.net.Address, backlog: u31) !fd_t {
    const sockfd = try socket(addr.any.family, os.SOCK_STREAM, os.IPPROTO_TCP);
    errdefer os.close(sockfd);
    try setsockopt(sockfd, os.SOL_SOCKET, os.SO_REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try bind(sockfd, &addr.any, addr.getOsSockLen());
    try listen(sockfd, backlog);
    return sockfd;
}

pub fn accept(sockfd: fd_t, addr: *os.sockaddr, addr_size: *os.socklen_t, flags: u32) !fd_t {
    return os.accept(sockfd, addr, addr_size, flags) catch |e| switch (e) {
        error.ConnectionAborted
        ,error.ConnectionResetByPeer
        ,error.ProtocolFailure
        ,error.BlockedByFirewall
        ,error.WouldBlock
        => {
            log("accept dropped client: {}", .{e});
            return error.ClientDropped;
        },
        error.SystemResources
        ,error.ProcessFdQuotaExceeded
        ,error.SystemFdQuotaExceeded
        ,error.NetworkSubsystemFailed
        => {
            log("WARNING: accept function error: {}", .{e});
            return error.Retry;
        },
        error.Unexpected
        ,error.PermissionDenied
        ,error.FileDescriptorNotASocket
        ,error.SocketNotListening
        ,error.OperationNotSupported
        => panic("accept function failed with: {}", .{e}),
    };
}
