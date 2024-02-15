const std = @import("std");
const allocators = @import("allocators.zig");

// just my own crappy testing
var buf: [1 << 25]u8 = undefined;
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
        std.debug.print("free:{}KB\n", .{linear_alloc.remainingCapacity() >> 10});
        alloc.free(bufs[0]);
        std.debug.print("free:{}KB\n", .{linear_alloc.remainingCapacity() >> 10});
    }
    {
        var buddy_alloc = try allocators.BuddyAllocator.init(&buf);
        var validated = std.mem.validationWrap(&buddy_alloc);
        var alloc = validated.allocator();
        const N = 1 << 10;
        var bufs: [N][]u8 = undefined;
        for (0..N) |i| {
            bufs[i] = try alloc.alloc(u8, 1 << 4);
        }
        for (0..N - 1) |i| {
            alloc.free(bufs[N - i - 1]);
        }
        std.debug.print("free:{}KB\n", .{buddy_alloc.remainingCapacity() >> 10});
        std.debug.print("biggest:{}KB\n", .{buddy_alloc.biggestPossibleAllocation() >> 10});
        alloc.free(bufs[0]);
        std.debug.print("free:{}KB\n", .{buddy_alloc.remainingCapacity() >> 10});
        std.debug.print("biggest:{}KB\n", .{buddy_alloc.biggestPossibleAllocation() >> 10});
        const t = buddy_alloc.remainingCapacity() * 100;
        std.debug.print("efficiency: {}.{:0>3}% ({}KB used to store internal allocator data structure)\n", .{ t / buf.len, t * 1000 / buf.len % 1000, buf.len - buddy_alloc.remainingCapacity() >> 10 });
        var allocs: [16384][]usize = undefined;
        var num_allocated: usize = 0;
        for (0..allocs.len) |i| {
            if (alloc.alloc(usize, (16 << 10) / @sizeOf(usize) - 7) catch null) |allocation| {
                allocs[i] = allocation;
                for (allocs[i]) |*e| {
                    e.* = i;
                }
                num_allocated += 1;
            } else {
                break;
            }
        }
        std.debug.print("num leaves: {}\n", .{num_allocated});
        std.debug.print("free:{}KB\n", .{buddy_alloc.remainingCapacity() >> 10});
        var indices: [16384]usize = undefined;
        for (0..num_allocated) |i| {
            indices[i] = i;
        }

        var rand_num: usize = undefined;
        const ptr_rand_num: [*]u8 = @ptrCast(&rand_num);
        var view_rand_num: []u8 = undefined;
        view_rand_num.len = @sizeOf(usize);
        view_rand_num.ptr = ptr_rand_num;
        std.crypto.random.bytes(view_rand_num);

        var rng = std.rand.Xoshiro256.init(rand_num);
        var rand = rng.random();
        rand.shuffle(usize, indices[0..num_allocated]);
        for (indices[0..num_allocated]) |i| {
            // std.debug.print("{}\n", .{i});
            for (allocs[i]) |e| {
                std.debug.assert(e == i);
            }
            alloc.free(allocs[i]);
        }
        std.debug.print("free:{}KB\n", .{buddy_alloc.remainingCapacity() >> 10});
    }
    // {
    //     var buddy_alloc = try allocators.BuddyAllocator.init(&buf);
    //     var alloc = buddy_alloc.allocator();

    //     var ints1 = try alloc.alloc(usize, 128);
    //     defer alloc.free(ints1);
    //     var ints2 = try alloc.alloc(usize, 128);
    //     defer alloc.free(ints2);

    //     for (0..128) |i| {
    //         ints1[i] = i;
    //         ints2[i] = i;
    //     }

    //     for (0..128) |i| {
    //         std.debug.print("{}\n", .{ints1[i]});
    //         std.debug.print("{}\n", .{ints2[i]});
    //     }
    // }
}
