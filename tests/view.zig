const std = @import("std");
const fps = @import("lenore-fps");

const testing = std.testing;

const Aim = fps.Aim;
const Handheld = fps.Handheld;
const Shake = fps.Shake;

test "the view follows the aim and arrives at it" {
    var aim: Aim = .{ .lag = 0.04 };
    const delta: f32 = 1.0 / 120.0;

    // A flick of half a radian. The first frame moves a fraction of it, which
    // is what takes the edge off a snap, and nothing overshoots.
    aim.follow(0.5, 0.0, delta);
    try testing.expect(aim.yaw > 0.02 and aim.yaw < 0.25);

    var t: f32 = delta;
    while (t < 0.3) : (t += delta) aim.follow(0.5, 0.0, delta);
    try testing.expectApproxEqAbs(@as(f32, 0.5), aim.yaw, 1e-3);

    // A turn held down is not slowed by this, only offset by it: after a second
    // of turning at a steady rate the view is behind the aim by one lag's worth
    // of that rate and no more.
    var steady: Aim = .{ .lag = 0.04 };
    var target: f32 = 0.0;
    const rate: f32 = 2.0;
    t = 0.0;
    while (t < 1.0) : (t += delta) {
        target += rate * delta;
        steady.follow(target, 0.0, delta);
    }
    // A little inside `rate * lag`, which is the continuous answer: the discrete
    // step reads the target after advancing it rather than before.
    try testing.expectApproxEqAbs(rate * 0.04, target - steady.yaw, 0.01);

    // And a lag of zero snaps.
    var snapping: Aim = .{ .lag = 0.0 };
    snapping.follow(1.25, -0.5, delta);
    try testing.expectEqual(@as(f32, 1.25), snapping.yaw);
    try testing.expectEqual(@as(f32, -0.5), snapping.pitch);
}

test "a held camera wanders slowly and never stops" {
    var hand: Handheld = .{ .angle = 0.006, .shift = 0.005 };
    const delta: f32 = 1.0 / 120.0;

    var largest_angle: f32 = 0.0;
    var largest_shift: f32 = 0.0;
    var largest_rate: f32 = 0.0;
    var previous = hand.update(delta);
    var t: f32 = delta;
    while (t < 120.0) : (t += delta) {
        const drift = hand.update(delta);
        largest_angle = @max(largest_angle, @abs(drift.pitch) + @abs(drift.yaw));
        largest_shift = @max(largest_shift, @abs(drift.right) + @abs(drift.up));
        largest_rate = @max(largest_rate, @abs(drift.pitch - previous.pitch) / delta);
        previous = drift;
    }

    // It moves, by about a third of a degree and a few millimetres.
    try testing.expect(largest_angle > 0.003 and largest_angle <= 0.0120);
    try testing.expect(largest_shift > 0.003 and largest_shift <= 0.0100);
    // And slowly: well under a degree a second, which is a hand and not a
    // tremor. A per-frame random number would fail this by four orders.
    try testing.expect(largest_rate < 0.01);

    // Two minutes in it is still going, so nothing here settles to a constant.
    var late: f32 = 0.0;
    while (t < 130.0) : (t += delta) late = @max(late, @abs(hand.update(delta).yaw));
    try testing.expect(late > 0.0005);
}

test "a knock decays to nothing and leaves no angle behind" {
    var shake: Shake = .{};
    shake.add(0.05);
    try testing.expectApproxEqAbs(@as(f32, 0.05), shake.trauma, 1e-6);

    const delta: f32 = 1.0 / 120.0;
    var largest: f32 = 0.0;
    var t: f32 = 0.0;
    while (t < 0.5) : (t += delta) {
        const angles = shake.update(delta);
        largest = @max(largest, @abs(angles.pitch));
    }
    // It moved at all, and by less than a tenth of a degree, which is what a
    // footfall's worth of a full shake comes to.
    try testing.expect(largest > 1e-5 and largest < 0.002);
    try testing.expectEqual(@as(f32, 0.0), shake.trauma);
    const settled = shake.update(delta);
    try testing.expectEqual(@as(f32, 0.0), settled.pitch);
    try testing.expectEqual(@as(f32, 0.0), settled.yaw);
    try testing.expectEqual(@as(f32, 0.0), settled.roll);
}

test "knocks accumulate but never past a full one" {
    var shake: Shake = .{};
    for (0..100) |_| shake.add(0.4);
    try testing.expectEqual(@as(f32, 1.0), shake.trauma);

    // A full shake is degrees rather than fractions of one, and still small
    // enough not to be a spin.
    const angles = shake.update(1.0 / 120.0);
    try testing.expect(@abs(angles.pitch) <= shake.pitch);
    try testing.expect(@abs(angles.roll) <= shake.roll);
}
