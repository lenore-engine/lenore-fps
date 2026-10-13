const std = @import("std");
const resources = @import("lenore-resources");
const scene = @import("lenore-scene");
const zm = @import("zmath");

const noise = @import("noise.zig");

const Vec3 = @Vector(3, f32);

// Where a round goes and what it gets through.
//
// A shot is a straight line from the muzzle, followed to the round's range.
// The caller finds what the line crosses, in whatever its world is made of,
// and hands the crossings here as distances along the line; this walks them
// in order and charges each against what the round can spend. A round that
// can afford a wall goes through it with less left, and one that cannot stops
// inside it. Nothing here knows what was crossed beyond the caller's tag and
// what its material costs, so a body, a door and a plate are all the same
// kind of thing and a round can pass through one to reach the next.
//
// No drop and no travel time: the hit is decided at the instant of the shot.
// That is a choice with a cost, not a limit taken to zero. At 360 m/s, 20 m
// takes 56 ms, in which gravity takes 15 mm (gt^2 / 2) and a body crossing
// at a walk moves 8 cm. Small against a torso at room distances; a game
// fought at hundreds of metres needs something else.

pub const Round = struct {
    // In the game's own units, before anything is crossed. A hit hands back
    // the share of it the round still had, so the game scales this.
    damage: f32,
    // What the round can spend getting through things, in the units a
    // `Material` charges.
    penetration: f32,
    // Metres the shot is followed for.
    range: f32,

    pub const Error = error{BadRound};

    pub fn validate(self: Round) Error!void {
        if (!(self.damage >= 0.0) or !std.math.isFinite(self.damage)) return error.BadRound;
        if (!(self.penetration > 0.0) or !std.math.isFinite(self.penetration)) return error.BadRound;
        if (!(self.range > 0.0) or !std.math.isFinite(self.range)) return error.BadRound;
    }
};

pub const Material = struct {
    // Charged once for getting in, however thin: what a plate costs above
    // its thickness.
    entry: f32 = 0.0,
    // Charged per metre crossed.
    per_metre: f32,

    pub const Error = error{BadMaterial};

    // Materials are game data. `resolve` does not check them, so a caller
    // reading them from a file checks them here, once.
    pub fn validate(self: Material) Error!void {
        if (!(self.entry >= 0.0) or !std.math.isFinite(self.entry)) return error.BadMaterial;
        if (!(self.per_metre >= 0.0) or !std.math.isFinite(self.per_metre)) return error.BadMaterial;
    }
};

// One thing the shot's line passes through.
pub const Crossing = struct {
    // Distances along the shot where it goes in and comes out.
    enter: f32,
    exit: f32,
    material: Material,
    // The caller's own name for what was crossed, handed back on its hit.
    tag: u32,
};

pub const Hit = struct {
    tag: u32,
    // Distance along the shot where the round went in.
    distance: f32,
    // The share of the round it arrived with and the share it spent here,
    // both of what it left the muzzle with.
    arrived: f32,
    spent: f32,
    // Metres it travelled inside, to where it stopped or came out.
    depth: f32,
    stopped: bool,
};

pub const Outcome = struct {
    // How many of the hits buffer were written.
    hits: usize,
    // Crossings the round reached that did not fit in the buffer. They were
    // still paid for: a full buffer does not make a wall free.
    unreported: usize,
    stopped: bool,
    // The share of the round left at the end of its range, or zero.
    remaining: f32,
};

// Walks the crossings nearest first and writes a hit for each one the round
// reaches. Sorts `crossings` in place; their order on the way in does not
// matter. Crossings that begin past the range are not reached, and one that
// runs past it is charged only up to it.
pub fn resolve(round: Round, crossings: []Crossing, hits: []Hit) Outcome {
    std.mem.sort(Crossing, crossings, {}, nearer);

    var budget = round.penetration;
    var outcome: Outcome = .{ .hits = 0, .unreported = 0, .stopped = false, .remaining = 0.0 };
    for (crossings) |crossing| {
        if (!(crossing.enter < round.range)) break;
        const through = @max(@min(crossing.exit, round.range) - crossing.enter, 0.0);
        const cost = crossing.material.entry + crossing.material.per_metre * through;

        const arrived = budget;
        var depth = through;
        const stopped = cost > budget;
        if (stopped) {
            // How far in the budget lasted once the way in was paid for. A
            // round that cannot pay for the entry stops on the face.
            const left = budget - crossing.material.entry;
            depth = if (left > 0.0 and crossing.material.per_metre > 0.0)
                @min(left / crossing.material.per_metre, through)
            else
                0.0;
            budget = 0.0;
        } else {
            budget -= cost;
        }

        const hit: Hit = .{
            .tag = crossing.tag,
            .distance = crossing.enter,
            .arrived = arrived / round.penetration,
            .spent = (arrived - budget) / round.penetration,
            .depth = depth,
            .stopped = stopped,
        };
        if (outcome.hits < hits.len) {
            hits[outcome.hits] = hit;
            outcome.hits += 1;
        } else {
            outcome.unreported += 1;
        }
        if (stopped) {
            outcome.stopped = true;
            return outcome;
        }
    }
    outcome.remaining = budget / round.penetration;
    return outcome;
}

fn nearer(_: void, a: Crossing, b: Crossing) bool {
    return a.enter < b.enter;
}

// Where a placed box lies along a shot, as a crossing, or null if the shot
// misses it or it is behind the muzzle. The distances are world metres because
// the shot's direction is unit; `scene.intersectInstance` keeps them so under
// the model's scale.
pub fn crossBox(shot: scene.Ray, model: zm.Mat, box: resources.Aabb, material: Material, tag: u32) ?Crossing {
    const met = scene.intersectInstance(shot, model, box) orelse return null;
    return .{ .enter = met.t, .exit = met.exit, .material = material, .tag = tag };
}

// The direction a shot leaves in: `direction` turned by up to `spread`
// radians, evenly over the disc of directions that cone covers.
//
// Keyed by the shot's index, so the same shots scatter the same way on every
// machine that fires them. `direction` must be unit.
pub fn scatter(direction: Vec3, spread: f32, seed: u32, index: u32) Vec3 {
    const key: i32 = @bitCast(index);
    // [-1, 1) to [0, 1).
    const u = 0.5 * (noise.grad1(seed, key) + 1.0);
    const v = 0.5 * (noise.grad1(seed +% 1, key) + 1.0);
    // The square root spreads the samples evenly over the disc's area rather
    // than bunching them at the centre.
    const angle = spread * @sqrt(u);
    const around = std.math.tau * v;

    // Any two axes square to the direction. Crossed with whichever world axis
    // it is least aligned with, so the cross product is never short.
    const helper: Vec3 = if (@abs(direction[1]) < 0.9) .{ 0.0, 1.0, 0.0 } else .{ 1.0, 0.0, 0.0 };
    const side = normalize(cross(direction, helper));
    const lift = cross(side, direction);

    const off = @sin(angle);
    return direction * @as(Vec3, @splat(@cos(angle))) +
        side * @as(Vec3, @splat(off * @cos(around))) +
        lift * @as(Vec3, @splat(off * @sin(around)));
}

fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn normalize(a: Vec3) Vec3 {
    return a / @as(Vec3, @splat(@sqrt(@reduce(.Add, a * a))));
}
