const std = @import("std");
const rl = @import("raylib");
const ecs = @import("ecs/ecs.zig");

pub fn main() void {
    const screenWidth = 800;
    const screenHeight = 450;

    rl.initWindow(screenWidth, screenHeight, "raylib [core] example - basic window");
    rl.setTargetFPS(144);

    while (rl.windowShouldClose()) {
        rl.beginDrawing();
        rl.clearBackground(rl.Color.ray_white);
        rl.drawText("Congrats! You created your first window!", 190, 200, 20, rl.Color.light_gray);
        rl.endDrawing();
    }

    rl.closeWindow();
}
