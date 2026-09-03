import XCTest
@testable import RicochetCore

/// Pausing and ending a round from the sofa.
final class PauseTests: XCTestCase {

    private func startedGame() -> (Game, UUID, TimeInterval) {
        let game = Game(arena: Arena(width: 1000, height: 600, walls: [],
                                     spawns: [Vec2(x: 200, y: 300), Vec2(x: 800, y: 300)]))
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        let began = 100 + game.settings.countdownDuration
        game.tick(at: began)
        return (game, id, began)
    }

    private func run(_ game: Game, from: TimeInterval, for seconds: Double, holding: [UUID: Controls] = [:]) {
        var t = from
        let end = from + seconds
        while t < end {
            t = min(t + 1.0 / 60, end)
            for (id, c) in holding { game.setControls(player: id, c, at: t) }
            game.tick(at: t)
        }
    }

    func testAPauseFreezesEverythingAndResumingPushesEveryDeadlineOn() {
        let (game, id, began) = startedGame()
        _ = game.fire(player: id, at: began)
        run(game, from: began, for: 0.5, holding: [id: .forward])
        let shell = game.shells[0]
        let tank = game.players[id]!.position
        let remaining = game.remaining(at: began + 0.5)!

        XCTAssertTrue(game.pause(at: began + 0.5))
        XCTAssertTrue(game.phase.isPaused)
        XCTAssertFalse(game.phase.isPlaying)
        run(game, from: began + 0.5, for: 20, holding: [id: .forward])
        XCTAssertEqual(game.shells[0].position, shell.position, "shells do not move while paused")
        XCTAssertEqual(game.players[id]!.position, tank, "tanks do not move while paused")
        XCTAssertEqual(game.remaining(at: began + 20.5)!, remaining, accuracy: 0.001, "the clock is frozen")
        XCTAssertEqual(game.pullTrigger(player: id, at: began + 10), .ignored)

        XCTAssertTrue(game.resume(at: began + 20.5))
        XCTAssertTrue(game.phase.isPlaying)
        XCTAssertEqual(game.remaining(at: began + 20.5)!, remaining, accuracy: 0.001,
                       "resuming gives back exactly the time that was left")
        XCTAssertEqual(game.shells[0].expiresAt, shell.expiresAt + 20, accuracy: 0.001)
        run(game, from: began + 20.5, for: 0.2)
        XCTAssertNotEqual(game.shells.first?.position, shell.position, "and things move again")
    }

    func testPausingOutsideARoundIsRefused() {
        let game = Game(seed: 1)
        XCTAssertFalse(game.pause(at: 0))
        XCTAssertNil(game.togglePause(at: 0))
        XCTAssertFalse(game.resume(at: 0))
    }

    func testTheRulesCannotChangeWhilePaused() {
        let (game, _, began) = startedGame()
        game.pause(at: began + 1)
        XCTAssertFalse(game.setMode(.ricochet))
        XCTAssertFalse(game.reshuffleMap())
    }

    func testEndingEarlyGoesToResultsWithTheScoresAsTheyStand() {
        let (game, id, began) = startedGame()
        XCTAssertTrue(game.endRoundEarly(at: began + 5))
        if case .results = game.phase {} else { return XCTFail("expected results, got \(game.phase)") }
        XCTAssertEqual(game.lastResults.map(\.id), [id])
        XCTAssertFalse(game.endRoundEarly(at: began + 6), "nothing to end on the results screen")
    }

    func testAPausedRoundCanBeEnded() {
        let (game, _, began) = startedGame()
        game.pause(at: began + 1)
        XCTAssertTrue(game.endRoundEarly(at: began + 2))
        if case .results = game.phase {} else { XCTFail("expected results") }
    }

    func testAnEliminationRoundEndsWhenTheLastPersonIsOutHoweverManyBotsRemain() {
        let game = Game(mapPolicy: .fixed(.crossfire), seed: 4)
        game.setMode(.lastStanding)
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        game.setBots(3, at: 0)
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        let began = 100 + game.settings.countdownDuration
        game.tick(at: began)
        // The person stands still and waits to be found. Three bots will get there.
        var t = began
        while game.phase.isPlaying, !(game.players[id]?.isEliminated ?? false), t < began + 240 {
            t += 1.0 / 60
            game.tick(at: t)
        }
        XCTAssertTrue(game.players[id]?.isEliminated ?? game.lastResults.first { $0.id == id }?.isEliminated ?? false,
                      "the person should have been found and eliminated")
        game.tick(at: t + 1.0 / 60)
        XCTAssertFalse(game.phase.isPlaying, "the round ends the moment the last person is out")
        XCTAssertGreaterThanOrEqual(game.lastResults.filter { $0.isBot && !$0.isEliminated }.count, 1,
                                    "with bots still standing, because nobody was left to watch them")
    }
}
