import XCTest
@testable import RicochetCore

final class SeatTests: XCTestCase {

    private func makeGame() -> Game { Game(seed: 1) }

    func testSeatsAreHandedOutLowestFree() {
        let game = makeGame()
        let a = UUID(), b = UUID(), c = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.addPlayer(id: b, name: "B", at: 0)
        game.removePlayer(id: a)
        game.addPlayer(id: c, name: "C", at: 0)
        XCTAssertEqual(game.players[c]?.seat, 0, "the freed seat is reused before a new one")
        XCTAssertEqual(game.players[b]?.seat, 1)
    }

    func testAReconnectingPlayerKeepsTheirSeat() {
        let game = makeGame()
        let a = UUID(), b = UUID()
        game.addPlayer(id: a, name: "A", at: 0)
        game.addPlayer(id: b, name: "B", at: 0)
        game.addPlayer(id: a, name: "A again", at: 1)
        XCTAssertEqual(game.players[a]?.seat, 0)
        XCTAssertEqual(game.players[a]?.name, "A again")
    }

    func testSeatsStartInDifferentCorners() {
        let game = makeGame()
        let ids = (0..<4).map { _ in UUID() }
        for (i, id) in ids.enumerated() { game.addPlayer(id: id, name: "P\(i)", at: 0) }
        let positions = ids.map { game.players[$0]!.position }
        for i in 0..<4 {
            for j in (i + 1)..<4 {
                XCTAssertGreaterThan(positions[i].distance(to: positions[j]), 500,
                                     "seats \(i) and \(j) start too close together")
            }
        }
    }

    func testEveryTankFacesTheMiddleAtTheStart() {
        let game = makeGame()
        let id = UUID()
        game.addPlayer(id: id, name: "A", at: 0)
        let player = game.players[id]!
        let toCenter = game.arena.center - player.position
        let facing = Vec2(heading: player.heading)
        let dot = toCenter.x * facing.x + toCenter.y * facing.y
        XCTAssertGreaterThan(dot, 0, "a tank that starts facing its own corner has to turn before it can do anything")
    }

    func testEightSeatsAreVisiblyDistinct() {
        XCTAssertGreaterThan(SeatPalette.minimumHueSeparation(seats: SeatPalette.capacity), 0.08,
                             "two of the first eight seats are too close in hue to tell apart on a TV")
    }

    func testAPlayersColourDoesNotDependOnWhoElseIsPlaying() {
        let alone = SeatPalette.color(seat: 2)
        let crowded = SeatPalette.color(seat: 2)
        XCTAssertEqual(alone.hue, crowded.hue)
    }
}
