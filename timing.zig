const builtin = @import("builtin");
const std = @import("std");

const logging = @import("./logging.zig");
const log = logging.log;

/// TODO: these functions should go somewhere else
pub fn SignModified(comptime T: type, comptime signedness: std.builtin.Signedness) type {
    return switch (@typeInfo(T)) {
        .Int => |info| @Type(std.builtin.Type{.Int = .{
            .signedness = signedness,
            .bits = info.bits,
        }}),
        else => @compileError("Signed requires an Int type but got: " ++ @typeName(T)),
    };
}
pub fn Signed  (comptime T: type) type { return SignModified(T, .signed ); }
pub fn Unsigned(comptime T: type) type { return SignModified(T, .unsigned); }

pub const Timestamp = switch (builtin.os.tag) {
    .windows => u32,
    else => usize,
};
pub const TimestampDiff = Signed(Timestamp);

pub fn getNowTimestamp() Timestamp {
    if (builtin.os.tag == .windows) return std.os.windows.GetTickCount();
    return std.time.Instant.now().timestamp;
}

pub fn timestampToMillis(timestamp: Timestamp) Timestamp {
    return timestamp; // already millis right now
}
pub fn secondsToTimestamp(value: anytype) Timestamp {
    return 1000 * value;
}

pub fn negate(val: anytype) @TypeOf(val) {
    return -%val;
}

pub fn timestampDiff(left: Timestamp, right: Timestamp) TimestampDiff {
    return @bitCast(left -% right);
}

fn testTimestampDiff(expected: TimestampDiff, left: Timestamp, right: Timestamp) !void {
//    std.debug.print(
//        "left {} right {} expected diff {} negate(diff) {}\n",
//        .{left, right, expected, negate(expected)},
//    );
//    std.debug.print(" {}\n", .{timestampDiff(left , right)});
//    std.debug.print(" {}\n", .{timestampDiff(right, left )});
    std.debug.assert(timestampDiff(left , right) == expected);
    std.debug.assert(timestampDiff(right, left ) == -%expected);
}

test "timestampDiff" {
    try testTimestampDiff(   0, 0, 0);
    try testTimestampDiff(   1, 1, 0);
    try testTimestampDiff(  17, 100, 83);
    try testTimestampDiff(   0, std.math.maxInt(Timestamp)     , std.math.maxInt(Timestamp)      );
    try testTimestampDiff(   1, std.math.maxInt(Timestamp)     , std.math.maxInt(Timestamp) -   1);
    try testTimestampDiff( 143, std.math.maxInt(Timestamp) - 80, std.math.maxInt(Timestamp) - 223);
    try testTimestampDiff(   1, 0, std.math.maxInt(Timestamp));
    try testTimestampDiff(1335, 1234, std.math.maxInt(Timestamp) - 100);
    try testTimestampDiff(std.math.maxInt(Timestamp) / 2      , std.math.maxInt(Timestamp)/2      ,   0);
    try testTimestampDiff(std.math.maxInt(Timestamp) / 2 - 123, std.math.maxInt(Timestamp)/2      , 123);
    try testTimestampDiff(std.math.maxInt(Timestamp) / 2      , std.math.maxInt(Timestamp)/2 + 234, 234);
    try testTimestampDiff(std.math.minInt(TimestampDiff)    , std.math.maxInt(Timestamp)/2 + 1, 0);
    try testTimestampDiff(std.math.minInt(TimestampDiff) + 1, std.math.maxInt(Timestamp)/2 + 2, 0);

    const extreme_offsets = [_]Timestamp{
        0, 1, 2,
        0xff, 0xffff, 0xffffff,
        std.math.maxInt(TimestampDiff) - 1,
        std.math.maxInt(TimestampDiff),
        std.math.maxInt(TimestampDiff) + 1,
        std.math.maxInt(Timestamp) - 1,
        std.math.maxInt(Timestamp),
    };
    for (extreme_offsets) |offset| {
        // The tests below should all pass regardless of what value we offset from.
        try testTimestampDiff(         0, offset +%          0, offset);
        try testTimestampDiff(         1, offset +%          1, offset);
        try testTimestampDiff(         2, offset +%          2, offset);
        try testTimestampDiff(    0xffff, offset +%    0xffff, offset);
        try testTimestampDiff(0x7fffffff, offset +% 0x7fffffff, offset);
        for (extreme_offsets) |offset2| {
            try testTimestampDiff(@bitCast(offset2), offset +% offset2, offset);
        }

        // the interpretation of what's newer changes when the difference
        // exceeds half that of std.math.maxInt(Timestamp)/2.
        try testTimestampDiff(         1,     offset, offset +% std.math.maxInt(Timestamp));
        try testTimestampDiff(         2, offset +% 1, offset +% std.math.maxInt(Timestamp));
        try testTimestampDiff(         2,     offset, offset +% (std.math.maxInt(Timestamp)-1));
        try testTimestampDiff(std.math.maxInt(TimestampDiff)    ,     offset, offset +% std.math.maxInt(TimestampDiff)+%2);
        try testTimestampDiff(std.math.maxInt(TimestampDiff) -% 1,     offset, offset +% std.math.maxInt(TimestampDiff)+%3);
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
        return TimerCheckResult { .Wait = self.durationMillis - @as(u32, diff) };
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
                    if (diff > 0) return @intCast(diff);
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
                std.time.sleep(ns_per_ms * @as(u64, self.desiredSleepMillis));
                self.sleepMillis = 0; // reset sleep time
            } else if (elapsedMillis >= self.desiredSleepMillis) {
                const workMillis = timestampDiff(nowMillis, self.beforeWorkTimestamp);
                std.debug.assert(workMillis >= 0 and workMillis <= elapsedMillis);
                if (workMillis >= self.desiredSleepMillis) {
                    self.sleepMillis = 0;
                } else {
                    self.sleepMillis = self.desiredSleepMillis - @as(Timestamp, workMillis);
                }
                if (self.logPrefix.len > 0)
                    log("{s}last operation took {} ms, no throttling needed (next sleep {} ms)...", .{self.logPrefix, workMillis, self.sleepMillis});
            } else {
                const millisNeeded = self.desiredSleepMillis - @as(Timestamp, elapsedMillis);
                const addMillis = if (millisNeeded < self.slowRateMillis) millisNeeded else self.slowRateMillis;
                self.sleepMillis += addMillis;
                if (self.logPrefix.len > 0)
                    log("{s}{} ms since last operation, will sleep {} ms...", .{self.logPrefix, elapsedMillis, self.sleepMillis});
                std.time.sleep(ns_per_ms * @as(u64, self.sleepMillis));
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
