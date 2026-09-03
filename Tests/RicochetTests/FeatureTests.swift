import XCTest
@testable import RicochetCore

/// The things a map can do to you, each on a purpose-built arena.
final class FeatureTests: XCTestCase {

    private func open(_ spawns: [Vec2]) -> Arena {
        Arena(width: 1000, height: 600, walls: [], spawns: spawns)
    }

    @discardableResult
    private func startRound(_ game: Game, at now: TimeInterval = 100) -> TimeInterval {
        for (id, p) in game.players where !p.isBot { _ = game.pullTrigger(player: id, at: now) }
        game.tick(at: now)
        let began = now + game.settings.countdownDuration
        game.tick(at: began)
        XCTAssertTrue(game.phase.isPlaying)
        return began
    }

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

    func testABumperReflectsAShellWithoutCostingABounce() {
        var arena = open([Vec2(x: 200, y: 300)])
        arena.bumpers = [Bumper(center: Vec2(x: 600, y: 300), radius: 50)]
        let game = Game(arena: arena)
        game.settings.shellBounces = 0
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        guard case .fired(let shellID) = game.fire(player: id, at: began) else { return XCTFail() }
        let events = run(game, from: began, for: 0.9)
        XCTAssertTrue(events.contains { if case .bounced(shellID, _) = $0 { return true }; return false })
        let shell = game.shells.first { $0.id == shellID }
        XCTAssertNotNil(shell, "a bumper does not spend the shell's bounces")
        XCTAssertLessThan(shell!.velocity.x, 0, "it should be coming back")
    }

    func testAShellBreaksABrickAndIsSpentOnIt() {
        var arena = open([Vec2(x: 200, y: 300)])
        arena.bricks = [Rect(minX: 500, minY: 250, maxX: 550, maxY: 350)]
        let game = Game(arena: arena)
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        _ = game.fire(player: id, at: began)
        let events = run(game, from: began, for: 1)
        XCTAssertTrue(events.contains { if case .brickBroken = $0 { return true }; return false })
        XCTAssertTrue(game.arena.bricks.isEmpty)
        XCTAssertTrue(game.shells.isEmpty)
    }

    func testBricksComeBackForTheNextRound() {
        var arena = open([Vec2(x: 200, y: 300)])
        arena.bricks = [Rect(minX: 500, minY: 250, maxX: 550, maxY: 350)]
        let game = Game(arena: arena)
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        _ = game.fire(player: id, at: began)
        run(game, from: began, for: 1)
        XCTAssertTrue(game.arena.bricks.isEmpty)
        game.tick(at: began + game.settings.roundDuration)
        game.tick(at: began + game.settings.roundDuration + game.settings.resultsDuration)
        startRound(game, at: began + game.settings.roundDuration + game.settings.resultsDuration + 1)
        XCTAssertEqual(game.arena.bricks.count, 1)
    }

    func testAConveyorCarriesAStandingTank() {
        var arena = open([Vec2(x: 300, y: 300)])
        arena.conveyors = [Conveyor(rect: Rect(minX: 0, minY: 200, maxX: 1000, maxY: 400), push: Vec2(x: 100, y: 0))]
        let game = Game(arena: arena)
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        run(game, from: began, for: 1)
        XCTAssertEqual(game.players[id]!.position.x, 400, accuracy: 3)
    }

    func testAPortalMovesAShellAndATank() {
        var arena = open([Vec2(x: 200, y: 300)])
        arena.portals = [Portal(a: Vec2(x: 400, y: 300), b: Vec2(x: 800, y: 100), radius: 30)]
        let game = Game(arena: arena)
        // No bounces: with one, the shell came off the far wall, went back through the
        // other end of the portal and destroyed the tank that fired it. Which is correct,
        // and not what this test is about.
        game.settings.shellBounces = 0
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        _ = game.fire(player: id, at: began)
        var events = run(game, from: began, for: 0.5)
        XCTAssertTrue(events.contains { if case .teleported = $0 { return true }; return false })
        XCTAssertGreaterThan(game.shells[0].position.x, 800, "the shell carries on from the other end")

        events = run(game, from: began + 0.5, for: 1.2, holding: [id: .forward])
        XCTAssertTrue(events.contains { if case .teleported = $0 { return true }; return false })
        XCTAssertGreaterThan(game.players[id]!.position.x, 800)
    }

    func testAClosedGateStopsATankAndAnOpenOneDoesNot() {
        var arena = open([Vec2(x: 200, y: 300)])
        arena.gates = [Gate(rect: Rect(minX: 400, minY: 0, maxX: 430, maxY: 600), period: 100, openFor: 50, phase: 0)]
        let game = Game(arena: arena)
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        // Open for the first fifty seconds of the arena's clock, which began with the round.
        run(game, from: began, for: 2, holding: [id: .forward])
        XCTAssertGreaterThan(game.players[id]!.position.x, 450, "an open gate is a doorway")

        let closed = Game(arena: arena)
        let other = UUID()
        closed.addPlayer(id: other, name: "B", at: 0)
        let began2 = startRound(closed)
        // Skip the arena clock past the open half: drive later.
        run(closed, from: began2, for: 51)
        run(closed, from: began2 + 51, for: 2, holding: [other: .forward])
        XCTAssertLessThan(closed.players[other]!.position.x, 400 - closed.settings.tankRadius + 1,
                          "a closed gate is a wall")
    }

    func testASweeperPushesATankAndCrushesOneAgainstAWall() {
        var arena = open([Vec2(x: 500, y: 300)])
        // Travels to within ten points of the far border: less than a tank's width.
        arena.sweepers = [Sweeper(home: Rect(minX: 100, minY: 0, maxX: 130, maxY: 600),
                                  travel: Vec2(x: 860, y: 0), period: 8)]
        let game = Game(arena: arena)
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        // The bar reaches x=500 after 2s and carries the tank to the right wall by 4s.
        let events = run(game, from: began, for: 4.2)
        XCTAssertTrue(events.contains { if case .destroyed(id, .crushed, _) = $0 { return true }; return false },
                      "pinned against the border, the tank is crushed")
        XCTAssertEqual(game.players[id]?.deaths, 1)
    }

    func testDrivingIntoAPitIsFatalAndShellsFlyOverIt() {
        var arena = open([Vec2(x: 200, y: 300), Vec2(x: 800, y: 300)])
        arena.pits = [Rect(minX: 450, minY: 0, maxX: 550, maxY: 600)]
        let game = Game(arena: arena)
        let a = UUID(), b = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.addPlayer(id: b, name: "B", at: 0)
        let began = startRound(game)
        _ = game.fire(player: a, at: began)
        var events = run(game, from: began, for: 1.5)
        XCTAssertTrue(events.contains { if case .destroyed(b, .shell(a), _) = $0 { return true }; return false },
                      "the shell crossed the pit")
        events = run(game, from: began + 1.5, for: 2, holding: [a: .forward])
        XCTAssertTrue(events.contains { if case .destroyed(a, .pit, _) = $0 { return true }; return false })
    }

    func testHazardsOutsideARoundCostNothing() {
        var arena = open([Vec2(x: 200, y: 300)])
        arena.pits = [Rect(minX: 300, minY: 0, maxX: 400, maxY: 600)]
        let game = Game(arena: arena)
        game.setMode(.lastStanding)
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        game.tick(at: 100)
        let events = run(game, from: 100, for: 1.5, holding: [id: .forward])
        XCTAssertTrue(events.contains { if case .destroyed(id, .pit, _) = $0 { return true }; return false })
        XCTAssertEqual(game.players[id]?.deaths, 0)
        XCTAssertFalse(game.players[id]!.isEliminated)
        run(game, from: 101.5, for: game.settings.respawnDelay + 0.5)
        XCTAssertTrue(game.players[id]!.isAlive, "and the tank comes back")
    }
}
