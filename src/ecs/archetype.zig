const std = @import("std");
const utils = @import("utils.zig");
const EntityId = @import("aliases.zig").EntityId;
const ArchetypeHash = @import("aliases.zig").ArchetypeHash;
const ErasedComponentData = @import("component_data.zig").ErasedComponentData;
const ComponentData = @import("component_data.zig").ComponentData;

pub const Archetype = @This();

allocator: std.mem.Allocator,
hash: u64,
components: std.AutoArrayHashMapUnmanaged(u32, ErasedComponentData),
entity_ids: std.ArrayListUnmanaged(EntityId),

pub fn addEntity(self: *Archetype, entity_id: EntityId) !u32 {
    const row_index = self.entity_ids.items.len;
    try self.entity_ids.append(self.allocator, entity_id);
    return @intCast(row_index);
}

pub fn undoAdd(self: *Archetype) void {
    _ = self.entity_ids.pop();
}

pub fn set(self: *Archetype, row_index: u32, component: anytype) !void {
    const T = @TypeOf(component);
    const erased = self.components.get(utils.typeId(T)).?;
    const component_data = ErasedComponentData.cast(erased.ptr, T);
    try component_data.set(self.allocator, row_index, component);
}

pub fn removeEntity(self: *Archetype, row_index: u32) void {
    _ = self.entity_ids.swapRemove(row_index);
    for (self.components.values()) |erased| {
        erased.remove(erased.ptr, row_index);
    }
}
