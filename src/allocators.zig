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

    pub fn remainingCapacity(self: *Self) usize {
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

fn contains(buf: []u8, allocation: []u8) bool {
    const start = @intFromPtr(buf.ptr);
    const end = start + buf.len;

    const allocation_start = @intFromPtr(allocation.ptr);
    const allocation_end = allocation_start + allocation.len;

    const allocation_start_within = start <= allocation_start and allocation_start < end;
    const allocation_end_within = start < allocation_end and allocation_end <= end;

    return allocation_start_within and allocation_end_within;
}

/// returns `x` cast to a `T`
fn get_runtime_constant(comptime T: type, x: anytype) T {
    return x;
}

test "contains" {
    var buf: [1024]u8 = undefined;

    for (0..buf.len) |start| {
        for (start + 1..buf.len) |end| {
            try std.testing.expect(contains(&buf, buf[start..end]));
        }
        var alloc = buf[start..buf.len];
        try std.testing.expect(contains(&buf, alloc));
        alloc.len += 1;
        try std.testing.expect(!contains(&buf, alloc));
    }

    {
        var alloc = buf[0..get_runtime_constant(usize, 1)];
        try std.testing.expect(contains(&buf, alloc));
        alloc.ptr -= 1;
        alloc.len = 1;
        try std.testing.expect(!contains(&buf, alloc));
        alloc.len = 2;
        try std.testing.expect(!contains(&buf, alloc));
    }
    {
        var alloc = buf[get_runtime_constant(usize, buf.len - 1)..buf.len];
        try std.testing.expect(contains(&buf, alloc));
        alloc.ptr += 1;
        alloc.len = 1;
        try std.testing.expect(!contains(&buf, alloc));
    }
}

// makes sure right node is always power of two size
fn compute_left_node_size(own_size: usize) usize {
    const log: std.math.Log2Int(usize) = @intCast(std.math.log2(own_size));
    const rounded = @as(usize, 1) << log;
    if (rounded == own_size) {
        return own_size / 2;
    } else {
        return own_size - rounded;
    }
}

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
        const left_size = compute_left_node_size(size);
        size = @max(left_size, size - left_size);
    }
    return num_nodes;
}

const BuddyAllocatorNode = struct {
    // children: ?[*]BuddyAllocatorNode,
    children_idx: ?usize,
    remaining_capacity: usize,

    const Self = @This();

    fn alloc(
        self: *Self,
        len: usize,
        ptr_align: u8,
        own_buf: []u8,
        allocator_nodes: []Self,
    ) ?struct {
        data: [*]u8,
        size_buffer_used: usize,
    } {
        if (len > self.remaining_capacity) {
            return null;
        }

        const left_buf_len = compute_left_node_size(own_buf.len);

        const left_buf = own_buf[0..left_buf_len];
        const right_buf = own_buf[left_buf_len..];

        if (self.children_idx) |idx| {
            for (
                allocator_nodes[idx .. idx + 2],
                [_][]u8{ left_buf, right_buf },
            ) |
                *child,
                child_buf,
            | {
                if (child.alloc(
                    len,
                    ptr_align,
                    child_buf,
                    allocator_nodes,
                )) |allocation| {
                    self.remaining_capacity -= allocation.size_buffer_used;
                    return allocation;
                }
            }
        }

        if (self.remaining_capacity < own_buf.len) {
            return null;
        }

        const start_idx = align_offset(own_buf.ptr, 0, ptr_align);
        const end_idx = start_idx + len;

        if (end_idx > own_buf.len) {
            return null;
        }
        self.remaining_capacity = 0;

        return .{
            // actually slice to make sure we get the runtime check when applicable
            .data = own_buf[start_idx..end_idx].ptr,
            .size_buffer_used = own_buf.len,
        };
    }

    fn free(
        self: *Self,
        allocation: []u8,
        own_buf: []u8,
        allocator_nodes: []Self,
    ) usize {
        if (!contains(own_buf, allocation)) {
            return 0;
        }

        const left_buf_len = compute_left_node_size(own_buf.len);

        const left_buf = own_buf[0..left_buf_len];
        const right_buf = own_buf[left_buf_len..];

        if (self.children_idx) |idx| {
            for (
                allocator_nodes[idx .. idx + 2],
                [_][]u8{ left_buf, right_buf },
            ) |
                *child,
                child_buf,
            | {
                const t = child.free(
                    allocation,
                    child_buf,
                    allocator_nodes,
                );
                if (t > 0) {
                    self.remaining_capacity += t;
                    return t;
                }
            }
        }

        self.remaining_capacity = own_buf.len;
        return own_buf.len;
    }

    fn resize(
        self: *const Self,
        allocation: []u8,
        len: usize,
        ptr_align: u8,
        own_buf: []u8,
        allocator_nodes: []Self,
    ) bool {
        if (!contains(own_buf, allocation)) {
            return false;
        }

        const left_buf_len = compute_left_node_size(own_buf.len);

        const left_buf = own_buf[0..left_buf_len];
        const right_buf = own_buf[left_buf_len..];

        if (self.children_idx) |idx| {
            for (
                allocator_nodes[idx .. idx + 2],
                [_][]u8{ left_buf, right_buf },
            ) |
                child,
                child_buf,
            | {
                if (child.resize(
                    allocation,
                    len,
                    ptr_align,
                    child_buf,
                    allocator_nodes,
                )) {
                    return true;
                }
            }
        }

        const start_idx = align_offset(own_buf.ptr, 0, ptr_align);
        const end_idx = start_idx + len;

        if (end_idx > own_buf.len) return false;
        return true;
    }

    fn biggest_possible_allocation(
        self: *Self,
        lower_bound: usize,
        ptr_align: u8,
        own_buf: []u8,
        allocator_nodes: []Self,
    ) usize {
        // remaining_capacity is an upper bound on the biggest possible allocation
        if (self.remaining_capacity < lower_bound) {
            return 0;
        }

        if (self.remaining_capacity == own_buf.len) {
            return self.remaining_capacity - align_offset(own_buf.ptr, 0, ptr_align);
        }

        var ans = lower_bound;
        const left_buf_len = compute_left_node_size(own_buf.len);

        const left_buf = own_buf[0..left_buf_len];
        const right_buf = own_buf[left_buf_len..];

        if (self.children_idx) |idx| {
            for (
                allocator_nodes[idx .. idx + 2],
                [_][]u8{ left_buf, right_buf },
            ) |
                child,
                child_buf,
            | {
                const child_val = child.biggest_possible_allocation(
                    ans,
                    ptr_align,
                    child_buf,
                    allocator_nodes,
                );
                if (ans < child_val) {
                    ans = child_val;
                }
            }
        }

        return ans;
    }

    fn split(
        self: *Self,
        idx: *usize,
        min_size: usize,
        buf_len: usize,
        allocator_nodes: []BuddyAllocatorNode,
    ) void {
        self.remaining_capacity = buf_len;
        if (buf_len <= min_size) {
            return;
        }

        std.debug.assert(buf_len > 1);
        std.debug.assert(self.children_idx == null);

        const left_buf_len = compute_left_node_size(buf_len);

        self.children_idx = idx.*;

        const left = &allocator_nodes[idx.*];
        const right = &allocator_nodes[idx.* + 1];
        idx.* += 2;

        left.split(idx, min_size, left_buf_len, allocator_nodes);
        right.split(idx, min_size, buf_len - left_buf_len, allocator_nodes);
    }
};

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
    root: *BuddyAllocatorNode,
    buf: []u8,
    allocator_nodes: []BuddyAllocatorNode,

    const Self = @This();

    pub fn biggestPossibleAllocation(self: *Self) usize {
        return self.root.biggest_possible_allocation(0, 0, self.buf);
    }

    pub fn remainingCapacity(self: *Self) usize {
        return self.root.remaining_capacity;
    }

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &BuddyAllocatorVtable,
        };
    }

    pub fn usableSize(self: *Self) usize {
        return self.buf.len;
    }

    // defaults to minimum size of 16KB
    pub fn init(buf: []u8) !BuddyAllocator {
        return initWithMinSize(buf, 16 << 10);
    }

    pub fn initWithMinSize(buf: []u8, min_size: usize) !BuddyAllocator {
        if (compute_overhead(min_size, min_size, buf) > buf.len) {
            return error.NotEnoughSpace;
        }

        var lo: usize = compute_overhead(min_size, min_size, buf);
        var hi: usize = buf.len;

        for (0..@bitSizeOf(usize)) |_| {
            const mi = lo + (hi - lo + 1) / 2;
            if (compute_overhead(min_size, mi, buf) + mi <= buf.len) {
                lo = mi;
            } else {
                hi = mi;
            }
        }

        const size_allocated = lo;

        var result: BuddyAllocator = undefined;
        var p: [*]BuddyAllocatorNode = @ptrCast(@alignCast(buf.ptr + wasted_space(BuddyAllocatorNode, buf)));
        var allocator_nodes = p[0..num_allocator_nodes(min_size, size_allocated)];
        result.allocator_nodes = allocator_nodes;
        for (0..allocator_nodes.len) |i| {
            allocator_nodes[i].children_idx = null;
        }

        const usable_start_idx = compute_overhead(min_size, size_allocated, buf);
        const usable_end_idx = usable_start_idx + size_allocated;

        result.root = &allocator_nodes[0];
        result.root.remaining_capacity = 0;
        result.root.children_idx = null;
        // result.root.buf = buf[usable_start_idx..usable_end_idx];
        result.buf = buf[usable_start_idx..usable_end_idx];
        var idx: usize = 1;
        result.root.split(&idx, min_size, result.buf.len, allocator_nodes);
        return result;
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.root.alloc(len, ptr_align, self.buf, self.allocator_nodes)) |allocation| {
            return allocation.data;
        } else {
            return null;
        }
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = buf_align;
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self.root.free(buf, self.buf, self.allocator_nodes);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.root.resize(buf, new_len, buf_align, self.buf, self.allocator_nodes);
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
