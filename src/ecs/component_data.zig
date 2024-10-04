const std = @import("std");

pub const ErasedComponentData = struct {
    ptr: *anyopaque,
    deinit: *const fn (self: *ErasedComponentData, allocator: std.mem.Allocator) void,
    clone: *const fn (self: ErasedComponentData, allocator: std.mem.Allocator, out: *ErasedComponentData) error{OutOfMemory}!void,
    copy: *const fn (dest: *anyopaque, allocator: std.mem.Allocator, dest_row: u32, src_row: u32, src: *anyopaque) error{OutOfMemory}!void,
    remove: *const fn (erased: *anyopaque, row: u32) void,

    pub fn cast(self: ErasedComponentData, comptime T: type) *ComponentData(T) {
        return @ptrCast(@alignCast(self.ptr));
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
            self.data.swapRemove(row_index);
        }

        pub inline fn copy_from(self: *Self, allocator: std.mem.Allocator, dest_row: u32, src_row: u32, src: *Self) !void {}
    };
}
