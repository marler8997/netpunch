const std = @import("std");

pub const select = @import("eventing/select.zig");
pub const epoll = @import("eventing/epoll.zig");

pub const default = if (std.builtin.os.tag == .windows) select else epoll;

pub const EventerOptions = struct {
    // The extra data type that the eventer tracks
    Data: type = struct {},
    // The error type for callbacks
    CallbackError: type = anyerror,
    // The data that is passed to callbacks
    CallbackData: type = struct {},
};
