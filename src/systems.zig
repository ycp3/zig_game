const rl = @import("raylib");
const std = @import("std");
const ecs = @import("ecs/ecs.zig");
const c = @import("components.zig");
const constants = @import("constants.zig");

pub fn setup(world: *ecs.World) !void {
    const e = try world.newEntity();
    try world.set(e, c.Player{});
    try world.set(e, c.Position{
        .x = constants.screen_width / 2,
        .y = constants.screen_height / 2,
    });
}

pub fn run(world: *ecs.World) !void {
    try movement(world);
    try gravity(world);
    try draw(world);
}

fn movement(world: *ecs.World) !void {
    var q = try world.query(.{ c.Position, c.Player }, .{});
    while (q.next()) |r| {
        if (rl.isKeyDown(rl.KeyboardKey.a)) {
            r.Position.x -= 10;
        }
        if (rl.isKeyDown(rl.KeyboardKey.d)) {
            r.Position.x += 10;
        }
        if (rl.isKeyDown(rl.KeyboardKey.w)) {
            r.Position.y -= 20;
        }
    }
}

fn gravity(world: *ecs.World) !void {
    var q = try world.query(.{c.Position}, .{});
    while (q.next()) |r| {
        r.Position.y = @min(r.Position.y + 10, constants.screen_height);
    }
}

fn draw(world: *ecs.World) !void {
    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(rl.Color.ray_white);

    var q = try world.query(.{c.Position}, .{});
    while (q.next()) |r| {
        rl.drawRectanglePro(
            rl.Rectangle{
                .x = r.Position.x,
                .y = r.Position.y,
                .width = 20,
                .height = 20,
            },
            rl.Vector2{ .x = 10, .y = 10 },
            0,
            rl.Color.red,
        );
    }
}
