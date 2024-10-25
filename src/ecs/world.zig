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
queries: std.ArrayHashMapUnmanaged(QueryInfo, std.ArrayListUnmanaged(u16), QueryContext, false),

pub const EntityInfo = struct {
    archetype_index: u16,
    row_index: u32,
};

pub const QueryInfo = struct {
    hash: u64,
    excl_hash: u64,
    component_ids: []const u32,
    excluded_ids: []const u32,
};

pub const QueryContext = struct {
    pub fn hash(_: QueryContext, key: QueryInfo) u32 {
        return @truncate(key.hash +% key.excl_hash);
    }

    pub fn eql(_: QueryContext, key: QueryInfo, other: QueryInfo, _: usize) bool {
        return key.hash == other.hash and
            key.excl_hash == other.excl_hash and
            key.component_ids.len == other.component_ids.len and
            key.excluded_ids.len == other.excluded_ids.len;
    }
};

pub fn init(allocator: std.mem.Allocator) !World {
    var world = World{
        .allocator = allocator,
        .entity_counter = 0,
        .entities = .{},
        .archetypes = .{},
        .queries = .{},
    };
    try world.archetypes.put(allocator, VOID_ARCHETYPE_HASH, Archetype{
        .allocator = allocator,
        .components = .{},
        .hash = VOID_ARCHETYPE_HASH,
        .entity_ids = .{},
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

    var void_archetype = self.archetypes.getPtr(VOID_ARCHETYPE_HASH).?;
    const row_index = try void_archetype.addEntity(id);
    errdefer void_archetype.undoAdd();

    try self.entities.put(self.allocator, id, EntityInfo{
        .archetype_index = 0,
        .row_index = row_index,
    });

    return id;
}

pub fn initErased(self: *World, comptime T: type) !ErasedComponentData {
    const new_ptr = try self.allocator.create(ComponentData(T));
    new_ptr.* = ComponentData(T){};

    return .{
        .ptr = new_ptr,
        .deinit = (struct {
            pub fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                var data_ptr = ErasedComponentData.cast(ptr, T);
                data_ptr.deinit(allocator);
                allocator.destroy(data_ptr);
            }
        }).deinit,
        .cloneType = (struct {
            pub fn cloneType(erased: ErasedComponentData, allocator: std.mem.Allocator, out: *ErasedComponentData) !void {
                const ptr = try allocator.create(ComponentData(T));
                ptr.* = ComponentData(T){};
                var tmp = erased;
                tmp.ptr = ptr;
                out.* = tmp;
            }
        }).cloneType,
        .copyFrom = (struct {
            pub fn copyFrom(dest: *anyopaque, allocator: std.mem.Allocator, dest_row: u32, src_row: u32, src: *anyopaque) !void {
                const dest_data = ErasedComponentData.cast(dest, T);
                const src_data = ErasedComponentData.cast(src, T);
                try dest_data.copyFrom(allocator, dest_row, src_row, src_data);
            }
        }).copyFrom,
        .remove = (struct {
            pub fn remove(ptr: *anyopaque, row: u32) void {
                ErasedComponentData.cast(ptr, T).remove(row);
            }
        }).remove,
    };
}

pub fn set(self: *World, entity_id: EntityId, component: anytype) !void {
    const T = @TypeOf(component);
    const component_id = utils.typeId(T);
    const entity_info = self.entities.get(entity_id).?;
    var old_archetype_ptr = &self.archetypes.values()[entity_info.archetype_index];

    if (old_archetype_ptr.components.contains(component_id)) {
        try old_archetype_ptr.set(entity_info.row_index, component);
        return;
    }

    const new_hash = old_archetype_ptr.hash +% std.hash.Wyhash.hash(0, std.mem.asBytes(&component_id));

    const new_archetype_entry = try self.archetypes.getOrPut(self.allocator, new_hash);
    const new_archetype_ptr: *Archetype = new_archetype_entry.value_ptr;
    if (!new_archetype_entry.found_existing) {
        errdefer std.debug.assert(self.archetypes.swapRemove(new_hash));

        new_archetype_ptr.* = Archetype{
            .allocator = self.allocator,
            .components = .{},
            .hash = new_hash,
            .entity_ids = .{},
        };

        var old_columns = old_archetype_ptr.components.iterator();
        while (old_columns.next()) |entry| {
            var erased: ErasedComponentData = undefined;
            try entry.value_ptr.cloneType(entry.value_ptr.*, self.allocator, &erased);
            try new_archetype_ptr.components.put(self.allocator, entry.key_ptr.*, erased);
        }

        const erased = try self.initErased(T);
        try new_archetype_ptr.components.put(self.allocator, component_id, erased);

        var query_iterator = self.queries.iterator();
        while (query_iterator.next()) |entry| {
            const query_info = entry.key_ptr;
            if (utils.matchesQuery(query_info.*, new_archetype_ptr.components.keys())) {
                try entry.value_ptr.append(self.allocator, @intCast(new_archetype_entry.index));
            }
        }
    }

    const new_row = try new_archetype_ptr.addEntity(entity_id);
    errdefer new_archetype_ptr.undoAdd();

    var column_iter = old_archetype_ptr.components.iterator();
    while (column_iter.next()) |entry| {
        const old_component_data: *ErasedComponentData = entry.value_ptr;
        var new_component_data: ErasedComponentData = new_archetype_ptr.components.get(entry.key_ptr.*).?;
        try new_component_data.copyFrom(new_component_data.ptr, self.allocator, new_row, entity_info.row_index, old_component_data.ptr);
    }

    try new_archetype_ptr.set(new_row, component);

    const swapped_entity_id = old_archetype_ptr.entity_ids.items[old_archetype_ptr.entity_ids.items.len - 1];
    old_archetype_ptr.removeEntity(entity_info.row_index);

    try self.entities.put(self.allocator, swapped_entity_id, entity_info);
    try self.entities.put(self.allocator, entity_id, EntityInfo{
        .archetype_index = @intCast(new_archetype_entry.index),
        .row_index = new_row,
    });
}

pub fn remove(self: *World, entity_id: EntityId, comptime T: type) !void {
    const component_id = utils.typeId(T);
    const entity_info = self.entities.get(entity_id).?;
    var old_archetype_ptr = &self.archetypes.values()[entity_info.archetype_index];

    if (!old_archetype_ptr.components.contains(component_id)) {
        return;
    }

    const new_hash = utils.hashComponentsWithout(old_archetype_ptr.components.keys(), component_id);

    const new_archetype_entry = try self.archetypes.getOrPut(self.allocator, new_hash);
    const new_archetype_ptr: *Archetype = new_archetype_entry.value_ptr;
    if (!new_archetype_entry.found_existing) {
        errdefer std.debug.assert(self.archetypes.swapRemove(new_hash));

        new_archetype_ptr.* = Archetype{
            .allocator = self.allocator,
            .components = .{},
            .hash = new_hash,
            .entity_ids = .{},
        };

        var old_columns = old_archetype_ptr.components.iterator();
        while (old_columns.next()) |entry| {
            if (entry.key_ptr.* == component_id) {
                continue;
            }
            var erased: ErasedComponentData = undefined;
            try entry.value_ptr.cloneType(entry.value_ptr.*, self.allocator, &erased);
            try new_archetype_ptr.components.put(self.allocator, entry.key_ptr.*, erased);
        }

        var query_iterator = self.queries.iterator();
        while (query_iterator.next()) |entry| {
            const query_info = entry.key_ptr;
            if (utils.matchesQuery(query_info.*, new_archetype_ptr.components.keys())) {
                try entry.value_ptr.append(self.allocator, @intCast(new_archetype_entry.index));
            }
        }
    }

    const new_row = try new_archetype_ptr.addEntity(entity_id);
    errdefer new_archetype_ptr.undoAdd();

    var column_iter = new_archetype_ptr.components.iterator();
    while (column_iter.next()) |entry| {
        const old_component_data: ErasedComponentData = old_archetype_ptr.components.get(entry.key_ptr.*).?;
        var new_component_data: *ErasedComponentData = entry.value_ptr;
        try new_component_data.copyFrom(new_component_data.ptr, self.allocator, new_row, entity_info.row_index, old_component_data.ptr);
    }

    const swapped_entity_id = old_archetype_ptr.entity_ids.items[old_archetype_ptr.entity_ids.items.len - 1];
    old_archetype_ptr.removeEntity(entity_info.row_index);

    try self.entities.put(self.allocator, swapped_entity_id, entity_info);
    try self.entities.put(self.allocator, entity_id, EntityInfo{
        .archetype_index = @intCast(new_archetype_entry.index),
        .row_index = new_row,
    });
}

pub fn get(self: World, entity_id: EntityId, comptime T: type) ?T {
    const entity_info = self.entities.get(entity_id).?;
    const archetype = self.archetypes.values()[entity_info.archetype_index];

    const erased = archetype.components.get(utils.typeId(T)) orelse return null;
    return ErasedComponentData.cast(erased.ptr, T).get(entity_info.row_index);
}

pub fn getPtr(self: World, entity_id: EntityId, comptime T: type) ?*T {
    const entity_info = self.entities.get(entity_id).?;
    const archetype = self.archetypes.values()[entity_info.archetype_index];

    const erased = archetype.components.get(utils.typeId(T)) orelse return null;
    return ErasedComponentData.cast(erased.ptr, T).getPtr(entity_info.row_index);
}

pub fn QueryIter(comptime components: anytype) type {
    return struct {
        world: *World,
        query_index: usize,
        archetype_index: usize = 0,
        component_index: usize = 0,

        pub fn next(iter: *QueryIter(components)) ?QueryResult(components) {
            const archetype_ids = iter.world.queries.values()[iter.query_index];
            if (iter.archetype_index >= archetype_ids.items.len) return null;
            const current_archetype_index = archetype_ids.items[iter.archetype_index];
            var archetype = iter.world.archetypes.values()[current_archetype_index];
            while (archetype.entity_ids.items.len == 0) {
                iter.archetype_index += 1;
                if (iter.archetype_index >= archetype_ids.items.len) return null;
                archetype = iter.world.archetypes.values()[archetype_ids.items[iter.archetype_index]];
            }

            var ret: QueryResult(components) = undefined;
            inline for (components) |T| {
                const name = comptime utils.componentNameZ(T);
                const component_id = utils.typeId(T);
                const erased = archetype.components.get(component_id).?;
                const component_data: *ComponentData(T) = ErasedComponentData.cast(erased.ptr, T);
                @field(ret, name) = component_data.getPtr(iter.component_index);
            }

            iter.component_index += 1;
            if (iter.component_index >= archetype.entity_ids.items.len) {
                iter.component_index = 0;
                iter.archetype_index += 1;
            }
            return ret;
        }
    };
}

pub fn QueryResult(comptime components: anytype) type {
    var f: [components.len]std.builtin.Type.StructField = undefined;
    inline for (components, 0..) |T, i| {
        const name = utils.componentNameZ(T);

        f[i] = std.builtin.Type.StructField{
            .name = name,
            .type = *T,
            .is_comptime = false,
            .default_value = null,
            .alignment = @alignOf(*T),
        };
    }

    return @Type(std.builtin.Type{
        .Struct = .{
            .fields = &f,
            .layout = .auto,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn query(self: *World, comptime components: anytype, comptime excluded: anytype) !QueryIter(components) {
    const component_ids = utils.typesToIds(components);
    const excluded_ids = utils.typesToIds(excluded);
    const hash = utils.hashComponents(&component_ids);
    const excl_hash = utils.hashComponents(&excluded_ids);
    const result = try self.queries.getOrPut(self.allocator, QueryInfo{
        .hash = hash,
        .excl_hash = excl_hash,
        .component_ids = &component_ids,
        .excluded_ids = &excluded_ids,
    });
    if (!result.found_existing) {
        const ptr = result.value_ptr;
        ptr.* = std.ArrayListUnmanaged(u16){};

        outer: for (self.archetypes.values(), 0..) |archetype, i| {
            inline for (excluded_ids) |id| {
                if (std.mem.containsAtLeast(u32, archetype.components.keys(), 1, &[_]u32{id})) {
                    continue :outer;
                }
            }
            inline for (component_ids) |id| {
                if (!std.mem.containsAtLeast(u32, archetype.components.keys(), 1, &[_]u32{id})) {
                    continue :outer;
                }
            }
            try ptr.append(self.allocator, @intCast(i));
        }
    }

    return QueryIter(components){
        .world = self,
        .query_index = result.index,
    };
}
