const std = @import("std");

pub fn typeId(comptime T: type) u32 {
    return @truncate(@intFromPtr(&struct {
        const _ = T;
        const byte: u8 = 0;
    }.byte));
}

pub fn hashComponents(component_ids: []u32) u64 {
    var hash: u64 = 0;
    for (component_ids) |component_id| {
        hash +%= std.hash.Wyhash.hash(0, std.mem.asBytes(&component_id));
    }
    return hash;
}
