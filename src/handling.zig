const std = @import("std");
const scene = @import("lenore-scene");
const zm = @import("zmath");

const gait = @import("gait.zig");
const recoil = @import("recoil.zig");
const Spring = @import("spring.zig").Spring;
const view = @import("view.zig");

const Vec3 = @Vector(3, f32);

// Where the weapon is held relative to the eye, and so where it points.
//
// There is no crosshair to aim with. The shot leaves the muzzle along the
// barrel, so everything that moves the weapon in the hand moves the shot:
// the weapon trailing a turn of the view, swinging with the walk, wandering
// with the hand that holds it, and kicking with the last round. Raising the
// sights brings the barrel onto the line of sight and quiets all of that,
// which is what aiming is for.
//
// The pose is in the frame of the view: `right`, `up` and `front` as a
// `scene.Placement` gives them, metres from the eye. Angles in radians and
// with the camera's sense: positive yaw turns the muzzle to the right of the
// view, positive pitch raises it, positive roll leans the top to the right.

pub const Pose = struct {
    // Where the model's origin sits: right, up, front. The angles turn the
    // weapon about that point, so an origin at the grip turns it in the hand.
    position: @Vector(3, f32),
    yaw: f32 = 0.0,
    pitch: f32 = 0.0,
    roll: f32 = 0.0,
};

pub const Profile = struct {
    // At the hip and with the sights raised. Raised, the sight line is the
    // view axis, so `aimed` puts the sights on it with no turn.
    hip: Pose,
    aimed: Pose,
    // Seconds to raise the sights and to lower them again.
    raise: f32,

    // The share of a turn of the view the weapon does not follow at once, in
    // [0, 1], and the most it may trail by. The spring brings it back.
    inertia: f32,
    inertia_limit: f32,
    look: Spring,

    // How the weapon trails a change in the body's speed: a band pass over
    // the speed, the same one `Lean` tips a body with, read as metres per
    // metre a second. A band pass rather than a spring kicked by the change,
    // because a walk starts and reverses within one frame, and a kick that size
    // in one frame is a jerk; the band pass answers a step with a curve that
    // starts at zero. `sway_rise` has to exceed `sway_settle` or there is no
    // throw, only a lag.
    sway: f32,
    sway_rise: f32,
    sway_settle: f32,
    // How much of the walk's swing the weapon takes on top of the camera's.
    // The camera already carries it, so zero is a weapon fixed to the eye
    // while the picture bobs.
    bob: f32,

    // The handheld wander at the hip, in radians and metres.
    drift_angle: f32,
    drift_shift: f32,
    // What remains of the trailing, the swing and the wander with the sights
    // raised, in [0, 1].
    steady: f32,

    // Where the shot leaves, in the model's own space.
    muzzle: @Vector(3, f32),

    pub const Error = Spring.Error || error{
        // A time, a share or a distance outside what it can mean.
        BadAmount,
    };

    pub fn validate(self: Profile) Error!void {
        try self.look.validate();
        if (!(self.sway_settle > 0.0) or !(self.sway_rise > self.sway_settle) or
            !std.math.isFinite(self.sway_rise)) return error.BadAmount;
        if (!(self.raise > 0.0) or !std.math.isFinite(self.raise)) return error.BadAmount;
        for ([_]f32{ self.inertia, self.steady }) |share| {
            if (!(share >= 0.0) or share > 1.0) return error.BadAmount;
        }
        for ([_]f32{ self.inertia_limit, self.sway, self.bob, self.drift_angle, self.drift_shift }) |amount| {
            if (!(amount >= 0.0) or !std.math.isFinite(amount)) return error.BadAmount;
        }
    }
};

// What the body did this frame, as the caller measured it.
pub const Motion = struct {
    // How far the view turned since the last frame, in radians.
    turn_yaw: f32 = 0.0,
    turn_pitch: f32 = 0.0,
    // The body's velocity across and along the view's level heading, in
    // metres a second. Level, because a body walks on the ground whatever the
    // view is pointed at.
    right: f32 = 0.0,
    forward: f32 = 0.0,
    // The walk's swing this frame.
    sway: gait.Sway = .{},
};

// A pose resolved into world space.
pub const Held = struct {
    // Model to world, for the draw. zmath's row-vector convention: a model
    // point `p` lands at `mul(p, model)`.
    model: zm.Mat,
    // Where the shot leaves and which way, unit length.
    muzzle: Vec3,
    direction: Vec3,
};

pub const Handling = struct {
    profile: Profile,

    // How far the sights are raised, in [0, 1], moving at a constant rate.
    // What is drawn eases it, so the weapon starts and stops gently while the
    // time to raise stays exactly `raise`.
    raised: f32 = 0.0,
    aiming: bool = false,

    // Yaw and pitch the weapon trails the view by.
    look_at: @Vector(2, f32) = @splat(0.0),
    look_speed: @Vector(2, f32) = @splat(0.0),
    // Right, up and front the weapon trails the body by, and the throw across
    // and along the heading that puts it there.
    move_at: @Vector(3, f32) = @splat(0.0),
    throw_right: gait.Lean,
    throw_forward: gait.Lean,

    hand: view.Handheld,
    // This frame's wander and swing, kept for `pose`.
    drift: view.Handheld.Drift = .{ .right = 0.0, .up = 0.0, .pitch = 0.0, .yaw = 0.0, .roll = 0.0 },
    sway: gait.Sway = .{},

    pub fn init(profile: Profile) Profile.Error!Handling {
        try profile.validate();
        return .{
            .profile = profile,
            .hand = .{ .angle = profile.drift_angle, .shift = profile.drift_shift, .seed = 0x7b3a91c5 },
            .throw_right = .{ .gain = profile.sway, .rise = profile.sway_rise, .settle = profile.sway_settle },
            .throw_forward = .{ .gain = profile.sway, .rise = profile.sway_rise, .settle = profile.sway_settle },
        };
    }

    pub fn update(self: *Handling, motion: Motion, delta: f32) void {
        const p = self.profile;
        const toward: f32 = if (self.aiming) 1.0 else -1.0;
        self.raised = std.math.clamp(self.raised + toward * delta / p.raise, 0.0, 1.0);

        // The weapon stays where it pointed for the share of the turn it does
        // not follow, then the spring pulls it after the view. Clamped before
        // the step, so a flick leaves it at the limit rather than past it.
        const turned: @Vector(2, f32) = .{ motion.turn_yaw, motion.turn_pitch };
        const limit: @Vector(2, f32) = @splat(p.inertia_limit);
        self.look_at = std.math.clamp(self.look_at - turned * @as(@Vector(2, f32), @splat(p.inertia)), -limit, limit);
        p.look.over(delta).apply(2, &self.look_at, &self.look_speed);

        // A change of speed throws the weapon the other way.
        self.move_at = .{
            -self.throw_right.update(motion.right, delta),
            0.0,
            -self.throw_forward.update(motion.forward, delta),
        };

        self.drift = self.hand.update(delta);
        self.sway = motion.sway;
    }

    // Where the weapon is this frame, with the shot's kick on top.
    pub fn pose(self: *const Handling, kick: recoil.WeaponOffset) Pose {
        const p = self.profile;
        const drift = self.drift;
        const sway = self.sway;
        const eased = smoothstep(self.raised);
        const loose = 1.0 + (p.steady - 1.0) * eased;

        const position = lerp3(p.hip.position, p.aimed.position, eased) +
            @as(@Vector(3, f32), @splat(loose)) * (self.move_at + @Vector(3, f32){
                (sway.right * p.bob) + drift.right,
                (sway.up * p.bob) + drift.up,
                0.0,
            }) -
            @Vector(3, f32){ 0.0, 0.0, kick.back };

        return .{
            .position = position,
            .yaw = lerp(p.hip.yaw, p.aimed.yaw, eased) + loose * (self.look_at[0] + drift.yaw) + kick.yaw,
            .pitch = lerp(p.hip.pitch, p.aimed.pitch, eased) + loose * (self.look_at[1] + drift.pitch) + kick.pitch,
            .roll = lerp(p.hip.roll, p.aimed.roll, eased) + loose * (sway.roll * p.bob + drift.roll),
        };
    }

    // The pose carried into the world by the view it is held in.
    pub fn place(self: *const Handling, held: Pose, eye: scene.Placement) Held {
        const axes = basis(held);
        // Each of the weapon's axes, from the view's components to the world.
        const right = worldOf(eye, axes.right);
        const up = worldOf(eye, axes.up);
        const front = worldOf(eye, axes.front);
        const origin = eye.position + worldOf(eye, held.position);

        // glTF 2.0, 3.4: +Y up, +Z forward, -X right. So the model's X axis
        // is the weapon's left, and the rows below are the images of the
        // model's axes.
        const model: zm.Mat = .{
            zm.f32x4(-right[0], -right[1], -right[2], 0.0),
            zm.f32x4(up[0], up[1], up[2], 0.0),
            zm.f32x4(front[0], front[1], front[2], 0.0),
            zm.f32x4(origin[0], origin[1], origin[2], 1.0),
        };
        const m = self.profile.muzzle;
        const muzzle = origin - right * @as(Vec3, @splat(m[0])) +
            up * @as(Vec3, @splat(m[1])) + front * @as(Vec3, @splat(m[2]));
        return .{ .model = model, .muzzle = muzzle, .direction = front };
    }
};

const Basis = struct {
    right: @Vector(3, f32),
    up: @Vector(3, f32),
    front: @Vector(3, f32),
};

// The weapon's axes in the view's components, by the same construction the
// camera uses for its own: yaw and pitch place the front, the level right
// depends on the yaw alone, and the roll turns right and up about the front.
fn basis(held: Pose) Basis {
    const sy = @sin(held.yaw);
    const cy = @cos(held.yaw);
    const sp = @sin(held.pitch);
    const cp = @cos(held.pitch);
    const sr = @sin(held.roll);
    const cr = @cos(held.roll);

    const front: @Vector(3, f32) = .{ sy * cp, sp, cy * cp };
    const level_right: @Vector(3, f32) = .{ cy, 0.0, -sy };
    const level_up: @Vector(3, f32) = .{ -sy * sp, cp, -cy * sp };
    return .{
        .right = level_right * @as(@Vector(3, f32), @splat(cr)) - level_up * @as(@Vector(3, f32), @splat(sr)),
        .up = level_up * @as(@Vector(3, f32), @splat(cr)) + level_right * @as(@Vector(3, f32), @splat(sr)),
        .front = front,
    };
}

fn worldOf(eye: scene.Placement, local: @Vector(3, f32)) Vec3 {
    return eye.right * @as(Vec3, @splat(local[0])) +
        eye.up * @as(Vec3, @splat(local[1])) +
        eye.front * @as(Vec3, @splat(local[2]));
}

fn smoothstep(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn lerp3(a: @Vector(3, f32), b: @Vector(3, f32), t: f32) @Vector(3, f32) {
    return a + (b - a) * @as(@Vector(3, f32), @splat(t));
}
