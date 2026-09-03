import Foundation
import RemoteKit

/// Turns game events into the feedback cues the phone renders.
///
/// Pure and separate from the host so the mapping is testable: "being destroyed should feel
/// worse than destroying" is a rule, and rules belong where they can be asserted rather
/// than buried in a network callback.
///
/// The cue vocabulary is deliberately about feel rather than meaning — `success` at some
/// intensity, not `tankDestroyed`. The phone decides what a firm success feels like on its
/// hardware, and the same vocabulary works for any host built on the same server.
public enum Feedback {

    /// A cue and who should feel it. `nil` means everybody.
    public struct Addressed: Equatable, Sendable {
        public var cue: CuePayload
        public var player: UUID?
        public init(_ cue: CuePayload, to player: UUID? = nil) {
            self.cue = cue
            self.player = player
        }

        public static func == (a: Addressed, b: Addressed) -> Bool {
            a.player == b.player && a.cue.kind == b.cue.kind
                && a.cue.intensity == b.cue.intensity && a.cue.text == b.cue.text
        }
    }

    /// What a trigger pull should feel like, to the player who pulled it.
    public static func cue(for result: TriggerResult) -> CuePayload? {
        switch result {
        case .fired:
            // A light kick. It happens constantly, so it must stay well under a hit.
            return CuePayload(kind: .tick, intensity: 0.25)

        case .readied(let ready):
            return CuePayload(kind: .info, intensity: ready ? 0.6 : 0.3,
                              text: ready ? "Ready" : "Not ready")

        // A shot the gun refused never happened, so it must not be felt. Buzzing here
        // would teach the player that the cooldown is a punishment rather than a rhythm —
        // and a dead tank's trigger doing nothing is the point of being dead.
        case .refused, .ignored, .noSuchPlayer:
            return nil
        }
    }

    /// What something that happened in a tick should feel like, and to whom.
    ///
    /// Names are looked up so the victim can be told who got them: the phone is the one
    /// screen a player looks at after being destroyed, and "Destroyed" alone leaves the
    /// obvious question unanswered.
    public static func cues(for event: Game.Event, names: [UUID: String]) -> [Addressed] {
        switch event {
        case .destroyed(let victim, let cause, _):
            switch cause {
            case .shell(let shooter) where shooter == victim:
                return [Addressed(CuePayload(kind: .failure, intensity: 1.0, text: "Own goal"), to: victim)]
            case .shell(let shooter):
                let name = names[shooter] ?? "a shell"
                return [
                    Addressed(CuePayload(kind: .success, intensity: 0.85, text: "+1"), to: shooter),
                    Addressed(CuePayload(kind: .failure, intensity: 0.9, text: "Hit by \(name)"), to: victim),
                ]
            case .crushed:
                return [Addressed(CuePayload(kind: .failure, intensity: 1.0, text: "Crushed"), to: victim)]
            case .pit:
                return [Addressed(CuePayload(kind: .failure, intensity: 1.0, text: "Fell in"), to: victim)]
            }

        case .eliminated(let player):
            return [Addressed(CuePayload(kind: .warning, intensity: 0.8, text: "Out"), to: player)]

        case .respawned(let player, _):
            return [Addressed(CuePayload(kind: .info, intensity: 0.4, text: "Go"), to: player)]

        case .mapChanged(let map):
            return [Addressed(CuePayload(kind: .info, intensity: 0.4, text: map.title))]

        // A ricochet is something to watch, not to feel: four players' shells bouncing is
        // a constant patter, and a phone that buzzed for each would never stop. The same
        // goes for a brick going, a shell going through a portal, and a shell timing out.
        case .bounced, .expired, .brickBroken, .teleported:
            return []
        }
    }

    /// What a phase change should feel like. `nil` when nothing should be felt.
    public static func cue(movingTo phase: Phase, from previous: Phase?) -> CuePayload? {
        guard phase != previous else { return nil }
        switch phase {
        case .countdown:
            return CuePayload(kind: .info, intensity: 0.5, text: "Get ready")
        case .playing:
            return CuePayload(kind: .start, intensity: 0.9, text: "GO")
        case .results:
            return CuePayload(kind: .finish, intensity: 0.8, text: "Round over")
        case .lobby:
            // Returning to the lobby is not an event anyone needs to feel.
            return previous == nil ? nil : CuePayload(kind: .info, intensity: 0.3)
        }
    }

    /// One beat of the countdown, so "3, 2, 1" is felt rather than watched.
    public static func countdownTick(secondsLeft: Int) -> CuePayload? {
        guard (1...3).contains(secondsLeft) else { return nil }
        return CuePayload(kind: .tick, intensity: 0.45, text: "\(secondsLeft)")
    }

    /// The last seconds of a round, so time pressure is felt too.
    public static func roundEndingTick(secondsLeft: Int) -> CuePayload? {
        guard (1...3).contains(secondsLeft) else { return nil }
        return CuePayload(kind: .warning, intensity: 0.5)
    }
}
