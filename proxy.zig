const std = @import("std");
const mem = std.mem;
const os = std.os;

const common = @import("./common.zig");

const assert = std.debug.assert;
const fd_t = os.fd_t;

const MAX_HOST = 253;
const MAX_PORT_DIGITS = 5;

pub const Proxy = union(enum) {
    None: void,
    Http: Http,
    
    pub const Http = struct {
        host: []const u8,
        port: u16,
    };

    // TODO: the HTTP protocol means that we could read data from the target
    //       server during negotiation, so this function would need to support
    //       returning any extra data received from the target server
    pub fn connectHost(self: *const @This(), host: []const u8, port: u16) !fd_t {
        std.debug.assert(host.len <= MAX_HOST);

        switch (self.*) {
            .None => return common.connectHost(host, port),
            .Http => |http| {
                const sockfd = try common.connectHost(http.host, http.port);
                errdefer common.shutdownclose(sockfd);
                try sendHttpConnect(sockfd, host, port);
                try receiveHttpOk(sockfd, 10000);
                return sockfd;
            },
        }
    }

    pub fn eql(self: *const @This(), other: *const @This()) bool {
        switch (self.*) {
            .None => switch (other.*) { .None => return true, else => return false },
            .Http => |selfHttp| switch (other.*) {
                .Http => |otherHttp| return selfHttp.port == otherHttp.port and
                    std.mem.eql(u8, selfHttp.host, otherHttp.host),
                else => return false,
            },
        }
    }

    pub fn format(
        self: Proxy,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        switch (self) {
            .None => return,
            .Http => |http| {
                try std.fmt.format(out_stream, "http://{}:{}/", .{http.host, http.port});
            },
        }
    }
};

pub fn sendHttpConnect(sockfd: fd_t, host: []const u8, port: u16) !void {
    const PART1 = "CONNECT ";
    const PART2 = " HTTP/1.1\r\nHost: ";
    const PART3 = "\r\n\r\n";
    const MAX_CONNECT_REQUEST =
          PART1.len
        + MAX_HOST + 1 + MAX_PORT_DIGITS
        + PART2.len
        + MAX_HOST + 1 + MAX_PORT_DIGITS
        + PART3.len;
    var requestBuffer : [MAX_CONNECT_REQUEST]u8 = undefined;
    const request = std.fmt.bufPrint(&requestBuffer,
        PART1 ++ "{}:{}" ++ PART2 ++ "{}:{}" ++ PART3,
        .{host, port, host, port}) catch |e| switch (e) {
        error.NoSpaceLeft
        => std.debug.panic("code bug: HTTP CONNECT requeset buffer {} not big enough", .{MAX_CONNECT_REQUEST}),
    };
    try common.sendfull(sockfd, request, 0);
}

const Http200Response = "HTTP/1.1 200";
const HttpEndResponse = "\r\n\r\n";
pub fn receiveHttpOk(sockfd: fd_t, readTimeoutMillis: i32) !void {
    // TODO: I must implement a reasonable timeout
    //       to prevent waiting forever if I never get \r\n\r\n
    const State = union(enum) {
        Reading200: u8,
        ReadingToEnd: u8,
    };
    var buf: [1]u8 = undefined;
    var state = State { .Reading200 = 0 };
    while (true) {
        // TODO: read with a timeout
        const received = try os.read(sockfd, &buf);
        if (received == 0)
            return error.HttpProxyDisconnectedDurringReply;
        //std.debug.warn("[DEBUG] got '{}' 0x{x}\n", .{buf[0..], buf[0]});
        switch (state) {
            .Reading200 => |left| {
                if (buf[0] != Http200Response[left])
                    return error.HttpProxyUnexpectedReply;
                state.Reading200 += 1;
                if (state.Reading200 == Http200Response.len)
                    state = State { .ReadingToEnd = 0 };
            },
            .ReadingToEnd => |matched| {
                if (buf[0] == HttpEndResponse[matched]) {
                    state.ReadingToEnd += 1;
                    if (state.ReadingToEnd == HttpEndResponse.len)
                        return; // success
                } else {
                    state.ReadingToEnd = 0;
                }
            },
        }
    }
}


pub const HostAndProxy = struct {
    host: []const u8,
    proxy: Proxy,

    pub fn eql(self: *const @This(), other: *const @This()) bool {
        return std.mem.eql(u8, self.host, other.host) and
            self.proxy.eql(&other.proxy);
    }
};

pub fn parseProxy(connectSpec: anytype) !HostAndProxy {
    return parseProxyTyped(@TypeOf(connectSpec), connectSpec);
}
pub fn parseProxyTyped(comptime String: type, connectSpec: String) !HostAndProxy {
    var rest = connectSpec;
    if (common.skipOver(String, &rest, "http://")) {
        const slashIndex = mem.indexOfScalar(u8, rest, '/') orelse
            return error.MissingSlashToDelimitProxy;
        var host = rest[slashIndex + 1..];
        if (host.len == 0)
            return error.NoHostAfterProxy;
        var proxyHostPort = rest[0 .. slashIndex];
        var proxyColonIndex = mem.indexOfScalar(u8, proxyHostPort, ':') orelse
            return error.ProxyMissingPort;
        var proxyHost = proxyHostPort[0 .. proxyColonIndex];
        if (proxyHost.len == 0)
            return error.ProxyMissingHost;
        var proxyPortString = proxyHostPort[proxyColonIndex+1..];
        if (proxyHost.len == 0)
            return error.ProxyMissingPort;
        const proxyPort = std.fmt.parseInt(u16, proxyPortString, 10) catch |e| switch (e) {
            error.Overflow => return error.ProxyPortOutOfRange,
            error.InvalidCharacter => return error.ProxyPortNotNumber,
        };
        return HostAndProxy {
            .host = host,
            .proxy = Proxy { .Http = .{
                .host = proxyHost,
                .port = proxyPort,
            }},
        };
    }
    return HostAndProxy { .host = connectSpec, .proxy = Proxy.None };
}

test "parseProxy" {
    assert((HostAndProxy {
        .host = "a",
        .proxy = Proxy.None,
    }).eql(&try parseProxyTyped([]const u8, "a")));
    assert((HostAndProxy {
        .host = "hey",
        .proxy = Proxy { .Http = .{.host = "what.com", .port = 1234} },
    }).eql(&try parseProxyTyped([]const u8, "http://what.com:1234/hey")));
}
