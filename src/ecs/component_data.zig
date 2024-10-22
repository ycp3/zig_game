const std = @import("std");

pub const ErasedComponentData = struct {
    ptr: *anyopaque,
    deinit: *const fn (erased: *anyopaque, allocator: std.mem.Allocator) void,
    cloneType: *const fn (erased: ErasedComponentData, allocator: std.mem.Allocator, out: *ErasedComponentData) error{OutOfMemory}!void,
    copyFrom: *const fn (erased: *anyopaque, allocator: std.mem.Allocator, dest_row: u32, src_row: u32, src: *anyopaque) error{OutOfMemory}!void,
    remove: *const fn (erased: *anyopaque, row: u32) void,

    pub fn cast(ptr: *anyopaque, comptime T: type) *ComponentData(T) {
        return @ptrCast(@alignCast(ptr));
    }
};

pub fn ComponentData(comptime T: type) type {
    return struct {
        const Self = @This();

        data: std.ArrayListUnmanaged(T) = .{},

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.data.deinit(allocator);
        }

        pub fn remove(self: *Self, row_index: u32) void {
            _ = self.data.swapRemove(row_index);
        }

        pub inline fn copyFrom(self: *Self, allocator: std.mem.Allocator, dest_row: u32, src_row: u32, src: *Self) !void {
            try self.set(allocator, dest_row, src.get(src_row));
        }

        pub inline fn get(self: *Self, row_index: u32) T {
            return self.data.items[row_index];
        }

        pub inline fn getPtr(self: *Self, row_index: usize) *T {
            return &self.data.items[row_index];
        }

        pub fn set(self: *Self, allocator: std.mem.Allocator, row_index: u32, component: T) !void {
            if (row_index >= self.data.items.len) {
                try self.data.appendNTimes(allocator, undefined, row_index - self.data.items.len + 1);
            }
            self.data.items[row_index] = component;
        }
    };
}
