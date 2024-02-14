const std = @import("std");
const os = std.os;

const logging = @import("../logging.zig");
const common = @import("./common.zig");

const eventing = @import("../eventing.zig");
const EventerOptions = eventing.EventerOptions;

const fd_t = os.fd_t;
const log = logging.log;

pub const EventFlags = struct {
    pub const read = os.linux.EPOLL.IN;
    pub const write = os.linux.EPOLL.OUT;
    pub const hangup = os.linux.EPOLL.RDHUP;
};

pub fn EventerTemplate(comptime options: EventerOptions) type {
    return struct {
        pub const Fd = fd_t;
        pub const Data = options.Data;
        pub const CallbackError = options.CallbackError;
        pub const Callback = struct {
            func: CallbackFn,
            data: options.CallbackData,
            pub fn init(func: CallbackFn, data: options.CallbackData) @This() {
                return @This() {
                    .func = func,
                    .data = data,
                };
            }
        };
        pub const CallbackFn = *const fn(server: *@This(), callback: *Callback) CallbackError!void;

        /// data that can be shared between all callbacks
        data: Data,
        epollfd: fd_t,
        ownEpollFd: bool,
        pub fn init(data: Data) !@This() {
            return @This().initEpoll(data, try os.epoll_create1(0), true);
        }
        pub fn initEpoll(data: Data, epollfd: fd_t, ownEpollFd: bool) @This() {
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

        pub fn add(self: *@This(), fd: fd_t, flags: u32, callback: *Callback) common.EventerAddError!void {
            var event = os.linux.epoll_event {
                .events = flags,
                .data = os.linux.epoll_data { .ptr = @intFromPtr(callback) },
            };
            try os.epoll_ctl(self.epollfd, os.linux.EPOLL.CTL_ADD, fd, &event);
        }
        pub fn modify(self: *@This(), fd: fd_t, flags: u32, callback: *Callback) common.EventerModifyError!void {
            var event = os.linux.epoll_event {
                .events = flags,
                .data = os.linux.epoll_data { .ptr = @intFromPtr(callback) },
            };
            try os.epoll_ctl(self.epollfd, os.linux.EPOLL.CTL_MOD, fd, &event);
        }

        pub fn remove(self: *@This(), fd: fd_t) void {
            // TODO: kernels before 2.6.9 had a bug where event must be non-null
            os.epoll_ctl(self.epollfd, os.linux.EPOLL.CTL_DEL, fd, null) catch |e| switch (e) {
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
        fn handleEventsGeneric(self: *@This(), timeoutMillis: i32) CallbackError!bool {
            // get 1 event at a time to prevent stale events
            var events : [1]os.linux.epoll_event = undefined;
            const count = os.epoll_wait(self.epollfd, &events, timeoutMillis);
            const errno = os.errno(count);
            switch (errno) {
                .SUCCESS => {},
                .BADF
                ,.FAULT
                ,.INTR
                ,.INVAL
                => std.debug.panic("epoll_wait failed with {}", .{errno}),
                else => std.debug.panic("epoll_wait failed with {}", .{errno}),
            }
            if (count == 0)
                return false; // timeout
            for (events[0..count]) |event| {
                const callback: *Callback = @ptrFromInt(event.data.ptr);
                try callback.func(self, callback);
            }
            return true; // was not a timeout
        }
        pub fn handleEvents(self: *@This(), timeoutMillis: u32) CallbackError!bool {
            return self.handleEventsGeneric(@intCast(timeoutMillis));
        }

        pub fn handleEventsNoTimeout(self: *@This()) CallbackError!void {
            if (!try self.handleEventsGeneric(-1))
                std.debug.panic("epoll returned 0 with ifinite timeout?", .{});
        }
        // a convenient helper method, might remove this
        // TODO: should only return CallbackError, not CallbackError!void
        pub fn loop(self: *@This()) CallbackError!void {
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
