const std = @import("std");
const Allocator = std.mem.Allocator;

export fn align_offset(p: [*]u8, id: usize, alignment: usize) usize {
    std.debug.assert((alignment & (alignment - 1)) == 0);
    const remainder = @intFromPtr(p + id) % alignment;
    if (remainder == 0) {
        return id;
    } else {
        return id + alignment - remainder;
    }
}

const LinearAllocatorVtable: Allocator.VTable = .{
    .alloc = LinearAllocator.alloc,
    .free = LinearAllocator.free,
    .resize = Allocator.noResize,
};

pub const LinearAllocator = struct {
    pub const Self = @This();

    id: usize,
    buf: []u8,

    pub fn reset(self: *Self) void {
        self.id = 0;
    }

    pub fn init(buf: []u8) Self {
        return .{
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
        const alignment = @as(usize, 1) << @intCast(ptr_align);
        const self: *Self = @ptrCast(@alignCast(ctx));

        const start_idx = align_offset(self.buf.ptr, self.id, alignment);
        const end_idx = start_idx + len;
        if (end_idx > self.buf.len) return null;
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
    }
};

test "stardard allocator tests on LinearAllocator" {
    // 640K ought to be enough for anybody
    var buf: [640 << 10]u8 = undefined;
    var linear_allocator = LinearAllocator.init(&buf);
    try std.heap.testAllocator(linear_allocator.allocator());
    try std.heap.testAllocatorAligned(linear_allocator.allocator());
    try std.heap.testAllocatorLargeAlignment(linear_allocator.allocator());
    try std.heap.testAllocatorAlignedShrink(linear_allocator.allocator());
}
