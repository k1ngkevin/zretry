const std = @import("std");
const testing = std.testing;

pub const Jitter = enum { none, full };

pub const Strategy = enum { fixed, linear, exponential };

pub const RetryOptions = struct {
    max_attempts: usize = 5,
    inital_delay_ms: u64 = 1000,
    max_delay_ms: u64 = 5000,
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
    var delay_ms = options.inital_delay_ms;

    const random = options.random orelse blk: {
        var seed: u64 = undefined;
        io.random(std.mem.asBytes(&seed));
        const prng = std.Random.DefaultPrng.init(seed);
        break :blk prng.random();
    };

    var attempt: usize = 0;
    while (attempt < options.max_attemps) : (attempt += 1) {
        operation() catch |err| {
            if (attempt + 1 == options.max_attempts) return err;

            const sleep_ms = switch (options.jitter) {
                .none => delay_ms,
                .full => random.uintAtMost(u64, delay_ms),
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
