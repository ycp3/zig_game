const rl = @import("raylib");

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
