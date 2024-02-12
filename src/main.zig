const std = @import("std");
const allocators = @import("allocators.zig");

var buf: [64 << 20]u8 = undefined;
pub fn main() !void {
    // const stdout_file = std.io.getStdOut().writer();
    // var bw = std.io.bufferedWriter(stdout_file);
    // defer bw.flush() catch unreachable; // don't forget to flush!
    // const stdout = bw.writer();

    {
        var linear_alloc = allocators.LinearAllocator.init(&buf);
        var validated = std.mem.validationWrap(&linear_alloc);
        var alloc = validated.allocator();
        const N = 1 << 16;
        var bufs: [N][]u8 = undefined;
        for (0..N) |i| {
            bufs[i] = try alloc.alloc(u8, 1 << 4);
        }
        for (0..N - 1) |i| {
            alloc.free(bufs[N - i - 1]);
        }
        std.debug.print("free:{}KB\n", .{linear_alloc.remaining_capacity() >> 10});
        alloc.free(bufs[0]);
        std.debug.print("free:{}KB\n", .{linear_alloc.remaining_capacity() >> 10});
    }
    {
        var buddy_alloc = try allocators.BuddyAllocator.init(&buf);
        var alloc = buddy_alloc.allocator();
        var ints1 = try alloc.alloc(usize, 128);
        defer alloc.free(ints1);
        var ints2 = try alloc.alloc(usize, 128);
        defer alloc.free(ints2);

        for (0..128) |i| {
            ints1[i] = i;
            ints2[i] = i;
        }

        for (0..128) |i| {
            std.debug.print("{}\n", .{ints1[i]});
            std.debug.print("{}\n", .{ints2[i]});
        }
    }
}
