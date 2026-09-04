import Foundation

/// What a tank fires. Unlocked by lifetime kills, in steps of five.
///
/// Every weapon is the same shell engine with different numbers and a few behaviours the
/// engine knows about — spread, homing, splash, mines, passing through walls — rather than
/// ten separate systems. That keeps one set of physics under test, and it is what makes
/// the ordering honest: each costs five more points than the last and is meant to be worth
/// them, not merely different. The trade each one makes is written next to it.
public enum Weapon: String, CaseIterable, Sendable {
    /// One shell, one bounce. The gun everyone starts with.
    case cannon
    /// Five pellets in a fan. Devastating close up, nothing past a tank's length or three.
    case scatter
    /// Fast small shells, a stream of them, each wandering a little. Range and bounces
    /// traded for rate.
    case repeater
    /// Shells that come off four walls. Trick shots — and the one weapon that is as
    /// dangerous to its owner as to anyone.
    case bouncer
    /// One very fast shell. Nearly impossible to dodge, slow to reload.
    case railgun
    /// Missiles that turn toward the nearest tank. Slow, and they die on walls, so cover
    /// still works.
    case seeker
    /// Three shells in a tight fan, each with a bounce. A cannon and a half.
    case volley
    /// A slow shell that goes off on anything it touches, and takes everything nearby with
    /// it. Splash goes round corners. So does the owner's, if they are close.
    case mortar
    /// Eight shells at once, in every direction. Short-lived. A panic button.
    case nova
    /// Drops a mine behind the tank. Four at a time, they wait half a minute, and they do
    /// not go off for their owner.
    case minelayer
    /// Shells that go through walls. Cover stops working. The last thing to unlock.
    case phantom

    /// Lifetime kills needed. Five apart, in order.
    public var cost: Int {
        (Weapon.allCases.firstIndex(of: self) ?? 0) * 5
    }

    public var title: String {
        switch self {
        case .cannon: return "Cannon"
        case .scatter: return "Scatter"
        case .repeater: return "Repeater"
        case .bouncer: return "Bouncer"
        case .railgun: return "Railgun"
        case .seeker: return "Seeker"
        case .volley: return "Volley"
        case .mortar: return "Mortar"
        case .nova: return "Nova"
        case .minelayer: return "Minelayer"
        case .phantom: return "Phantom"
        }
    }

    public var summary: String {
        switch self {
        case .cannon: return "one shell, one bounce"
        case .scatter: return "five pellets in a fan; close range only"
        case .repeater: return "a stream of fast shells; no bounces"
        case .bouncer: return "shells bounce four times; watch your back"
        case .railgun: return "one very fast shell; slow to reload"
        case .seeker: return "missiles that turn toward the nearest tank"
        case .volley: return "three bouncing shells at once"
        case .mortar: return "goes off on anything; splash goes round corners"
        case .nova: return "eight shells in every direction"
        case .minelayer: return "drops mines behind you; four at a time"
        case .phantom: return "shells go through walls"
        }
    }

    /// The numbers the shell engine reads.
    public struct Profile: Equatable, Sendable {
        /// Headings relative to the barrel, one per shell fired in a volley.
        public var spread: [Double]
        /// Degrees of random error added to every shell, either way.
        public var jitter: Double
        public var shellSpeed: Double
        public var shellRadius: Double
        public var bounces: Int
        public var lifetime: Double
        /// How many volleys — presses of the trigger — may be in the air at once.
        public var volleysInFlight: Int
        public var cooldown: Double
        /// Radians per second a shell turns toward its target. Zero does not home.
        public var homingTurn: Double
        /// How far a homing shell looks for a tank.
        public var homingRange: Double
        /// Radius everything within is destroyed when the shell goes off. Zero is a plain
        /// shell that only hits what it touches.
        public var blastRadius: Double
        /// A mine: does not move, goes off when a tank other than its owner comes within
        /// `blastRadius` after `armDelay`, and is dropped behind rather than fired ahead.
        public var isMine: Bool
        public var armDelay: Double
        /// Passes through everything solid. The border still absorbs it.
        public var isGhost: Bool
    }

    public var profile: Profile {
        // Everything the cannon is, then what each weapon changes.
        var p = Profile(spread: [0], jitter: 0, shellSpeed: 460, shellRadius: 5, bounces: 1,
                        lifetime: 6, volleysInFlight: 3, cooldown: 0.3, homingTurn: 0,
                        homingRange: 0, blastRadius: 0, isMine: false, armDelay: 0, isGhost: false)
        switch self {
        case .cannon:
            break
        case .scatter:
            p.spread = [-16, -8, 0, 8, 16].map { $0 * .pi / 180 }
            p.jitter = 2
            p.shellSpeed = 500
            p.shellRadius = 4
            p.bounces = 0
            // Six hundred points of reach: three tank-lengths, then gone.
            p.lifetime = 1.2
            p.volleysInFlight = 1
            p.cooldown = 0.9
        case .repeater:
            p.jitter = 4
            p.shellSpeed = 540
            p.shellRadius = 4
            p.bounces = 0
            p.lifetime = 2.5
            p.volleysInFlight = 8
            p.cooldown = 0.12
        case .bouncer:
            p.shellSpeed = 420
            p.bounces = 4
            p.lifetime = 9
            p.volleysInFlight = 2
            p.cooldown = 0.5
        case .railgun:
            p.shellSpeed = 1100
            p.shellRadius = 4
            p.lifetime = 3
            p.volleysInFlight = 1
            p.cooldown = 1.2
        case .seeker:
            p.shellSpeed = 340
            p.shellRadius = 6
            p.bounces = 0
            p.lifetime = 5
            p.volleysInFlight = 2
            p.cooldown = 1.0
            p.homingTurn = 2.6
            p.homingRange = 520
        case .volley:
            p.spread = [-7, 0, 7].map { $0 * .pi / 180 }
            p.shellSpeed = 500
            p.volleysInFlight = 2
            p.cooldown = 0.5
        case .mortar:
            p.shellSpeed = 320
            p.shellRadius = 8
            p.bounces = 0
            p.lifetime = 1.8
            p.volleysInFlight = 1
            p.cooldown = 1.4
            p.blastRadius = 95
        case .nova:
            p.spread = (0..<8).map { Double($0) * .pi / 4 }
            p.shellSpeed = 400
            p.bounces = 0
            p.lifetime = 1.4
            p.volleysInFlight = 1
            p.cooldown = 2.0
        case .minelayer:
            p.shellSpeed = 0
            p.shellRadius = 12
            p.bounces = 0
            p.lifetime = 30
            p.volleysInFlight = 4
            p.cooldown = 1.5
            p.blastRadius = 70
            p.isMine = true
            p.armDelay = 1.0
        case .phantom:
            // Cannon speed: its trade is that cover stops working, not that it is slow.
            p.bounces = 0
            p.lifetime = 3.5
            p.volleysInFlight = 2
            p.cooldown = 0.9
            p.isGhost = true
        }
        return p
    }

    /// Everything a player with this many lifetime kills may use, cheapest first.
    public static func unlocked(with points: Int) -> [Weapon] {
        allCases.filter { $0.cost <= points }
    }

    /// The weapon this many points has just reached, if any: `true` for a threshold hit
    /// exactly, since points arrive one at a time.
    public static func newlyUnlocked(at points: Int) -> Weapon? {
        allCases.first { $0.cost == points && $0.cost > 0 }
    }

    /// The next one to save for, and how far off it is.
    public static func next(after points: Int) -> (weapon: Weapon, pointsToGo: Int)? {
        guard let weapon = allCases.first(where: { $0.cost > points }) else { return nil }
        return (weapon, weapon.cost - points)
    }
}
