const std = @import("std");

const logging = @import("./logging.zig");
const log = logging.log;

/// TODO: these functions should go somewhere else
pub fn SignModified(comptime T: type, comptime signedness: std.builtin.Signedness) type {
    return switch (@typeInfo(T)) {
        .Int => |info| @Type(std.builtin.TypeInfo{.Int = .{
            .signedness = signedness,
            .bits = info.bits,
        }}),
        else => @compileError("Signed requires an Int type but got: " ++ @typeName(T)),
    };
}
pub fn Signed  (comptime T: type) type { return SignModified(T, .signed ); }
pub fn Unsigned(comptime T: type) type { return SignModified(T, .unsigned); }

pub const Timestamp = @typeInfo(@TypeOf(std.time.milliTimestamp)).Fn.return_type.?;
pub const TimestampDiff = Signed(Timestamp);

pub fn getNowTimestamp() Timestamp {
    return std.time.milliTimestamp();
}

pub fn timestampToMillis(timestamp: Timestamp) Timestamp {
    return timestamp; // already millis right now
}
pub fn secondsToTimestamp(value: anytype) Timestamp {
    return 1000 * value;
}

// 2's complement negate
pub fn negate(val: anytype) @TypeOf(val) {
    var result : @TypeOf(val) = undefined;
    _ = @addWithOverflow(@TypeOf(val), ~val, 1, &result);
    return result;
}

pub fn timestampDiff(left: Timestamp, right: Timestamp) TimestampDiff {
    var result : Timestamp = undefined;
    _ = @subWithOverflow(Timestamp, left, right, &result);
    return @intCast(TimestampDiff, result);
}

test "timestampDiff" {
    const Test = struct { left: Timestamp, right: Timestamp, diff: TimestampDiff };
    const tests = [_]Test {
        Test {.left=  0, .right= 0, .diff= 0},
        Test {.left=  1, .right= 0, .diff= 1},
        Test {.left=100, .right=83, .diff=17},
        Test {.left=std.math.maxInt(Timestamp)     , .right=std.math.maxInt(Timestamp)      , .diff=0},
        Test {.left=std.math.maxInt(Timestamp)     , .right=std.math.maxInt(Timestamp) -   1, .diff=1},
        Test {.left=std.math.maxInt(Timestamp) - 80, .right=std.math.maxInt(Timestamp) - 223, .diff=143},
        Test {.left=0, .right=std.math.maxInt(Timestamp), .diff=1},
        Test {.left=1234, .right=std.math.maxInt(Timestamp) - 100, .diff=1335},
        Test {.left=std.math.maxInt(Timestamp)/2, .right=0, .diff=std.math.maxInt(Timestamp)/2},
        Test {.left=std.math.maxInt(Timestamp)/2, .right=123, .diff=std.math.maxInt(Timestamp)/2 - 123},
        Test {.left=std.math.maxInt(Timestamp)/2 + 234, .right=234, .diff=std.math.maxInt(Timestamp)/2},
        Test {.left=std.math.maxInt(Timestamp)/2 + 1, .right=0, .diff=std.math.minInt(TimestampDiff)},
        Test {.left=std.math.maxInt(Timestamp)/2 + 2, .right=0, .diff=std.math.minInt(TimestampDiff) + 1},
    };
    for (tests) |t| {
        std.debug.warn("left {} right {} diff {} ndiff {}\n", .{t.left, t.right, t.diff, negate(t.diff)});
        std.debug.warn(" {}\n", .{timestampDiff(t.left , t.right)});
        std.debug.warn(" {}\n", .{timestampDiff(t.right, t.left )});
        std.debug.assert(timestampDiff(t.left , t.right) ==   t.diff);
        std.debug.assert(timestampDiff(t.right, t.left ) ==  negate(t.diff));
    }
}

// TODO: create a single timer (used for the heartbeat timer)
pub const TimerCheckResult = union (enum) {
    Expired: void,
    Wait: u32,
};
pub const Timer = struct {
    durationMillis: u32,
    started: bool,
    lastExpireTimestamp: Timestamp,
    pub fn init(durationMillis: u32) Timer {
        return Timer {
            .durationMillis = durationMillis,
            .started = false,
            .lastExpireTimestamp = undefined,
        };
    }
    pub fn check(self: *Timer) TimerCheckResult {
        const nowMillis = getNowTimestamp();
        if (!self.started) {
            self.started = true;
            self.lastExpireTimestamp = nowMillis;
            return TimerCheckResult { .Wait = self.durationMillis };
        }
        const diff = timestampDiff(nowMillis, self.lastExpireTimestamp);
        if (diff < 0 or diff >= self.durationMillis) {
            self.lastExpireTimestamp = nowMillis;
            return TimerCheckResult.Expired;
        }
        return TimerCheckResult { .Wait = self.durationMillis - @intCast(u32, diff) };
    }
};

pub fn TimersTemplate(comptime CallbackData: type) type {
    return struct {
        pub const CallbackFn = fn(*@This(), *Callback) anyerror!void;
        pub const Callback = struct {
            optionalNext: ?*Callback,
            timestamp: Timestamp,
            func: CallbackFn,
            data: CallbackData,
            pub fn init(timestamp: Timestamp, func: CallbackFn, data: CallbackData) @This() {
                return @This() {
                    .optionalNext = null,
                    .timestamp = timestamp,
                    .func = func,
                    .data = data,
                };
            }
        };

        optionalNext: ?*Callback,
        pub fn init() @This() {
            return @This() { .optionalNext = null };
        }
        pub fn add(self: *@This(), callback: *Callback) !void {
            if (self.optionalNext) |_| {
                std.debug.assert(false);
            } else {
                self.optionalNext = callback;
            }
        }
        pub fn handleEvents(self: *@This()) !?Timestamp {
            while (true) {
                if (self.optionalNext) |next| {
                    const diff = timestampDiff(next.timestamp, getNowTimestamp());
                    //std.debug.warn("[DEBUG] timestamp diff {}\n", .{diff});
                    if (diff > 0) return @intCast(Timestamp, diff);
                    self.optionalNext = next.optionalNext;
                    try next.func(self, next);
                } else {
                    return null;
                }
            }
        }
    };
}


pub const makeThrottler = struct {
    logPrefix: []const u8,
    desiredSleepMillis: Timestamp,
    slowRateMillis: Timestamp,
    pub fn create(self: *const makeThrottler) Throttler {
        return Throttler.init(self.logPrefix, self.desiredSleepMillis, self.slowRateMillis);
    }
};

const ns_per_ms = std.time.ns_per_s / std.time.ms_per_s;

/// Use to throttle an operation from happening to quickly
/// Note that if it is occuring too fast, it will slow down
/// gruadually based on `slowRateMillis`.
pub const Throttler = struct {
    logPrefix: []const u8,
    desiredSleepMillis: Timestamp,
    slowRateMillis: Timestamp,
    started: bool,
    sleepMillis: Timestamp,
    checkinTimestamp : Timestamp,
    beforeWorkTimestamp: Timestamp,
    pub fn init(logPrefix: []const u8, desiredSleepMillis: Timestamp, slowRateMillis: Timestamp) Throttler {
        return Throttler {
            .logPrefix = logPrefix,
            .desiredSleepMillis = desiredSleepMillis,
            .slowRateMillis = slowRateMillis,
            .started = false,
            .sleepMillis = 0,
            .checkinTimestamp = undefined,
            .beforeWorkTimestamp = undefined,
        };
    }
    /// call this function before performing the work because it needs to
    /// save the timestamp before performing the work, i.e.
    ///    var t = Throttler.init()
    ///    while (true) { t.throttle(); dowork() }
    pub fn throttle(self: *Throttler) void {
        const nowMillis = getNowTimestamp();
        if (!self.started) {
            self.started = true;
        } else {
            const elapsedMillis = timestampDiff(nowMillis, self.checkinTimestamp);
            if (elapsedMillis < 0) {
                if (self.logPrefix.len > 0)
                    log("{s}elapsed time is negative ({} ms), will wait {} ms...", .{self.logPrefix, elapsedMillis, self.desiredSleepMillis});
                std.time.sleep(ns_per_ms * @intCast(u64, self.desiredSleepMillis));
                self.sleepMillis = 0; // reset sleep time
            } else if (elapsedMillis >= self.desiredSleepMillis) {
                const workMillis = timestampDiff(nowMillis, self.beforeWorkTimestamp);
                std.debug.assert(workMillis >= 0 and workMillis <= elapsedMillis);
                if (workMillis >= self.desiredSleepMillis) {
                    self.sleepMillis = 0;
                } else {
                    self.sleepMillis = self.desiredSleepMillis - @intCast(Timestamp, workMillis);
                }
                if (self.logPrefix.len > 0)
                    log("{s}last operation took {} ms, no throttling needed (next sleep {} ms)...", .{self.logPrefix, workMillis, self.sleepMillis});
            } else {
                const millisNeeded = self.desiredSleepMillis - @intCast(Timestamp, elapsedMillis);
                const addMillis = if (millisNeeded < self.slowRateMillis) millisNeeded else self.slowRateMillis;
                self.sleepMillis += addMillis;
                if (self.logPrefix.len > 0)
                    log("{s}{} ms since last operation, will sleep {} ms...", .{self.logPrefix, elapsedMillis, self.sleepMillis});
                std.time.sleep(ns_per_ms * @intCast(u64, self.sleepMillis));
            }
        }
        self.checkinTimestamp = nowMillis;
        self.beforeWorkTimestamp = getNowTimestamp();
    }
};

//pub fn throttle(comptime eventName: []const u8, minTimeMillis: u32, elapsedMillis: timing.TimestampDiff) void {
//    if (elapsedMillis < 0) {
//        log("time since " ++ eventName ++ " is negative ({} ms)? Will wait {} ms...", .{elapsedMillis, minTimeMillis});
//        std.time.sleep(ns_per_ms * @intCast(u64, minTimeMillis));
//    } else if (elapsedMillis < minTimeMillis) {
//        const sleepMillis : u64 = minTimeMillis - @intCast(u32, elapsedMillis);
//        log("been {} ms since " ++ eventName ++ ", will sleep for {} ms...", .{elapsedMillis, sleepMillis});
//        std.time.sleep(ns_per_ms * sleepMillis);
//    } else {
//        log("been {} ms since last connect, will retry immediately", .{elapsedMillis});
//    }
//}
