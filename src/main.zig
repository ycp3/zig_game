const std = @import("std");
const rl = @import("raylib");
const rlm = rl.math;

pub const VOID_ARCHETYPE_HASH: u64 = 0;

pub const EntityId = u64;
pub const World = struct {
    allocator: std.mem.Allocator,
    // hash -> Archetype
    archetypes: std.AutoArrayHashMapUnmanaged(u64, Archetype),
    entities: std.AutoHashMapUnmanaged(EntityId, EntityInfo),
    entity_counter: EntityId,
    queries: std.ArrayHashMapUnmanaged(QueryInfo, std.ArrayListUnmanaged(*Archetype), QueryContext, false),

    pub const QueryInfo = struct {
        hash: u64,
        component_ids: std.ArrayListUnmanaged(u32),
    };

    pub const EntityInfo = struct {
        archetype_index: u16,
        row_index: u32,
    };

    pub const QueryContext = struct {
        pub fn hash(_: QueryContext, key: QueryInfo) u32 {
            return std.hash.Fnv1a_32.hash(std.mem.asBytes(&key.hash));
        }

        pub fn eql(_: QueryContext, key: QueryInfo, other: QueryInfo, _: usize) bool {
            return key.hash == other.hash and key.component_ids.items.len == other.component_ids.items.len;
        }
    };

    pub fn init(allocator: std.mem.Allocator) !World {
        var world = World{
            .allocator = allocator,
            .archetypes = .{},
            .entities = .{},
            .entity_counter = 0,
            .queries = .{},
        };
        try world.archetypes.put(allocator, VOID_ARCHETYPE_HASH, Archetype{
            .allocator = allocator,
            .components = .{},
            .hash = VOID_ARCHETYPE_HASH,
        });
        return world;
    }

    pub fn deinit(world: *World) void {
        var iter = world.archetypes.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        world.archetypes.deinit();
    }

    pub fn initErasedStorage(world: *const World, len: *usize, comptime T: type) !ErasedComponentStorage {
        const new_ptr = try world.allocator.create(ComponentStorage(T));
        new_ptr.* = ComponentStorage(T){ .len = len };

        return .{
            .ptr = new_ptr,
            .deinit = (struct {
                pub fn deinit(erased: *anyopaque, allocator: std.mem.Allocator) void {
                    var ptr = ErasedComponentStorage.cast(erased, T);
                    ptr.deinit(allocator);
                    allocator.destroy(ptr);
                }
            }).deinit,
            .cloneType = (struct {
                pub fn cloneType(erased: ErasedComponentStorage, _len: *usize, allocator: std.mem.Allocator, out: *ErasedComponentStorage) !void {
                    const clone = try allocator.create(ComponentStorage(T));
                    clone.* = ComponentStorage(T){ .len = _len };
                    var tmp = erased;
                    tmp.ptr = clone;
                    out.* = tmp;
                }
            }).cloneType,
            .copy = (struct {
                pub fn copy(dest: *anyopaque, allocator: std.mem.Allocator, dest_row: u32, src_row: u32, src: *anyopaque) !void {
                    var dest_casted = ErasedComponentStorage.cast(dest, T);
                    const src_casted = ErasedComponentStorage.cast(src, T);
                    return dest_casted.copy(allocator, dest_row, src_row, src_casted);
                }
            }).copy,
            .remove = (struct {
                pub fn remove(erased: *anyopaque, row: u32) void {
                    var ptr = ErasedComponentStorage.cast(erased, T);
                    ptr.remove(row);
                }
            }).remove,
        };
    }

    pub fn entity(world: *World) !EntityId {
        const id = world.entity_counter;
        world.entity_counter += 1;

        var void_archetype = world.archetypes.getPtr(VOID_ARCHETYPE_HASH).?;
        const new_row = try void_archetype.add(id);
        const entity_info = EntityInfo{
            .archetype_index = 0,
            .row_index = new_row,
        };

        world.entities.put(world.allocator, id, entity_info) catch |err| {
            void_archetype.undoAdd();
            return err;
        };

        return id;
    }

    pub inline fn archetypeById(world: *World, _entity: EntityId) *Archetype {
        const ptr = world.entities.get(_entity).?;
        return &world.archetypes.values()[ptr.archetype_index];
    }

    pub fn setComponent(world: *World, _entity: EntityId, comptime T: type, component: T) !void {
        const component_id = typeId(T);
        var current_archetype = world.archetypeById(_entity);
        const old_hash = current_archetype.hash;
        const new_hash = if (current_archetype.components.contains(component_id))
            old_hash
        else
            old_hash +% std.hash.Wyhash.hash(0, std.mem.asBytes(&component_id));

        const archetype_entry = try world.archetypes.getOrPut(world.allocator, new_hash);
        if (!archetype_entry.found_existing) {
            archetype_entry.value_ptr.* = Archetype{
                .allocator = world.allocator,
                .components = .{},
                .hash = 0,
            };

            var new_archetype = archetype_entry.value_ptr;

            var column_iter = current_archetype.components.iterator();
            while (column_iter.next()) |entry| {
                var erased: ErasedComponentStorage = undefined;
                entry.value_ptr.cloneType(entry.value_ptr.*, &new_archetype.entity_ids.items.len, world.allocator, &erased) catch |err| {
                    std.debug.assert(world.archetypes.swapRemove(new_hash));
                    return err;
                };
                new_archetype.components.put(world.allocator, entry.key_ptr.*, erased) catch |err| {
                    std.debug.assert(world.archetypes.swapRemove(new_hash));
                    return err;
                };
            }

            const erased = world.initErasedStorage(&new_archetype.entity_ids.items.len, T) catch |err| {
                std.debug.assert(world.archetypes.swapRemove(new_hash));
                return err;
            };
            new_archetype.components.put(world.allocator, component_id, erased) catch |err| {
                std.debug.assert(world.archetypes.swapRemove(new_hash));
                return err;
            };
            new_archetype.calculateHash();
            var query_iter = world.queries.iterator();
            outer: while (query_iter.next()) |entry| {
                const query_info = entry.key_ptr;
                for (query_info.component_ids.items) |id| {
                    if (!std.mem.containsAtLeast(u32, new_archetype.components.keys(), 1, &[_]u32{id})) {
                        continue :outer;
                    }
                }
                try entry.value_ptr.append(world.allocator, new_archetype);
            }
        }

        var new_archetype = archetype_entry.value_ptr;

        if (new_hash == old_hash) {
            const ptr = world.entities.get(_entity).?;
            try new_archetype.set(ptr.row_index, T, component);
            return;
        }

        const new_row = try new_archetype.add(_entity);
        const entity_info = world.entities.get(_entity).?;

        var column_iter = current_archetype.components.iterator();
        while (column_iter.next()) |entry| {
            const old_component_storage: *ErasedComponentStorage = entry.value_ptr;
            var new_component_storage: ErasedComponentStorage = new_archetype.components.get(entry.key_ptr.*).?;
            new_component_storage.copy(new_component_storage.ptr, world.allocator, new_row, entity_info.row_index, old_component_storage.ptr) catch |err| {
                new_archetype.undoAdd();
                return err;
            };
        }

        new_archetype.set(new_row, T, component) catch |err| {
            new_archetype.undoAdd();
            return err;
        };

        const swapped_entity_id = current_archetype.entity_ids.items[current_archetype.entity_ids.items.len - 1];
        current_archetype.remove(entity_info.row_index) catch |err| {
            new_archetype.undoAdd();
            return err;
        };

        try world.entities.put(world.allocator, swapped_entity_id, entity_info);

        try world.entities.put(world.allocator, _entity, EntityInfo{
            .archetype_index = @intCast(archetype_entry.index),
            .row_index = new_row,
        });
    }

    pub fn getComponent(world: *World, _entity: EntityId, comptime T: type) ?T {
        const entity_info = world.entities.get(_entity).?;
        const archetype = world.archetypes.values()[entity_info.archetype_index];

        const component_storage_erased: ErasedComponentStorage = archetype.components.get(typeId(T)) orelse return null;
        const component_storage = ErasedComponentStorage.cast(component_storage_erased.ptr, T);
        return component_storage.get(entity_info.row_index);
    }

    pub fn QueryResult(comptime components: []const type) type {
        var f: [components.len]std.builtin.Type.StructField = undefined;
        inline for (components, 0..) |T, i| {
            var name: []const u8 = @typeName(T);
            var name_parts = std.mem.splitScalar(u8, name, '.');
            while (name_parts.next()) |s| {
                name = s;
            }
            const nameZ: [:0]const u8 = std.fmt.comptimePrint("{s}", .{name});

            f[i] = std.builtin.Type.StructField{
                .name = nameZ,
                .type = *T,
                .is_comptime = false,
                .default_value = null,
                .alignment = @alignOf(*T),
            };
        }

        return @Type(std.builtin.Type{
            .@"struct" = .{
                .fields = &f,
                .layout = .auto,
                .decls = &.{},
                .is_tuple = false,
            },
        });
    }

    pub fn QueryIter(comptime components: []const type) type {
        return struct {
            archetypes: *std.ArrayListUnmanaged(*Archetype),
            archetype_index: usize = 0,
            component_index: usize = 0,
            next: *const fn (self: *@This()) ?QueryResult(components),
        };
    }

    pub fn query(world: *World, comptime components: []const type) !QueryIter(components) {
        const hash = blk: {
            var h: u64 = 0;
            inline for (components) |T| {
                h +%= std.hash.Wyhash.hash(0, std.mem.asBytes(&typeId(T)));
            }
            break :blk h;
        };
        var component_ids: std.ArrayListUnmanaged(u32) = .{};
        inline for (components) |T| {
            try component_ids.append(world.allocator, typeId(T));
        }
        var archetypes: *std.ArrayListUnmanaged(*Archetype) = undefined;
        const result = try world.queries.getOrPut(world.allocator, QueryInfo{ .hash = hash, .component_ids = component_ids });
        if (!result.found_existing) {
            const ptr: *std.ArrayListUnmanaged(*Archetype) = result.value_ptr;
            ptr.* = std.ArrayListUnmanaged(*Archetype){};

            outer: for (world.archetypes.values()) |archetype| {
                inline for (components) |T| {
                    if (!std.mem.containsAtLeast(u32, archetype.components.keys(), 1, &[_]u32{typeId(T)})) {
                        continue :outer;
                    }
                }
                std.debug.print("success, component id is {d} and component_ids for archetype is {d}\n", .{ component_ids.items, archetype.components.keys() });
                try ptr.append(world.allocator, @constCast(&archetype));
            }

            std.debug.print("ARCHTYEPS.LEN THRU PTR:{}\n", .{ptr.items.len});
            result.key_ptr.* = QueryInfo{ .hash = hash, .component_ids = component_ids };
        }
        archetypes = result.value_ptr;
        std.debug.print("ARCHTYEPS.LEN THRU PTR2:{d}\n", .{archetypes.items[0].components.keys()});

        return QueryIter(components){
            .archetypes = archetypes,
            .next = (struct {
                pub fn next(self: *QueryIter(components)) ?QueryResult(components) {
                    if (self.archetype_index >= self.archetypes.items.len) return null;

                    std.debug.print("ARCHTYEPS.LEN THRU OBJ:{d}\n", .{self.archetypes.items[0].components.keys()});
                    std.debug.print("SELFARCHETYPEINDEX:{}\n", .{self.archetype_index});
                    var ret: QueryResult(components) = undefined;
                    var len: usize = undefined;
                    inline for (components) |T| {
                        const name = blk: {
                            comptime {
                                var n: []const u8 = @typeName(T);
                                var name_parts = std.mem.splitScalar(u8, n, '.');
                                while (name_parts.next()) |s| {
                                    n = s;
                                }
                                break :blk n;
                            }
                        };
                        const component_id = typeId(T);
                        const erased_storage = self.archetypes.items[self.archetype_index].components.get(component_id).?;
                        const storage = ErasedComponentStorage.cast(erased_storage.ptr, T);
                        std.debug.print("COMPONENT IDS OF ARCHETYPE:{d},", .{storage.data.items.len});
                        len = storage.len.*;
                        @field(ret, name) = &storage.data.items[self.component_index];
                    }

                    self.component_index += 1;
                    if (self.component_index >= len) {
                        self.component_index = 0;
                        self.archetype_index += 1;
                    }
                    return ret;
                }
            }).next,
        };
    }
};

pub const Archetype = struct {
    allocator: std.mem.Allocator,
    hash: u64,
    // component_id -> component storage
    components: std.AutoArrayHashMapUnmanaged(u32, ErasedComponentStorage),
    entity_ids: std.ArrayListUnmanaged(EntityId) = .{},

    pub fn calculateHash(storage: *Archetype) void {
        var hash: u64 = 0;
        for (storage.components.keys()) |id| {
            hash +%= std.hash.Wyhash.hash(0, std.mem.asBytes(&id));
        }
        storage.hash = hash;
    }

    pub fn deinit(storage: *Archetype) void {
        for (storage.components.values()) |erased| {
            erased.deinit(erased.ptr, storage.allocator);
        }
        storage.components.deinit(storage.allocator);
        storage.entity_ids.deinit(storage.allocator);
    }

    pub fn add(storage: *Archetype, entity: EntityId) !u32 {
        const row_index = storage.entity_ids.items.len;
        try storage.entity_ids.append(storage.allocator, entity);
        return @intCast(row_index);
    }

    pub fn undoAdd(storage: *Archetype) void {
        _ = storage.entity_ids.pop();
    }

    pub fn remove(storage: *Archetype, row_index: u32) !void {
        _ = storage.entity_ids.swapRemove(row_index);
        for (storage.components.values()) |component_storage| {
            component_storage.remove(component_storage.ptr, row_index);
        }
    }

    pub fn set(storage: *Archetype, row_index: u32, comptime T: type, component: T) !void {
        const component_storage_erased = storage.components.get(typeId(T)).?;
        const component_storage = ErasedComponentStorage.cast(component_storage_erased.ptr, T);
        try component_storage.set(storage.allocator, row_index, component);
    }
};

pub const ErasedComponentStorage = struct {
    ptr: *anyopaque,
    deinit: *const fn (erased: *anyopaque, allocator: std.mem.Allocator) void,
    cloneType: *const fn (erased: ErasedComponentStorage, len: *usize, allocator: std.mem.Allocator, out: *ErasedComponentStorage) error{OutOfMemory}!void,
    copy: *const fn (dest: *anyopaque, allocator: std.mem.Allocator, dest_row: u32, src_row: u32, src: *anyopaque) error{OutOfMemory}!void,
    remove: *const fn (erased: *anyopaque, row: u32) void,

    pub fn cast(ptr: *anyopaque, comptime T: type) *ComponentStorage(T) {
        return @ptrCast(@alignCast(ptr));
    }
};

pub fn ComponentStorage(comptime T: type) type {
    return struct {
        const Self = @This();

        len: *usize,
        data: std.ArrayListUnmanaged(T) = .{},

        pub fn deinit(storage: *Self, allocator: std.mem.Allocator) void {
            storage.data.deinit(allocator);
        }

        pub fn remove(storage: *Self, row_index: u32) void {
            if (row_index < storage.data.items.len) {
                _ = storage.data.swapRemove(row_index);
            }
        }

        pub inline fn copy(dest: *Self, allocator: std.mem.Allocator, dest_row: u32, src_row: u32, src: *Self) !void {
            try dest.set(allocator, dest_row, src.get(src_row));
        }

        // TODO: does this need to take a ptr and return a ptr to the actual component?
        pub inline fn get(storage: Self, row_index: u32) T {
            return storage.data.items[row_index];
        }

        pub fn set(storage: *Self, allocator: std.mem.Allocator, row_index: u32, component: T) !void {
            if (row_index >= storage.data.items.len) {
                try storage.data.appendNTimes(allocator, undefined, storage.data.items.len + 1 - row_index);
            }
            storage.data.items[row_index] = component;
        }
    };
}

pub const Position = struct {
    x: i32,
    y: i32,
};

pub const Rotation = struct { degrees: f32 };

pub fn main() !void {
    const screenWidth = 800;
    const screenHeight = 450;

    rl.initWindow(screenWidth, screenHeight, "raylib-zig [core] example - basic window");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var world = try World.init(allocator);
    var r = std.Random.DefaultPrng.init(0);

    for (0..100000) |_| {
        const e = try world.entity();
        try world.setComponent(e, Position, Position{
            .x = @mod(r.random().int(i32), @as(i32, screenWidth)),
            .y = @mod(r.random().int(i32), @as(i32, screenHeight)),
        });
        try world.setComponent(e, Rotation, Rotation{
            .degrees = r.random().float(f32),
        });
    }

    while (!rl.windowShouldClose()) {
        // std.debug.print("{}\n", .{rl.getFPS()});

        rl.beginDrawing();
        defer rl.endDrawing();

        var a = try world.query(&[_]type{ Position, Rotation });
        // const b = world.query(&[_]type{Rotation});
        while (a.next(&a)) |result| {
            result.Rotation.degrees += 1.0;
        }

        // std.debug.print("a:{s}\n", .{std.meta.fieldNames(World.QueryResult(&[_]type{ Position, Rotation }))});

        rl.clearBackground(rl.Color.white);

        rl.drawText("Congrats! You created your first window!", 190, 200, 20, rl.Color.light_gray);
    }
}

pub fn typeId(comptime T: type) u32 {
    return @truncate(@intFromPtr(&struct {
        const _ = T;
        const byte: u8 = 0;
    }.byte));
}

// pub fn queryId(comptime []const type) u32 {
//
// }
