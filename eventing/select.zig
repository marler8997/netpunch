const std = @import("std");
const builtin = std.builtin;
const os = std.os;

const common = @import("./common.zig");

usingnamespace if (builtin.os.tag == .windows)
    @import("./selectwindows.zig")
else
    @import("./selectnotwindows.zig");

pub const EventFlags = struct {
    pub const read = 0x01;
    pub const write = 0x02;
    pub const hangup = 0x04;
};

// TODO: allow various backend-specific options like select fd capacity
// TODO: add Eventer reference to EventerData rather
//       than passing it by default
//       some programs only have 1 eventer and don't need to
//       pass it as an argument
pub fn EventerTemplate(comptime EventError: type, comptime EventerData: type, comptime CallbackData: type) type {
    return struct {
        pub const Fd = fd_t;
        pub const Callback = struct {
            func: CallbackFn,
            data: CallbackData,
        };
        pub const CallbackFn = fn(server: *@This(), callback: *Callback) EventError!void;
        const FdInfo = struct {
            fd: fd_t,
            flags: u32,
            callback: *Callback,
        };
        const CountType = u8;

        /// data that can be shared between all callbacks
        eventerData: EventerData,
        fdlist: [64]FdInfo,
        fdcount: CountType,
        pub fn init(eventerData: EventerData) !@This() {
            var this : @This() = undefined;
            this.eventerData = eventerData;
            return this;
        }

        fn find(self: @This(), fd: fd_t) ?CountType {
            var i : CountType = 0;
            while (i < self.fdcount) {
                if (self.fdlist[i].fd == fd)
                    return i;
            }
            return null;
        }

        pub fn add(self: *@This(), fd: fd_t, flags: u32, callback: *Callback) common.EventerAddError!void {
            if (self.fdcount == self.fdlist.len)
                return error.UserResourceLimitReached;
            std.debug.assert(self.find(fd) == null);
            self.fdlist[self.fdcount] = .{ .fd = fd, .flags = flags, .callback = callback };
            self.fdcount += 1;
        }
        pub fn modify(self: *@This(), fd: fd_t, flags: u32, callback: *Callback) common.EventerAddError!void {
            if (self.find(fd)) |i| {
                self.fdlist[i].flags = flags;
                self.fdlist[i].callback = callback;
            } else return error.SocketNotAddedToEventer;
        }
        pub fn remove(self: *@This(), fd: fd_t) void {
            if (self.find(fd)) |i| {
                var j = i;
                while (j + 1 < self.fdcount) {
                    self.fdlist[j] = self.fdlist[j+1];
                }
                self.fdcount -= 1;
            } else std.debug.panic("remove called on socket {} that is not registered with eventer", .{fd});
        }

        // returns: false if there was a timeout
        fn handleEventsGeneric(self: *@This(), timeout_ms: i32) EventError!bool {

            const nfds = if (builtin.os.tag == .windows) 0 else @compileError("select nfds not implemented for non-windows");

            // for now, just limit this to 64
            var read_set  : fd_set(64) = .{ .fd_count = 0, .fd_array = undefined };
            var write_set : fd_set(64) = .{ .fd_count = 0, .fd_array = undefined };
            var error_set : fd_set(64) = .{ .fd_count = 0, .fd_array = undefined };
            {var i : CountType = 0; while (i < self.fdcount) : (i += 1) {
                if ( (self.fdlist[i].flags & EventFlags.read) != 0) {
                    set_fd(fd_set(64), &read_set, self.fdlist[i].fd);
                }
                if ( (self.fdlist[i].flags & EventFlags.write) != 0) {
                    set_fd(fd_set(64), &write_set, self.fdlist[i].fd);
                }
                if ( (self.fdlist[i].flags & EventFlags.hangup) != 0) {
                    set_fd(fd_set(64), &error_set, self.fdlist[i].fd);
                }
            }}
            var timeout_buf : timeval = undefined;
            const timeout = init: {
                if (timeout_ms == -1) break :init null;
                std.debug.assert(timeout_ms >= 0);
                timeout_buf = msToTimeval(@intCast(u31, timeout_ms));
                break :init &timeout_buf;
            };
            const result = select(nfds, read_set.base(), write_set.base(), error_set.base(), timeout);
            if (result == -1) {
                // TODO: create wrapper function in std.os to handle all error codes
                std.debug.panic("select failed, lasterror = {}", .{std.os.windows.ws2_32.WSAGetLastError()});
                //std.debug.warn("Error: select failed, lasterror = {}", .{std.os.windows.ws2_32.WSAGetLastError()});
                //return error.SelectFailed;
            }
            if (result == 0)
                return false; // timeout

            var left = result;
            while (left > 0) {
                // TODO: prevent sockets from being called multiple times from different sets?
                for (read_set.fd_array[0..read_set.fd_count]) |fd| {
                    if (self.find(fd)) |i| {
                        try self.fdlist[i].callback.func(self, self.fdlist[i].callback);
                    } else std.debug.panic("bug, select returned socket not in list {}", .{fd});
                }
            }
            return true;
        }

        pub fn handleEventsNoTimeout(self: *@This()) EventError!void {
            if (!try self.handleEventsGeneric(-1))
                std.debug.panic("epoll returned 0 with ifinite timeout?", .{});
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
