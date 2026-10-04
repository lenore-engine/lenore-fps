const std = @import("std");
const fps = @import("lenore-fps");

const testing = std.testing;

const Recoil = fps.Recoil;
const Spring = fps.Spring;

// A pistol, near enough to be about the shape of the motion.
const pistol: fps.RecoilProfile = .{
    .rise = 0.035,
    .drift = 0.012,
    .recovery = 0.7,
    .view = .{ .frequency = 4.0, .damping = 0.8 },
    .kick_back = 0.03,
    .muzzle_rise = 0.12,
    .muzzle_drift = 0.02,
    .hand = .{ .frequency = 9.0, .damping = 0.55 },
    .shake = 0.15,
};

// The same spring by brute force: semi-implicit Euler at a microsecond, which
// is ten thousand steps inside the fastest period below and close enough to
// be the reference.
fn integrate(spring: Spring, x0: f32, v0: f32, seconds: f32) [2]f64 {
    const omega: f64 = std.math.tau * @as(f64, spring.frequency);
    const zeta: f64 = spring.damping;
    var x: f64 = x0;
    var v: f64 = v0;
    const dt: f64 = 1e-6;
    var t: f64 = 0.0;
    while (t < seconds) : (t += dt) {
        v += (-2.0 * zeta * omega * v - omega * omega * x) * dt;
        x += v * dt;
    }
    return .{ x, v };
}

test "the exact step agrees with a fine integration, damped and critical" {
    for ([_]Spring{
        .{ .frequency = 9.0, .damping = 0.55 },
        .{ .frequency = 4.0, .damping = 1.0 },
        .{ .frequency = 2.5, .damping = 0.15 },
    }) |spring| {
        var at: @Vector(1, f32) = .{0.4};
        var speed: @Vector(1, f32) = .{-3.0};
        spring.over(0.137).apply(1, &at, &speed);
        const reference = integrate(spring, 0.4, -3.0, 0.137);
        try testing.expectApproxEqAbs(reference[0], at[0], 1e-3);
        try testing.expectApproxEqAbs(reference[1], speed[0], 2e-2);
    }
}

test "two steps are one step of their sum" {
    const spring: Spring = .{ .frequency = 6.0, .damping = 0.4 };
    var split_at: @Vector(2, f32) = .{ 0.1, -0.2 };
    var split_speed: @Vector(2, f32) = .{ 1.5, 0.0 };
    var whole_at = split_at;
    var whole_speed = split_speed;

    spring.over(0.010).apply(2, &split_at, &split_speed);
    spring.over(0.023).apply(2, &split_at, &split_speed);
    spring.over(0.033).apply(2, &whole_at, &whole_speed);
    inline for (0..2) |axis| {
        try testing.expectApproxEqAbs(whole_at[axis], split_at[axis], 1e-5);
        try testing.expectApproxEqAbs(whole_speed[axis], split_speed[axis], 1e-4);
    }
}

test "a frame many times the period does not blow up" {
    // Ninety hertz stepped at a tenth of a second is ω·dt of 57, far past
    // where an explicit integrator diverges.
    const spring: Spring = .{ .frequency = 90.0, .damping = 0.3 };
    var at: @Vector(1, f32) = .{1.0};
    var speed: @Vector(1, f32) = .{0.0};
    for (0..10) |_| spring.over(0.1).apply(1, &at, &speed);
    try testing.expect(@abs(at[0]) < 1e-6);
}

test "the reach is the height of the first peak" {
    for ([_]Spring{
        .{ .frequency = 9.0, .damping = 0.55 },
        .{ .frequency = 4.0, .damping = 1.0 },
    }) |spring| {
        var at: @Vector(1, f32) = .{0.0};
        var speed: @Vector(1, f32) = .{1.0 / spring.reach()};
        var peak: f32 = 0.0;
        const step = spring.over(1e-4);
        for (0..20000) |_| {
            step.apply(1, &at, &speed);
            peak = @max(peak, at[0]);
        }
        try testing.expectApproxEqAbs(@as(f32, 1.0), peak, 1e-3);
    }
}

test "a spring that is not one is refused" {
    try testing.expectError(error.FrequencyNotPositive, (Spring{ .frequency = 0.0, .damping = 0.5 }).validate());
    try testing.expectError(error.FrequencyNotPositive, (Spring{ .frequency = std.math.inf(f32), .damping = 0.5 }).validate());
    try testing.expectError(error.DampingOutOfRange, (Spring{ .frequency = 3.0, .damping = 1.5 }).validate());
    try testing.expectError(error.DampingOutOfRange, (Spring{ .frequency = 3.0, .damping = std.math.nan(f32) }).validate());

    var bad = pistol;
    bad.recovery = 1.2;
    try testing.expectError(error.RecoveryOutOfRange, Recoil.init(bad));
    bad = pistol;
    bad.muzzle_rise = -0.1;
    try testing.expectError(error.BadAmount, Recoil.init(bad));
    bad = pistol;
    bad.drift_bias = 2.0;
    try testing.expectError(error.DriftBiasOutOfRange, Recoil.init(bad));
}

test "a shot climbs by what the view does not recover, and the rest comes back" {
    var recoil = try Recoil.init(pistol);
    const kick = recoil.kick();

    // Up, by the unrecovered share of a rise within its spread.
    try testing.expect(kick.climb_pitch > 0.3 * 0.035 * 0.8 - 1e-6);
    try testing.expect(kick.climb_pitch < 0.3 * 0.035 * 1.2 + 1e-6);
    try testing.expect(@abs(kick.climb_yaw) <= 0.3 * 0.012 + 1e-6);
    try testing.expectEqual(pistol.shake, kick.shake);

    var highest: f32 = 0.0;
    var hand_highest: f32 = 0.0;
    for (0..240) |_| {
        recoil.update(1.0 / 240.0);
        highest = @max(highest, recoil.view().pitch);
        hand_highest = @max(hand_highest, recoil.weapon().pitch);
    }
    // The recovered share shows once at its full height, and the weapon's
    // kick at the authored muzzle rise, give or take the spread.
    const shown = kick.climb_pitch / 0.3 * 0.7;
    try testing.expectApproxEqAbs(shown, highest, shown * 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.12), hand_highest, 0.12 * 0.01);

    // A second later both are back at rest.
    try testing.expect(@abs(recoil.view().pitch) < 1e-4);
    try testing.expect(@abs(recoil.weapon().back) < 1e-4);
}

test "the same shots kick the same way and the frame rate does not matter" {
    var slow = try Recoil.init(pistol);
    var fast = try Recoil.init(pistol);
    for (0..5) |_| {
        const a = slow.kick();
        const b = fast.kick();
        try testing.expectEqual(a.climb_pitch, b.climb_pitch);
        try testing.expectEqual(a.climb_yaw, b.climb_yaw);
        for (0..3) |_| slow.update(1.0 / 30.0);
        for (0..24) |_| fast.update(1.0 / 240.0);
    }
    try testing.expectApproxEqAbs(slow.view().pitch, fast.view().pitch, 1e-5);
    try testing.expectApproxEqAbs(slow.weapon().pitch, fast.weapon().pitch, 1e-5);
}

test "successive shots do not all turn the same way" {
    var recoil = try Recoil.init(pistol);
    var left: usize = 0;
    var right: usize = 0;
    for (0..64) |_| {
        if (recoil.kick().climb_yaw < 0.0) left += 1 else right += 1;
    }
    try testing.expect(left > 16 and right > 16);

    var leaning = pistol;
    leaning.drift_bias = 1.0;
    var biased = try Recoil.init(leaning);
    for (0..64) |_| try testing.expect(biased.kick().climb_yaw >= 0.0);
}
