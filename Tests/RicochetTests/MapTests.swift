import XCTest
@testable import RicochetCore

/// Every map, checked the same way: nothing off the edge, every spawn clear, and every
/// spawn reachable from every other with a tank's radius. The last is the one that
/// matters for the maze, where a generator bug would strand a seat behind a wall.
final class MapTests: XCTestCase {

    private let radius = Game.Settings().tankRadius

    private func build(_ map: Map, seed: UInt64) -> Arena {
        var rng = SeededGenerator(seed: seed)
        return map.build(using: &rng)
    }

    func testEveryMapHasATitleAndASummary() {
        for map in Map.allCases {
            XCTAssertFalse(map.title.isEmpty)
            XCTAssertFalse(map.summary.isEmpty)
        }
        XCTAssertEqual(Map.allCases.count, 10)
    }

    func testEverythingSolidIsInsideTheArena() {
        for map in Map.allCases {
            for seed in 1...3 as ClosedRange<UInt64> {
                let arena = build(map, seed: seed)
                let solids = arena.solids(at: 0) + arena.pits + arena.conveyors.map(\.rect)
                    + arena.sweepers.map { $0.rect(at: $0.period / 2) }
                for rect in solids {
                    XCTAssertGreaterThanOrEqual(rect.minX, -1, "\(map) has a block off the left")
                    XCTAssertGreaterThanOrEqual(rect.minY, -1, "\(map) has a block off the bottom")
                    XCTAssertLessThanOrEqual(rect.maxX, arena.width + 1, "\(map) has a block off the right")
                    XCTAssertLessThanOrEqual(rect.maxY, arena.height + 1, "\(map) has a block off the top")
                }
            }
        }
    }

    func testEveryMapHasAtLeastEightSpawnsAndAllAreClear() {
        for map in Map.allCases {
            for seed in 1...3 as ClosedRange<UInt64> {
                let arena = build(map, seed: seed)
                XCTAssertGreaterThanOrEqual(arena.spawns.count, 8, "\(map)")
                for spawn in arena.spawns {
                    XCTAssertFalse(arena.blocks(center: spawn, radius: radius, at: 0),
                                   "\(map) seed \(seed): spawn \(spawn) is inside something")
                    XCTAssertFalse(arena.pits.contains { $0.contains(spawn) },
                                   "\(map) seed \(seed): spawn \(spawn) is over a pit")
                }
            }
        }
    }

    func testEverySpawnCanReachEveryOtherOnEveryMap() {
        for map in Map.allCases {
            for seed in 1...5 as ClosedRange<UInt64> {
                let arena = build(map, seed: seed)
                // Gates count as open and sweepers as absent: both move out of the way.
                let grid = NavGrid(arena: arena, solids: arena.walls + arena.bricks, radius: radius)
                for (i, from) in arena.spawns.enumerated() {
                    for to in arena.spawns.dropFirst(i + 1) {
                        XCTAssertFalse(grid.path(from: from, to: to).isEmpty,
                                       "\(map) seed \(seed): no route from \(from) to \(to)")
                    }
                }
            }
        }
    }

    func testTheMazeIsDifferentWithADifferentSeedAndTheSameWithTheSame() {
        XCTAssertNotEqual(build(.labyrinth, seed: 1).walls, build(.labyrinth, seed: 2).walls)
        XCTAssertEqual(build(.labyrinth, seed: 7).walls, build(.labyrinth, seed: 7).walls)
    }

    func testTheMazeHasLoops() {
        // A perfect maze on 8×5 cells has exactly 39 openings; loops mean fewer walls.
        let arena = build(.labyrinth, seed: 3)
        let interiorWalls = 7 * 5 + 8 * 4
        XCTAssertLessThan(arena.walls.count, interiorWalls - 39,
                          "a maze with a single route between any two points is a corridor chase")
    }

    func testEachMapHasTheFeatureItIsNamedFor() {
        XCTAssertFalse(build(.pinball, seed: 1).bumpers.isEmpty)
        XCTAssertFalse(build(.crumble, seed: 1).bricks.isEmpty)
        XCTAssertFalse(build(.currents, seed: 1).conveyors.isEmpty)
        XCTAssertFalse(build(.portals, seed: 1).portals.isEmpty)
        XCTAssertFalse(build(.shutters, seed: 1).gates.isEmpty)
        XCTAssertFalse(build(.sweeper, seed: 1).sweepers.isEmpty)
        XCTAssertFalse(build(.chasm, seed: 1).pits.isEmpty)
        XCTAssertGreaterThan(build(.labyrinth, seed: 1).walls.count, 12)
    }

    func testAGateIsOpenForItsShareOfEachCycleAndASweeperComesBack() {
        let gate = Gate(rect: Rect(minX: 0, minY: 0, maxX: 10, maxY: 10), period: 6, openFor: 2, phase: 0)
        XCTAssertTrue(gate.isOpen(at: 0))
        XCTAssertTrue(gate.isOpen(at: 1.9))
        XCTAssertFalse(gate.isOpen(at: 2.1))
        XCTAssertTrue(gate.isOpen(at: 6.5))
        XCTAssertEqual(gate.timeUntilChange(at: 1), 1, accuracy: 0.001)

        let sweeper = Sweeper(home: Rect(minX: 0, minY: 0, maxX: 10, maxY: 10), travel: Vec2(x: 100, y: 0), period: 4)
        XCTAssertEqual(sweeper.rect(at: 0), sweeper.home)
        XCTAssertEqual(sweeper.rect(at: 2).minX, 100, accuracy: 0.001)
        XCTAssertEqual(sweeper.rect(at: 4).minX, 0, accuracy: 0.001)
        XCTAssertGreaterThan(sweeper.velocity(at: 1).x, 0)
        XCTAssertLessThan(sweeper.velocity(at: 3).x, 0)
    }

    func testARandomGameNeverPlaysTheSameMapTwiceRunning() {
        let game = Game(seed: 42)
        var seen: [Map] = [game.map!]
        for _ in 0..<30 {
            game.reshuffleMap()
            XCTAssertNotEqual(game.map, seen.last)
            seen.append(game.map!)
        }
        XCTAssertGreaterThan(Set(seen).count, 5, "thirty picks should cover most of the maps")
    }

    func testAFixedMapStaysFixedAcrossRounds() {
        let game = Game(mapPolicy: .fixed(.fortress), seed: 5)
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        let start = 100 + game.settings.countdownDuration
        game.tick(at: start)
        game.tick(at: start + game.settings.roundDuration)
        game.tick(at: start + game.settings.roundDuration + game.settings.resultsDuration)
        XCTAssertEqual(game.phase, .lobby)
        XCTAssertEqual(game.map, .fortress)
    }

    func testTheNextRoundIsOnANewMapAndTheLobbyShowsIt() {
        let game = Game(seed: 9)
        let first = game.map
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        _ = game.pullTrigger(player: id, at: 100)
        game.tick(at: 100)
        let start = 100 + game.settings.countdownDuration
        game.tick(at: start)
        XCTAssertEqual(game.map, first, "the map does not change between the lobby and the round")
        game.tick(at: start + game.settings.roundDuration)
        let events = game.tick(at: start + game.settings.roundDuration + game.settings.resultsDuration + 0.01)
        XCTAssertNotEqual(game.map, first)
        XCTAssertTrue(events.contains { if case .mapChanged = $0 { return true }; return false })
        XCTAssertTrue(Scoreboard.screen(for: game, at: start + 200).body.contains(game.map!.title))
    }
}
