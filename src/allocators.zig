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
    children: ?[*]BuddyAllocatorNode,
    remaining_capacity: usize,
    buf: []u8,

    const Self = @This();

    pub fn alloc(self: *Self, len: usize, ptr_align: u8) ?BuddyAllocReturn {
        if (len > self.remaining_capacity) {
            return null;
        }

        if (self.children) |children| {
            for (0..2) |i| {
                if (children[i].alloc(len, ptr_align)) |allocation| {
                    self.remaining_capacity -= allocation.size_buffer_used;
                    return allocation;
                }
            }
        }

        if (self.remaining_capacity < self.buf.len) {
            return null;
        }

        const start_idx = align_offset(self.buf.ptr, 0, ptr_align);
        const end_idx = start_idx + len;

        if (end_idx > self.buf.len) {
            return null;
        }
        self.remaining_capacity = 0;

        return .{ .data = self.buf[start_idx..end_idx].ptr, .size_buffer_used = self.buf.len };
    }

    pub fn free(self: *Self, allocation: []u8) usize {
        if (!contains(self.buf, allocation)) {
            return 0;
        }

        if (self.children) |children| {
            for (0..2) |i| {
                const t = children[i].free(allocation);
                if (t > 0) {
                    self.remaining_capacity += t;
                    return t;
                }
            }
        }

        self.remaining_capacity = self.buf.len;
        return self.buf.len;
    }

    pub fn resize(self: *Self, allocation: []u8, len: usize, ptr_align: u8) bool {
        if (!contains(self.buf, allocation)) {
            return false;
        }

        if (self.children) |children| {
            for (0..2) |i| {
                if (children[i].resize(allocation, len, ptr_align)) {
                    return true;
                }
            }
        }

        const start_idx = align_offset(self.buf.ptr, 0, ptr_align);
        const end_idx = start_idx + len;

        if (end_idx > self.buf.len) return false;
        return true;
    }

    fn biggest_possible_allocation(self: *Self, lower_bound: usize) usize {
        // remaining_capacity is an upper bound on the biggest possible allocation
        if (self.remaining_capacity < lower_bound) {
            return 0;
        }

        if (self.remaining_capacity == self.buf.len) {
            return self.remaining_capacity;
        }

        var ans = lower_bound;
        if (self.children) |children| {
            for (0..2) |i| {
                const child_val = children[i].biggest_possible_allocation(ans);
                if (ans < child_val) {
                    ans = child_val;
                }
            }
        }

        return ans;
    }

    fn split(self: *Self, allocator_nodes: *[]BuddyAllocatorNode, min_size: usize) void {
        self.remaining_capacity = self.buf.len;
        if (self.buf.len <= min_size) {
            return;
        }

        std.debug.assert(self.buf.len > 1);
        std.debug.assert(self.children == null);

        const left_buf_end = (self.buf.len + 1) / 2;

        const left_buf = self.buf[0..left_buf_end];
        const right_buf = self.buf[left_buf_end..];

        self.children = allocator_nodes.*.ptr;
        self.children.?[0].buf = left_buf;
        allocator_nodes.* = allocator_nodes.*[1..];

        self.children.?[1].buf = right_buf;
        allocator_nodes.* = allocator_nodes.*[1..];

        self.children.?[0].split(allocator_nodes, min_size);
        self.children.?[1].split(allocator_nodes, min_size);
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
    root: BuddyAllocatorNode,

    const Self = @This();

    pub fn biggest_possible_allocation(self: *Self) usize {
        return self.root.biggest_possible_allocation(0);
    }

    pub fn remaining_capacity(self: *Self) usize {
        return self.root.remaining_capacity;
    }

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &BuddyAllocatorVtable,
        };
    }

    pub fn usable_size(self: *Self) usize {
        return self.root.buf.len;
    }

    pub fn init(buf: []u8) !BuddyAllocator {
        const min_size = 64 << 10;
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

        var p: [*]BuddyAllocatorNode = @ptrCast(@alignCast(buf.ptr + wasted_space(BuddyAllocatorNode, buf)));
        var allocator_nodes = p[0 .. num_allocator_nodes(min_size, size_allocated) - 1];
        for (0..allocator_nodes.len) |i| {
            allocator_nodes[i].children = null;
        }

        var result: BuddyAllocator = undefined;

        const usable_start_idx = compute_overhead(min_size, size_allocated, buf);
        const usable_end_idx = usable_start_idx + size_allocated;

        result.root.children = null;
        result.root.buf = buf[usable_start_idx..usable_end_idx];
        result.root.split(&allocator_nodes, min_size);

        return result;
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
};

var global_buf: [64 << 20]u8 = undefined;
test "standard allocator tests on LinearAllocator" {
    var linear_allocator = std.mem.validationWrap(LinearAllocator.init(&global_buf));
    try std.heap.testAllocator(linear_allocator.allocator());
    try std.heap.testAllocatorAligned(linear_allocator.allocator());
    try std.heap.testAllocatorLargeAlignment(linear_allocator.allocator());
    try std.heap.testAllocatorAlignedShrink(linear_allocator.allocator());
}
test "standard allocator tests on BuddyAllocator" {
    var buddy_allocator = std.mem.validationWrap(try BuddyAllocator.init(&global_buf));
    try std.heap.testAllocator(buddy_allocator.allocator());
    try std.heap.testAllocatorAligned(buddy_allocator.allocator());
    try std.heap.testAllocatorLargeAlignment(buddy_allocator.allocator());
    try std.heap.testAllocatorAlignedShrink(buddy_allocator.allocator());
}
