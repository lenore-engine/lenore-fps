const std = @import("std");
const fps = @import("lenore-fps");

const testing = std.testing;

const Action = fps.Action;
const Spec = fps.ActionSpec;

// A service pistol: fifteen in the magazine, the slide locks on the last
// round, and the rate is how fast a finger pulls.
const pistol: Spec = .{
    .modes = .init(.{ .semi = true }),
    .rate = 400.0,
    .capacity = 15,
    .locks_open = true,
    .reload = 1.8,
    .reload_empty = 2.3,
};

// A select-fire carbine with a bolt that closes on an empty chamber, so it
// clicks rather than locks.
const carbine: Spec = .{
    .modes = .init(.{ .semi = true, .burst = true, .auto = true }),
    .rate = 800.0,
    .capacity = 100,
    .locks_open = false,
    .reload = 2.5,
    .reload_empty = 3.0,
};

const tick_ns: u64 = std.time.ns_per_s / 60;
const ms = std.time.ns_per_ms;

// Advances in steps of `step_ns` for as many whole steps as fit in
// `elapsed_ns`, never past it.
fn run(action: anytype, elapsed_ns: u64, step_ns: u64) u32 {
    var shots: u32 = 0;
    var t: u64 = 0;
    while (t + step_ns <= elapsed_ns) : (t += step_ns) shots += action.advance(step_ns).shots;
    return shots;
}

test "a spec that would not make a weapon is refused" {
    var bad = pistol;
    bad.modes = .empty;
    try testing.expectError(error.NoFireMode, Action(4).init(bad, 0));

    bad = carbine;
    bad.burst = 0;
    try testing.expectError(error.BurstEmpty, Action(4).init(bad, 0));

    bad = pistol;
    bad.capacity = 0;
    try testing.expectError(error.CapacityZero, Action(4).init(bad, 0));

    for ([_]f32{ 0.0, -600.0, std.math.nan(f32), std.math.inf(f32), 1e-12 }) |rate| {
        bad = pistol;
        bad.rate = rate;
        try testing.expectError(error.BadDuration, Action(4).init(bad, 0));
    }
    bad = pistol;
    bad.reload_empty = 0.0;
    try testing.expectError(error.BadDuration, Action(4).init(bad, 0));

    // Four magazines in all: the one in the weapon and three spare.
    try testing.expectError(error.TooManyMagazines, Action(4).init(pistol, 4));
    _ = try Action(4).init(pistol, 3);
}

test "a pull fires one round and holding it fires no more" {
    var gun = try Action(4).init(pistol, 3);
    try testing.expectEqual(@as(u32, 16), gun.loaded());

    gun.pull();
    try testing.expectEqual(@as(u32, 1), run(&gun, 2 * std.time.ns_per_s, tick_ns));
    try testing.expectEqual(@as(u32, 15), gun.loaded());
    try testing.expectEqual(@as(?u16, 14), gun.magazine);
}

test "a tap between two updates still fires" {
    var gun = try Action(4).init(pistol, 3);
    gun.pull();
    gun.release();
    try testing.expectEqual(@as(u32, 1), gun.advance(tick_ns).shots);
}

test "a pull while the action cycles fires when it is ready" {
    var gun = try Action(4).init(pistol, 3);
    gun.pull();
    gun.release();
    try testing.expectEqual(@as(u32, 1), gun.advance(tick_ns).shots);

    // 400 rounds a minute is 150 ms a round. A second pull a tick later is
    // held, and answered on the update the 150 ms run out.
    gun.pull();
    gun.release();
    var fired_at: ?usize = null;
    for (1..20) |tick| {
        if (gun.advance(tick_ns).shots > 0) {
            fired_at = tick;
            break;
        }
    }
    // The update that fired had already spent its tick of the 150 ms, so
    // eight more cover the rest. A tick rounded down to whole nanoseconds
    // leaves a few of them owed, which the ninth pays.
    try testing.expect(fired_at.? == 8 or fired_at.? == 9);
}

test "automatic fire keeps the cyclic rate whatever the update rate" {
    // 800 rounds a minute is 75 ms a round, which is four and a half ticks at
    // 60 Hz: a rate that rounded to whole updates would come out at 720 or 900.
    // Two seconds from the first round is 27 rounds, at 0, 75, ..., 1950 ms,
    // and every step below divides two seconds to within a few nanoseconds.
    for ([_]u64{ tick_ns, std.time.ns_per_s / 144, std.time.ns_per_s / 30, 2 * std.time.ns_per_s }) |step| {
        var gun = try Action(2).init(carbine, 0);
        _ = gun.cycleMode(); // burst
        try testing.expectEqual(fps.FireMode.auto, gun.cycleMode());
        gun.pull();
        const shots = run(&gun, 2 * std.time.ns_per_s, step);
        try testing.expectEqual(@as(u32, 27), shots);
    }
}

test "a weapon left idle does not bank a volley" {
    var gun = try Action(2).init(carbine, 0);
    gun.mode = .auto;
    try testing.expectEqual(@as(u32, 0), run(&gun, 10 * std.time.ns_per_s, tick_ns));

    gun.pull();
    // One round now, and the next only after 75 ms: the ten idle seconds are
    // not owed. Three more ticks are 50 ms.
    try testing.expectEqual(@as(u32, 1), gun.advance(tick_ns).shots);
    for (0..3) |_| try testing.expectEqual(@as(u32, 0), gun.advance(tick_ns).shots);
}

test "a burst fires its rounds and finishes after the trigger is let go" {
    var gun = try Action(2).init(carbine, 0);
    gun.mode = .burst;
    gun.pull();
    gun.release();
    try testing.expectEqual(@as(u32, 3), run(&gun, std.time.ns_per_s, tick_ns));

    gun.pull();
    try testing.expectEqual(@as(u32, 3), run(&gun, std.time.ns_per_s, tick_ns));
}

test "the selector skips the modes the weapon does not have" {
    var gun = try Action(2).init(.{
        .modes = .init(.{ .semi = true, .auto = true }),
        .rate = 700.0,
        .capacity = 30,
        .locks_open = true,
        .reload = 2.0,
        .reload_empty = 2.5,
    }, 0);
    try testing.expectEqual(fps.FireMode.semi, gun.mode);
    try testing.expectEqual(fps.FireMode.auto, gun.cycleMode());
    try testing.expectEqual(fps.FireMode.semi, gun.cycleMode());

    var single = try Action(1).init(pistol, 0);
    try testing.expectEqual(fps.FireMode.semi, single.cycleMode());
}

test "the last round locks the slide and the trigger then does nothing" {
    var gun = try Action(4).init(pistol, 3);
    var locked_on: ?u32 = null;
    var shot: u32 = 0;
    while (shot < 16) {
        gun.pull();
        gun.release();
        const report = gun.advance(200 * ms);
        shot += report.shots;
        if (report.locked) locked_on = shot;
    }
    try testing.expectEqual(@as(?u32, 16), locked_on);
    try testing.expect(gun.locked);
    try testing.expectEqual(@as(u32, 0), gun.loaded());

    gun.pull();
    const empty = gun.advance(200 * ms);
    try testing.expectEqual(@as(u32, 0), empty.shots);
    try testing.expect(!empty.dry);
}

test "a bolt that closes on an empty chamber clicks once per pull" {
    var gun = try Action(1).init(.{
        .modes = .init(.{ .auto = true }),
        .rate = 600.0,
        .capacity = 3,
        .locks_open = false,
        .reload = 2.0,
        .reload_empty = 2.5,
    }, 0);
    gun.pull();
    try testing.expectEqual(@as(u32, 4), run(&gun, std.time.ns_per_s, tick_ns));
    try testing.expect(!gun.locked);

    // Still held: the pull that emptied the weapon has been answered.
    try testing.expect(!gun.advance(tick_ns).dry);
    gun.release();
    gun.pull();
    try testing.expect(gun.advance(tick_ns).dry);
    try testing.expect(!gun.advance(tick_ns).dry);
}

test "a reload with a round chambered keeps it and keeps the old magazine" {
    var gun = try Action(4).init(pistol, 3);
    for (0..5) |_| {
        gun.pull();
        gun.release();
        _ = gun.advance(200 * ms);
    }
    try testing.expectEqual(@as(?u16, 10), gun.magazine);

    try gun.reload();
    try testing.expectEqual(@as(?u16, null), gun.magazine);
    try testing.expectEqual(@as(u32, 1), gun.loaded());

    try testing.expect(!gun.advance(1700 * ms).reloaded);
    try testing.expect(gun.advance(100 * ms).reloaded);
    try testing.expectEqual(@as(u32, 16), gun.loaded());

    // Two full ones and the ten-round one, which comes back out only once it
    // is the fullest left.
    var spare = [_]u16{ 0, 0, 0 };
    @memcpy(&spare, gun.spareMagazines());
    std.mem.sort(u16, &spare, {}, std.sort.asc(u16));
    try testing.expectEqualSlices(u16, &.{ 10, 15, 15 }, &spare);
}

test "an empty reload takes longer, chambers a round and releases the slide" {
    var gun = try Action(4).init(pistol, 1);
    for (0..16) |_| {
        gun.pull();
        gun.release();
        _ = gun.advance(200 * ms);
    }
    try testing.expect(gun.locked);

    try gun.reload();
    // Past the tactical time, short of the empty one.
    try testing.expect(!gun.advance(2000 * ms).reloaded);
    try testing.expect(gun.advance(300 * ms).reloaded);
    try testing.expect(!gun.locked);
    try testing.expect(gun.chambered);
    try testing.expectEqual(@as(?u16, 14), gun.magazine);
    // The empty magazine was dropped, not stowed.
    try testing.expectEqual(@as(usize, 0), gun.spareMagazines().len);
}

test "a reload that would not gain anything is refused" {
    var gun = try Action(4).init(pistol, 3);
    try testing.expectError(error.NoFullerMagazine, gun.reload());

    var bare = try Action(1).init(pistol, 0);
    bare.pull();
    _ = bare.advance(tick_ns);
    try testing.expectError(error.NoFullerMagazine, bare.reload());

    gun.pull();
    gun.release();
    _ = gun.advance(tick_ns);
    try gun.reload();
    try testing.expectError(error.Reloading, gun.reload());
}

test "a cancelled reload leaves no magazine in, and every magazine fits" {
    // The pouch at its fullest: three spares and one in the weapon, with room
    // for four. A cancel puts all four in the pouch at once.
    var gun = try Action(4).init(pistol, 3);
    gun.pull();
    gun.release();
    _ = gun.advance(tick_ns);

    try gun.reload();
    _ = gun.advance(500 * ms);
    gun.cancelReload();
    try testing.expectEqual(@as(?u16, null), gun.magazine);
    try testing.expect(gun.chambered);
    try testing.expectEqual(@as(usize, 4), gun.spareMagazines().len);

    // The chambered round still fires, and the next reload is the short one.
    gun.pull();
    gun.release();
    try testing.expectEqual(@as(u32, 1), gun.advance(200 * ms).shots);
    try testing.expect(gun.locked);
    try gun.reload();
    try testing.expect(gun.advance(2300 * ms).reloaded);
    try testing.expectEqual(@as(u32, 15), gun.loaded());
}

test "a pull during a reload is not fired when it ends" {
    var gun = try Action(4).init(pistol, 3);
    gun.pull();
    gun.release();
    _ = gun.advance(tick_ns);

    try gun.reload();
    gun.pull();
    gun.release();
    try testing.expect(gun.advance(1800 * ms).reloaded);
    try testing.expectEqual(@as(u32, 0), gun.advance(tick_ns).shots);
}
