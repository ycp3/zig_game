const rl = @import("raylib");
const std = @import("std");
const ecs = @import("ecs/ecs.zig");
const c = @import("components.zig");
const constants = @import("constants.zig");

pub fn setup(world: *ecs.World) !void {
    var r = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    var random = r.random();

    for (0..100000) |_| {
        const e = try world.newEntity();
        try world.set(e, c.Position{
            .x = random.float(f32) * constants.screen_width,
            .y = random.float(f32) * constants.screen_height,
        });
        try world.set(e, c.Rotation{
            .degrees = random.float(f32) * 360,
        });
        try world.set(e, c.Color{
            .color = rl.Color{
                .r = random.int(u8),
                .g = random.int(u8),
                .b = random.int(u8),
                .a = 255,
            },
        });
    }
}

pub fn run(world: *ecs.World) !void {
    try moveSquares(world);
    try rotateSquares(world);
    try drawSquares(world);
}

fn moveSquares(world: *ecs.World) !void {
    var q = try world.query(.{c.Position});
    while (q.next()) |r| {
        r.Position.x += 1;
    }
}

fn rotateSquares(world: *ecs.World) !void {
    var q = try world.query(.{c.Rotation});
    while (q.next()) |r| {
        r.Rotation.degrees += 2;
    }
}

fn drawSquares(world: *ecs.World) !void {
    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(rl.Color.ray_white);

    var q = try world.query(.{ c.Position, c.Rotation, c.Color });
    while (q.next()) |r| {
        rl.drawRectanglePro(
            rl.Rectangle{
                .x = r.Position.x,
                .y = r.Position.y,
                .width = 20,
                .height = 20,
            },
            rl.Vector2.init(10, 10),
            r.Rotation.degrees,
            r.Color.color,
        );
    }
}
