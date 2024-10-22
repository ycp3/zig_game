const std = @import("std");

pub fn typeId(comptime T: type) u32 {
    return @truncate(@intFromPtr(&struct {
        const _ = T;
        const byte: u8 = 0;
    }.byte));
}

pub fn hashComponents(component_ids: []const u32) u64 {
    var hash: u64 = 0;
    for (component_ids) |component_id| {
        hash +%= std.hash.Wyhash.hash(0, std.mem.asBytes(&component_id));
    }
    return hash;
}

pub fn typesToIds(comptime components: anytype) [components.len]u32 {
    var component_ids: [components.len]u32 = undefined;
    inline for (components, 0..) |T, i| {
        component_ids[i] = typeId(T);
    }
    return component_ids;
}

pub fn componentNameZ(comptime T: type) [:0]const u8 {
    var name: []const u8 = @typeName(T);
    var name_parts = std.mem.splitScalar(u8, name, '.');
    while (name_parts.next()) |s| {
        name = s;
    }
    const nameZ: [:0]const u8 = std.fmt.comptimePrint("{s}", .{name});
    return nameZ;
}
