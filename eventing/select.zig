const std = @import("std");
const builtin = std.builtin;
const os = std.os;

const fd_t = os.fd_t;

usingnamespace if (builtin.os.tag == .windows)
    @import("./selectwindows.zig")
else
    @import("./selectnotwindows.zig");

pub const EventFlags = struct {
    pub const read = 0x01;
    pub const hangup = 0x02;
};

// TODO: allow various backend-specific options like select fd capacity
// TODO: add Eventer reference to EventerData rather
//       than passing it by default
//       some programs only have 1 eventer and don't need to
//       pass it as an argument
pub fn EventerTemplate(comptime EventError: type, comptime EventerData: type, comptime CallbackData: type) type {
    return struct {
        pub const Callback = struct {
            func: CallbackFn,
            data: CallbackData,
        };
        pub const CallbackFn = fn(server: *@This(), callback: *Callback) anyerror!void;
        const FdInfo = struct {
            fd: fd_t,
            flags: u8,
            callback: *Callback,
        };

        /// data that can be shared between all callbacks
        eventerData: EventerData,
        fdlist: [64]FdInfo,
        pub fn init(eventerData: EventerData) !@This() {
            var this : @This() = undefined;
            this.eventerData = eventerData;
            return this;
        }

        pub fn add(self: *@This(), fd: fd_t, flags: u32, data: *Callback) !void {
            std.debug.panic("not implemented", .{});
            //if (flags & EventFlags.read) {
            //    //self.readSet.add(
            //}
            //var event = os.epoll_event {
            //    .events = flags,
            //    .data = os.epoll_data { .ptr = @ptrToInt(data) },
            //};
            //try os.epoll_ctl(self.epollfd, os.EPOLL_CTL_ADD, fd, &event);
        }
        pub fn modify(self: *@This(), fd: fd_t, flags: u32, data: *Callback) !void {
            var event = os.epoll_event {
                .events = flags,
                .data = os.epoll_data { .ptr = @ptrToInt(data) },
            };
            try os.epoll_ctl(self.epollfd, os.EPOLL_CTL_MOD, fd, &event);
        }

        pub fn remove(self: *@This(), fd: fd_t) !void {
            // TODO: kernels before 2.6.9 had a bug where event must be non-null
            try os.epoll_ctl(self.epollfd, os.EPOLL_CTL_DEL, fd, null);
        }

        pub fn loop(self: *@This()) anyerror!void {
            std.debug.panic("not implemented", .{});
            //while (true) {
            //    readSet: fd_set(64), // just hardcode to 64 for now
            //    writeSet: fd_set(64), // just hardcode to 64 for now
            //    errorSet: fd_set(64), // just hardcode to 64 for now
            //    var events : [16]os.epoll_event = undefined;
            //    //std.debug.warn("[DEBUG] waiting for event...\n", .{});
            //    const count = os.epoll_wait(self.epollfd, &events, -1);
            //    //std.debug.warn("[DEBUG] epoll_wait returned {}\n", .{count});
            //    {
            //        const errno = os.errno(count);
            //        if (errno != 0) {
            //            std.debug.warn("epoll_wait failed, errno={}", .{errno});
            //            return error.EpollFailed;
            //        }
            //    }
            //    for (events[0..count]) |event| {
            //        const callback = @intToPtr(*Callback, event.data.ptr);
            //        try callback.func(self, callback);
            //    }
            //}
        }
    };
}
