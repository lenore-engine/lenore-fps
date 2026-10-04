const std = @import("std");

// What happens between the trigger and the bullet: the fire control, the
// chamber, the magazine in the weapon and the ones on the body.
//
// Advanced by elapsed time rather than called per shot, so the cyclic rate is
// the weapon's and not the caller's. A caller ticking at a fixed rate and one
// advancing per frame get the same rate of fire, because the time a shot owes
// is carried into the next one rather than rounded to a whole update.
//
// Integer nanoseconds throughout. Two machines advancing the same weapon by
// the same intervals fire on the same updates, which a float accumulator only
// promises until its rounding differs.

pub const FireMode = enum {
    semi,
    burst,
    auto,
};

// A weapon's action, as authored. Seconds and rounds per minute because that
// is what a data sheet gives; `Action.init` turns them into what the action
// counts in and refuses anything that would not make a weapon.
pub const Spec = struct {
    modes: std.EnumSet(FireMode),
    // Rounds per minute while the trigger is held, and the fastest a semi or a
    // burst can follow. A self-loading pistol has no cyclic rate of its own
    // that a finger can reach, so for one this is how fast a trigger is pulled.
    rate: f32,
    // Rounds a burst fires. Read only when `modes` holds `burst`.
    burst: u8 = 3,
    // Rounds a magazine holds, not counting the one in the chamber.
    capacity: u16,
    // Whether the last round leaves the slide or bolt held open. When it does,
    // the trigger on an empty weapon does nothing at all, and the reload that
    // follows has to release it.
    locks_open: bool,
    // Seconds for a magazine change with a round still chambered, and for one
    // that also has to chamber a round.
    reload: f32,
    reload_empty: f32,
};

pub const SpecError = error{
    NoFireMode,
    BurstEmpty,
    CapacityZero,
    // A rate or a reload time that is not a positive duration the action can
    // count in nanoseconds: zero, negative, not a number, or too long to hold.
    BadDuration,
};

pub const ReloadError = error{
    // A reload is already under way.
    Reloading,
    // Nothing on the body holds more rounds than the magazine in the weapon.
    NoFullerMagazine,
};

pub const PouchError = error{
    // More magazines than the action was built to carry.
    TooManyMagazines,
};

// What one advance did, for the sound, the animation and the recoil.
pub const Report = struct {
    // Rounds that left the barrel. More than one in a single advance when the
    // interval is longer than a cycle, which a long frame under automatic fire
    // is. Wide enough for a whole magazine and the chamber.
    shots: u32 = 0,
    // The hammer or striker fell on an empty chamber.
    dry: bool = false,
    // The last round left and the slide stayed back.
    locked: bool = false,
    // A reload completed.
    reloaded: bool = false,
};

// The action of one weapon, carrying at most `magazines` magazines in all,
// the one in the weapon included.
//
// The pouch is part of the weapon's state rather than the player's: a
// magazine fits one weapon, and keeping its rounds here is what lets a
// partial magazine go back into the pouch and come out again later with the
// same count, which is the rule a reload in this kind of game is built on.
//
// The pouch has room for every magazine, not every spare. Between the start
// of a reload and a cancelled one's end the weapon holds none, and all of
// them are in the pouch at once.
pub fn Action(comptime magazines: usize) type {
    if (magazines == 0) @compileError("an action needs room for the magazine it fires from");
    return struct {
        const Self = @This();
        const Indexer = std.EnumSet(FireMode).Indexer;

        // The spec, in the units it is counted in.
        modes: std.EnumSet(FireMode),
        cycle_ns: i64,
        reload_ns: u64,
        reload_empty_ns: u64,
        burst: u8,
        locks_open: bool,

        mode: FireMode,
        chambered: bool,
        // Null while no magazine is in the weapon, which is from the start of
        // a reload to its end, and after a reload that was cancelled.
        magazine: ?u16,
        locked: bool,

        // Time until the action can fire again. Negative inside one advance
        // while shots are owed, and clamped to zero at its end once firing has
        // stopped, so a weapon that stood idle does not bank a volley.
        wait_ns: i64 = 0,
        held: bool = false,
        // A pull not yet answered. A tap that starts and ends between two
        // advances still fires, and one made while the action cycles fires when
        // it is ready rather than being lost.
        latched: bool = false,
        burst_left: u8 = 0,

        reloading: ?Reloading = null,

        spares: [magazines]u16 = undefined,
        spare_count: usize = 0,

        const Reloading = struct {
            left_ns: u64,
            incoming: u16,
            // Decided when the reload starts: an empty chamber is what makes it
            // the longer one, and what has it chamber a round at the end.
            empty: bool,
        };

        // Loaded and ready: a full magazine in, a round chambered on top of
        // it, and `spares` full magazines on the body.
        pub fn init(spec: Spec, spares: usize) (SpecError || PouchError)!Self {
            var modes = spec.modes.iterator();
            const first = modes.next() orelse return error.NoFireMode;
            if (spec.modes.contains(.burst) and spec.burst == 0) return error.BurstEmpty;
            if (spec.capacity == 0) return error.CapacityZero;
            if (spares > magazines - 1) return error.TooManyMagazines;

            var self: Self = .{
                .modes = spec.modes,
                .cycle_ns = try nanoseconds(i64, 60.0 / spec.rate),
                .reload_ns = try nanoseconds(u64, spec.reload),
                .reload_empty_ns = try nanoseconds(u64, spec.reload_empty),
                .burst = spec.burst,
                .locks_open = spec.locks_open,
                .mode = first,
                .chambered = true,
                .magazine = spec.capacity,
                .locked = false,
            };
            for (0..spares) |_| self.stow(spec.capacity);
            return self;
        }

        pub fn pull(self: *Self) void {
            self.held = true;
            self.latched = true;
        }

        pub fn release(self: *Self) void {
            self.held = false;
        }

        // The next mode the weapon has, in declaration order, wrapping. A
        // burst in progress stops: the selector moved under it.
        pub fn cycleMode(self: *Self) FireMode {
            var index = Indexer.indexOf(self.mode);
            for (0..Indexer.count) |_| {
                index = (index + 1) % Indexer.count;
                if (self.modes.contains(Indexer.keyForIndex(index))) break;
            }
            self.mode = Indexer.keyForIndex(index);
            self.burst_left = 0;
            return self.mode;
        }

        // Starts a magazine change: the fullest spare comes out of the pouch
        // and the one in the weapon goes into the pouch in its place, unless it
        // is empty, in which case it is dropped.
        pub fn reload(self: *Self) ReloadError!void {
            if (self.reloading != null) return error.Reloading;
            const fullest = self.fullestSpare() orelse return error.NoFullerMagazine;
            if (self.magazine) |rounds| if (self.spares[fullest] <= rounds)
                return error.NoFullerMagazine;

            const incoming = self.spares[fullest];
            self.spares[fullest] = self.spares[self.spare_count - 1];
            self.spare_count -= 1;
            // Room is certain: one magazine just left the pouch.
            if (self.magazine) |rounds| if (rounds > 0) self.stow(rounds);

            self.magazine = null;
            self.latched = false;
            self.burst_left = 0;
            const empty = !self.chambered;
            self.reloading = .{
                .left_ns = if (empty) self.reload_empty_ns else self.reload_ns,
                .incoming = incoming,
                .empty = empty,
            };
        }

        // Abandons a reload. The magazine that was on its way in goes back to
        // the pouch, and the weapon is left with none: the old one is already
        // stowed or on the floor.
        pub fn cancelReload(self: *Self) void {
            const under_way = self.reloading orelse return;
            self.stow(under_way.incoming);
            self.reloading = null;
        }

        pub fn advance(self: *Self, elapsed_ns: u64) Report {
            var report: Report = .{};
            const elapsed: i64 = @intCast(@min(elapsed_ns, std.math.maxInt(i64)));

            if (self.reloading) |*under_way| {
                // Both hands are on the magazine. A pull now is not saved for
                // later, or a reload would end in a shot nobody meant.
                self.latched = false;
                if (elapsed_ns < under_way.left_ns) {
                    under_way.left_ns -= elapsed_ns;
                    return report;
                }
                self.finishReload(under_way.*);
                self.reloading = null;
                report.reloaded = true;
                // The remainder of the interval is not spent firing. A round
                // that arrived and left within one update would never have been
                // seen in the weapon.
                return report;
            }

            self.startBurst();
            self.wait_ns -|= elapsed;
            while (self.wait_ns <= 0 and self.wantsToFire()) {
                if (!self.chambered) {
                    // Nothing falls while the slide is held open, so only a
                    // closed one clicks. Either way the pull is answered.
                    if (self.latched and !self.locked) report.dry = true;
                    self.latched = false;
                    self.burst_left = 0;
                    break;
                }
                self.fire(&report);
            }
            if (self.wait_ns < 0) self.wait_ns = 0;
            return report;
        }

        // Rounds in the weapon, chamber included.
        pub fn loaded(self: *const Self) u32 {
            return @as(u32, self.magazine orelse 0) + @intFromBool(self.chambered);
        }

        pub fn spareMagazines(self: *const Self) []const u16 {
            return self.spares[0..self.spare_count];
        }

        // A pull in burst mode becomes a burst. Only between advances: a pull
        // cannot arrive inside one, and a burst ending inside one has already
        // consumed the pull that started it.
        //
        // DECIDE: a burst runs to its end once started, even if the trigger
        // is let go. The other rule stops it on release, which turns a quick
        // tap into a single round. Close by feel in the example.
        fn startBurst(self: *Self) void {
            if (self.mode != .burst or self.burst_left > 0 or !self.latched) return;
            self.burst_left = self.burst;
            self.latched = false;
        }

        fn wantsToFire(self: *const Self) bool {
            return switch (self.mode) {
                .semi => self.latched,
                .auto => self.latched or self.held,
                .burst => self.burst_left > 0,
            };
        }

        fn fire(self: *Self, report: *Report) void {
            self.chambered = false;
            self.latched = false;
            self.burst_left -|= 1;
            report.shots += 1;

            if (self.magazine) |*rounds| if (rounds.* > 0) {
                rounds.* -= 1;
                self.chambered = true;
            };
            if (!self.chambered and self.locks_open) {
                self.locked = true;
                report.locked = true;
            }
            self.wait_ns += self.cycle_ns;
        }

        fn finishReload(self: *Self, finished: Reloading) void {
            var rounds = finished.incoming;
            if (finished.empty and rounds > 0) {
                rounds -= 1;
                self.chambered = true;
            }
            // An empty reload releases the slide whether or not it found a
            // round: what was holding it was the follower of the magazine that
            // came out.
            self.locked = false;
            self.magazine = rounds;
        }

        fn fullestSpare(self: *const Self) ?usize {
            var best: ?usize = null;
            for (self.spares[0..self.spare_count], 0..) |rounds, index| {
                if (rounds == 0) continue;
                if (best == null or rounds > self.spares[best.?]) best = index;
            }
            return best;
        }

        // The room is there by construction. `init` stows at most
        // `magazines - 1`, a reload takes one out before it puts one back,
        // and a cancel returns the one magazine the weapon is now without.
        fn stow(self: *Self, rounds: u16) void {
            std.debug.assert(self.spare_count < magazines);
            self.spares[self.spare_count] = rounds;
            self.spare_count += 1;
        }
    };
}

// A positive whole number of nanoseconds, or the error that says it is not
// one. The comparison is in f64 against the type's limit as a float, which
// rounds that limit up to a power of two; values at it are refused, so the
// conversion below never sees one it cannot hold.
fn nanoseconds(comptime T: type, seconds: f32) SpecError!T {
    const ns = @round(@as(f64, seconds) * std.time.ns_per_s);
    if (!(ns >= 1.0) or !(ns < @as(f64, @floatFromInt(std.math.maxInt(T))))) return error.BadDuration;
    return @intFromFloat(ns);
}
