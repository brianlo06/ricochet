import XCTest
import RemoteKit
@testable import RicochetCore

final class FeedbackTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()

    func testAShotIsFeltLightly() {
        let cue = Feedback.cue(for: .fired(shellID: UUID()))
        XCTAssertEqual(cue?.kind, .tick)
        XCTAssertLessThan(cue!.intensity, 0.5)
    }

    func testARefusedShotIsNotFelt() {
        XCTAssertNil(Feedback.cue(for: .refused(.tooSoon)))
        XCTAssertNil(Feedback.cue(for: .refused(.outOfShells)))
        XCTAssertNil(Feedback.cue(for: .refused(.destroyed)))
        XCTAssertNil(Feedback.cue(for: .ignored))
    }

    func testAKillIsFeltByBothAndTheVictimIsToldWho() {
        let cues = Feedback.cues(for: .destroyed(victim: b, cause: .shell(owner: a), at: .zero),
                                 names: [a: "Ada", b: "Bob"])
        XCTAssertEqual(cues.count, 2)
        let shooter = cues.first { $0.player == a }!
        let victim = cues.first { $0.player == b }!
        XCTAssertEqual(shooter.cue.kind, .success)
        XCTAssertEqual(victim.cue.kind, .failure)
        XCTAssertEqual(victim.cue.text, "Hit by Ada")
        XCTAssertGreaterThan(victim.cue.intensity, shooter.cue.intensity,
                             "being destroyed should feel worse than destroying")
    }

    func testAnOwnGoalIsOnlyFeltByTheOnePlayerAndSaysSo() {
        let cues = Feedback.cues(for: .destroyed(victim: a, cause: .shell(owner: a), at: .zero), names: [a: "Ada"])
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].player, a)
        XCTAssertEqual(cues[0].cue.text, "Own goal")
    }

    func testAShooterWhoHasLeftStillHasAName() {
        let cues = Feedback.cues(for: .destroyed(victim: b, cause: .shell(owner: a), at: .zero), names: [b: "Bob"])
        XCTAssertEqual(cues.first { $0.player == b }?.cue.text, "Hit by a shell")
    }

    func testHazardsSayWhatHappened() {
        XCTAssertEqual(Feedback.cues(for: .destroyed(victim: a, cause: .crushed, at: .zero), names: [:]).first?.cue.text, "Crushed")
        XCTAssertEqual(Feedback.cues(for: .destroyed(victim: a, cause: .pit, at: .zero), names: [:]).first?.cue.text, "Fell in")
    }

    func testRicochetsAreSeenNotFelt() {
        XCTAssertTrue(Feedback.cues(for: .bounced(shell: UUID(), at: .zero), names: [:]).isEmpty)
        XCTAssertTrue(Feedback.cues(for: .expired(shell: UUID(), at: .zero), names: [:]).isEmpty)
    }

    func testTheCountdownIsFeltForTheLastThreeSecondsOnly() {
        XCTAssertNil(Feedback.countdownTick(secondsLeft: 4))
        XCTAssertEqual(Feedback.countdownTick(secondsLeft: 3)?.text, "3")
        XCTAssertEqual(Feedback.countdownTick(secondsLeft: 1)?.text, "1")
        XCTAssertNil(Feedback.countdownTick(secondsLeft: 0))
    }

    func testPhaseChangesAreFeltOnceAndTheFirstLobbyIsSilent() {
        XCTAssertNil(Feedback.cue(movingTo: .lobby, from: nil))
        XCTAssertEqual(Feedback.cue(movingTo: .playing(endsAt: 1), from: .countdown(startsAt: 0))?.kind, .start)
        XCTAssertNil(Feedback.cue(movingTo: .lobby, from: .lobby))
    }
}
