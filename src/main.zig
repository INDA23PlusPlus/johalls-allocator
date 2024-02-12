const std = @import("std");
const allocators = @import("allocators.zig");

var buf: [8 << 20]u8 = undefined;
pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    defer bw.flush() catch unreachable; // don't forget to flush!
    const stdout = bw.writer();

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
        try stdout.print("free:{}KB\n", .{linear_alloc.remaining_capacity() >> 10});
        alloc.free(bufs[0]);
        try stdout.print("free:{}KB\n", .{linear_alloc.remaining_capacity() >> 10});
    }
    {
        var small_buf: [128]u8 = undefined;
        var buddy_alloc = try allocators.BuddyAllocator.init(&small_buf);
        try stdout.print("{}\n", .{buddy_alloc.usable_size()});

        
        for (0..100) |_| {
            const alloc = buddy_alloc.root.alloc(8, 3).?;
            defer _ = buddy_alloc.root.free(alloc);
            const p: *u64 = @ptrCast(@alignCast(alloc.ptr));
            p.* = 0;
            for (0..8) |i| {
                p.* = p.* * 256 + 'A' + i;
            }
            try stdout.print("{s}\n", .{alloc});
        }
    }
}
