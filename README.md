# zretry

A Zig retry helper with configurable delay strategy and jitter.

## Usage

Import the module from your `build.zig` and call `zretry` with an operation that returns `!void`.
The retry options carry the `std.Io` value used for sleeping and randomness.

```zig
const std = @import("std");
const retry = @import("zretry");

fn doWork() !void {
    // fallible operation
}

pub fn main(init: std.process.Init) !void {
    try retry.zretry(doWork, .{
        .io = init.io,
        .max_attempts = 5,
        .inital_delay_ms = 250,
        .max_delay_ms = 5_000,
    });
}
```

## Options

- `io`: `std.Io` used to sleep between retries and seed jitter randomness.
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
