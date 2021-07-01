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

const INVALID_FD = if(std.builtin.os.tag == .windows) std.os.windows.ws2_32.INVALID_SOCKET
    else -1;

const Client = struct {
    fd: fd_t,
    callback: Eventer.Callback,
};

const global = struct {
    var listenFd : fd_t = undefined;
    var clientA : Client = undefined;
    var clientB : Client = undefined;

    // client's are 'linked' once they have sent data to each-other
    // if client's are linked, then when one closes it will cause
    // the other to close
    var clientsLinked : bool = undefined;

    var buffer : [8192]u8 = undefined;
};

fn callbackToClient(callback: *Eventer.Callback) *Client {
    if (callback == &global.clientA.callback)
        return &global.clientA;
    std.debug.assert(callback == &global.clientB.callback); // code bug if false
    return &global.clientB;
}

pub fn main() anyerror!u8 {
    global.clientA.fd = INVALID_FD;
    global.clientB.fd = INVALID_FD;
    var eventer = try Eventer.init(.{});

    var serverCallback = initServer: {
        const port : u16 = 9282;
        global.listenFd = try common.makeListenSock(&Address.initIp4([4]u8 {0, 0, 0, 0}, port));
        std.debug.warn("[DEBUG] server socket is {}\n", .{global.listenFd});
        break :initServer Eventer.Callback {
            .func = onAccept,
            .data = .{},
        };
    };
    try eventer.add(global.listenFd, EventFlags.read, &serverCallback);
    try eventer.loop();
    return 0;
}

fn onAccept(eventer: *Eventer, callback: *Eventer.Callback) anyerror!void {
    _ = callback;
    var addr : Address = undefined;
    var addrlen : os.socklen_t = @sizeOf(@TypeOf(addr));

    const newsockfd = try os.accept(global.listenFd, &addr.any, &addrlen, os.SOCK_NONBLOCK);
    errdefer common.shutdownclose(newsockfd);

    const ClientInfos = struct { newClient: *Client, otherClient: *Client };
    var info = clientInit: {
        if (global.clientA.fd == INVALID_FD)
            break :clientInit ClientInfos {.newClient=&global.clientA, .otherClient=&global.clientB};
        if (global.clientB.fd == INVALID_FD)
            break :clientInit ClientInfos {.newClient=&global.clientB, .otherClient=&global.clientA};

        std.debug.warn("s={} closing connection from {}, already have 2 clients\n", .{newsockfd, addr});
        common.shutdownclose(newsockfd);
        return;
    };

    std.debug.warn("s={} new client from {}\n", .{newsockfd, addr});
    errdefer info.newClient.fd = INVALID_FD;
    if (info.otherClient.fd == INVALID_FD or info.otherClient.callback.func == onDataClosing) {
        info.newClient.* = Client {
            .fd = newsockfd,
            .callback = Eventer.Callback {
                .func = onDataOneClient,
                .data = .{},
            },
        };
        try eventer.add(newsockfd, EventFlags.hangup, &info.newClient.callback);
    } else {
        std.debug.assert(info.otherClient.callback.func == onDataOneClient);
        info.newClient.* = Client {
            .fd = newsockfd,
            .callback = Eventer.Callback {
                .func = onDataTwoClients,
                .data = .{},
            },
        };
        try eventer.add(newsockfd, EventFlags.read, &info.newClient.callback);

        try eventer.modify(info.otherClient.fd, EventFlags.read, &info.otherClient.callback);
        info.otherClient.callback.func = onDataTwoClients;

        // initialize this because now we're using onDataTwoClients which is where it
        // will be used
        global.clientsLinked = false;
    }
}

// because we aren't listening for data, this should only be called if the socket has been closed
fn onDataOneClient(eventer: *Eventer, callback: *Eventer.Callback) anyerror!void {
    const clientRef = callbackToClient(callback);
    std.debug.warn("s={} connection closed\n", .{clientRef.fd});
    std.debug.assert(clientRef.fd != INVALID_FD);
    eventer.remove(clientRef.fd);
    common.shutdownclose(clientRef.fd);
    clientRef.fd = INVALID_FD;
}

// in this callback, you can assume that both clients are valid and have this callback
fn onDataTwoClients(eventer: *Eventer, callback: *Eventer.Callback) anyerror!void {
    std.debug.assert(global.clientA.fd != INVALID_FD and global.clientB.fd != INVALID_FD);
    std.debug.assert(global.clientA.callback.func == onDataTwoClients);
    std.debug.assert(global.clientB.callback.func == onDataTwoClients);

    if (callback == &global.clientA.callback) {
        try forward(eventer, &global.clientA, &global.clientB);
    } else {
        std.debug.assert(callback == &global.clientB.callback); // code bug if false
        try forward(eventer, &global.clientB, &global.clientA);
    }
}

fn in_forward_from_closed(eventer: *Eventer, from: *Client, to: *Client) !void {
    eventer.remove(from.fd);
    os.close(from.fd);
    from.fd = INVALID_FD;

    if (!global.clientsLinked) {
        std.debug.warn("client's weren't linked, back to one-client s={}\n", .{to.fd});
        // clients haven't sent any data so keep the other client open
        to.callback.func = onDataOneClient;
        try eventer.modify(to.fd, EventFlags.hangup, &to.callback);
    } else {
        std.debug.warn("client's were linked, disconnecting s={}\n", .{to.fd});
        to.callback.func = onDataClosing;
        try common.shutdown(to.fd);
    }
}

fn forward(eventer: *Eventer, from: *Client, to: *Client) !void {
    const length = os.read(from.fd, &global.buffer) catch |e| {
        std.debug.warn("s={} read failed: {}\n", .{from.fd, e});
        try in_forward_from_closed(eventer, from, to);
        return;
    };
    if (length == 0) {
        std.debug.warn("s={} disconnected\n", .{from.fd});
        try in_forward_from_closed(eventer, from, to);
        return;
    }
    std.debug.warn("s={} forwarding {} bytes to {}\n", .{from.fd, length, to.fd});
    const sendResult = os.send(to.fd, global.buffer[0..length], 0) catch |e| {
        std.debug.warn("send on {} failed: {}\n", .{to.fd, e});
        std.debug.warn("TODO: implement cleanup...\n", .{});
        return error.NotImplemented;
    };
    if (sendResult != length) {
        std.debug.warn("only sent {} out of {} on {}\n", .{sendResult, length, to.fd});
        std.debug.warn("TODO: implement something here...\n", .{});
        return error.NotImplemented;
    }
    if (!global.clientsLinked) {
        std.debug.warn("s={} linked to s={}\n", .{from.fd, to.fd});
        global.clientsLinked = true;
    }
}

fn onDataClosing(eventer: *Eventer, callback: *Eventer.Callback) anyerror!void {
    const clientRef = callbackToClient(callback);
    std.debug.warn("s={} finishing close\n", .{clientRef.fd});
    eventer.remove(clientRef.fd);
    os.close(clientRef.fd);
    clientRef.fd = INVALID_FD;
}
