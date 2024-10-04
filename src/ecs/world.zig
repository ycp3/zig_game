const std = @import("std");
const utils = @import("utils.zig");
const Archetype = @import("archetype.zig");
const EntityId = @import("aliases.zig").EntityId;
const ArchetypeHash = @import("aliases.zig").ArchetypeHash;
const ErasedComponentData = @import("component_data.zig").ErasedComponentData;
const ComponentData = @import("component_data.zig").ComponentData;

pub const World = @This();

const VOID_ARCHETYPE_HASH: u64 = 0;

allocator: std.mem.Allocator,
entity_counter: EntityId,
entities: std.AutoHashMapUnmanaged(EntityId, EntityInfo),
archetypes: std.AutoArrayHashMapUnmanaged(ArchetypeHash, Archetype),

pub const EntityInfo = struct {
    archetype_index: u16,
    row_index: u32,
};

pub fn init(allocator: std.mem.Allocator) !World {
    var world = World{
        .allocator = allocator,
        .entity_counter = 0,
        .entities = .{},
        .archetypes = .{},
    };
    try world.archetypes.put(allocator, VOID_ARCHETYPE_HASH, Archetype{
        .allocator = allocator,
        .components = .{},
        .hash = VOID_ARCHETYPE_HASH,
    });
    return world;
}

pub fn deinit(self: *World) void {
    var iter = self.archetypes.iterator();
    while (iter.next()) |entry| {
        entry.value_ptr.deinit();
    }
    self.archetypes.deinit(self.allocator);
    self.entities.deinit(self.allocator);
}

pub fn newEntity(self: *World) !EntityId {
    const id = self.entity_counter;
    self.entity_counter += 1;

    var void_archetype = self.archetypes.get(VOID_ARCHETYPE_HASH).?;
    const row_index = try void_archetype.addEntity(id);
    errdefer void_archetype.undoAdd();

    try self.entities.put(id, EntityInfo{
        .archetype_index = 0,
        .row_index = row_index,
    });

    return id;
}

pub fn initErased(self: *World, comptime T: type) !ErasedComponentData {
    const new_ptr = try self.allocator.create(ComponentData(T));
    new_ptr.* = ComponentData(T){};
}

pub fn set(self: *World, entity_id: EntityId, component: anytype) !void {
    const T = @TypeOf(component);
    const component_id = utils.typeId(T);
    const entity_info = self.entities.get(entity_id).?;
    const old_archetype = self.archetypes.values()[entity_info.archetype_index];

    if (old_archetype.components.contains(component_id)) {
        try old_archetype.set(entity_info.row_index, component);
        return;
    }

    const new_hash = old_archetype.hash +% std.hash.Wyhash.hash(0, std.mem.asBytes(&component_id));

    const new_archetype_entry = self.archetypes.getOrPut(self.allocator, new_hash);
    if (!new_archetype_entry.found_existing) {
        errdefer self.archetypes.swapRemove(new_hash);

        new_archetype_entry.value_ptr.* = Archetype{
            .allocator = self.allocator,
            .components = .{},
            .hash = new_hash,
        };

        const new_archetype_ptr = new_archetype_entry.value_ptr;
        var old_columns = old_archetype.components.iterator();
        while (old_columns.next()) |entry| {
            var erased = undefined;
            entry.value_ptr.clone(self.allocator, &erased);
            new_archetype_ptr.components.put(self.allocator, entry.key_ptr.*, erased);
        }

        const erased = self.initErased(T);
    }

    var new_archetype = new_archetype_entry.value_ptr;
}
