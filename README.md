# zretry

A Zig retry helper with configurable delay strategy and jitter.

## Usage

Import the module from your `build.zig` and call `zretry` with an operation that returns `!void`.

```zig
const std = @import("std");
const retry = @import("zretry");

fn doWork() !void {
    // Your fallible operation here.
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();

    try retry.zretry(threaded.io(), doWork, .{
        .max_attempts = 5,
        .inital_delay_ms = 250,
        .max_delay_ms = 5_000,
        .strategy = .exponential,
        .jitter = .full,
    });
}
```

## Options

- `max_attempts`: total number of attempts before returning the final error.
- `inital_delay_ms`: starting delay in milliseconds.
- `max_delay_ms`: maximum delay in milliseconds.
- `strategy`: `.fixed`, `.linear`, or `.exponential`.
- `jitter`: `.none` or `.full`.
- `random`: optional `std.Random`; if omitted, one is seeded from `std.Io`.

## Development

Run the test suite:

```sh
zig build test
```
