import XCTest
@testable import RicochetCore

/// The guns: what they cost, what they do, and that each is worth more than the last.
final class WeaponTests: XCTestCase {

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
            for (id, c) in holding { game.setControls(player: id, c, at: t) }
            events += game.tick(at: t)
        }
        return events
    }

    /// Two tanks facing each other on an open field, the first with the given gun and
    /// the given score.
    private func duel(_ weapon: Weapon, points: Int? = nil, apart: Double = 500) -> (Game, UUID, UUID, TimeInterval) {
        let game = Game(arena: open([Vec2(x: 200, y: 300), Vec2(x: 200 + apart, y: 300)]))
        let a = UUID(), b = UUID()
        game.addPlayer(id: a, name: "A", at: 0, points: points ?? weapon.cost, weapon: weapon)
        game.addPlayer(id: b, name: "B", at: 0)
        let began = startRound(game)
        XCTAssertEqual(game.players[a]?.weapon, weapon)
        return (game, a, b, began)
    }

    // MARK: Cost and unlocking

    func testGunsCostFivePointsEachInOrderAndTheCannonIsFree() {
        XCTAssertEqual(Weapon.cannon.cost, 0)
        for (earlier, later) in zip(Weapon.allCases, Weapon.allCases.dropFirst()) {
            XCTAssertEqual(later.cost, earlier.cost + 5)
        }
        XCTAssertEqual(Weapon.allCases.count, 11)
        XCTAssertEqual(Weapon.unlocked(with: 0), [.cannon])
        XCTAssertEqual(Weapon.unlocked(with: 12).count, 3)
        XCTAssertEqual(Weapon.newlyUnlocked(at: 5), .scatter)
        XCTAssertNil(Weapon.newlyUnlocked(at: 6))
        XCTAssertEqual(Weapon.next(after: 7)?.weapon, .repeater)
        XCTAssertEqual(Weapon.next(after: 7)?.pointsToGo, 3)
    }

    func testAKillIsALifetimePointAndTheFifthUnlocksAGun() {
        let (game, a, b, began) = duel(.cannon, points: 4)
        _ = game.fire(player: a, at: began)
        let events = run(game, from: began, for: 1.5)
        XCTAssertEqual(game.players[a]?.lifetimePoints, 5)
        XCTAssertTrue(events.contains { if case .unlocked(a, .scatter) = $0 { return true }; return false })
        XCTAssertEqual(game.unlockedWeapons(for: a), [.cannon, .scatter])
        XCTAssertEqual(game.players[b]?.lifetimePoints, 0)
    }

    func testOwnGoalsAndBotsEarnNothing() {
        let game = Game(arena: open([Vec2(x: 200, y: 300)]))
        let a = UUID()
        game.addPlayer(id: a, name: "A", at: 0, points: 4)
        game.setBots(1, at: 0)
        let began = startRound(game)
        game.settings.shellBounces = 3
        _ = game.fire(player: a, at: began)
        run(game, from: began, for: 4)
        let bot = game.players.values.first { $0.isBot }!
        XCTAssertEqual(bot.lifetimePoints, 0, "bots keep no score")
        XCTAssertLessThanOrEqual(game.players[a]!.lifetimePoints, 4 + game.players[a]!.kills)
    }

    func testAWeaponYouHaveNotEarnedIsRefusedAndAPointsHistoryRestoresYourGun() {
        let game = Game(arena: open([Vec2(x: 200, y: 300)]))
        let a = UUID()
        game.addPlayer(id: a, name: "A", at: 0, points: 12, weapon: .railgun)
        XCTAssertEqual(game.players[a]?.weapon, .cannon, "the railgun costs 20; twelve points does not keep it")
        XCTAssertFalse(game.setWeapon(player: a, .railgun))
        XCTAssertTrue(game.setWeapon(player: a, .repeater))
        XCTAssertEqual(game.cycleWeapon(player: a), .cannon, "cycling wraps round")
        XCTAssertEqual(game.cycleWeapon(player: a), .scatter)
        let b = UUID()
        game.addPlayer(id: b, name: "B", at: 0, points: 25, weapon: .seeker)
        XCTAssertEqual(game.players[b]?.weapon, .seeker)
    }

    // MARK: Behaviour

    func testScatterFiresFivePelletsAsOneVolleyThatDieYoung() {
        let (game, a, _, began) = duel(.scatter, apart: 700)
        _ = game.fire(player: a, at: began)
        XCTAssertEqual(game.shells.count, 5)
        XCTAssertEqual(Set(game.shells.map(\.volley)).count, 1, "one press, one volley")
        XCTAssertEqual(game.fire(player: a, at: began + 0.01), .refused(.tooSoon))
        XCTAssertEqual(game.fire(player: a, at: began + 1.0), .refused(.outOfShells), "one volley in the air at a time")
        run(game, from: began, for: 1.5)
        XCTAssertTrue(game.shells.isEmpty, "pellets are gone well before they cross the field")
    }

    func testTheRepeaterFiresFastAndTheRailgunFiresOnce() {
        let (fast, a, _, began) = duel(.repeater)
        var fired = 0
        var t = began
        for _ in 0..<60 {
            if case .fired = fast.fire(player: a, at: t) { fired += 1 }
            t += 1.0 / 60
        }
        XCTAssertGreaterThanOrEqual(fired, 7, "a second of trigger should put a stream in the air")

        let (slow, s, _, began2) = duel(.railgun)
        if case .fired = slow.fire(player: s, at: began2) {} else { XCTFail() }
        XCTAssertEqual(slow.shells[0].velocity.length, Weapon.railgun.profile.shellSpeed, accuracy: 0.01)
        XCTAssertEqual(slow.fire(player: s, at: began2 + 0.5), .refused(.tooSoon))
    }

    func testTheBouncerComesOffFourWallsAndThePhantomGoesThroughThem() {
        var arena = open([Vec2(x: 200, y: 300), Vec2(x: 800, y: 300)])
        arena.walls = [Rect(minX: 480, minY: 0, maxX: 520, maxY: 600)]
        let game = Game(arena: arena)
        let a = UUID(), b = UUID()
        game.addPlayer(id: a, name: "A", at: 0, points: 50, weapon: .phantom)
        game.addPlayer(id: b, name: "B", at: 0)
        let began = startRound(game)
        _ = game.fire(player: a, at: began)
        let events = run(game, from: began, for: 2.5)
        XCTAssertTrue(events.contains { if case .destroyed(b, .shell(a), _) = $0 { return true }; return false },
                      "a phantom shell ignores the wall between them")

        let (bouncy, x, _, began2) = duel(.bouncer, apart: 300)
        _ = bouncy.fire(player: x, at: began2)
        XCTAssertEqual(bouncy.shells[0].bouncesLeft, 4)
    }

    func testASeekerTurnsTowardATankItWasNotAimedAt() {
        let game = Game(arena: open([Vec2(x: 200, y: 300), Vec2(x: 700, y: 480)]))
        let a = UUID(), b = UUID()
        game.addPlayer(id: a, name: "A", at: 0, points: 25, weapon: .seeker)
        game.addPlayer(id: b, name: "B", at: 0)
        let began = startRound(game)
        // A faces the centre, which is not where B is. The missile should find B anyway.
        _ = game.fire(player: a, at: began)
        let events = run(game, from: began, for: 3)
        XCTAssertTrue(events.contains { if case .destroyed(b, .shell(a), _) = $0 { return true }; return false })
    }

    func testAMortarGoesOffOnTheFirstThingItTouchesAndCatchesEveryoneNearby() {
        var arena = open([Vec2(x: 200, y: 300), Vec2(x: 560, y: 300), Vec2(x: 560, y: 380)])
        arena.walls = [Rect(minX: 600, minY: 0, maxX: 640, maxY: 600)]
        let game = Game(arena: arena)
        let a = UUID(), b = UUID(), c = UUID()
        game.addPlayer(id: a, name: "A", at: 0, points: 35, weapon: .mortar)
        game.addPlayer(id: b, name: "B", at: 0)
        game.addPlayer(id: c, name: "C", at: 0)
        let began = startRound(game)
        _ = game.fire(player: a, at: began)
        let events = run(game, from: began, for: 2)
        XCTAssertTrue(events.contains { if case .exploded = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .destroyed(b, .shell(a), _) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .destroyed(c, .shell(a), _) = $0 { return true }; return false },
                      "C was beside B, inside the blast")
        XCTAssertEqual(game.players[a]?.kills, 2)
    }

    func testAMineWaitsIgnoresItsOwnerAndGoesOffForAnyoneElse() {
        let game = Game(arena: open([Vec2(x: 500, y: 300), Vec2(x: 900, y: 300)]))
        let a = UUID(), b = UUID()
        game.addPlayer(id: a, name: "A", at: 0, points: 45, weapon: .minelayer)
        game.addPlayer(id: b, name: "B", at: 0)
        let began = startRound(game)
        _ = game.fire(player: a, at: began)
        XCTAssertEqual(game.shells.count, 1)
        let mine = game.shells[0]
        XCTAssertEqual(mine.velocity, .zero)
        XCTAssertLessThan(mine.position.x, 500, "dropped behind a tank facing the centre, to its right")

        // The owner reverses over it: nothing.
        run(game, from: began, for: 1.5, holding: [a: .reverse])
        XCTAssertTrue(game.players[a]!.isAlive)
        XCTAssertEqual(game.shells.count, 1)

        // B drives across the field and onto it.
        var t = began + 1.5
        var events: [Game.Event] = []
        while t < began + 8, game.shells.count == 1 {
            t += 1.0 / 60
            game.setControls(player: b, .forward, at: t)
            events += game.tick(at: t)
        }
        XCTAssertTrue(events.contains { if case .destroyed(b, .shell(a), _) = $0 { return true }; return false },
                      "B should have driven into the mine")
    }

    func testNovaFiresARingAndAVolleyFiresThree() {
        let (nova, a, _, began) = duel(.nova)
        _ = nova.fire(player: a, at: began)
        XCTAssertEqual(nova.shells.count, 8)
        let headings = Set(nova.shells.map { Int(($0.velocity.heading * 180 / .pi).rounded()) })
        XCTAssertEqual(headings.count, 8, "eight distinct directions")
        let (volley, v, _, began2) = duel(.volley)
        _ = volley.fire(player: v, at: began2)
        XCTAssertEqual(volley.shells.count, 3)
        XCTAssertTrue(volley.shells.allSatisfy { $0.bouncesLeft == 1 })
    }

    /// Each gun should be worth its price. For the guns that fire straight, measured the
    /// one way that is fair to all of them: a stationary target in the open at a middling
    /// distance, time to first kill, trigger held. None may be slower than the cannon.
    /// The rest earn their price with something other than a straight shot — homing,
    /// splash, a fan, mines — and each is checked for that above.
    func testEveryDirectFireGunKillsAtLeastAsFastAsTheCannon() {
        func timeToKill(_ weapon: Weapon) -> Double {
            let (game, a, b, began) = duel(weapon, apart: 420)
            var t = began
            while t < began + 8 {
                t += 1.0 / 60
                _ = game.fire(player: a, at: t)
                let events = game.tick(at: t)
                if events.contains(where: { if case .destroyed(b, _, _) = $0 { return true }; return false }) {
                    return t - began
                }
            }
            return .infinity
        }
        let cannon = timeToKill(.cannon)
        XCTAssertLessThan(cannon, 8)
        for weapon in [Weapon.repeater, .railgun, .volley, .phantom] {
            XCTAssertLessThanOrEqual(timeToKill(weapon), cannon + 0.05, "\(weapon) is slower to a kill than the cannon")
        }
    }
}
