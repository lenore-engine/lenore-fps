const std = @import("std");

// A damped spring pulling a displacement back to zero, stepped exactly.
//
// Exact rather than integrated: the step is the closed-form solution of
// x'' + 2ζωx' + ω²x = 0 over the interval, so a weapon settles the same way at
// 30 updates a second as at 240, and a stiff spring cannot blow up on a long
// frame the way an explicit integrator does once ω·dt passes its bound. The
// solution is linear in the state, so one step is four coefficients, and the
// coefficients serve every axis the spring moves.
//
// Under- and critically damped only. An overdamped spring creeps back without
// ever crossing zero, which is a weight on a damper rather than a recoil.
pub const Spring = struct {
    // Hertz of the undamped oscillation, ω / 2π.
    frequency: f32,
    // ζ, in (0, 1]. One returns as fast as possible without crossing zero;
    // below it the spring overshoots, by more the lower it is.
    damping: f32,

    pub const Error = error{
        FrequencyNotPositive,
        DampingOutOfRange,
    };

    pub fn validate(self: Spring) Error!void {
        if (!(self.frequency > 0.0) or !std.math.isFinite(self.frequency)) return error.FrequencyNotPositive;
        if (!(self.damping > 0.0) or self.damping > 1.0) return error.DampingOutOfRange;
    }

    // What `delta` seconds does to a state: x' = xx·x + xv·v and
    // v' = vx·x + vv·v.
    pub const Step = struct {
        xx: f32,
        xv: f32,
        vx: f32,
        vv: f32,

        pub fn apply(self: Step, comptime n: usize, position: *@Vector(n, f32), velocity: *@Vector(n, f32)) void {
            const x = position.*;
            const v = velocity.*;
            position.* = x * @as(@Vector(n, f32), @splat(self.xx)) + v * @as(@Vector(n, f32), @splat(self.xv));
            velocity.* = x * @as(@Vector(n, f32), @splat(self.vx)) + v * @as(@Vector(n, f32), @splat(self.vv));
        }
    };

    // The underdamped solution, with ωd = ω√(1 - ζ²):
    //   x(t) = e^(-ζωt) [x0 cos ωd t + (v0 + ζω x0) / ωd sin ωd t]
    //   v(t) = e^(-ζωt) [v0 cos ωd t - (ζω v0 + ω² x0) / ωd sin ωd t]
    // and at ζ = 1, where ωd is zero and the form above divides by it:
    //   x(t) = e^(-ωt) [x0 + (v0 + ω x0) t]
    //   v(t) = e^(-ωt) [v0 - ωt (v0 + ω x0)]
    // Each pair is the derivative of its first line, and each starts at
    // (x0, v0), which is what the test against a fine integration checks.
    pub fn over(self: Spring, delta: f32) Step {
        const omega = std.math.tau * self.frequency;
        const zeta = self.damping;
        const decay = @exp(-zeta * omega * delta);
        if (zeta >= 1.0) {
            return .{
                .xx = decay * (1.0 + omega * delta),
                .xv = decay * delta,
                .vx = -decay * omega * omega * delta,
                .vv = decay * (1.0 - omega * delta),
            };
        }
        const damped = omega * @sqrt(1.0 - zeta * zeta);
        const c = @cos(damped * delta);
        const s = @sin(damped * delta);
        return .{
            .xx = decay * (c + zeta * omega / damped * s),
            .xv = decay * s / damped,
            .vx = -decay * omega * omega / damped * s,
            .vv = decay * (c - zeta * omega / damped * s),
        };
    }

    // How far the spring travels from rest per unit of velocity it is given
    // there: the height of the first peak, which is what an author means by a
    // kick of so many radians.
    //
    // From the solution above with x0 = 0, the first peak is at
    // t = atan(ωd / ζω) / ωd, where sin ωd t = ωd / ω, so the peak is
    // e^(-ζωt) / ω. At ζ = 1 it is at t = 1/ω and is 1 / (ωe).
    pub fn reach(self: Spring) f32 {
        const omega = std.math.tau * self.frequency;
        const zeta = self.damping;
        if (zeta >= 1.0) return 1.0 / (omega * std.math.e);
        const root = @sqrt(1.0 - zeta * zeta);
        return @exp(-zeta / root * std.math.atan(root / zeta)) / omega;
    }
};
