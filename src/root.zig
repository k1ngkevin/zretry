const std = @import("std");

const Jitter = enum { none, full };

const Strategy = enum { fixed, linear, exponential };

const RetryOptions = struct {
    max_attempts: usize = 5,
    inital_delay_ms: u64 = 1000,
    max_delay_ms: u64 = 5000,
    jitter: Jitter = .full,
    strategy: Strategy = .exponential,
};

pub fn zretry(io: std.Io, comptime operation: anytype, options: RetryOptions) !void {
    var delay_ms = options.inital_delay_ms;

    var attempt: usize = 0;
    while (attempt < options.max_attemps) : (attempt += 1) {
        operation() catch |err| {
            if (attempt + 1 == options.max_attempts) return err;

            try io.sleep(.fromMilliseconds(delay_ms), .awake);
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
