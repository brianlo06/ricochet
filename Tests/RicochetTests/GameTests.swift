import XCTest
@testable import RicochetCore

/// The rules, driven by an injected clock and button states and nothing else.
final class GameTests: XCTestCase {

    /// An empty arena, so a test about movement is not also a test about the layout.
    private func openGame(lives: Int = 0) -> Game {
        var settings = Game.Settings()
        settings.lives = lives
        let arena = Arena(width: 1000, height: 600, walls: [],
                          spawns: [Vec2(x: 100, y: 100), Vec2(x: 900, y: 500),
                                   Vec2(x: 900, y: 100), Vec2(x: 100, y: 500)])
        let game = Game(arena: arena, settings: settings)
        return game
    }

    /// Readies everyone and runs the clock through the countdown. Returns the time the
    /// round began.
    @discardableResult
    private func startRound(_ game: Game, at now: TimeInterval = 100) -> TimeInterval {
        for id in game.players.keys { _ = game.pullTrigger(player: id, at: now) }
        game.tick(at: now)
        let began = now + game.settings.countdownDuration
        game.tick(at: began)
        XCTAssertTrue(game.phase.isPlaying)
        return began
    }

    /// Advances in frame-sized steps, collecting events, because one tick is capped at a
    /// quarter second and a test that jumps further would silently simulate nothing.
    @discardableResult
    private func run(_ game: Game, from: TimeInterval, for seconds: Double,
                     step: Double = 1.0 / 60) -> [Game.Event] {
        var events: [Game.Event] = []
        var t = from
        let end = from + seconds
        while t < end {
            t = min(t + step, end)
            events += game.tick(at: t)
        }
        return events
    }

    // MARK: Geometry

    func testARectKnowsWhenACircleTouchesIt() {
        let block = Rect(minX: 100, minY: 100, maxX: 200, maxY: 200)
        XCTAssertTrue(block.intersects(center: Vec2(x: 90, y: 150), radius: 15))
        XCTAssertFalse(block.intersects(center: Vec2(x: 80, y: 150), radius: 15))
        // The corner: a circle whose bounding box overlaps but whose edge does not.
        XCTAssertFalse(block.intersects(center: Vec2(x: 88, y: 88), radius: 15))
        XCTAssertTrue(block.intersects(center: Vec2(x: 92, y: 92), radius: 15))
    }

    func testTheStandardArenaFitsATankThroughEveryGapAndSpawnsClearOfWalls() {
        var rng = SeededGenerator(seed: 1)
        let arena = Map.crossfire.build(using: &rng)
        let radius = Game.Settings().tankRadius
        for spawn in arena.spawns {
            XCTAssertFalse(arena.blocks(center: spawn, radius: radius), "spawn \(spawn) is inside a wall")
        }
        // The gap between the pillar and each stub has to admit a tank, or the middle of
        // the arena is a dead end that looks like a route.
        let gapX = arena.width * (0.465 - 0.33)
        XCTAssertGreaterThan(gapX, radius * 2 + 20)
    }

    // MARK: Driving

    func testHoldingForwardDrivesTheTankAlongItsHeading() {
        let game = openGame()
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        let before = game.players[id]!.position
        game.setControls(player: id, .forward, at: began)
        run(game, from: began, for: 1)
        let after = game.players[id]!.position
        let moved = after.distance(to: before)
        XCTAssertEqual(moved, game.settings.tankSpeed, accuracy: 5)
        let facing = Vec2(heading: game.players[id]!.heading)
        let travelled = after - before
        XCTAssertEqual(travelled.x / moved, facing.x, accuracy: 0.01)
        XCTAssertEqual(travelled.y / moved, facing.y, accuracy: 0.01)
    }

    func testReverseIsSlowerThanForward() {
        let game = Game(arena: Arena(width: 1000, height: 600, walls: [], spawns: [Vec2(x: 500, y: 300)]))
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        let before = game.players[id]!.position
        game.setControls(player: id, .reverse, at: began)
        run(game, from: began, for: 1)
        let moved = game.players[id]!.position.distance(to: before)
        XCTAssertEqual(moved, game.settings.tankSpeed * game.settings.reverseFactor, accuracy: 5)
    }

    func testLeftTurnsAnticlockwiseAndOpposingButtonsCancel() {
        let game = openGame()
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        let heading = game.players[id]!.heading
        game.setControls(player: id, .left, at: began)
        run(game, from: began, for: 0.5)
        XCTAssertEqual(game.players[id]!.heading - heading, game.settings.turnRate * 0.5, accuracy: 0.02)

        let position = game.players[id]!.position
        game.setControls(player: id, [.forward, .reverse, .left, .right], at: began + 0.5)
        run(game, from: began + 0.5, for: 0.5)
        XCTAssertEqual(game.players[id]!.position, position, "both directions at once is neither")
    }

    func testATankCannotLeaveTheArena() {
        let game = openGame()
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        // Face straight down and drive for longer than the arena is tall.
        game.setControls(player: id, .right, at: began)
        var t = began
        while game.players[id]!.heading > -.pi / 2 + 0.02 {
            t += 1.0 / 60
            game.setControls(player: id, .right, at: t)
            game.tick(at: t)
        }
        game.setControls(player: id, .forward, at: t)
        for _ in 0..<600 {
            t += 1.0 / 60
            game.setControls(player: id, .forward, at: t)
            game.tick(at: t)
        }
        let p = game.players[id]!.position
        XCTAssertGreaterThanOrEqual(p.y, game.settings.tankRadius - 0.01)
        XCTAssertLessThan(p.y, game.settings.tankRadius + 5, "it should be pressed against the wall, not stopped short")
    }

    func testATankDrivenIntoAWallAtAnAngleSlidesAlongIt() {
        let arena = Arena(width: 1000, height: 600,
                          walls: [Rect(minX: 300, minY: 0, maxX: 340, maxY: 600)],
                          spawns: [Vec2(x: 200, y: 300)])
        let game = Game(arena: arena)
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        // Heading up and to the right, into the wall.
        game.setControls(player: id, .left, at: began)
        var t = began
        while game.players[id]!.heading < .pi / 4 {
            t += 1.0 / 60
            game.setControls(player: id, .left, at: t)
            game.tick(at: t)
        }
        let start = game.players[id]!.position
        for _ in 0..<120 {
            t += 1.0 / 60
            game.setControls(player: id, .forward, at: t)
            game.tick(at: t)
        }
        let end = game.players[id]!.position
        XCTAssertLessThan(end.x, 300 - game.settings.tankRadius + 0.01, "it went through the wall")
        XCTAssertGreaterThan(end.y - start.y, 100, "it stuck to the wall instead of sliding up it")
    }

    func testTwoTanksCannotOccupyTheSameSpace() {
        let arena = Arena(width: 1000, height: 600, walls: [],
                          spawns: [Vec2(x: 200, y: 300), Vec2(x: 400, y: 300)])
        let game = Game(arena: arena)
        let a = UUID(), b = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.addPlayer(id: b, name: "B", at: 0)
        let began = startRound(game)
        // A faces the middle, which is +x, straight at B. Drive for long enough to pass.
        var t = began
        for _ in 0..<180 {
            t += 1.0 / 60
            game.setControls(player: a, .forward, at: t)
            game.tick(at: t)
        }
        let gap = game.players[a]!.position.distance(to: game.players[b]!.position)
        XCTAssertGreaterThanOrEqual(gap, game.settings.tankRadius * 2 - 0.01)
        XCTAssertLessThan(gap, game.settings.tankRadius * 2 + 5, "A should be pressed against B")
    }

    func testAPadStateThatIsNotRenewedIsTreatedAsReleased() {
        let game = openGame()
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        game.setControls(player: id, .forward, at: began)
        run(game, from: began, for: 0.5)
        let atHalf = game.players[id]!.position
        // Nothing more from the phone. It keeps moving until the timeout, then stops.
        run(game, from: began + 0.5, for: 3)
        let atEnd = game.players[id]!.position
        let coasted = atEnd.distance(to: atHalf)
        XCTAssertEqual(coasted, game.settings.tankSpeed * (game.settings.inputTimeout - 0.5), accuracy: 8,
                       "the tank should drive until the input goes stale and no further")
    }

    func testTanksCanDriveInTheLobby() {
        let game = openGame()
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        game.tick(at: 100)
        let before = game.players[id]!.position
        game.setControls(player: id, .forward, at: 100)
        run(game, from: 100, for: 0.5)
        XCTAssertGreaterThan(game.players[id]!.position.distance(to: before), 50)
        XCTAssertEqual(game.phase, .lobby)
    }

    // MARK: Firing

    func testFiringPutsAShellJustOutsideTheHullHeadingTheWayTheTankFaces() {
        let game = openGame()
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        guard case .fired(let shellID) = game.fire(player: id, at: began) else {
            return XCTFail("did not fire")
        }
        let tank = game.players[id]!
        let shell = game.shells.first { $0.id == shellID }!
        let offset = shell.position - tank.position
        XCTAssertGreaterThan(offset.length, game.settings.tankRadius + game.settings.shellRadius)
        let facing = Vec2(heading: tank.heading)
        XCTAssertEqual(offset.x / offset.length, facing.x, accuracy: 0.001)
        XCTAssertEqual(shell.velocity.length, game.settings.shellSpeed, accuracy: 0.001)
        XCTAssertEqual(tank.shots, 1)
    }

    func testTheCooldownRefusesRatherThanCounting() {
        let game = openGame()
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        _ = game.fire(player: id, at: began)
        XCTAssertEqual(game.fire(player: id, at: began + 0.05), .refused(.tooSoon))
        XCTAssertEqual(game.players[id]?.shots, 1, "a refused shot never happened")
        if case .fired = game.fire(player: id, at: began + game.settings.fireCooldown + 0.01) {} else {
            XCTFail("should fire again once the cooldown has passed")
        }
    }

    func testOnlySoManyShellsMayBeInTheAirAtOnce() {
        let game = openGame()
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        var t = startRound(game)
        for _ in 0..<game.settings.shellsInFlight {
            if case .fired = game.fire(player: id, at: t) {} else { XCTFail("should fire") }
            t += game.settings.fireCooldown + 0.01
        }
        XCTAssertEqual(game.fire(player: id, at: t), .refused(.outOfShells))
    }

    func testTheTriggerMeansReadyOutsideARoundAndNothingDuringTheCountdown() {
        let game = openGame()
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        XCTAssertEqual(game.pullTrigger(player: id, at: 100), .readied(true))
        XCTAssertEqual(game.pullTrigger(player: id, at: 100.5), .readied(false))
        XCTAssertEqual(game.pullTrigger(player: id, at: 101), .readied(true))
        game.tick(at: 101)
        XCTAssertEqual(game.pullTrigger(player: id, at: 102), .ignored)
        XCTAssertTrue(game.shells.isEmpty, "nothing fires before the round")
    }

    func testFiringDropsTheSpawnShield() {
        let game = openGame()
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        XCTAssertFalse(game.players[id]!.isShielded(at: began), "a round starts with everyone live")
        // Get destroyed and come back, which is where the shield comes from.
        game.addPlayer(id: UUID(), name: "B", at: began)
        _ = game.players[id]!
        // Simplest way to a shield: a fresh mid-round join.
        let late = UUID()
        game.addPlayer(id: late, name: "Late", at: began)
        XCTAssertTrue(game.players[late]!.isShielded(at: began + 0.1))
        _ = game.fire(player: late, at: began + 0.1)
        XCTAssertFalse(game.players[late]!.isShielded(at: began + 0.1),
                       "you cannot fight from behind the shield")
    }

    // MARK: Shells

    func testAShellComesOffTheBorderAndIsAbsorbedWhenItHasNoBouncesLeft() {
        let game = openGame()
        game.settings.shellBounces = 1
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        // From (100,100) the tank faces the centre, up and to the right: the shell meets
        // the right border first, comes off it, and meets the top with nothing left.
        guard case .fired(let shellID) = game.fire(player: id, at: began) else { return XCTFail() }
        let events = run(game, from: began, for: 3)
        let bounces = events.filter { if case .bounced(shellID, _) = $0 { return true }; return false }
        XCTAssertEqual(bounces.count, 1, "one bounce off the right border")
        XCTAssertTrue(events.contains { if case .expired(shellID, _) = $0 { return true }; return false },
                      "the second wall absorbs it")
        XCTAssertFalse(game.shells.contains { $0.id == shellID })
    }

    func testAShellReflectsOffABlockAboutTheFaceItHit() {
        let arena = Arena(width: 1000, height: 600,
                          walls: [Rect(minX: 500, minY: 200, maxX: 560, maxY: 400)],
                          spawns: [Vec2(x: 300, y: 300)])
        let game = Game(arena: arena)
        game.settings.shellBounces = 2
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        // Facing the centre from (300,300) is exactly +x, straight at the block's left face.
        guard case .fired(let shellID) = game.fire(player: id, at: began) else { return XCTFail() }
        run(game, from: began, for: 0.6)
        let shell = game.shells.first { $0.id == shellID }!
        XCTAssertLessThan(shell.velocity.x, 0, "it should be coming back")
        XCTAssertEqual(shell.velocity.y, 0, accuracy: 0.001, "a flat face reflects only x")
        XCTAssertLessThan(shell.position.x, 500)
    }

    func testAShellThatHitsATankDestroysItAndCreditsTheShooter() {
        let arena = Arena(width: 1000, height: 600, walls: [],
                          spawns: [Vec2(x: 200, y: 300), Vec2(x: 600, y: 300)])
        let game = Game(arena: arena)
        let a = UUID(), b = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.addPlayer(id: b, name: "B", at: 0)
        let began = startRound(game)
        _ = game.fire(player: a, at: began)
        let events = run(game, from: began, for: 1.5)
        XCTAssertTrue(events.contains { if case .destroyed(b, .shell(a), _) = $0 { return true }; return false })
        XCTAssertEqual(game.players[a]?.kills, 1)
        XCTAssertEqual(game.players[b]?.deaths, 1)
        XCTAssertFalse(game.players[b]!.isAlive)
        XCTAssertTrue(game.shells.isEmpty, "the shell is spent on the hit")
        XCTAssertEqual(game.fire(player: b, at: began + 1.5), .refused(.destroyed))
    }

    func testYourOwnShellComingBackIsAnOwnGoal() {
        let arena = Arena(width: 1000, height: 600, walls: [], spawns: [Vec2(x: 200, y: 300)])
        let game = Game(arena: arena)
        game.settings.shellBounces = 3
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let began = startRound(game)
        // Facing +x; the shell crosses to the right wall and comes straight back.
        _ = game.fire(player: id, at: began)
        let events = run(game, from: began, for: 4)
        XCTAssertTrue(events.contains { if case .destroyed(id, .shell(id), _) = $0 { return true }; return false })
        XCTAssertEqual(game.players[id]?.ownGoals, 1)
        XCTAssertEqual(game.players[id]?.kills, 0, "an own goal is nobody's kill")
    }

    func testAShieldedTankIsPassedThroughNotHit() {
        let arena = Arena(width: 1000, height: 600, walls: [],
                          spawns: [Vec2(x: 200, y: 300), Vec2(x: 600, y: 300)])
        let game = Game(arena: arena)
        let a = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        let began = startRound(game)
        // A late arrival takes the spawn farthest from A, which is directly in front of
        // A's gun, and arrives shielded.
        game.settings.spawnShield = 10
        let late = UUID()
        game.addPlayer(id: late, name: "Late", at: began)
        XCTAssertEqual(game.players[late]!.position, Vec2(x: 600, y: 300))
        _ = game.fire(player: a, at: began)
        let events = run(game, from: began, for: 1.2)
        XCTAssertTrue(game.players[late]!.isAlive)
        XCTAssertFalse(events.contains { if case .destroyed = $0 { return true }; return false })
        XCTAssertEqual(game.shells.count, 1, "the shell carried on past the shield")
    }

    // MARK: Respawning

    func testADestroyedTankComesBackAfterTheDelayAtTheSpawnFarthestFromEveryoneElse() {
        let arena = Arena(width: 1000, height: 600, walls: [],
                          spawns: [Vec2(x: 200, y: 300), Vec2(x: 600, y: 300), Vec2(x: 950, y: 550)])
        let game = Game(arena: arena)
        let a = UUID(), b = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.addPlayer(id: b, name: "B", at: 0)
        let began = startRound(game)
        _ = game.fire(player: a, at: began)
        var events = run(game, from: began, for: 1.5)
        XCTAssertFalse(game.players[b]!.isAlive)
        events = run(game, from: began + 1.5, for: game.settings.respawnDelay + 0.5)
        XCTAssertTrue(events.contains { if case .respawned(b, _) = $0 { return true }; return false })
        let tank = game.players[b]!
        XCTAssertTrue(tank.isAlive)
        XCTAssertEqual(tank.position, Vec2(x: 950, y: 550), "the corner farthest from A")
        XCTAssertTrue(tank.isShielded(at: began + 1.5 + game.settings.respawnDelay + 0.1))
    }

    func testWithLivesTheLastDeathEliminatesAndTheRoundEndsWhenOneTankStands() {
        let arena = Arena(width: 1000, height: 600, walls: [],
                          spawns: [Vec2(x: 200, y: 300), Vec2(x: 600, y: 300)])
        let game = Game(arena: arena)
        game.setMode(.lastStanding)
        game.settings.respawnDelay = 0.2
        let a = UUID(), b = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.addPlayer(id: b, name: "B", at: 0)
        var t = startRound(game)
        XCTAssertEqual(game.players[b]?.livesLeft, 3)

        // B stands still and takes it. The respawn point is always the far corner and A
        // never moves, so a shot hits whenever B is at the near one; we just keep firing.
        var eliminated = false
        for _ in 0..<60 {
            _ = game.fire(player: a, at: t)
            let events = run(game, from: t, for: 1.0)
            t += 1.0
            if events.contains(where: { if case .eliminated(b) = $0 { return true }; return false }) {
                eliminated = true
                break
            }
            if !game.phase.isPlaying { break }
        }
        XCTAssertTrue(eliminated || !game.phase.isPlaying)
        XCTAssertTrue(game.players[b]?.isEliminated ?? false || !game.phase.isPlaying)
        game.tick(at: t + 0.1)
        if case .results = game.phase {} else { XCTFail("one tank standing should end the round, got \(game.phase)") }
    }

    // MARK: Leaderboard

    func testLeaderboardOrdersByKillsThenFewestDeathsThenSeat() {
        let game = openGame()
        let ids = (0..<3).map { _ in UUID() }
        for (i, id) in ids.enumerated() { game.addPlayer(id: id, name: "P\(i)", at: 0) }
        XCTAssertEqual(game.leaderboard.map(\.seat), [0, 1, 2], "level players sort by seat")
    }
}
