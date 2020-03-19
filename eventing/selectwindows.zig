const std = @import("std");
const os = std.os;

const fd_t = os.fd_t;

pub const fd_base_set = extern struct {
    fd_count: c_uint,
    fd_array: [0]fd_t,
};

pub fn fd_set(comptime setSize: comptime_int) type {
    return extern struct {
        fd_count: c_uint,
        fd_array: [setSize]fd_t,
        pub fn base(self: *@This()) *fd_base_set {
            return @ptrCast(*fd_base_set, self);
        }
        pub fn add(self: *@This(), fd: fd_t) void {
            self.fd_array[self.fd_count] = fd;
            self.fd_count += 1;
        }
    };
}

pub extern "ws2_32" fn select(
    nfds: c_int, // ignored
    readfds: *fd_base_set,
    writefds: *fd_base_set,
    exceptfds: *fd_base_set,
) callconv(.Stdcall) c_int;
