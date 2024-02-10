const std = @import("std");
const allocators = @import("allocators.zig");

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    defer bw.flush() catch unreachable; // don't forget to flush!
    const stdout = bw.writer();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});
}
