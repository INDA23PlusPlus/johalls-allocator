const std = @import("std");
const Allocator = std.mem.Allocator;

fn align_offset(p: [*]u8, id: usize, ptr_align: u8) usize {
    const alignment: usize = @as(usize, 1) << @intCast(ptr_align);
    const remainder = @intFromPtr(p + id) % alignment;
    return id + (alignment - remainder) % alignment;
}

const LinearAllocatorVtable: Allocator.VTable = .{
    .alloc = LinearAllocator.alloc,
    .free = LinearAllocator.free,
    .resize = Allocator.noResize,
};

pub const LinearAllocator = struct {
    pub const Self = @This();

    non_freed_allocs: usize,
    id: usize,
    buf: []u8,

    pub fn remaining_capacity(self: *Self) usize {
        return self.buf.len - self.id;
    }

    pub fn reset(self: *Self) void {
        self.id = 0;
        self.non_freed_allocs = 0;
    }

    pub fn init(buf: []u8) Self {
        return .{
            .non_freed_allocs = 0,
            .id = 0,
            .buf = buf,
        };
    }

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &LinearAllocatorVtable,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));

        const start_idx = align_offset(self.buf.ptr, self.id, ptr_align);
        const end_idx = start_idx + len;
        if (end_idx >= self.buf.len) return null;
        self.non_freed_allocs += 1;
        self.id = end_idx;
        return self.buf.ptr + start_idx;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = ret_addr;
        _ = buf_align;
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.buf.ptr + self.id == buf.ptr + buf.len) {
            self.id -= buf.len;
        }
        self.non_freed_allocs -= 1;
        if (self.non_freed_allocs == 0) {
            self.reset();
        }
    }
};

test "standard allocator tests on LinearAllocator" {
    // 640K ought to be enough for anybody
    var buf: [640 << 10]u8 = undefined;
    var linear_allocator = std.mem.validationWrap(LinearAllocator.init(&buf));
    try std.heap.testAllocator(linear_allocator.allocator());
    try std.heap.testAllocatorAligned(linear_allocator.allocator());
    try std.heap.testAllocatorLargeAlignment(linear_allocator.allocator());
    try std.heap.testAllocatorAlignedShrink(linear_allocator.allocator());
}

fn contains(buf: ?[]u8, allocation: []u8) bool {
    if (buf) |b| {
        const start = @intFromPtr(b.ptr);
        const end = start + b.len;

        const allocation_start = @intFromPtr(allocation.ptr);
        const allocation_end = allocation_start + allocation.len;

        const allocation_start_within = start <= allocation_start and allocation_start < end;
        const allocation_end_within = start <= allocation_end and allocation_end < end;

        return allocation_start_within and allocation_end_within;
    } else {
        return false;
    }
}

const BuddyAllocReturn = struct {
    data: [*]u8,
    size_buffer_used: usize,
};

const BuddyAllocatorNode = struct {
    left: ?*BuddyAllocatorNode,
    right: ?*BuddyAllocatorNode,
    num_allocations_in_subtree: usize,
    remaining_capacity: usize,
    buf: []u8,
    allocated: bool,

    const Self = @This();

    pub fn alloc(self: *Self, len: usize, ptr_align: u8) ?BuddyAllocReturn {
        if (self.allocated) {
            return null;
        }
        if (len > self.remaining_capacity) {
            return null;
        }

        if (self.left) |left| {
            if (left.alloc(len, ptr_align)) |allocation| {
                self.num_allocations_in_subtree += 1;
                self.remaining_capacity -= allocation.size_buffer_used;
                return allocation;
            }
        }

        if (self.right) |right| {
            if (right.alloc(len, ptr_align)) |allocation| {
                self.num_allocations_in_subtree += 1;
                self.remaining_capacity -= allocation.size_buffer_used;
                return allocation;
            }
        }

        if (self.num_allocations_in_subtree > 0) {
            return null;
        }

        const start_idx = align_offset(self.buf.ptr, 0, ptr_align);
        const end_idx = start_idx + len;

        if (end_idx > self.buf.len) {
            return null;
        }
        self.allocated = true;
        self.remaining_capacity = 0;

        return .{ .data = self.buf[start_idx..end_idx].ptr, .size_buffer_used = self.buf.len };
    }

    pub fn free(self: *Self, allocation: []u8) usize {
        if (!contains(self.buf, allocation)) {
            return 0;
        }

        if (self.left) |left| {
            const t = left.free(allocation);
            if (t > 0) {
                self.num_allocations_in_subtree -= 1;
                self.remaining_capacity += t;
                return t;
            }
        }
        if (self.right) |right| {
            const t = right.free(allocation);
            if (t > 0) {
                self.num_allocations_in_subtree -= 1;
                self.remaining_capacity += t;
                return t;
            }
        }

        self.allocated = false;
        self.remaining_capacity = self.buf.len;
        return self.buf.len;
    }

    pub fn resize(self: *Self, allocation: []u8, len: usize, ptr_align: u8) bool {
        if (!contains(self.buf, allocation)) {
            return false;
        }

        if (self.left) |left| {
            if (left.resize(allocation, len, ptr_align)) {
                return true;
            }
        }
        if (self.right) |right| {
            if (right.resize(allocation, len, ptr_align)) {
                return true;
            }
        }

        const start_idx = align_offset(self.buf.ptr, 0, ptr_align);
        const end_idx = start_idx + len;

        if (end_idx > self.buf.len) return false;
        return true;
    }

    fn split(self: *Self, allocator_nodes: *[]BuddyAllocatorNode) void {
        self.remaining_capacity = self.buf.len;
        if (self.buf.len <= 65536) {
            return;
        }

        std.debug.assert(self.buf.len > 1);
        std.debug.assert(self.left == null and self.right == null);

        const left_buf_end = (self.buf.len + 1) / 2;

        const left_buf = self.buf[0..left_buf_end];
        const right_buf = self.buf[left_buf_end..];

        self.left = &allocator_nodes.*[0];
        self.left.?.buf = left_buf;
        allocator_nodes.* = allocator_nodes.*[1..];

        self.right = &allocator_nodes.*[0];
        self.right.?.buf = right_buf;
        allocator_nodes.* = allocator_nodes.*[1..];

        self.left.?.split(allocator_nodes);
        self.right.?.split(allocator_nodes);
    }
};

/// computes amount of space wasted by alignment if storying a `T` in `buf`
fn wasted_space(comptime T: type, buf: []u8) usize {
    return align_offset(buf.ptr, 0, std.math.log2(@alignOf(T)));
}

fn num_allocator_nodes(min_size: usize, n: usize) usize {
    var num_nodes: usize = 1;
    var layer: usize = 1;
    var size: usize = n;
    while (size > min_size) {
        layer *= 2;
        num_nodes += layer;
        size = (size + 1) / 2;
    }
    return num_nodes;
}

test "correct allocator node count" {
    try std.testing.expectEqual(@as(usize, 1), num_allocator_nodes(1, 1));
    try std.testing.expectEqual(@as(usize, 8 + 4 + 2 + 1), num_allocator_nodes(16, 128));
}

fn compute_overhead(min_size: usize, n: usize, buf: []u8) usize {
    return wasted_space(BuddyAllocatorNode, buf) + num_allocator_nodes(min_size, n) * @sizeOf(BuddyAllocatorNode);
}

const BuddyAllocatorVtable: Allocator.VTable = .{
    .alloc = BuddyAllocator.alloc,
    .free = BuddyAllocator.free,
    .resize = BuddyAllocator.resize,
};

pub const BuddyAllocator = struct {
    buf: []u8, // contains both allocator nodes and actual buffer of data
    usable_buf: []u8,
    // not necessary to store, may be compute implicitly if needed
    // allocator_nodes: []BuddyAllocatorNode,

    root: *BuddyAllocatorNode,

    const Self = @This();

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &BuddyAllocatorVtable,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.root.alloc(len, ptr_align)) |allocation| {
            return allocation.data;
        } else {
            return null;
        }
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = buf_align;
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self.root.free(buf);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.root.resize(buf, new_len, buf_align);
    }

    pub fn usable_size(self: *Self) usize {
        return self.usable_buf.len;
    }

    pub fn init(buf: []u8) !BuddyAllocator {
        const min_size = 65536;
        // std.debug.print("overhead: {}\n", .{compute_overhead(min_size, min_size, buf)});
        if (compute_overhead(min_size, min_size, buf) > buf.len) {
            return error.NotEnoughSpace;
        }

        var lo: usize = compute_overhead(min_size, min_size, buf);
        var hi: usize = buf.len;

        for (0..64) |_| {
            const mi = lo + (hi - lo + 1) / 2;
            if (compute_overhead(min_size, mi, buf) + mi <= buf.len) {
                lo = mi;
            } else {
                hi = mi;
            }
        }

        const size_allocated = lo;

        // const oh = compute_overhead(min_size, size_allocated, buf) * 100;
        // std.debug.print("overhead: {}.{}%\n", .{ oh / buf.len, oh * 1000 / buf.len % 1000 });

        var p: [*]BuddyAllocatorNode = @ptrCast(@alignCast(buf.ptr + wasted_space(BuddyAllocatorNode, buf)));
        var allocator_nodes = p[0..num_allocator_nodes(min_size, size_allocated)];
        for (0..allocator_nodes.len) |i| {
            allocator_nodes[i].allocated = false;
            allocator_nodes[i].num_allocations_in_subtree = 0;
            allocator_nodes[i].left = null;
            allocator_nodes[i].right = null;
        }

        var result: BuddyAllocator = undefined;
        result.buf = buf;
        result.root = &allocator_nodes[0];
        allocator_nodes = allocator_nodes[1..];

        const usable_start_idx = compute_overhead(min_size, size_allocated, buf);
        const usable_end_idx = usable_start_idx + size_allocated;
        result.usable_buf = buf[usable_start_idx..usable_end_idx];

        result.root.buf = result.usable_buf;
        result.root.split(&allocator_nodes);

        return result;
    }
};

var buddy_allocator_buf: [64 << 20]u8 = undefined;
test "standard allocator tests on BuddyAllocator" {
    var buddy_allocator = std.mem.validationWrap(try BuddyAllocator.init(&buddy_allocator_buf));
    try std.heap.testAllocator(buddy_allocator.allocator());
    try std.heap.testAllocatorAligned(buddy_allocator.allocator());
    try std.heap.testAllocatorLargeAlignment(buddy_allocator.allocator());
    try std.heap.testAllocatorAlignedShrink(buddy_allocator.allocator());
}
