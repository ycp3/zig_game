const std = @import("std");
const rl = @import("raylib");
const ecs = @import("ecs/ecs.zig");
const systems = @import("systems.zig");
const constants = @import("constants.zig");

pub fn main() !void {
    rl.initWindow(constants.screen_width, constants.screen_height, "raylib [core] example - basic window");
    rl.setTargetFPS(144);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var world = try ecs.World.init(allocator);
    try systems.setup(&world);

    while (!rl.windowShouldClose()) {
        std.debug.print("{}\n", .{rl.getFPS()});

        try systems.run(&world);
    }

    rl.closeWindow();
}
