import XCTest
@testable import RicochetCore

final class ModeTests: XCTestCase {

    func testEveryModeHasATitleAndASummary() {
        for mode in Mode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.summary.isEmpty)
        }
    }

    func testOnlyLastStandingHasLives() {
        XCTAssertEqual(Mode.lastStanding.settings.lives, 3)
        XCTAssertEqual(Mode.skirmish.settings.lives, 0)
        XCTAssertEqual(Mode.ricochet.settings.lives, 0)
    }

    func testRicochetBouncesMoreAndCarriesFewerShells() {
        XCTAssertGreaterThan(Mode.ricochet.settings.shellBounces, Mode.skirmish.settings.shellBounces)
        XCTAssertLessThan(Mode.ricochet.settings.shellsInFlight, Mode.skirmish.settings.shellsInFlight)
    }

    func testAShellCanCrossTheArenaBeforeItExpiresInEveryMode() {
        var rng = SeededGenerator(seed: 1)
        let arena = Map.crossfire.build(using: &rng)
        let diagonal = (arena.width * arena.width + arena.height * arena.height).squareRoot()
        for mode in Mode.allCases {
            let s = mode.settings
            XCTAssertGreaterThan(s.shellSpeed * s.shellLifetime, diagonal * Double(s.shellBounces + 1) * 0.5,
                                 "\(mode) shells die before they can use their bounces")
        }
    }

    func testSettingAModeReplacesTheSettingsWholesale() {
        let game = Game()
        game.settings.shellBounces = 99
        game.setMode(.skirmish)
        XCTAssertEqual(game.settings.shellBounces, Mode.skirmish.settings.shellBounces)
    }
}
