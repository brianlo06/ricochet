import XCTest
@testable import RicochetCore

final class BotTests: XCTestCase {

    @discardableResult
    private func run(_ game: Game, from: TimeInterval, for seconds: Double,
                     holding: [UUID: Controls] = [:]) -> [Game.Event] {
        var events: [Game.Event] = []
        var t = from
        let end = from + seconds
        while t < end {
            t = min(t + 1.0 / 60, end)
            for (id, controls) in holding { game.setControls(player: id, controls, at: t) }
            events += game.tick(at: t)
        }
        return events
    }

    private func startRound(_ game: Game, at now: TimeInterval = 100) -> TimeInterval {
        for (id, p) in game.players where !p.isBot { _ = game.pullTrigger(player: id, at: now) }
        game.tick(at: now)
        let began = now + game.settings.countdownDuration
        game.tick(at: began)
        XCTAssertTrue(game.phase.isPlaying)
        return began
    }

    // MARK: Seats

    func testBotsOnlyTakeTheSeatsPeopleLeave() {
        let game = Game(seed: 1)
        game.seatLimit = 4
        let a = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.setBots(5, at: 0)
        XCTAssertEqual(game.botCount, 3, "one person leaves three seats")
        XCTAssertEqual(game.maxBots, 3)

        let b = UUID()
        game.addPlayer(id: b, name: "B", at: 0)
        XCTAssertEqual(game.botCount, 2, "a second person takes a bot's seat")
        XCTAssertEqual(game.players.count, 4)

        game.addPlayer(id: UUID(), name: "C", at: 0)
        game.addPlayer(id: UUID(), name: "D", at: 0)
        XCTAssertEqual(game.botCount, 0, "a full table has no bots")

        game.removePlayer(id: b)
        XCTAssertEqual(game.botCount, 1, "a seat freed goes back to a bot, since five were asked for")
    }

    func testAPersonJoiningAFullTableGetsTheHighestBotsSeat() {
        let game = Game(seed: 1)
        game.seatLimit = 2
        let a = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.setBots(1, at: 0)
        XCTAssertEqual(game.players.values.first { $0.isBot }?.seat, 1)
        let b = UUID()
        game.addPlayer(id: b, name: "B", at: 0)
        XCTAssertEqual(game.players[b]?.seat, 1)
        XCTAssertEqual(game.botCount, 0)
    }

    func testCyclingBotsWrapsToNone() {
        let game = Game(seed: 1)
        game.seatLimit = 4
        game.addPlayer(id: UUID(), name: "A", at: 0)
        XCTAssertEqual(game.cycleBots(at: 0), 1)
        XCTAssertEqual(game.cycleBots(at: 0), 2)
        XCTAssertEqual(game.cycleBots(at: 0), 3)
        XCTAssertEqual(game.cycleBots(at: 0), 0)
    }

    func testBotsNeedSomebodyToPlayWith() {
        let game = Game(seed: 1)
        game.setBots(3, at: 0)
        XCTAssertEqual(game.botCount, 0, "no people, no bots")
        let a = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        XCTAssertEqual(game.botCount, 3)
        game.removePlayer(id: a)
        XCTAssertEqual(game.botCount, 0)
        XCTAssertEqual(game.phase, .lobby)
    }

    func testBotsAreAlwaysReadyAndNeverHoldUpTheLobby() {
        let game = Game(seed: 1)
        let a = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.setBots(2, at: 0)
        game.tick(at: 100)
        XCTAssertEqual(game.phase, .lobby, "the person has not readied")
        _ = game.pullTrigger(player: a, at: 100)
        game.tick(at: 101)
        if case .countdown = game.phase {} else { XCTFail("bots should not be waited for") }
    }

    func testBotsHaveNamesAndDistinctColours() {
        let game = Game(seed: 1)
        game.addPlayer(id: UUID(), name: "A", at: 0)
        game.setBots(3, at: 0)
        let bots = game.players.values.filter(\.isBot)
        XCTAssertEqual(Set(bots.map(\.name)).count, 3)
        XCTAssertEqual(Set(bots.map(\.seat)).count, 3)
        XCTAssertTrue(Scoreboard.row(for: bots[0]).contains("bot"))
    }

    // MARK: Behaviour

    func testABotShootsATankItCanSee() {
        let arena = Arena(width: 1000, height: 600, walls: [],
                          spawns: [Vec2(x: 200, y: 300), Vec2(x: 700, y: 300)])
        let game = Game(arena: arena)
        let a = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.setBots(1, at: 0)
        let began = startRound(game)
        let events = run(game, from: began, for: 6)
        let bot = game.players.values.first { $0.isBot }!
        XCTAssertGreaterThan(bot.shots, 0, "the bot never fired")
        XCTAssertTrue(events.contains { if case .destroyed(a, .shell(bot.id), _) = $0 { return true }; return false },
                      "a stationary target in plain view should be hit inside six seconds")
    }

    func testABotFindsItsWayThroughAMaze() {
        // A fixed seed, so it is the same maze every time.
        let game = Game(mapPolicy: .fixed(.labyrinth), seed: 11)
        let a = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.setBots(1, at: 0)
        let began = startRound(game)
        let bot = game.players.values.first { $0.isBot }!
        let before = bot.position.distance(to: game.players[a]!.position)
        run(game, from: began, for: 12)
        let after = game.players[bot.id]!.position.distance(to: game.players[a]!.position)
        let hit = game.players[a]!.deaths > 0
        XCTAssertTrue(hit || after < before * 0.6,
                      "in twelve seconds the bot should have closed in (from \(Int(before)) to \(Int(after))) or scored")
    }

    func testABotDoesNotSitStill() {
        let game = Game(mapPolicy: .fixed(.crossfire), seed: 3)
        let a = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.setBots(1, at: 0)
        let began = startRound(game)
        let bot = game.players.values.first { $0.isBot }!
        let start = bot.position
        run(game, from: began, for: 3)
        XCTAssertGreaterThan(game.players[bot.id]!.position.distance(to: start), 100)
    }

    func testAReplayWithTheSameSeedAndInputsIsIdentical() {
        func play() -> [Vec2] {
            let game = Game(mapPolicy: .fixed(.pinball), seed: 77)
            let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            game.addPlayer(id: a, name: "A", at: 0)
            game.setBots(2, at: 0)
            let began = startRound(game)
            run(game, from: began, for: 5, holding: [a: [.forward, .left]])
            return game.players.values.sorted { $0.seat < $1.seat }.map(\.position)
        }
        XCTAssertEqual(play(), play())
    }
}
