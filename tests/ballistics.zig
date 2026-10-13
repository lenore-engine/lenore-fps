const std = @import("std");
const fps = @import("lenore-fps");
const resources = @import("lenore-resources");
const scene = @import("lenore-scene");
const zm = @import("zmath");

const testing = std.testing;

const Crossing = fps.Crossing;
const Hit = fps.Hit;

// Units are the module's: a round spends what a material charges. These are
// shaped so the arithmetic below reads off directly.
const ball: fps.Round = .{ .damage = 100.0, .penetration = 10.0, .range = 50.0 };
const drywall: fps.Material = .{ .per_metre = 20.0 }; // a 0.1 m wall costs 2
const flesh: fps.Material = .{ .per_metre = 10.0 }; // a 0.3 m body costs 3
const plate: fps.Material = .{ .entry = 12.0, .per_metre = 100.0 };

test "a round goes through a wall and a body and keeps what it did not spend" {
    var crossings = [_]Crossing{
        .{ .enter = 5.0, .exit = 5.1, .material = drywall, .tag = 1 },
        .{ .enter = 8.0, .exit = 8.3, .material = flesh, .tag = 2 },
    };
    var hits: [4]Hit = undefined;
    const outcome = fps.resolve(ball, &crossings, &hits);

    try testing.expectEqual(@as(usize, 2), outcome.hits);
    try testing.expect(!outcome.stopped);
    try testing.expectApproxEqAbs(@as(f32, 1.0), hits[0].arrived, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.2), hits[0].spent, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.8), hits[1].arrived, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.3), hits[1].spent, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.3), hits[1].depth, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), outcome.remaining, 1e-5);
}

test "crossings are taken nearest first whatever order they come in" {
    var crossings = [_]Crossing{
        .{ .enter = 8.0, .exit = 8.3, .material = flesh, .tag = 2 },
        .{ .enter = 5.0, .exit = 5.1, .material = drywall, .tag = 1 },
    };
    var hits: [4]Hit = undefined;
    _ = fps.resolve(ball, &crossings, &hits);
    try testing.expectEqual(@as(u32, 1), hits[0].tag);
    try testing.expectEqual(@as(u32, 2), hits[1].tag);
}

test "a plate the round cannot afford stops it on the face, and hides what is behind" {
    var crossings = [_]Crossing{
        .{ .enter = 6.0, .exit = 6.01, .material = plate, .tag = 7 },
        .{ .enter = 6.01, .exit = 6.3, .material = flesh, .tag = 8 },
    };
    var hits: [4]Hit = undefined;
    const outcome = fps.resolve(ball, &crossings, &hits);
    try testing.expect(outcome.stopped);
    try testing.expectEqual(@as(usize, 1), outcome.hits);
    try testing.expectEqual(@as(u32, 7), hits[0].tag);
    try testing.expect(hits[0].stopped);
    try testing.expectEqual(@as(f32, 0.0), hits[0].depth);
    try testing.expectApproxEqAbs(@as(f32, 1.0), hits[0].spent, 1e-6);
    try testing.expectEqual(@as(f32, 0.0), outcome.remaining);
}

test "a round stops partway into something too thick for it" {
    var crossings = [_]Crossing{
        .{ .enter = 2.0, .exit = 4.0, .material = flesh, .tag = 3 },
    };
    var hits: [1]Hit = undefined;
    const outcome = fps.resolve(ball, &crossings, &hits);
    try testing.expect(outcome.stopped);
    // Ten to spend at ten a metre.
    try testing.expectApproxEqAbs(@as(f32, 1.0), hits[0].depth, 1e-5);
}

test "nothing past the range is reached, and a crossing running past it is cut" {
    var crossings = [_]Crossing{
        .{ .enter = 49.9, .exit = 60.0, .material = flesh, .tag = 1 },
        .{ .enter = 55.0, .exit = 56.0, .material = flesh, .tag = 2 },
    };
    var hits: [4]Hit = undefined;
    const outcome = fps.resolve(ball, &crossings, &hits);
    try testing.expectEqual(@as(usize, 1), outcome.hits);
    try testing.expectApproxEqAbs(@as(f32, 0.1), hits[0].depth, 1e-4);
    try testing.expect(!outcome.stopped);
}

test "a full buffer still pays for what it could not report" {
    var crossings = [_]Crossing{
        .{ .enter = 1.0, .exit = 1.1, .material = drywall, .tag = 1 },
        .{ .enter = 2.0, .exit = 2.1, .material = drywall, .tag = 2 },
        .{ .enter = 3.0, .exit = 3.1, .material = drywall, .tag = 3 },
    };
    var hits: [1]Hit = undefined;
    const outcome = fps.resolve(ball, &crossings, &hits);
    try testing.expectEqual(@as(usize, 1), outcome.hits);
    try testing.expectEqual(@as(usize, 2), outcome.unreported);
    try testing.expectApproxEqAbs(@as(f32, 0.4), outcome.remaining, 1e-5);
}

test "bad data is refused where it enters" {
    try testing.expectError(error.BadRound, (fps.Round{ .damage = 1.0, .penetration = 0.0, .range = 10.0 }).validate());
    try testing.expectError(error.BadRound, (fps.Round{ .damage = 1.0, .penetration = 1.0, .range = std.math.inf(f32) }).validate());
    try testing.expectError(error.BadMaterial, (fps.Material{ .per_metre = -1.0 }).validate());
    try testing.expectError(error.BadMaterial, (fps.Material{ .entry = std.math.nan(f32), .per_metre = 1.0 }).validate());
}

test "a placed box becomes a crossing in world metres" {
    const unit: resources.Aabb = .{ .min = .{ -0.5, -0.5, -0.5 }, .max = .{ 0.5, 0.5, 0.5 } };
    const shot: scene.Ray = .{ .origin = .{ 0.0, 0.0, 0.0 }, .direction = .{ 0.0, 0.0, -1.0 } };

    // A wall ten centimetres thick, five metres ahead.
    const wall = zm.mul(zm.scaling(4.0, 3.0, 0.1), zm.translation(0.0, 0.0, -5.0));
    const crossing = fps.crossBox(shot, wall, unit, drywall, 9).?;
    try testing.expectApproxEqAbs(@as(f32, 4.95), crossing.enter, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5.05), crossing.exit, 1e-4);
    try testing.expectEqual(@as(u32, 9), crossing.tag);

    try testing.expectEqual(@as(?Crossing, null), fps.crossBox(shot, zm.translation(0.0, 0.0, 5.0), unit, drywall, 0));
}

test "a scattered shot stays inside its cone and fills it" {
    const forward: @Vector(3, f32) = .{ 0.0, 0.0, -1.0 };
    const spread: f32 = 0.01;
    var sum: f32 = 0.0;
    var widest: f32 = 0.0;
    const count = 2000;
    for (0..count) |i| {
        const d = fps.scatter(forward, spread, 0x1234, @intCast(i));
        try testing.expectApproxEqAbs(@as(f32, 1.0), @reduce(.Add, d * d), 1e-5);
        const angle = std.math.acos(@min(-d[2], 1.0));
        try testing.expect(angle <= spread + 1e-4);
        sum += angle;
        widest = @max(widest, angle);
        try testing.expectEqual(d, fps.scatter(forward, spread, 0x1234, @intCast(i)));
    }
    // Even over the disc, the mean distance from the centre is two thirds of
    // the radius.
    try testing.expectApproxEqAbs(spread * 2.0 / 3.0, sum / count, spread * 0.05);
    try testing.expect(widest > spread * 0.95);

    // Straight up, where the helper axis changes.
    const up = fps.scatter(.{ 0.0, 1.0, 0.0 }, spread, 7, 3);
    try testing.expectApproxEqAbs(@as(f32, 1.0), @reduce(.Add, up * up), 1e-5);
    try testing.expect(up[1] >= @cos(spread) - 1e-5);
}
