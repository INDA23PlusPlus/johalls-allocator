const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn ChunkedList(comptime T: type) type {
    const ChunkedListNode = struct {
        const Self = @This();
        next: ?*Self,
        items: []T,
        size: usize,

        fn default() Self {
            return .{
                .next = null,
                .items = &[_]T{},
                .size = 0,
            };
        }

        fn realloc(self: *Self, allocator: Allocator) bool {
            if (self.items.len == 0) {
                self.items = allocator.alloc(T, 16) catch return false;
                return true;
            } else {
                const new_cap = self.items.len * 5 / 4;
                if (allocator.resize(self.items, new_cap)) {
                    self.items.len = new_cap;
                    return true;
                } else {
                    return false;
                }
            }
        }

        fn push_back(self: *Self, val: T, allocator: Allocator) !void {
            if (self.size + 1 > self.items.len) {
                if (self.realloc(allocator)) {
                    self.items[self.size] = val;
                    self.size += 1;
                    return;
                }
                if (self.next) |next| {
                    return next.push_back(val, allocator);
                }
                self.next = try allocator.create(Self);
                self.next.?.* = default();
                return self.next.?.push_back(val, allocator);
            } else {
                self.items[self.size] = val;
                self.size += 1;
            }
        }

        fn my_back(self: *const Self) ?T {
            if (self.size == 0) {
                return null;
            } else {
                return self.items[self.size - 1];
            }
        }

        fn back(self: *const Self) ?T {
            if (self.next) |next| {
                if (next.back()) |b| {
                    return b;
                } else {
                    return self.my_back();
                }
            } else {
                return self.my_back();
            }
        }

        fn my_pop_back(self: *Self) ?T {
            if (self.size == 0) {
                return null;
            } else {
                self.size -= 1;
                return self.items[self.size];
            }
        }

        fn pop_back(self: *Self) ?T {
            if (self.next) |next| {
                if (next.pop_back()) |b| {
                    return b;
                } else {
                    return self.my_pop_back();
                }
            } else {
                return self.my_pop_back();
            }
        }

        fn deinit(self: *Self, allocator: Allocator) void {
            if (self.items.len > 0) {
                allocator.free(self.items);
            }
        }
    };

    return struct {
        const Self = @This();
        allocator: Allocator,
        head: ?*ChunkedListNode,

        pub fn deinit(self: *Self) void {
            var head = self.head;
            while (head) |curr| {
                head = curr.next;
                curr.deinit(self.allocator);
                self.allocator.destroy(curr);
            }
        }

        pub fn init(alloc: Allocator) Self {
            return .{
                .allocator = alloc,
                .head = null,
            };
        }

        pub fn pushBack(self: *Self, val: T) !void {
            if (self.head) |head| {
                return head.push_back(val, self.allocator);
            } else {
                self.head = try self.allocator.create(ChunkedListNode);
                self.head.?.* = ChunkedListNode.default();
                return self.head.?.push_back(val, self.allocator);
            }
        }

        pub fn back(self: *const Self) ?T {
            if (self.head) |head| {
                return head.back();
            } else {
                return null;
            }
        }

        pub fn popBack(self: *Self) ?T {
            if (self.head) |head| {
                return head.pop_back();
            } else {
                return null;
            }
        }
    };
}

test "basic functionality of chunked list" {
    var l = ChunkedList(usize).init(std.testing.allocator);
    defer l.deinit();

    for (0..128) |i| {
        try l.pushBack(i);
    }

    try std.testing.expectEqual(@as(usize, 127), l.back() orelse 0);

    for (0..128) |i| {
        try std.testing.expectEqual(127 - i, l.popBack().?);
    }
    try std.testing.expectEqual(@as(?usize, null), l.back());
}