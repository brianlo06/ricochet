import XCTest
@testable import RicochetCore

/// The match lifecycle: lobby, countdown, round, results, back to the lobby.
final class RoundTests: XCTestCase {

    private func makeGame() -> Game { Game(seed: 1) }

    private func addPlayers(_ game: Game, _ count: Int) -> [UUID] {
        (0..<count).map { index in
            let id = UUID()
            game.addPlayer(id: id, name: "P\(index + 1)", at: 0)
            return id
        }
    }

    func testAGameWithNoPlayersStaysInTheLobby() {
        let game = makeGame()
        for i in 0..<100 { game.tick(at: 100 + Double(i)) }
        XCTAssertEqual(game.phase, .lobby)
    }

    func testAllPlayersMustReadyBeforeTheCountdown() {
        let game = makeGame()
        let players = addPlayers(game, 2)
        XCTAssertEqual(game.pullTrigger(player: players[0], at: 100), .readied(true))
        game.tick(at: 100)
        XCTAssertEqual(game.phase, .lobby, "one ready player must not start a two-player game")
        XCTAssertEqual(game.pullTrigger(player: players[1], at: 101), .readied(true))
        game.tick(at: 101)
        XCTAssertEqual(game.phase, .countdown(startsAt: 101 + game.settings.countdownDuration))
    }

    func testAFullMatchRunsThroughEveryPhaseAndBackToTheLobby() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        let start = 100 + game.settings.countdownDuration
        game.tick(at: start)
        XCTAssertEqual(game.phase, .playing(endsAt: start + game.settings.roundDuration))

        let end = start + game.settings.roundDuration
        game.tick(at: end)
        XCTAssertEqual(game.phase, .results(until: end + game.settings.resultsDuration))
        XCTAssertEqual(game.lastResults.map(\.id), [id])

        game.tick(at: end + game.settings.resultsDuration)
        XCTAssertEqual(game.phase, .lobby)
        XCTAssertFalse(game.players[id]!.isReady, "readiness resets for the next round")
    }

    func testARoundStartsEveryoneAliveInTheirOwnCornerWithFreshScores() {
        let game = makeGame()
        let ids = addPlayers(game, 2)
        for id in ids { _ = game.pullTrigger(player: id, at: 100) }
        game.tick(at: 100)
        game.tick(at: 100 + game.settings.countdownDuration)
        for (index, id) in ids.enumerated() {
            let player = game.players[id]!
            XCTAssertTrue(player.isAlive)
            XCTAssertEqual(player.kills, 0)
            XCTAssertEqual(player.position, game.arena.spawns[index])
        }
        XCTAssertTrue(game.shells.isEmpty)
    }

    func testTheLastPlayerLeavingReturnsToTheLobby() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        game.tick(at: 100 + game.settings.countdownDuration)
        XCTAssertTrue(game.phase.isPlaying)
        game.removePlayer(id: id)
        XCTAssertEqual(game.phase, .lobby)
    }

    func testAPlayerLeavingDoesNotDeadlockALobbyWaitingOnThem() {
        let game = makeGame()
        let ids = addPlayers(game, 2)
        _ = game.pullTrigger(player: ids[0], at: 100)
        game.tick(at: 100)
        XCTAssertEqual(game.phase, .lobby)
        game.removePlayer(id: ids[1])
        game.tick(at: 101)
        if case .countdown = game.phase {} else { XCTFail("the remaining ready player should start") }
    }

    func testJoiningMidRoundPutsYouStraightIn() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        let start = 100 + game.settings.countdownDuration
        game.tick(at: start)
        let late = UUID()
        game.addPlayer(id: late, name: "Late", at: start + 5)
        XCTAssertTrue(game.players[late]!.isReady)
        XCTAssertTrue(game.players[late]!.isAlive)
        XCTAssertTrue(game.players[late]!.isShielded(at: start + 5))
        XCTAssertFalse(game.arena.blocks(center: game.players[late]!.position,
                                         radius: game.settings.tankRadius))
    }

    func testChangingModeIsRefusedMidRound() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        XCTAssertTrue(game.setMode(.ricochet))
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        game.tick(at: 100 + game.settings.countdownDuration)
        XCTAssertFalse(game.setMode(.skirmish))
        XCTAssertEqual(game.mode, .ricochet)
    }

    func testALongGapDoesNotTeleportAnything() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        let start = 100 + game.settings.countdownDuration
        game.tick(at: start)
        game.setControls(player: id, .forward, at: start)
        let before = game.players[id]!.position
        // The machine slept for two seconds. The tank must not jump 460 points.
        game.tick(at: start + 2)
        XCTAssertEqual(game.players[id]!.position, before)
    }

    func testTheClockReadsWhatIsLeft() {
        let game = makeGame()
        let id = addPlayers(game, 1)[0]
        XCTAssertNil(game.remaining(at: 100))
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        XCTAssertEqual(game.remaining(at: 101)!, game.settings.countdownDuration - 1, accuracy: 0.001)
    }
}
