const std = @import("std");

const noise = @import("noise.zig");

// What walking does to the eye.
//
// The camera is carried by a body, and a body walking swings it: down onto each
// heel and up over the stride, side to side over whichever foot is loaded, and
// rolled a little toward that side. Everything here is that swing, produced from
// how fast the body is actually moving and nothing else, so it starts, stops and
// changes pace without a caller sequencing it.
//
// The whole of it is a function of state driven by a speed and a delta, so it
// is tested without a device and without a window.
//
// Randomness at three timescales, none of it per frame. A per-frame random
// number would shake at the frame rate rather than at the body's, so it would
// change with the frame rate and read as a defect. Instead `noise1` stretches
// and shortens the stride over about a second and a half, a hash of the
// half-step index gives each individual step its own size, and `limp` biases
// every left step against every right one for as long as the run lasts.

// The knobs. Split by where each number comes from: the ones with a default
// here describe the body and are derived, and the ones without are taste and
// come from the game. Each number has one home, so no value is stated in two
// places and no setting silently disagrees with a default.
pub const Tuning = struct {
    // Metres of ground per full cycle, which is two steps, at `ref_speed`.
    stride: f32,
    // How the stride grows with speed. Zero would keep one stride length and
    // put the whole of a faster walk into a faster cadence, which is not what a
    // body does: it lengthens the step first. Just over a half puts a walk at
    // 1.4 m/s on a 1.5 m cycle and a run at 4 m/s on a 2.75 m one, which is the
    // pair a person actually covers.
    stride_exp: f32 = 0.55,
    // The speed everything is quoted at, in metres per second. An ordinary
    // human walk, which is the one speed there are numbers for.
    ref_speed: f32 = 1.4,
    // How the swing grows with speed. Below one, so that running does not
    // multiply the excursion by the speed ratio: a body running holds its head
    // steadier than the arithmetic of a walk would predict.
    speed_exp: f32 = 0.6,

    // The swing itself, at `ref_speed`: metres for the two offsets, radians for
    // the two angles.
    vert: f32,
    lat: f32,
    roll: f32,
    pitch: f32,
    // Where the roll sits against the sideways sway, in radians of phase. A
    // body does not roll and sway at the same instant; the roll follows.
    roll_lag: f32 = 0.6,

    // How much of the vertical carrier is its second harmonic, which is what
    // puts a heel strike in it. Zero is a plain sinusoid.
    //
    // A second harmonic rather than the usual abs(sin): the absolute value has
    // a corner at the bottom of every step, and at speed that corner is visible
    // as a twitch. This stays smooth at every setting.
    sharp: f32,
    // The fraction of the amplitude that wanders, both slowly and per step.
    jitter: f32,
    // How fast the slow wander runs, in cycles per second. Well under the
    // cadence, so it stretches a run of steps rather than alternating them.
    jitter_freq: f32 = 0.6,
    // How far a left step differs from a right one, as a fraction.
    limp: f32,
    // How fast the swing reaches its speed and returns to nothing, per second.
    // It is what makes a stop fade out over about a third of a second instead
    // of freezing the eye wherever the last frame left it.
    settle: f32 = 6.0,
    // The master, and the only one that is meant to reach a settings screen.
    // Zero removes the whole effect.
    scale: f32,
};

// What one update of the gait does to the camera.
//
// Named fields rather than a pair of vectors, because the consumer takes each of
// them to a different place: the offsets move the eye and the angles are added
// to the pose the player aimed.
pub const Sway = struct {
    // Metres. Across the direction of travel and straight up the world, not
    // along the camera's own axes: a head rises and falls vertically whether or
    // not the view it carries is pitched down at the floor.
    right: f32 = 0.0,
    up: f32 = 0.0,
    // Radians, added to the pose the player aimed.
    pitch: f32 = 0.0,
    roll: f32 = 0.0,
    // True on the update a foot lands. One per half cycle, whatever the frame
    // rate, and it is an edge rather than a state.
    footfall: bool = false,
};

pub const Walk = struct {
    tuning: Tuning,

    // Where in the cycle the body is, in radians over [0, tau). It advances
    // with distance covered rather than with time, so a body that slows down
    // does not skip part of a step.
    phase: f32 = 0.0,
    // The smoothed amplitude, which is what starts and stops the swing.
    gain: f32 = 0.0,
    // Half cycles since the start of the run, which is the number of footfalls.
    // Its parity is which foot, and its value keys the per-step variation.
    // Wrapping is deliberate and means nothing: only the parity and the hash of
    // it are read.
    half_steps: u32 = 0,
    seed: u32 = 0x51ed270b,

    // One frame of the walk.
    //
    // `speed` is the distance actually covered over `delta`, not the speed the
    // keys asked for. A body pressed into a wall covers nothing and so does not
    // sway, which is the difference between walking and pushing.
    //
    // `t` is a clock in seconds for the slow wander alone. It is the caller's
    // own, not the engine's shader clock, which folds every hour and would step
    // the gait's wander when it wrapped.
    pub fn update(self: *Walk, speed: f32, delta: f32, t: f32) Sway {
        const tau = std.math.tau;
        const tune = self.tuning;

        // Never zero, so the stride below is always a real length. Under this
        // the gait is stopping in any case, and `gain` is what decides that.
        const ratio = @max(speed, 0.05) / tune.ref_speed;
        const stride = tune.stride * std.math.pow(f32, ratio, tune.stride_exp);

        // The slow wander, which stretches and shortens the stride. Held above
        // a quarter of its length: a stride may be stretched or shortened, and
        // a setting that would reverse or annihilate one is not a gait.
        const wander = noise.noise1(t * tune.jitter_freq, self.seed) * tune.jitter;
        const stretch = @max(1.0 + wander * 0.5, 0.25);

        // Capped at half a cycle, for the same reason the engine clamps its own
        // frame delta: a frame that took long enough to skip a whole step is a
        // hitch, and stepping the gait through it would put the eye somewhere
        // unrelated to where it was. The cap also bounds the crossing count
        // below to one.
        const advance = @min(tau * speed * delta / (stride * stretch), std.math.pi);

        const before = self.phase;
        self.phase += advance;
        var out: Sway = .{};

        // Feet land at the two half-cycle marks. Counted from how many marks
        // the phase passed rather than tested against one of them, so no
        // footfall is lost to a long frame and none is counted twice.
        const crossings = @floor(self.phase / std.math.pi) - @floor(before / std.math.pi);
        if (crossings > 0.0) {
            self.half_steps +%= @intFromFloat(crossings);
            out.footfall = true;
        }
        if (self.phase >= tau) self.phase -= tau;

        // Exact exponential smoothing, so the approach takes the same time
        // whatever the frame rate. `settle` carries both directions: a walk
        // reaches full swing in the time a stop takes to lose it.
        const target = if (speed > 0.05) std.math.pow(f32, ratio, tune.speed_exp) else 0.0;
        self.gain += (target - self.gain) * (1.0 - @exp(-tune.settle * delta));

        const step_index: i32 = @bitCast(self.half_steps);
        const this_step = 1.0 + tune.jitter * noise.grad1(self.seed +% 77, step_index);
        const side: f32 = if (self.half_steps & 1 == 0) 1.0 else -1.0;
        const amount = self.gain * tune.scale * this_step;

        const p = self.phase;
        // Twice a cycle for the vertical: the eye drops onto each of the two
        // feet. Once a cycle for everything sideways, which is what tells the
        // two feet apart.
        const carrier = (@sin(2.0 * p) + tune.sharp * 0.5 * @sin(4.0 * p)) /
            (1.0 + tune.sharp * 0.5);
        const sway = @sin(p) * (1.0 + tune.limp * side);

        out.right = tune.lat * amount * sway;
        out.up = tune.vert * amount * carrier;
        out.roll = tune.roll * amount * @sin(p + tune.roll_lag);
        out.pitch = tune.pitch * amount * @cos(2.0 * p);
        return out;
    }
};

// Which way a body tips when it starts moving sideways.
//
// A step to the right is an acceleration to the right, and the feet produce it
// by pushing left, so the body has to lean into it or it topples. The lean is
// therefore an answer to the change in sideways speed and not to the speed
// itself: it appears when a strafe starts, is gone a couple of hundred
// milliseconds later while the strafe continues, and appears the other way when
// the strafe stops.
//
// Two lagging copies of the sideways speed and a subtraction, which is a band
// pass. The faster one decides how long the tip takes to arrive and the slower
// one how long it lasts, and taking a difference of two lags rather than
// subtracting the speed itself is the whole of why the tip has no edge on it: a
// step in the speed reaches the output as a curve that starts at zero.
//
// At the rates below the tip peaks 0.14 s after a strafe starts and is down to a
// tenth of that peak by 0.6 s, and it is 0.46 of `gain` times the speed rather
// than all of it, since the fast copy has not finished arriving when the slow
// one starts catching up.
pub const Lean = struct {
    // Radians of tilt per metre per second of sideways speed. Negative tips the
    // other way, which is what a camera operator leaning away from the move
    // would do and is the opposite of what a body does.
    gain: f32,
    // How fast the tip arrives and how fast it goes, per second. The first has
    // to be the larger or there is no tip at all, only a delayed tilt.
    rise: f32 = 9.0,
    settle: f32 = 5.5,

    // The two copies. They are the whole of the state.
    fast: f32 = 0.0,
    slow: f32 = 0.0,

    pub fn update(self: *Lean, sideways: f32, delta: f32) f32 {
        self.fast += (sideways - self.fast) * (1.0 - @exp(-self.rise * delta));
        self.slow += (self.fast - self.slow) * (1.0 - @exp(-self.settle * delta));
        return (self.fast - self.slow) * self.gain;
    }
};
