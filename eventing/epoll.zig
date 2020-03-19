const std = @import("std");
const os = std.os;

const timing = @import("./timing.zig");
const logging = @import("../logging.zig");

const fd_t = os.fd_t;
const log = logging.log;

pub const EventFlags = struct {
    pub const read = os.EPOLLIN;
    pub const write = os.EPOLLOUT;
    pub const hangup = os.EPOLLRDHUP;
};

pub fn EventerTemplate(comptime EventError: type, comptime EventerData: type, comptime CallbackData: type) type {
    return struct {
        pub const EventerErrorAlias = EventerError;
        pub const EventerDataAlias = EventerData;
        pub const Callback = struct {
            func: CallbackFn,
            data: CallbackData,
            pub fn init(func: CallbackFn, data: CallbackData) @This() {
                return @This() {
                    .func = func,
                    .data = data,
                };
            }
        };
        pub const CallbackFn = fn(server: *@This(), callback: *Callback) EventError!void;

        /// data that can be shared between all callbacks
        data: EventerData,
        epollfd: fd_t,
        ownEpollFd: bool,
        pub fn init(data: EventerData) !@This() {
            return @This().initEpoll(data, try os.epoll_create1(0), true);
        }
        pub fn initEpoll(data: EventerData, epollfd: fd_t, ownEpollFd: bool) @This() {
            return @This() {
                .data = data,
                .epollfd = epollfd,
                .ownEpollFd = ownEpollFd,
            };
        }
        pub fn deinit(self: *@This()) void {
            if (self.ownEpollFd)
                os.close(self.epollfd);
        }

        pub fn add(self: *@This(), fd: fd_t, flags: u32, callback: *Callback) !void {
            var event = os.epoll_event {
                .events = flags,
                .data = os.epoll_data { .ptr = @ptrToInt(callback) },
            };
            try os.epoll_ctl(self.epollfd, os.EPOLL_CTL_ADD, fd, &event);
        }
        pub fn modify(self: *@This(), fd: fd_t, flags: u32, callback: *Callback) !void {
            var event = os.epoll_event {
                .events = flags,
                .data = os.epoll_data { .ptr = @ptrToInt(callback) },
            };
            try os.epoll_ctl(self.epollfd, os.EPOLL_CTL_MOD, fd, &event);
        }

        pub fn remove(self: *@This(), fd: fd_t) void {
            // TODO: kernels before 2.6.9 had a bug where event must be non-null
            os.epoll_ctl(self.epollfd, os.EPOLL_CTL_DEL, fd, null) catch |e| switch (e) {
                error.FileDescriptorNotRegistered // we could ignore this, but this represents a code bug
                ,error.FileDescriptorAlreadyPresentInSet
                ,error.FileDescriptorIncompatibleWithEpoll
                ,error.OperationCausesCircularLoop
                ,error.SystemResources // this should never happen during removal
                ,error.UserResourceLimitReached // this should never happen during removal
                ,error.Unexpected
                => std.debug.panic("epoll_ctl DEL failed with {}", .{e}),
            };
        }

        // returns: false if there was a timeout
        fn handleEventsGeneric(self: *@This(), timeoutMillis: i32) EventError!bool {
            // get 1 event at a time to prevent stale events
            var events : [1]os.epoll_event = undefined;
            const count = os.epoll_wait(self.epollfd, &events, timeoutMillis);
            const errno = os.errno(count);
            switch (errno) {
                0 => {},
                os.EBADF
                ,os.EFAULT
                ,os.EINTR
                ,os.EINVAL
                => std.debug.panic("epoll_wait failed with {}", .{errno}),
                else => std.debug.panic("epoll_wait failed with {}", .{errno}),
            }
            if (count == 0)
                return false; // timeout
            for (events[0..count]) |event| {
                const callback = @intToPtr(*Callback, event.data.ptr);
                try callback.func(self, callback);
            }
            return true; // was not a timeout
        }
        pub fn handleEvents(self: *@This(), timeoutMillis: u32) EventError!bool {
            return self.handleEventsGeneric(@intCast(i32, timeoutMillis));
        }

        pub fn handleEventsNoTimeout(self: *@This()) EventError!void {
            if (!try self.handleEventsGeneric(-1))
                std.debug.panic("epoll returned 0 with ifinite timeout?", .{});
        }
        // a convenient helper method, might remove this
        pub fn loop(self: *@This()) EventError!void {
            while (true) {
                try self.handleEventsNoTimeout();
            }
        }
    };
}

pub fn epoll_create1(flags: u32) !fd_t {
    return os.epoll_create1(flags) catch |e| switch (e) {
        error.SystemFdQuotaExceeded
        ,error.ProcessFdQuotaExceeded
        ,error.SystemResources
        => {
            log("epoll_create1 failed with {}", .{e});
            return error.Retry;
        },
        error.Unexpected
        => std.debug.panic("epoll_create1 failed with {}", .{e}),
    };
}