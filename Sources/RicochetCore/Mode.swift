import Foundation

/// How a round is played.
///
/// Each mode is a named set of `Game.Settings`, so a mode is data rather than a branch in
/// the rules. That keeps every mode covered by the same tests and makes adding one a matter
/// of choosing numbers, not writing logic.
public enum Mode: String, CaseIterable, Sendable {
    /// The default: ninety seconds, respawns, most kills wins.
    case skirmish
    /// Three lives each, no respawns after the last. The round ends when one tank stands.
    case lastStanding
    /// Shells bounce three times and live longer. Nowhere is safe, including behind you.
    case ricochet

    public var title: String {
        switch self {
        case .skirmish: return "Skirmish"
        case .lastStanding: return "Last Tank Standing"
        case .ricochet: return "Ricochet"
        }
    }

    public var summary: String {
        switch self {
        case .skirmish: return "90s · respawns · most kills wins"
        case .lastStanding: return "three lives · no respawn after the last · last one wins"
        case .ricochet: return "90s · shells bounce three times · nowhere is safe"
        }
    }

    public var settings: Game.Settings {
        var settings = Game.Settings()
        switch self {
        case .skirmish:
            settings.shellBounces = 1
            settings.lives = 0
        case .lastStanding:
            settings.shellBounces = 1
            settings.lives = 3
            // A long respawn, because coming back is the scarce thing here.
            settings.respawnDelay = 3.5
            // No fixed length to speak of: it ends when one tank is left.
            settings.roundDuration = 300
        case .ricochet:
            settings.shellBounces = 3
            settings.shellLifetime = 9
            // Fewer in the air at once, or the field fills with everyone's old shots.
            settings.shellsInFlight = 2
            settings.lives = 0
        }
        return settings
    }
}
