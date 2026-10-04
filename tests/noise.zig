const std = @import("std");
const fps = @import("lenore-fps");

const testing = std.testing;

const grad1 = fps.grad1;
const noise1 = fps.noise1;

test "the noise stays inside its range and has no crease at a control point" {
    var lowest: f32 = 1.0;
    var highest: f32 = -1.0;
    var x: f32 = -40.0;
    while (x < 40.0) : (x += 0.0037) {
        const value = noise1(x, 0x2f6e2b1);
        lowest = @min(lowest, value);
        highest = @max(highest, value);
    }
    try testing.expect(lowest >= -1.0 and highest <= 1.0);
    // And it really does use the range, rather than hugging the middle.
    try testing.expect(lowest < -0.8 and highest > 0.8);

    // Across a control point the slope from either side agrees, which is what
    // says the interpolant's derivative vanishes there. A curve with a crease
    // at every integer is the defect this interpolant is chosen against.
    const step: f32 = 1e-3;
    for ([_]f32{ -3.0, 0.0, 5.0, 12.0 }) |at| {
        const before = (noise1(at, 7) - noise1(at - step, 7)) / step;
        const after = (noise1(at + step, 7) - noise1(at, 7)) / step;
        try testing.expectApproxEqAbs(before, after, 1e-2);
    }

    // Not zero at the integers, which gradient noise would be and which would
    // give the wander a period.
    var nonzero: usize = 0;
    for (0..16) |i| {
        if (@abs(noise1(@floatFromInt(i), 7)) > 0.05) nonzero += 1;
    }
    try testing.expect(nonzero >= 12);
}

test "the hash is spread over its range and answers the same way twice" {
    var lowest: f32 = 1.0;
    var highest: f32 = -1.0;
    var sum: f64 = 0.0;
    const count = 4096;
    for (0..count) |i| {
        const value = grad1(0x9d2c5680, @intCast(i));
        lowest = @min(lowest, value);
        highest = @max(highest, value);
        sum += value;
        try testing.expectEqual(value, grad1(0x9d2c5680, @intCast(i)));
    }
    try testing.expect(lowest < -0.99 and highest > 0.99);
    // Consecutive indices, which is the case that a weak mix fails: a poorly
    // spread hash of 0, 1, 2 ... leaves a visible trend.
    try testing.expect(@abs(sum / count) < 0.05);
}
