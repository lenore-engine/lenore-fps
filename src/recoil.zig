const std = @import("std");

const noise = @import("noise.zig");
const Spring = @import("spring.zig").Spring;

// What a shot does to the view and to the weapon in the hand.
//
// Two springs and a remainder. Each shot throws the view up and to one side
// and throws the weapon back and up in the hand; both springs bring their
// part back to rest. What the view does not recover by itself is handed back
// to the caller as climb, to be added to the aim, which is where it stays
// until the player pulls it down. That split is what makes a string of fast
// shots walk upward while a single one only twitches.
//
// The weapon's spring is not only a picture. Where the muzzle points is where
// the next shot goes, so a follow-up fired before the weapon has settled
// leaves along the kick, and that is the cost of firing fast.
//
// Angles in radians. Positive pitch raises the muzzle, positive yaw turns it
// to the right of the view.

pub const Profile = struct {
    // Radians the view climbs per shot, on average, and how far one shot may
    // stray from that as a fraction of it.
    rise: f32,
    rise_spread: f32 = 0.2,
    // Radians the view may turn sideways per shot, at most, and which way it
    // leans: -1 always left, 1 always right, 0 either way alike.
    drift: f32,
    drift_bias: f32 = 0.0,
    // The fraction of each shot's turn the view returns from by itself, in
    // [0, 1]. The rest is climb.
    recovery: f32,
    view: Spring,

    // The weapon in the hand, per shot: metres straight back, and radians of
    // muzzle rise and of sideways twist. The twist follows the view's drift,
    // so the two move to the same side.
    kick_back: f32,
    muzzle_rise: f32,
    muzzle_drift: f32,
    hand: Spring,

    // Disturbance handed to a `Shake` per shot, in its [0, 1].
    shake: f32,

    pub const Error = Spring.Error || error{
        // A per-shot amount that is negative or not a number.
        BadAmount,
        RecoveryOutOfRange,
        DriftBiasOutOfRange,
    };

    pub fn validate(self: Profile) Error!void {
        try self.view.validate();
        try self.hand.validate();
        for ([_]f32{
            self.rise,        self.rise_spread,  self.drift, self.kick_back,
            self.muzzle_rise, self.muzzle_drift, self.shake,
        }) |amount| {
            if (!(amount >= 0.0) or !std.math.isFinite(amount)) return error.BadAmount;
        }
        if (!(self.recovery >= 0.0) or self.recovery > 1.0) return error.RecoveryOutOfRange;
        if (!(self.drift_bias >= -1.0) or self.drift_bias > 1.0) return error.DriftBiasOutOfRange;
    }
};

// What a shot hands back to the caller.
pub const Kick = struct {
    // Radians to add to the aim, which is where the shot leaves for good.
    climb_pitch: f32,
    climb_yaw: f32,
    // For `Shake.add`.
    shake: f32,
};

pub const ViewOffset = struct {
    pitch: f32,
    yaw: f32,
};

pub const WeaponOffset = struct {
    // Metres along the view, toward the eye.
    back: f32,
    pitch: f32,
    yaw: f32,
};

pub const Recoil = struct {
    profile: Profile,

    // Pitch and yaw.
    view_at: @Vector(2, f32) = @splat(0.0),
    view_speed: @Vector(2, f32) = @splat(0.0),
    // Back, pitch and yaw.
    hand_at: @Vector(3, f32) = @splat(0.0),
    hand_speed: @Vector(3, f32) = @splat(0.0),

    // Shots taken, which keys each shot's randomness. Two runs that fire the
    // same shots kick the same way, and a client and a host agreeing on the
    // count agree on the kick without sending it.
    shots: u32 = 0,
    seed: u32 = 0x632be5ab,

    pub fn init(profile: Profile) Profile.Error!Recoil {
        try profile.validate();
        return .{ .profile = profile };
    }

    // One shot. The springs take it as velocity, sized so that the first
    // peak of each is the authored amount: a kick shows its full height once
    // and is then pulled back, rather than appearing at once.
    pub fn kick(self: *Recoil) Kick {
        const p = self.profile;
        const index: i32 = @bitCast(self.shots);
        self.shots +%= 1;

        const rise = p.rise * (1.0 + p.rise_spread * noise.grad1(self.seed, index));
        const side = std.math.clamp(noise.grad1(self.seed +% 1, index) + p.drift_bias, -1.0, 1.0);
        const turn: @Vector(2, f32) = .{ rise, p.drift * side };

        const view_gain: @Vector(2, f32) = @splat(p.recovery / p.view.reach());
        self.view_speed += turn * view_gain;

        const hand: @Vector(3, f32) = .{ p.kick_back, p.muzzle_rise, p.muzzle_drift * side };
        self.hand_speed += hand * @as(@Vector(3, f32), @splat(1.0 / p.hand.reach()));

        const kept = 1.0 - p.recovery;
        return .{ .climb_pitch = turn[0] * kept, .climb_yaw = turn[1] * kept, .shake = p.shake };
    }

    pub fn update(self: *Recoil, delta: f32) void {
        self.profile.view.over(delta).apply(2, &self.view_at, &self.view_speed);
        self.profile.hand.over(delta).apply(3, &self.hand_at, &self.hand_speed);
    }

    // To add to the view the frame is drawn from, on top of the aim.
    pub fn view(self: *const Recoil) ViewOffset {
        return .{ .pitch = self.view_at[0], .yaw = self.view_at[1] };
    }

    // To add to where the weapon is held, and so to where it points.
    pub fn weapon(self: *const Recoil) WeaponOffset {
        return .{ .back = self.hand_at[0], .pitch = self.hand_at[1], .yaw = self.hand_at[2] };
    }
};
