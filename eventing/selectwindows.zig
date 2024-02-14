const std = @import("std");
const os = std.os;

pub const fd_t = os.socket_t;

pub const fd_base_set = extern struct {
    fd_count: c_uint,
    fd_array: [0]fd_t,
};

pub fn fd_set(comptime setSize: comptime_int) type {
    return extern struct {
        fd_count: c_uint,
        fd_array: [setSize]fd_t,
        pub fn base(self: *@This()) *fd_base_set {
            return @ptrCast(self);
        }
        pub fn add(self: *@This(), fd: fd_t) void {
            self.fd_array[self.fd_count] = fd;
            self.fd_count += 1;
        }
    };
}

pub const timeval = extern struct {
    tv_sec: c_long,
    tv_usec: c_long,
};

pub extern "ws2_32" fn select(
    nfds: c_int, // ignored
    readfds: *fd_base_set,
    writefds: *fd_base_set,
    exceptfds: *fd_base_set,
    timeout: ?*const timeval,
) callconv(os.windows.WINAPI) c_int;

pub fn set_fd(comptime SetType: type, set: *SetType, s: fd_t) void {
    set.fd_array[set.fd_count] = s;
    set.fd_count += 1;
}

pub fn msToTimeval(ms: u31) timeval {
    return .{
        .tv_sec = ms / 1000,
        .tv_usec = (ms % 1000) * 1000,
    };
}
