const std = @import("std");
const testing = std.testing;

pub const Jitter = enum { none, percent };

pub const Strategy = enum { fixed, linear, exponential };

pub const RetryFilter = *const fn (anyerror) bool;

pub const RetryOptions = struct {
    io: std.Io,
    max_attempts: usize = 5,
    initial_delay_ms: i64 = 1000,
    max_delay_ms: i64 = 5000,
    jitter: Jitter = .percent,
    random: ?std.Random = null,
    retry_if: ?RetryFilter = null,
    strategy: Strategy = .exponential,
};

pub const RetryError = error{
    InvalidMaxAttempts,
    InvalidDelay,
};

fn validateOptions(options: RetryOptions) RetryError!void {
    if (options.max_attempts == 0) return RetryError.InvalidMaxAttempts;
    if (options.initial_delay_ms < 0) return RetryError.InvalidDelay;
    if (options.max_delay_ms < 0) return RetryError.InvalidDelay;
    if (options.initial_delay_ms > options.max_delay_ms) return RetryError.InvalidDelay;
}

fn RetryPayload(comptime operation: anytype) type {
    const ret = @typeInfo(@TypeOf(operation)).@"fn".return_type.?;

    return switch (@typeInfo(ret)) {
        .error_union => |eu| eu.payload,
        else => @compileError("zretry operation must return an error union"),
    };
}

pub fn zretry(comptime operation: anytype, args: anytype, options: RetryOptions) !RetryPayload(operation) {
    try validateOptions(options);

    var delay_ms: i64 = options.initial_delay_ms;

    var prng: std.Random.DefaultPrng = undefined;

    const maybe_random = switch (options.jitter) {
        .none => null,
        .percent => options.random orelse blk: {
            var seed: u64 = undefined;
            options.io.random(std.mem.asBytes(&seed));
            prng = std.Random.DefaultPrng.init(seed);
            break :blk prng.random();
        },
    };

    var attempt: usize = 0;
    while (attempt < options.max_attempts) : (attempt += 1) {
        const result = @call(.auto, operation, args) catch |err| {
            if (options.retry_if) |retry_if| {
                if (!retry_if(err)) return err;
            }

            if (attempt + 1 == options.max_attempts) return err;

            const jitter_ms: i64 = switch (options.jitter) {
                .none => 0,
                .percent => maybe_random.?.intRangeAtMost(i64, 0, @divFloor(delay_ms, 20)),
            };

            const sleep_ms = delay_ms - jitter_ms;
            try options.io.sleep(.fromMilliseconds(sleep_ms), .awake);

            delay_ms = switch (options.strategy) {
                .fixed => delay_ms,
                .linear => @min(delay_ms + options.initial_delay_ms, options.max_delay_ms),
                .exponential => @min(delay_ms * 2, options.max_delay_ms),
            };
            continue;
        };
        return result;
    }
    unreachable;
}

fn testOptions() RetryOptions {
    return .{ .io = std.testing.io };
}

fn zeroDelayTestOptions() RetryOptions {
    var options = testOptions();
    options.initial_delay_ms = 0;
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

test "doesn't retry when max_attempts = 1" {
    Work.calls = 0;
    var options = testOptions();
    options.max_attempts = 1;

    try zretry(Work.doWork, .{}, options);
    try testing.expectEqual(@as(i32, 1), Work.calls);
}

test "initial can't exceed max" {
    var options = testOptions();
    options.initial_delay_ms = 2000;
    options.max_delay_ms = 1000;

    try testing.expectError(error.InvalidDelay, validateOptions(options));
}

test "delays can't be negative" {
    var options = testOptions();
    options.initial_delay_ms = -1;
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

    fn returnWork() !i32 {
        const value: i32 = 10 + 10;
        try testing.expectEqual(@as(i32, 20), value);
        calls += 1;
        return value;
    }

    fn faultyWork() WorkError!void {
        calls += 1;

        if (calls < 3) {
            return error.FunctionFail;
        }
    }

    fn downloadFile(url: []const u8, output_path: []const u8) !void {
        _ = url;
        _ = output_path;
        calls += 1;
    }
};

test "only calls once on working function" {
    Work.calls = 0;

    try zretry(Work.doWork, .{}, zeroDelayTestOptions());
    try testing.expectEqual(@as(i32, 1), Work.calls);
}

test "faultyWork fails twice succeeds on third" {
    Work.calls = 0;

    try zretry(Work.faultyWork, .{}, zeroDelayTestOptions());
    try testing.expectEqual(@as(i32, 3), Work.calls);
}

test "can't put in negative ms values" {
    Work.calls = 0;

    var options = zeroDelayTestOptions();
    options.initial_delay_ms = -1;

    try testing.expectError(
        error.InvalidDelay,
        zretry(Work.doWork, .{}, options),
    );
    try testing.expectEqual(@as(i32, 0), Work.calls);
}

test "works with functions with parameters" {
    Work.calls = 0;

    try zretry(
        Work.downloadFile,
        .{ "https://example.com/file.html", "output.html" },
        zeroDelayTestOptions(),
    );
    try testing.expectEqual(@as(i32, 1), Work.calls);
}

test "works with functions that return a value" {
    Work.calls = 0;

    const return_value = try zretry(Work.returnWork, .{}, zeroDelayTestOptions());
    try testing.expectEqual(@as(i32, 1), Work.calls);
    try testing.expectEqual(@as(i32, 20), return_value);
}

const AlwaysFail = struct {
    var calls: i32 = 0;

    fn doWork() WorkError!void {
        calls += 1;
        return WorkError.FunctionFail;
    }
};

test "retries max_retry times" {
    AlwaysFail.calls = 0;
    const max_attempts = 5;

    var options = zeroDelayTestOptions();
    options.max_attempts = max_attempts;

    try testing.expectError(
        error.FunctionFail,
        zretry(AlwaysFail.doWork, .{}, options),
    );
    try testing.expectEqual(@as(i32, max_attempts), AlwaysFail.calls);
}

const FilteredError = error{ Retryable, Permanent };

fn shouldRetryError(err: anyerror) bool {
    return switch (err) {
        error.Retryable => true,
        else => false,
    };
}

const FilteredWork = struct {
    var calls: i32 = 0;

    fn permanentFailure() FilteredError!void {
        calls += 1;
        return error.Permanent;
    }

    fn retryableThenSucceeds() FilteredError!void {
        calls += 1;

        if (calls < 3) {
            return error.Retryable;
        }
    }
};

test "retry_if stops retries when it returns false" {
    FilteredWork.calls = 0;

    var options = zeroDelayTestOptions();
    options.max_attempts = 5;
    options.retry_if = shouldRetryError;

    try testing.expectError(
        error.Permanent,
        zretry(FilteredWork.permanentFailure, .{}, options),
    );
    try testing.expectEqual(@as(i32, 1), FilteredWork.calls);
}

test "retry_if allows retries when it returns true" {
    FilteredWork.calls = 0;

    var options = zeroDelayTestOptions();
    options.max_attempts = 5;
    options.retry_if = shouldRetryError;

    try zretry(FilteredWork.retryableThenSucceeds, .{}, options);
    try testing.expectEqual(@as(i32, 3), FilteredWork.calls);
}
