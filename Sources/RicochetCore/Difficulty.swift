import Foundation

/// How good the bots are.
///
/// A difficulty is a set of numbers the bot brain reads, not a different brain: every
/// level plans routes, shoots what it sees and dodges what it can, and what changes is how
/// well it aims, how fast it reacts, how far it will engage from and how often it bothers
/// to get out of the way. That keeps one brain under test and makes a level a matter of
/// choosing numbers.
public enum Difficulty: String, CaseIterable, Sendable {
    case easy, medium, hard, impossible

    public var title: String {
        switch self {
        case .easy: return "Easy"
        case .medium: return "Medium"
        case .hard: return "Hard"
        case .impossible: return "Impossible"
        }
    }

    public var summary: String {
        switch self {
        case .easy: return "slow to shoot, wide of the mark, never dodges"
        case .medium: return "a fair fight"
        case .hard: return "quick, accurate, and it sees you coming"
        case .impossible: return "never misses; you have been warned"
        }
    }

    public struct Tuning: Equatable, Sendable {
        /// Radians of error added to each shot, either way.
        public var aimError: Double
        /// Seconds between shots when it has a target lined up.
        public var shotInterval: ClosedRange<Double>
        /// Seconds between decisions. Longer is slower to notice anything.
        public var reactionTime: Double
        /// How much of a moving target's travel it allows for. 1 leads perfectly.
        public var lead: Double
        /// How far ahead, in seconds, it looks for shells about to hit it. Zero is never.
        public var dodgeHorizon: Double
        /// The share of threats it actually does something about.
        public var dodgeChance: Double
        /// How close a target has to be before it will shoot. It still comes to find you.
        public var range: Double
    }

    public var tuning: Tuning {
        switch self {
        case .easy:
            return Tuning(aimError: 0.24, shotInterval: 1.4...2.4, reactionTime: 0.3,
                          lead: 0, dodgeHorizon: 0, dodgeChance: 0, range: 620)
        case .medium:
            return Tuning(aimError: 0.13, shotInterval: 0.9...1.6, reactionTime: 0.2,
                          lead: 0.5, dodgeHorizon: 0.5, dodgeChance: 0.55, range: 950)
        case .hard:
            return Tuning(aimError: 0.06, shotInterval: 0.45...0.9, reactionTime: 0.1,
                          lead: 1, dodgeHorizon: 0.8, dodgeChance: 1, range: .infinity)
        case .impossible:
            return Tuning(aimError: 0, shotInterval: 0.3...0.4, reactionTime: 0.05,
                          lead: 1, dodgeHorizon: 1.0, dodgeChance: 1, range: .infinity)
        }
    }

    public var next: Difficulty {
        let all = Difficulty.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}
