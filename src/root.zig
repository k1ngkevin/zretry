const std = @import("std");
const testing = std.testing;

pub const Jitter = enum { none, full };

pub const Strategy = enum { fixed, linear, exponential };

pub const RetryOptions = struct {
    io: std.Io,
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
    if (options.inital_delay_ms < 0) return RetryError.InvalidDelay;
    if (options.max_delay_ms < 0) return RetryError.InvalidDelay;
    if (options.inital_delay_ms > options.max_delay_ms) return RetryError.InvalidDelay;
}

pub fn zretry(comptime operation: anytype, options: RetryOptions) !void {
    try validateOptions(options);

    var delay_ms: i64 = options.inital_delay_ms;

    const random = options.random orelse blk: {
        var seed: u64 = undefined;
        options.io.random(std.mem.asBytes(&seed));
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

            try options.io.sleep(.fromMilliseconds(sleep_ms), .awake);

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

fn testOptions() RetryOptions {
    return .{ .io = std.testing.io };
}

fn zeroDelayTestOptions() RetryOptions {
    var options = testOptions();
    options.inital_delay_ms = 0;
    options.max_delay_ms = 0;
    return options;
}

test "default options pass" {
    try validateOptions(testOptions());
}

test "max attempts can't be zero" {
    var options = testOptions();
    options.max_attempts = 0;

    try testing.expectError(error.InvalidMaxAttempts, validateOptions(options));
}

test "inital can't exceed max" {
    var options = testOptions();
    options.inital_delay_ms = 2000;
    options.max_delay_ms = 1000;

    try testing.expectError(error.InvalidDelay, validateOptions(options));
}

test "delays can't be negative" {
    var options = testOptions();
    options.inital_delay_ms = -1;
    try testing.expectError(error.InvalidDelay, validateOptions(options));

    options = testOptions();
    options.max_delay_ms = -1;
    try testing.expectError(error.InvalidDelay, validateOptions(options));
}

const WorkError = error{FunctionFail};

const Work = struct {
    var calls: i32 = 0;

    fn doWork() !void {
        const value: i32 = 10 + 10;
        try testing.expectEqual(@as(i32, 20), value);
        calls += 1;
    }

    fn faultyWork() WorkError!void {
        calls += 1;

        if (calls < 3) {
            return error.FunctionFail;
        }
    }
};

test "only calls once on working function" {
    Work.calls = 0;

    try zretry(Work.doWork, zeroDelayTestOptions());
    try testing.expectEqual(@as(i32, 1), Work.calls);
}

test "faultyWork fails twice succeeds on third" {
    Work.calls = 0;

    try zretry(Work.faultyWork, zeroDelayTestOptions());
    try testing.expectEqual(@as(i32, 3), Work.calls);
}

test "zretry validates options before calling operation" {
    Work.calls = 0;

    var options = zeroDelayTestOptions();
    options.inital_delay_ms = -1;

    try testing.expectError(error.InvalidDelay, zretry(Work.doWork, options));
    try testing.expectEqual(@as(i32, 0), Work.calls);
}
