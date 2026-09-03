import Foundation

/// A small seeded generator, so a match is a function of its seed and its button log.
///
/// The system generator would do for play. It would not do for the tests, which replay a
/// whole round and expect the same maze, the same bumpers and the same bot decisions
/// every time; and it would not do for a bot, whose "randomness" has to be the same on a
/// replay or the replay is not one.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
