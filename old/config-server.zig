const std = @import("std");
const mem = std.mem;
const os = std.os;
const net = std.net;

const common = @import("./common.zig");
const eventing = @import("./eventing.zig");
const pool = @import("./pool.zig");
const Pool = pool.Pool;

const fd_t = os.fd_t;
const Address = net.Address;
const EventFlags = eventing.EventFlags;

const Fd = struct {
    fd: fd_t,
};
const Eventer = eventing.EventerTemplate(anyerror, struct {}, Fd);

const global = struct {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    // TODO: change from 1 to something else
    var clientPool = Pool(Client, 1).init(&arena.allocator);
    var config = [_]u8 {
        11,                 // msg size
        3,                  // add endpoint
        0, 0, 0, 0,         // connection ID (one connection per ID)
        96, 19, 192, 252,   // ip address
        0xFF & (9282 >> 8), // port
        0xFF & (9282 >> 0),
    };
};

const Client = struct {
    callback: Eventer.Callback,
};

fn callbackToClient(callback: *Eventer.Callback) *Client {
    return @ptrCast(*Client,
        @ptrCast([*]u8, callback) - @byteOffsetOf(Client, "callback")
    );
}

pub fn main() anyerror!u8 {
    var eventer = try Eventer.init(.{});

    var serverCallback = initServer: {
        const port : u16 = 9281; // picked a random one
        const sockfd = try common.makeListenSock(&Address.initIp4([4]u8 {0, 0, 0, 0}, port));
        std.debug.warn("[DEBUG] server socket is {}\n", .{sockfd});
        break :initServer Eventer.Callback {
            .func = onAccept,
            .data = Fd { .fd = sockfd },
        };
    };
    try eventer.add(serverCallback.data.fd, EventFlags.read, &serverCallback);
    try eventer.loop();
    return 0;
}

fn onAccept(eventer: *Eventer, callback: *Eventer.Callback) anyerror!void {
    const fd = callback.data.fd;
    std.debug.warn("accepting client on socket {}!\n", .{fd});

    var addr : Address = undefined;
    var addrlen : os.socklen_t = @sizeOf(@TypeOf(addr));

    const newsockfd = try os.accept(fd, &addr.any, &addrlen, os.SOCK_NONBLOCK);
    errdefer common.shutdownclose(newsockfd);
    std.debug.warn("got new client {} from {}\n", .{newsockfd, addr});

    // can add a client/server handshake/auth but for now I'm just going to send the config
    // send the config
    {
        std.debug.warn("s={} sending {}-byte config...\n", .{newsockfd, global.config.len});
        const sendResult = os.send(newsockfd, &global.config, 0) catch |e| {
            std.debug.warn("s={} send initial config of {}-bytes failed: {}\n", .{newsockfd, global.config.len, e});
            common.shutdownclose(newsockfd);
            return;
        };
        if (sendResult != global.config.len) {
            std.debug.warn("s={} failed to send {}-byte initial config, returned {}\n", .{newsockfd, global.config.len, sendResult});
            common.shutdownclose(newsockfd);
            return;
        }
    }

    {
        var newClient = try global.clientPool.create();
        errdefer global.clientPool.destroy(newClient);
        //std.debug.warn("[DEBUG] new client at 0x{x}\n", .{@ptrToInt(newClient)});
        newClient.* = Client {
            .callback = Eventer.Callback {
                .func = onClientData,
                .data = Fd { .fd = newsockfd },
            },
        };
        try eventer.add(newsockfd, EventFlags.read, &newClient.callback);
        // we've now tranferred ownership of newClient, do not free it here, even on errors
    }
}

fn removeClient(eventer: *Eventer, callback: *Eventer.Callback) !void {
    eventer.remove(callback.data.fd);
    common.shutdownclose(callback.data.fd);
    global.clientPool.destroy(callbackToClient(callback));
}

fn onClientData(eventer: *Eventer, callback: *Eventer.Callback) anyerror!void {
    const fd = callback.data.fd;
    //std.debug.warn("got data on socket {}!\n", .{fd});
    var buffer: [100]u8 = undefined;
    const len = os.read(fd, &buffer) catch |e| {
        try removeClient(eventer, callback);
        return e;
    };
    if (len == 0) {
        std.debug.warn("client {} closed because read returned 0\n", .{fd});
        try removeClient(eventer, callback);
        return;
    }
    std.debug.warn("[DEBUG] got {} bytes from socket {}\n", .{len, fd});
}
