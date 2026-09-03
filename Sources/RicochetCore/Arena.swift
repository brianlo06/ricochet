import Foundation

/// A point or a direction in arena space: origin bottom-left, matching SpriteKit.
public struct Vec2: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public static let zero = Vec2(x: 0, y: 0)

    /// A unit vector pointing along `heading`, in radians anticlockwise from +x.
    public init(heading: Double) { self.init(x: cos(heading), y: sin(heading)) }

    public var length: Double { (x * x + y * y).squareRoot() }
    public var heading: Double { atan2(y, x) }
    public var normalized: Vec2 { length > 0 ? self * (1 / length) : .zero }

    public func distance(to other: Vec2) -> Double { (self - other).length }
    public func dot(_ other: Vec2) -> Double { x * other.x + y * other.y }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(x: a.x * s, y: a.y * s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(x: -a.x, y: -a.y) }
    public static func += (a: inout Vec2, b: Vec2) { a = a + b }
}

/// An axis-aligned block. Everything solid in the arena is one of these or a circle, which
/// is what keeps a ricochet a reflection about one axis rather than a geometry problem.
public struct Rect: Equatable, Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = min(minX, maxX); self.maxX = max(minX, maxX)
        self.minY = min(minY, maxY); self.maxY = max(minY, maxY)
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: Vec2 { Vec2(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }

    public func offset(by delta: Vec2) -> Rect {
        Rect(minX: minX + delta.x, minY: minY + delta.y, maxX: maxX + delta.x, maxY: maxY + delta.y)
    }

    public func contains(_ point: Vec2) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    /// Whether a circle overlaps this block. Closest-point test, so a circle brushing a
    /// corner counts, which is what stops a tank cutting a corner it should not fit round.
    public func intersects(center: Vec2, radius: Double) -> Bool {
        let nearest = Vec2(x: min(max(center.x, minX), maxX),
                           y: min(max(center.y, minY), maxY))
        return nearest.distance(to: center) < radius
    }

    /// Whether the segment from `a` to `b` passes through this block, grown by `margin`.
    /// The slab test; it is what a line of sight is.
    public func intersects(segmentFrom a: Vec2, to b: Vec2, margin: Double = 0) -> Bool {
        let (x0, x1) = (minX - margin, maxX + margin)
        let (y0, y1) = (minY - margin, maxY + margin)
        var tMin = 0.0
        var tMax = 1.0
        let d = b - a
        for (origin, delta, lo, hi) in [(a.x, d.x, x0, x1), (a.y, d.y, y0, y1)] {
            if abs(delta) < 1e-9 {
                if origin < lo || origin > hi { return false }
            } else {
                var t0 = (lo - origin) / delta
                var t1 = (hi - origin) / delta
                if t0 > t1 { swap(&t0, &t1) }
                tMin = max(tMin, t0)
                tMax = min(tMax, t1)
                if tMin > tMax { return false }
            }
        }
        return true
    }
}

/// A round obstacle. Shells come off it along the normal, and — the whole point of it — it
/// does not use up a bounce.
public struct Bumper: Equatable, Sendable {
    public var center: Vec2
    public var radius: Double
    public init(center: Vec2, radius: Double) { self.center = center; self.radius = radius }
}

/// A strip of floor that carries tanks along. Shells fly over it.
public struct Conveyor: Equatable, Sendable {
    public var rect: Rect
    /// Points per second.
    public var push: Vec2
    public init(rect: Rect, push: Vec2) { self.rect = rect; self.push = push }
}

/// Two places that are the same place. Anything entering one leaves the other, still
/// going the way it was going.
public struct Portal: Equatable, Sendable {
    public var a: Vec2
    public var b: Vec2
    public var radius: Double
    public init(a: Vec2, b: Vec2, radius: Double) { self.a = a; self.b = b; self.radius = radius }
}

/// A block that is only sometimes there.
public struct Gate: Equatable, Sendable {
    public var rect: Rect
    public var period: Double
    public var openFor: Double
    public var phase: Double

    public init(rect: Rect, period: Double, openFor: Double, phase: Double = 0) {
        self.rect = rect
        self.period = max(period, 0.1)
        self.openFor = min(max(openFor, 0), self.period)
        self.phase = phase
    }

    public func isOpen(at t: Double) -> Bool {
        let cycle = (t + phase).truncatingRemainder(dividingBy: period)
        return (cycle < 0 ? cycle + period : cycle) < openFor
    }

    /// Seconds until the state next changes, for a screen that wants to warn.
    public func timeUntilChange(at t: Double) -> Double {
        let cycle = (t + phase).truncatingRemainder(dividingBy: period)
        let c = cycle < 0 ? cycle + period : cycle
        return c < openFor ? openFor - c : period - c
    }
}

/// A block that travels back and forth. A tank between it and something solid is crushed.
public struct Sweeper: Equatable, Sendable {
    public var home: Rect
    /// Where it gets to at the far end of its travel, relative to `home`.
    public var travel: Vec2
    /// Seconds for a full trip out and back.
    public var period: Double

    public init(home: Rect, travel: Vec2, period: Double) {
        self.home = home
        self.travel = travel
        self.period = max(period, 0.1)
    }

    /// 0 at home, 1 at the far end, and back: a triangle wave.
    public func progress(at t: Double) -> Double {
        var u = (t / period).truncatingRemainder(dividingBy: 1)
        if u < 0 { u += 1 }
        return u < 0.5 ? u * 2 : 2 - u * 2
    }

    public func rect(at t: Double) -> Rect { home.offset(by: travel * progress(at: t)) }

    /// Which way it is going right now, in points per second.
    public func velocity(at t: Double) -> Vec2 {
        var u = (t / period).truncatingRemainder(dividingBy: 1)
        if u < 0 { u += 1 }
        return travel * ((u < 0.5 ? 1 : -1) * 2 / period)
    }
}

/// The playfield: a fixed logical size, what is in it, and where tanks appear.
///
/// Fixed rather than following the window, unlike a shooting gallery's. A reticle can be
/// re-clamped when the window changes size; a tank halfway through a gap cannot be, so the
/// rules run in one coordinate space and the screen scales it to fit.
///
/// Time-dependent things — gates, sweepers — are described here and asked about with a
/// clock, so the arena itself is a value and the game keeps the clock.
public struct Arena: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var walls: [Rect]
    /// Where a tank can appear, in a fixed order: corners first, because those are the
    /// four seats a round usually starts with and they are the farthest apart.
    public var spawns: [Vec2]
    public var bumpers: [Bumper] = []
    /// Solid until a shell hits one, which removes it and the shell.
    public var bricks: [Rect] = []
    public var conveyors: [Conveyor] = []
    public var portals: [Portal] = []
    public var gates: [Gate] = []
    public var sweepers: [Sweeper] = []
    /// A tank whose centre crosses into one is gone. Shells fly over.
    public var pits: [Rect] = []

    public init(width: Double, height: Double, walls: [Rect] = [], spawns: [Vec2] = []) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.walls = walls
        self.spawns = spawns.isEmpty ? [Vec2(x: self.width / 2, y: self.height / 2)] : spawns
    }

    public var center: Vec2 { Vec2(x: width / 2, y: height / 2) }

    /// Everything a tank or a shell cannot pass through right now.
    public func solids(at t: Double) -> [Rect] {
        var all = walls
        all += bricks
        all += gates.filter { !$0.isOpen(at: t) }.map(\.rect)
        all += sweepers.map { $0.rect(at: t) }
        return all
    }

    /// Whether a circle of this size can sit here: inside the border and clear of every
    /// solid thing. Tanks are the only thing that asks; shells bounce instead.
    public func blocks(center: Vec2, radius: Double, at t: Double = 0) -> Bool {
        if center.x - radius < 0 || center.x + radius > width
            || center.y - radius < 0 || center.y + radius > height { return true }
        if solids(at: t).contains(where: { $0.intersects(center: center, radius: radius) }) { return true }
        return bumpers.contains { $0.center.distance(to: center) < $0.radius + radius }
    }

    /// Whether a straight line between two points is clear of everything solid — the test
    /// a shot depends on. Gates count as they are now; pits and conveyors do not count,
    /// because a shell flies over both.
    public func hasLineOfSight(from a: Vec2, to b: Vec2, at t: Double) -> Bool {
        if solids(at: t).contains(where: { $0.intersects(segmentFrom: a, to: b) }) { return false }
        return !bumpers.contains { bumper in
            // Distance from the circle's centre to the segment.
            let d = b - a
            let lengthSquared = d.dot(d)
            let u = lengthSquared > 0 ? min(max((bumper.center - a).dot(d) / lengthSquared, 0), 1) : 0
            return (a + d * u).distance(to: bumper.center) < bumper.radius
        }
    }
}
