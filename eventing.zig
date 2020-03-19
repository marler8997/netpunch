const std = @import("std");
pub usingnamespace if (std.builtin.os.tag == .windows)
    @import("./eventing/select.zig")
else
    @import("./eventing/epoll.zig");
