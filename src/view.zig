const noise = @import("noise.zig");

// The view does not arrive where the hand points at the instant the hand points
// there.
//
// A camera has mass and whoever is turning it has arms. This is the whole of
// that: one exponential approach to where the input has put the aim, which
// rounds the start and the end of every turn and leaves a turn in progress
// exactly where it would have been.
//
// Small on purpose. What is being smoothed is the snap at either end of a flick,
// and a lag long enough to be felt as lag is a different and much disliked
// effect wearing the same name.
pub const Aim = struct {
    // Seconds for the view to cover about two thirds of the distance to the
    // aim. Zero or less snaps.
    lag: f32,

    // Where the view actually points, which is what the frame is drawn from and
    // what the feet walk along.
    yaw: f32 = 0.0,
    pitch: f32 = 0.0,

    pub fn follow(self: *Aim, yaw: f32, pitch: f32, delta: f32) void {
        if (!(self.lag > 0.0)) {
            self.yaw = yaw;
            self.pitch = pitch;
            return;
        }
        const caught = 1.0 - @exp(-delta / self.lag);
        self.yaw += (yaw - self.yaw) * caught;
        self.pitch += (pitch - self.pitch) * caught;
    }
};

// What a camera does in a hand rather than on a tripod.
//
// Nobody holds one still. It is not a tremor, which would be fast and would read
// as a defect at this amplitude; it is a slow wander in every axis at once, of
// the order of a fifth of a degree and a few millimetres, and its whole purpose
// is that a level standing still is not perfectly frozen.
//
// Five curves at five rates that are not multiples of each other, so the axes
// never return to the same arrangement and the wander has no period. The rates
// are a fraction of a cycle a second: anything faster stops being a hand and
// starts being a shake.
pub const Handheld = struct {
    // Radians and metres. Both are the curve's full reach; what is on screen at
    // any moment is usually well inside it.
    angle: f32,
    shift: f32,
    seed: u32 = 0x27d4eb2f,
    clock: f32 = 0.0,

    pub const Drift = struct {
        right: f32,
        up: f32,
        pitch: f32,
        yaw: f32,
        roll: f32,
    };

    pub fn update(self: *Handheld, delta: f32) Drift {
        self.clock += delta;
        const t = self.clock;
        return .{
            .pitch = self.angle * noise.noise1(t * 0.23, self.seed),
            .yaw = self.angle * noise.noise1(t * 0.31, self.seed +% 1),
            // Less roll than the two that aim it. A hand tires in the direction
            // it points; it does not turn the horizon as freely.
            .roll = self.angle * 0.7 * noise.noise1(t * 0.17, self.seed +% 2),
            .right = self.shift * noise.noise1(t * 0.19, self.seed +% 3),
            .up = self.shift * noise.noise1(t * 0.13, self.seed +% 4),
        };
    }
};

// A knock, and what is left of it a moment later.
//
// One scalar of accumulated disturbance that decays at a fixed rate, read out
// through three noise curves at three different rates so the three angles never
// line up into a direction. A caller drives it from the gait's footfalls,
// which is what keeps a walk from being exactly periodic: the swing repeats and
// the kick on top of it does not.
//
// Linear in the disturbance rather than squared. The squared response exists to
// separate a large knock from a small one, and here there is one source and it
// is always the same size.
pub const Shake = struct {
    // What is left to shake out, in [0, 1].
    trauma: f32 = 0.0,
    // How fast it drains, per second. At this rate a footfall's worth is gone
    // in about thirty milliseconds, which is well inside the time between two
    // steps, so each one reads as its own kick rather than as a rumble.
    decay: f32 = 1.6,
    // Radians at full disturbance. Unjudged: nothing here has been seen.
    pitch: f32 = 0.030,
    yaw: f32 = 0.024,
    roll: f32 = 0.030,
    // Cycles per second of the curve each angle is read from. Three rates that
    // are not multiples of each other, so the three do not return to the same
    // arrangement.
    rate: f32 = 11.0,
    seed: u32 = 0x1b873593,
    clock: f32 = 0.0,

    pub const Angles = struct {
        pitch: f32 = 0.0,
        yaw: f32 = 0.0,
        roll: f32 = 0.0,
    };

    pub fn add(self: *Shake, amount: f32) void {
        self.trauma = @min(1.0, self.trauma + amount);
    }

    pub fn update(self: *Shake, delta: f32) Angles {
        self.clock += delta;
        self.trauma = @max(0.0, self.trauma - self.decay * delta);
        if (self.trauma == 0.0) return .{};

        const t = self.clock * self.rate;
        return .{
            .pitch = self.pitch * self.trauma * noise.noise1(t, self.seed),
            .yaw = self.yaw * self.trauma * noise.noise1(t * 1.31, self.seed +% 1),
            .roll = self.roll * self.trauma * noise.noise1(t * 0.83, self.seed +% 2),
        };
    }
};
