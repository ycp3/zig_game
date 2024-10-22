const std = @import("std");
const rl = @import("raylib");
const ecs = @import("ecs/ecs.zig");

pub const Position = struct {
    x: f32,
    y: f32,
};

pub const Rotation = struct {
    degrees: f32,
};

pub const Color = struct {
    color: rl.Color,
};

pub fn main() !void {
    const screenWidth = 800;
    const screenHeight = 450;

    rl.initWindow(screenWidth, screenHeight, "raylib [core] example - basic window");
    rl.setTargetFPS(144);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var world = try ecs.World.init(allocator);
    var r = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    var random = r.random();

    for (0..100000) |_| {
        const e = try world.newEntity();
        try world.set(e, Position{
            .x = random.float(f32) * screenWidth,
            .y = random.float(f32) * screenHeight,
        });
        try world.set(e, Rotation{
            .degrees = random.float(f32) * 360,
        });
        try world.set(e, Color{
            .color = rl.Color{
                .r = random.int(u8),
                .g = random.int(u8),
                .b = random.int(u8),
                .a = 255,
            },
        });
    }

    while (!rl.windowShouldClose()) {
        std.debug.print("{}\n", .{rl.getFPS()});

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(rl.Color.ray_white);

        // rl.drawText("Congrats! You created your first window!", 190, 200, 20, rl.Color.light_gray);

        var q = try world.query(.{ Position, Rotation, Color });
        while (try q.next()) |result| {
            // result.Position.x -= 5;
            result.Rotation.degrees += 2;

            rl.drawRectanglePro(
                rl.Rectangle{
                    .x = result.Position.x,
                    .y = result.Position.y,
                    .width = 20,
                    .height = 20,
                },
                rl.Vector2.init(10, 10),
                result.Rotation.degrees,
                result.Color.color,
            );
        }
    }

    rl.closeWindow();
}
