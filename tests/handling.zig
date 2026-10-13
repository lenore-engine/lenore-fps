const std = @import("std");
const fps = @import("lenore-fps");
const scene = @import("lenore-scene");
const zm = @import("zmath");

const testing = std.testing;

const Handling = fps.Handling;

const rest: fps.WeaponOffset = .{ .back = 0.0, .pitch = 0.0, .yaw = 0.0 };

// A pistol held low and right at the hip and on the line of sight when
// raised, with no wander so that every number below is the mechanism's own.
const pistol: fps.HandlingProfile = .{
    .hip = .{ .position = .{ 0.16, -0.14, 0.32 } },
    .aimed = .{ .position = .{ 0.0, -0.065, 0.28 } },
    .raise = 0.25,
    .inertia = 0.5,
    .inertia_limit = 0.08,
    .look = .{ .frequency = 3.0, .damping = 0.75 },
    .sway = 0.02,
    .sway_rise = 9.0,
    .sway_settle = 5.5,
    .bob = 0.5,
    .drift_angle = 0.0,
    .drift_shift = 0.0,
    .steady = 0.25,
    .muzzle = .{ 0.0, 0.061, 0.101 },
};

test "a profile that cannot mean anything is refused" {
    var bad = pistol;
    bad.raise = 0.0;
    try testing.expectError(error.BadAmount, Handling.init(bad));
    bad = pistol;
    bad.inertia = 1.5;
    try testing.expectError(error.BadAmount, Handling.init(bad));
    bad = pistol;
    bad.sway = std.math.nan(f32);
    try testing.expectError(error.BadAmount, Handling.init(bad));
    bad = pistol;
    bad.sway_rise = 1.0;
    try testing.expectError(error.BadAmount, Handling.init(bad));
    bad = pistol;
    bad.look.damping = 2.0;
    try testing.expectError(error.DampingOutOfRange, Handling.init(bad));
}

test "a turn leaves the weapon behind, never past the limit, and it catches up" {
    var hand = try Handling.init(pistol);
    const delta: f32 = 1.0 / 120.0;

    // A turn to the right at three radians a second for a fifth of a second.
    var furthest: f32 = 0.0;
    for (0..24) |_| {
        hand.update(.{ .turn_yaw = 3.0 * delta }, delta);
        furthest = @min(furthest, hand.pose(rest).yaw);
    }
    // Trailing means pointing left of the view, by no more than the limit.
    try testing.expect(furthest < -0.02);
    try testing.expect(furthest >= -0.08 - 1e-6);

    // A flick far past the limit in one frame is held at it.
    var flicked = try Handling.init(pistol);
    flicked.update(.{ .turn_pitch = 1.0 }, delta);
    try testing.expect(flicked.look_at[1] >= -0.08 - 1e-6);

    for (0..240) |_| hand.update(.{}, delta);
    try testing.expect(@abs(hand.pose(rest).yaw) < 1e-4);
}

test "the sights come up in the time given and land on the line of sight" {
    var hand = try Handling.init(pistol);
    hand.aiming = true;
    const delta: f32 = 1.0 / 100.0;

    for (0..24) |_| hand.update(.{}, delta);
    try testing.expect(hand.raised < 1.0);
    hand.update(.{}, delta);
    try testing.expectEqual(@as(f32, 1.0), hand.raised);

    const raised = hand.pose(rest);
    try expectVec(pistol.aimed.position, raised.position, 1e-6);
    try testing.expectEqual(@as(f32, 0.0), raised.yaw);
    try testing.expectEqual(@as(f32, 0.0), raised.pitch);

    hand.aiming = false;
    for (0..25) |_| hand.update(.{}, delta);
    try testing.expectEqual(@as(f32, 0.0), hand.raised);
}

test "with the sights up the weapon trails by the steady share" {
    var hip = try Handling.init(pistol);
    var aimed = try Handling.init(pistol);
    aimed.aiming = true;
    aimed.raised = 1.0;

    const delta: f32 = 1.0 / 120.0;
    for (0..6) |_| {
        hip.update(.{ .turn_yaw = 0.01 }, delta);
        aimed.update(.{ .turn_yaw = 0.01 }, delta);
    }
    try testing.expectApproxEqAbs(hip.pose(rest).yaw * 0.25, aimed.pose(rest).yaw, 1e-6);
}

test "starting to walk throws the weapon back toward the eye, gently" {
    var hand = try Handling.init(pistol);
    const delta: f32 = 1.0 / 240.0;
    hand.update(.{ .forward = 1.0 }, delta);
    const first = pistol.hip.position[2] - hand.pose(rest).position[2];

    var nearest: f32 = pistol.hip.position[2];
    for (0..720) |_| {
        hand.update(.{ .forward = 1.0 }, delta);
        nearest = @min(nearest, hand.pose(rest).position[2]);
    }
    // Back, by the share of `sway` this band pass passes at its peak, which
    // `Lean`'s own test puts near 0.46 at these rates.
    const peak = pistol.hip.position[2] - nearest;
    try testing.expect(peak > 0.40 * 0.02 and peak < 0.50 * 0.02);
    // A step in the speed arrives as a curve: the first frame is a small part
    // of the peak, not all of it.
    try testing.expect(first > 0.0 and first < 0.12 * peak);
    // And it is gone while the walk goes on.
    try testing.expectApproxEqAbs(pistol.hip.position[2], hand.pose(rest).position[2], 1e-4);
}

test "a strafe reversed in one frame does not jerk the weapon" {
    var hand = try Handling.init(pistol);
    const delta: f32 = 1.0 / 240.0;
    for (0..480) |_| hand.update(.{ .right = 1.8 }, delta);

    var previous = hand.pose(rest).position[0];
    var largest_step: f32 = 0.0;
    var furthest: f32 = 0.0;
    for (0..480) |_| {
        hand.update(.{ .right = -1.8 }, delta);
        const now = hand.pose(rest).position[0];
        largest_step = @max(largest_step, @abs(now - previous));
        furthest = @max(furthest, now - pistol.hip.position[0]);
        previous = now;
    }
    // Thrown to the right, against the new direction, and never by more than
    // a tenth of that in one frame.
    try testing.expect(furthest > 0.01);
    try testing.expect(largest_step < 0.1 * furthest);
}

test "the kick moves the weapon back and turns it up" {
    var hand = try Handling.init(pistol);
    hand.update(.{}, 1.0 / 60.0);
    const kicked = hand.pose(.{ .back = 0.02, .pitch = 0.1, .yaw = -0.01 });
    try testing.expectApproxEqAbs(pistol.hip.position[2] - 0.02, kicked.position[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.1), kicked.pitch, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.01), kicked.yaw, 1e-6);
}

fn expectVec(expected: anytype, actual: anytype, tolerance: f32) !void {
    inline for (0..3) |axis| try testing.expectApproxEqAbs(expected[axis], actual[axis], tolerance);
}

test "placed in the world, the model and the muzzle agree with the view" {
    const camera: scene.Camera = .{
        .anchor = .{ .eye = .{ 3.0, 1.6, -2.0 } },
        .yaw = 0.7,
        .pitch = -0.2,
    };
    const eye = camera.placement();
    var hand = try Handling.init(pistol);
    hand.update(.{}, 1.0 / 60.0);

    // Square to the view: the barrel is the view's front, and the model's
    // own +Z is the barrel and its -X the view's right.
    const square = hand.place(hand.pose(rest), eye);
    try expectVec(eye.front, square.direction, 1e-6);
    const model_forward = zm.mul(zm.f32x4(0.0, 0.0, 1.0, 0.0), square.model);
    try expectVec(eye.front, model_forward, 1e-6);
    const model_left = zm.mul(zm.f32x4(1.0, 0.0, 0.0, 0.0), square.model);
    try expectVec(-eye.right, model_left, 1e-6);

    // The muzzle the handling reports is the model's muzzle point carried by
    // the model matrix.
    const m = pistol.muzzle;
    const carried = zm.mul(zm.f32x4(m[0], m[1], m[2], 1.0), square.model);
    try expectVec(carried, square.muzzle, 1e-5);

    // Turned right and up in the hand, it points right of and above the view.
    var turned = hand.pose(rest);
    turned.yaw = 0.1;
    turned.pitch = 0.05;
    const placed = hand.place(turned, eye);
    const dot = struct {
        fn f(a: @Vector(3, f32), b: @Vector(3, f32)) f32 {
            return @reduce(.Add, a * b);
        }
    }.f;
    try testing.expect(dot(placed.direction, eye.right) > 0.09);
    try testing.expect(dot(placed.direction, eye.up) > 0.04);
    try testing.expectApproxEqAbs(@as(f32, 1.0), dot(placed.direction, placed.direction), 1e-5);

    // Turned and rolled, the model's axes stay unit and square to each other,
    // the roll leans the top toward the view's right, and the muzzle is still
    // the model's own point carried.
    turned.roll = 0.3;
    const rolled = hand.place(turned, eye);
    const axes = [_]@Vector(3, f32){
        lane(rolled.model[0]), lane(rolled.model[1]), lane(rolled.model[2]),
    };
    for (axes, 0..) |a, i| {
        try testing.expectApproxEqAbs(@as(f32, 1.0), dot(a, a), 1e-5);
        for (axes[i + 1 ..]) |b| try testing.expectApproxEqAbs(@as(f32, 0.0), dot(a, b), 1e-5);
    }
    try testing.expect(dot(axes[1], eye.right) > 0.25);
    const rolled_muzzle = zm.mul(zm.f32x4(m[0], m[1], m[2], 1.0), rolled.model);
    try expectVec(rolled_muzzle, rolled.muzzle, 1e-5);
}

fn lane(row: zm.Vec) @Vector(3, f32) {
    return .{ row[0], row[1], row[2] };
}
