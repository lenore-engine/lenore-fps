const std = @import("std");

// One number for an integer, in [-1, 1), the same one every time.
//
// The mix is the usual pair of xorshift-multiplies. What it has to be is
// well distributed in its low bits, because the value below is taken from the
// top 24 and the caller's indices are consecutive small integers.
pub fn grad1(seed: u32, index: i32) f32 {
    var h: u32 = @bitCast(index);
    h = h *% 0x9e3779b1 ^ seed *% 0x85ebca6b;
    h ^= h >> 15;
    h *%= 0x2545f491;
    h ^= h >> 13;
    // 24 bits, which is exactly what an f32 mantissa holds, so the conversion
    // is exact and the values are evenly spaced.
    const bits: f32 = @floatFromInt(h >> 8);
    return bits * (2.0 / 16777216.0) - 1.0;
}

// A smooth curve through those numbers, one unit of `x` to a control point, in
// [-1, 1] and twice differentiable.
//
// Value noise rather than gradient noise, and the difference matters for what
// this is used for. Gradient noise is zero at every integer, so a gait wobbling
// on it would return to exactly no wobble at a fixed rate, which is a period the
// eye finds however small the amplitude is. This one has no such fixed points.
//
// The blend is Perlin's second interpolant, 6t^5 - 15t^4 + 10t^3, whose first
// and second derivatives both vanish at either end, so the curve has no crease
// where it crosses a control point.
pub fn noise1(x: f32, seed: u32) f32 {
    const cell = @floor(x);
    const t = x - cell;
    // The control points are consecutive integers around `x`. Anything outside
    // an i32 has left the range where `x` still resolves single units anyway,
    // and it is a clock that would have to run for weeks to get there.
    const index: i32 = @intFromFloat(std.math.clamp(cell, -2147483000.0, 2147483000.0));

    const blend = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    const low = grad1(seed, index);
    const high = grad1(seed, index +| 1);
    return low + (high - low) * blend;
}
