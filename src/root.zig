const std = @import("std");
const testing = std.testing;

pub const Jitter = enum { none, full };

pub const Strategy = enum { fixed, linear, exponential };

pub const RetryOptions = struct {
    max_attempts: usize = 5,
    inital_delay_ms: i64 = 1000,
    max_delay_ms: i64 = 5000,
    jitter: Jitter = .full,
    random: ?std.Random = null,
    strategy: Strategy = .exponential,
};

pub const RetryError = error{
    InvalidMaxAttempts,
    InvalidDelay,
};

fn validateOptions(options: RetryOptions) RetryError!void {
    if (options.max_attempts == 0) return RetryError.InvalidMaxAttempts;
    if (options.inital_delay_ms > options.max_delay_ms) return RetryError.InvalidDelay;
}

pub fn zretry(io: std.Io, comptime operation: anytype, options: RetryOptions) !void {
    var delay_ms: i64 = options.inital_delay_ms;

    const random = options.random orelse blk: {
        var seed: u64 = undefined;
        io.random(std.mem.asBytes(&seed));
        var prng = std.Random.DefaultPrng.init(seed);
        break :blk prng.random();
    };

    var attempt: usize = 0;
    while (attempt < options.max_attempts) : (attempt += 1) {
        operation() catch |err| {
            if (attempt + 1 == options.max_attempts) return err;

            const sleep_ms: i64 = switch (options.jitter) {
                .none => delay_ms,
                .full => random.intRangeAtMost(i64, 0, delay_ms),
            };

            try io.sleep(.fromMilliseconds(sleep_ms), .awake);

            delay_ms = switch (options.strategy) {
                .fixed => delay_ms,
                .linear => @min(delay_ms + options.inital_delay_ms, options.max_delay_ms),
                .exponential => @min(delay_ms * 2, options.max_delay_ms),
            };
            continue;
        };
        return;
    }
}

test "default options pass" {
    try validateOptions(.{});
}

test "max attempts can't be zero" {
    try testing.expectError(error.InvalidMaxAttempts, validateOptions(.{ .max_attempts = 0 }));
}

test "inital can't exceed max" {
    try testing.expectError(error.InvalidDelay, validateOptions(.{ .inital_delay_ms = 2000, .max_delay_ms = 1000 }));
}

const Work = struct {
    var calls: i32 = 0;

    fn doWork() !void {
        const value: i32 = 10 + 10;
        try testing.expectEqual(@as(i32, 20), value);
        calls += 1;
    }
};

test "only calls once on working function" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try zretry(threaded.io(), Work.doWork, .{ .inital_delay_ms = 0, .max_delay_ms = 0 });
    try testing.expectEqual(@as(i32, 1), Work.calls);
}
