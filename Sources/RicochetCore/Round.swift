import Foundation

/// Where a match is in its lifecycle.
///
/// Phases carry their own deadline rather than the game holding a separate timer, so
/// `tick(at:)` can advance everything from the current time alone and a whole match replays
/// deterministically in a test.
public enum Phase: Equatable, Sendable {
    /// Waiting for players to say they are ready. Tanks can drive around meanwhile.
    case lobby
    /// Everyone is ready; the round begins at `startsAt`.
    case countdown(startsAt: TimeInterval)
    case playing(endsAt: TimeInterval)
    /// Final scores are on screen until `until`, then back to the lobby.
    case results(until: TimeInterval)

    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }
}

/// Why a trigger pull did not fire a shell.
public enum Refusal: Equatable, Sendable {
    /// Faster than the gun reloads. Not felt: a shot that never happened is not a mistake.
    case tooSoon
    /// Every shell this player may have in the air is still in the air.
    case outOfShells
    /// Destroyed, and waiting to come back — or out for the round.
    case destroyed
}

/// What a trigger pull did, given the phase. The phone's button always means "the player
/// pressed A"; what that *means* depends on where the match is, which is exactly the kind
/// of decision that belongs in the rules rather than in the controller.
public enum TriggerResult: Equatable, Sendable {
    case fired(shellID: UUID)
    case refused(Refusal)
    /// Toggled readiness in the lobby, or asked for another round from the results screen.
    case readied(Bool)
    /// Pressed during the countdown, which does nothing on purpose.
    case ignored
    case noSuchPlayer
}
