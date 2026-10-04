const gait = @import("gait.zig");
const noise = @import("noise.zig");
const view = @import("view.zig");

pub const grad1 = noise.grad1;
pub const noise1 = noise.noise1;

pub const WalkTuning = gait.Tuning;
pub const Sway = gait.Sway;
pub const Walk = gait.Walk;
pub const Lean = gait.Lean;

pub const Aim = view.Aim;
pub const Handheld = view.Handheld;
pub const Shake = view.Shake;
