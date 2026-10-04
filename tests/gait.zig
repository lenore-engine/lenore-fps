const std = @import("std");
const fps = @import("lenore-fps");

const testing = std.testing;

const Lean = fps.Lean;
const Sway = fps.Sway;
const Walk = fps.Walk;

// A walking tuning a game has shipped, near enough for the tests to be about
// the shape of the motion rather than about a number.
const walking: fps.WalkTuning = .{
    .stride = 1.5,
    .stride_exp = 0.55,
    .ref_speed = 1.4,
    .speed_exp = 0.6,
    .vert = 0.009,
    .lat = 0.006,
    .roll = 0.0035,
    .pitch = 0.0015,
    .roll_lag = 0.6,
    .sharp = 0.35,
    .jitter = 0.12,
    .jitter_freq = 0.6,
    .limp = 0.05,
    .settle = 6.0,
    .scale = 1.0,
};

// Runs the gait for `seconds` at one speed and one frame rate, handing every
// update to `each`.
fn drive(walk: *Walk, speed: f32, seconds: f32, rate: f32, each: anytype) void {
    const delta = 1.0 / rate;
    var t: f32 = 0.0;
    while (t < seconds) : (t += delta) each.frame(walk.update(speed, delta, t));
}

test "a body at rest does not sway" {
    var gait: Walk = .{ .tuning = walking };
    const counter = struct {
        var largest: f32 = 0.0;
        fn frame(sway: Sway) void {
            largest = @max(largest, @abs(sway.up) + @abs(sway.right));
        }
    };
    drive(&gait, 0.0, 4.0, 60.0, counter);
    try testing.expectEqual(@as(f32, 0.0), counter.largest);
    try testing.expectEqual(@as(f32, 0.0), gait.phase);
}

test "the swing fades in at a walk and out at a stop" {
    var gait: Walk = .{ .tuning = walking };
    var t: f32 = 0.0;
    const delta: f32 = 1.0 / 60.0;

    // A third of a second in, most of the swing is there but not all of it.
    while (t < 0.3) : (t += delta) _ = gait.update(3.4, delta, t);
    try testing.expect(gait.gain > 0.5 and gait.gain < 1.71);

    while (t < 2.0) : (t += delta) _ = gait.update(3.4, delta, t);
    const walking_gain = gait.gain;
    // (3.4 / 1.4) ^ 0.6, which is the amplitude a 3.4 m/s walk asks for.
    try testing.expectApproxEqAbs(@as(f32, 1.704), walking_gain, 0.01);

    // Stopping leaves the phase where it stood and takes the amplitude down,
    // so the eye returns to the middle rather than freezing off to one side.
    const held = gait.phase;
    while (t < 2.6) : (t += delta) _ = gait.update(0.0, delta, t);
    try testing.expectEqual(held, gait.phase);
    try testing.expect(gait.gain < 0.03 * walking_gain);
}

test "the excursion at walking and running speed is what the eye was promised" {
    // The numbers in `walking` are amplitudes at 1.4 m/s, and what the eye sees
    // is the whole excursion at the speed a body actually walks, which is
    // twice the amplitude times the swing's growth with speed. That is the
    // quantity with a bound on it: nausea in a first-person view starts a little
    // past three centimetres of rise and fall and a degree of roll, so the
    // constants are chosen backwards from here rather than judged themselves.
    const swing = struct {
        var up_low: f32 = 0.0;
        var up_high: f32 = 0.0;
        var roll_high: f32 = 0.0;
        fn reset() void {
            up_low = 0.0;
            up_high = 0.0;
            roll_high = 0.0;
        }
        fn frame(sway: Sway) void {
            up_low = @min(up_low, sway.up);
            up_high = @max(up_high, sway.up);
            roll_high = @max(roll_high, @abs(sway.roll));
        }
    };

    var walker: Walk = .{ .tuning = walking };
    swing.reset();
    drive(&walker, 3.4, 12.0, 120.0, swing);
    const walk_excursion = swing.up_high - swing.up_low;
    // 31 mm from top to bottom and 0.38 degrees of roll.
    try testing.expect(walk_excursion > 0.026 and walk_excursion < 0.036);
    try testing.expect(swing.roll_high < 0.0075);

    var runner: Walk = .{ .tuning = walking };
    swing.reset();
    drive(&runner, 6.46, 12.0, 120.0, swing);
    const run_excursion = swing.up_high - swing.up_low;
    // Bigger than the walk and not proportionally bigger, which is the whole
    // point of an exponent below one on the speed.
    try testing.expect(run_excursion > walk_excursion);
    try testing.expect(run_excursion < walk_excursion * 6.46 / 3.4);
    // 45 mm and 0.56 degrees, which is still inside the bound above.
    try testing.expect(run_excursion > 0.040 and run_excursion < 0.050);
    try testing.expect(swing.roll_high < 0.011);
}

test "footfalls come at the cadence the stride implies, at any frame rate" {
    const counter = struct {
        var falls: usize = 0;
        fn reset() void {
            falls = 0;
        }
        fn frame(sway: Sway) void {
            if (sway.footfall) falls += 1;
        }
    };

    // Ten seconds at 3.4 m/s. The stride at that speed is 1.5 * (3.4/1.4)^0.55
    // = 2.47 m per cycle, so 34 m is 13.8 cycles and 27.5 footfalls. The slow
    // wander moves that by a few per cent either way.
    for ([_]f32{ 240.0, 60.0, 24.0, 11.0 }) |rate| {
        var gait: Walk = .{ .tuning = walking };
        counter.reset();
        drive(&gait, 3.4, 10.0, rate, counter);
        try testing.expect(counter.falls >= 25 and counter.falls <= 30);
    }

    // A frame long enough to be clamped by the engine, which is where a test
    // against one phase mark rather than a count of them loses a step.
    var hitching: Walk = .{ .tuning = walking };
    counter.reset();
    drive(&hitching, 3.4, 10.0, 10.0, counter);
    try testing.expect(counter.falls >= 25 and counter.falls <= 30);
}

test "no two steps are the same size and the two feet differ" {
    var gait: Walk = .{ .tuning = walking };
    const sizes = struct {
        var left: f32 = 0.0;
        var right: f32 = 0.0;
        var largest: f32 = 0.0;
        var smallest: f32 = 1.0;
        var current: f32 = 0.0;
        var falls: usize = 0;
        fn frame(sway: Sway) void {
            if (sway.footfall) {
                if (falls > 0) {
                    largest = @max(largest, current);
                    smallest = @min(smallest, current);
                    if (falls & 1 == 0) left += current else right += current;
                }
                falls += 1;
                current = 0.0;
            }
            current = @max(current, @abs(sway.right));
        }
    };
    drive(&gait, 3.4, 30.0, 120.0, sizes);

    // Step to step, the sideways sway varies by well over a per cent, which is
    // what says the two randomnesses reach the output at all.
    try testing.expect(sizes.largest > sizes.smallest * 1.05);
    // And one foot is consistently different from the other over eighty steps,
    // which the per-step hash alone would average away.
    try testing.expect(@abs(sizes.left - sizes.right) > 0.01 * (sizes.left + sizes.right));
}

test "the gait is the same run twice and does not depend on the frame rate" {
    var one: Walk = .{ .tuning = walking };
    var two: Walk = .{ .tuning = walking };
    var t: f32 = 0.0;
    while (t < 5.0) : (t += 1.0 / 90.0) {
        _ = one.update(3.4, 1.0 / 90.0, t);
        _ = two.update(3.4, 1.0 / 90.0, t);
    }
    try testing.expectEqual(one.phase, two.phase);
    try testing.expectEqual(one.half_steps, two.half_steps);

    // The same distance covered in half-sized frames reaches the same place in
    // the cycle. Not bit for bit: twice the number of additions is twice the
    // rounding, and the wander is read at different instants along the way.
    var fine: Walk = .{ .tuning = walking };
    t = 0.0;
    while (t < 5.0) : (t += 1.0 / 180.0) _ = fine.update(3.4, 1.0 / 180.0, t);
    try testing.expectApproxEqAbs(one.phase, fine.phase, 0.05);
    try testing.expectEqual(one.half_steps, fine.half_steps);
}

test "the scale takes the whole gait to nothing" {
    var silent: Walk = .{ .tuning = walking };
    silent.tuning.scale = 0.0;
    const counter = struct {
        var largest: f32 = 0.0;
        var falls: usize = 0;
        fn frame(sway: Sway) void {
            largest = @max(largest, @abs(sway.up) + @abs(sway.right) +
                @abs(sway.roll) + @abs(sway.pitch));
            if (sway.footfall) falls += 1;
        }
    };
    drive(&silent, 3.4, 6.0, 60.0, counter);
    try testing.expectEqual(@as(f32, 0.0), counter.largest);
    // The steps are still counted, so whatever else hangs off a footfall keeps
    // working with the swing turned off.
    try testing.expect(counter.falls > 10);
}

test "a lean rises into a strafe, falls away under it, and reverses on the stop" {
    var lean: Lean = .{ .gain = 0.056 / 3.4 };
    const delta: f32 = 1.0 / 240.0;

    // The first frame is a small fraction of what is coming. A plain high pass
    // would put the whole tip on screen in one frame, and that reads as a snap.
    const first = lean.update(3.4, delta);

    var t: f32 = delta;
    var peak: f32 = 0.0;
    var peak_at: f32 = 0.0;
    var last: f32 = first;
    while (t < 3.0) : (t += delta) {
        last = lean.update(3.4, delta);
        if (last > peak) {
            peak = last;
            peak_at = t;
        }
    }
    // A degree and a half, a seventh of a second in, and gone well before the
    // strafe is.
    try testing.expectApproxEqAbs(@as(f32, 0.0255), peak, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.138), peak_at, 0.02);
    try testing.expect(@abs(last) < peak * 0.01);
    try testing.expect(first > 0.0 and first < peak * 0.12);

    // Stopping tips the other way, which is the same body catching itself, and
    // it arrives just as gradually.
    const stopping = lean.update(0.0, delta);
    try testing.expect(@abs(stopping) < peak * 0.12);
    var back: f32 = 0.0;
    while (t < 4.0) : (t += delta) back = @min(back, lean.update(0.0, delta));
    try testing.expect(back < -peak * 0.8);
}

test "a lean holds nothing while the walk is straight" {
    var lean: Lean = .{ .gain = 0.056 / 3.4 };
    const delta: f32 = 1.0 / 120.0;
    var t: f32 = 0.0;
    var largest: f32 = 0.0;
    while (t < 3.0) : (t += delta) largest = @max(largest, @abs(lean.update(0.0, delta)));
    try testing.expectEqual(@as(f32, 0.0), largest);
}
