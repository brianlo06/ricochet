import XCTest
@testable import RicochetCore

final class ScoreboardTests: XCTestCase {

    func testAnEmptyLobbyAsksPeopleToScan() {
        let screen = Scoreboard.screen(for: Game(seed: 1), at: 0)
        XCTAssertTrue(screen.headline.contains("Scan"))
        XCTAssertTrue(screen.showsJoinPanel)
    }

    func testTheLobbyCountsWhoIsNotReady() {
        let game = Game(seed: 1)
        let a = UUID(), b = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.addPlayer(id: b, name: "B", at: 0)
        _ = game.pullTrigger(player: a, at: 0)
        XCTAssertTrue(Scoreboard.screen(for: game, at: 0).headline.contains("waiting for 1"))
    }

    func testTheRoundShowsAClockThatTurnsUrgentAtTheEnd() {
        let game = Game(seed: 1)
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        let start = 100 + game.settings.countdownDuration
        game.tick(at: start)
        let early = Scoreboard.screen(for: game, at: start)
        XCTAssertEqual(early.clock, "1:30")
        XCTAssertFalse(early.isUrgent)
        XCTAssertFalse(early.showsJoinPanel)
        let late = Scoreboard.screen(for: game, at: start + game.settings.roundDuration - 5)
        XCTAssertTrue(late.isUrgent)
    }

    func testARowShowsLivesOnlyWhenTheyAreFinite() {
        var player = PlayerState(id: UUID(), seat: 0, name: "Ada", position: .zero, heading: 0)
        player.kills = 2
        player.lifetimePoints = 7
        XCTAssertEqual(Scoreboard.row(for: player), "Ada   2   Cannon ★7")
        player.livesLeft = 2
        XCTAssertEqual(Scoreboard.row(for: player), "Ada   2   ♥♥   Cannon ★7")
        player.isEliminated = true
        XCTAssertEqual(Scoreboard.row(for: player), "Ada   2   OUT   Cannon ★7")
        var bot = PlayerState(id: UUID(), seat: 1, name: "Rusty", position: .zero, heading: 0)
        bot.isBot = true
        XCTAssertEqual(Scoreboard.row(for: bot), "Rusty ·bot   0   Cannon", "bots show no lifetime score")
    }

    func testResultsListEveryoneWithOwnGoalsOnlyWhenTheyHappened() {
        let game = Game(seed: 1)
        let id = UUID()
        game.addPlayer(id: id, name: "Ada", at: 0)
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        let start = 100 + game.settings.countdownDuration
        game.tick(at: start)
        game.tick(at: start + game.settings.roundDuration)
        let screen = Scoreboard.screen(for: game, at: start + game.settings.roundDuration)
        XCTAssertTrue(screen.body.hasPrefix("1.  Ada   0 kills"))
        XCTAssertFalse(screen.body.contains("own goal"))
    }
}
