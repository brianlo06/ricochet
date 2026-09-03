import Foundation

/// What the screen says, as opposed to how it is drawn.
///
/// The wording belongs here, with the rules and the tests; the rendering belongs to the
/// scene. "Waiting for 2" versus "Starting…", how a results table is numbered, when the
/// clock turns urgent — these are decisions, and decisions are testable.
public enum Scoreboard {

    /// How loudly the headline should be set. The scene owns the point sizes — this only
    /// says what kind of thing is being said.
    public enum Emphasis: Equatable, Sendable {
        /// An instruction to the room, read from a sofa.
        case prompt
        /// A single digit that has to be legible from across it.
        case countdown
        /// The verdict at the end of a round.
        case verdict
        /// Nothing is being said, so there is nothing to size.
        case silent
    }

    public struct Screen: Equatable, Sendable {
        public var headline: String
        public var emphasis: Emphasis
        public var body: String
        public var clock: String
        /// The last of the round, when the clock should stop being furniture.
        public var isUrgent: Bool
        /// The join panel is only useful before a round. During one it would cover the
        /// arena, and its code is stale the moment somebody has used it anyway.
        public var showsJoinPanel: Bool
    }

    /// Seconds at which the clock starts insisting.
    public static let urgentSeconds = 10

    public static func screen(for game: Game, at now: TimeInterval) -> Screen {
        let remaining = game.remaining(at: now)
        let left = Int(ceil(remaining ?? 0))

        switch game.phase {
        case .lobby:
            let waiting = game.players.values.filter { !$0.isReady }.count
            let headline: String
            if game.players.isEmpty {
                headline = "Scan with your phone's camera to join"
            } else if waiting == 0 {
                headline = "Starting…"
            } else {
                headline = "Press FIRE when ready  ·  waiting for \(waiting)"
            }
            let bots = game.botCount
            let botLine: String
            if game.humanCount == 0 {
                botLine = "Bots join once somebody has"
            } else if game.maxBots == 0 {
                botLine = "Every seat is taken, so no bots"
            } else {
                botLine = "Bots: \(bots) of up to \(game.maxBots)  ·  Bots on your phone adds one"
            }
            return Screen(headline: headline, emphasis: .prompt,
                          body: "\(game.mode.title.uppercased())  ·  \(game.mode.summary)"
                              + "\n\(mapLine(for: game))"
                              + "\n\(botLine)"
                              + "\n\nDrive around while you wait  ·  Mode on your phone changes the rules",
                          clock: "", isUrgent: false, showsJoinPanel: true)

        case .countdown:
            return Screen(headline: "\(left)", emphasis: .countdown, body: "",
                          clock: "", isUrgent: false, showsJoinPanel: false)

        case .playing:
            return Screen(headline: "", emphasis: .silent, body: "",
                          clock: String(format: "%d:%02d", left / 60, left % 60),
                          isUrgent: left <= urgentSeconds, showsJoinPanel: false)

        case .paused:
            return Screen(headline: "PAUSED", emphasis: .verdict,
                          body: "Pause on a phone, or P on the Mac, to carry on"
                              + "\nEnd on a phone, or E on the Mac, to end the round",
                          clock: String(format: "%d:%02d", left / 60, left % 60),
                          isUrgent: false, showsJoinPanel: false)

        case .results:
            // There is always at least one row: the last player to leave a round drops the
            // game back to the lobby rather than finishing it.
            let lines = game.lastResults.enumerated().map { index, player in
                String(format: "%d.  %@   %d kills  ·  %d deaths  ·  %.0f%% of %d shots",
                       index + 1, player.name, player.kills, player.deaths,
                       player.accuracy * 100, player.shots)
                    + (player.ownGoals > 0 ? "  ·  \(player.ownGoals) own goal\(player.ownGoals == 1 ? "" : "s")" : "")
            }
            return Screen(headline: "\(game.mode.title) over", emphasis: .verdict,
                          body: lines.joined(separator: "\n")
                              + "\n\nPress FIRE for another round",
                          clock: "\(left)", isUrgent: false, showsJoinPanel: true)
        }
    }

    /// The map, as the lobby names it. A round on a map somebody built by hand has no
    /// name to give, so it says so.
    public static func mapLine(for game: Game) -> String {
        guard let map = game.map else { return "MAP: custom" }
        return "MAP: \(map.title)  ·  \(map.summary)"
    }

    /// The map's name alone, for the corner of the screen during a round.
    public static func mapTag(for game: Game) -> String {
        game.map?.title.uppercased() ?? ""
    }

    /// One player's line in the corner list: name, kills, and only the state worth the
    /// width. Lives are shown when they are finite, being out when it has happened.
    public static func row(for player: PlayerState) -> String {
        var row = "\(player.name)\(player.isBot ? " ·bot" : "")   \(player.kills)"
        if player.isEliminated {
            row += "   OUT"
        } else if let lives = player.livesLeft {
            row += "   " + String(repeating: "♥", count: max(lives, 0))
        }
        return row
    }
}
