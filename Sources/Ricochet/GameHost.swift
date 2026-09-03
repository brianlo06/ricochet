import Foundation
import RemoteKit
import RemoteServer
import RicochetCore

/// What the phone's events mean in a tank battle.
///
/// The entire network stack — TLS, pairing, framing, validation, rate limiting — comes from
/// AirPoint's `RemoteServer` and is not reimplemented here. This type is the whole
/// difference between "a remote" and "a game": a pad state becomes a throttle and a
/// steering direction, a tap becomes a shell, and everything underneath already knew how
/// to get either from a phone to this machine safely.
final class GameHost: RemoteSessionHandler {

    private let game: Game
    /// The game is not thread-safe and the scene reads it every frame, so every mutation is
    /// funnelled to the main queue. Sessions arrive on arbitrary queues.
    private let queue: DispatchQueue = .main

    /// Called on the main queue when a trigger pull resolves, for the muzzle flash.
    var onTrigger: ((UUID, TriggerResult) -> Void)?
    var onRosterChange: (() -> Void)?
    /// Every cue this host raises, whoever it was addressed to. The television hears the
    /// whole room: a cue meant for one player's phone is still something the other three
    /// should hear happen.
    var onCue: ((CuePayload) -> Void)?

    private var announcedPhase: Phase?
    private var sessions: [UUID: RemoteSession] = [:]
    private var lastTickSecond: Int?

    init(game: Game) {
        self.game = game
    }

    /// Send a cue to one player, or to everyone when `player` is nil. Either way the room
    /// hears it.
    private func emit(_ cue: CuePayload, to player: UUID? = nil) {
        if let player {
            sessions[player]?.send(cue: cue)
        } else {
            for session in sessions.values { session.send(cue: cue) }
        }
        onCue?(cue)
    }

    private func name(_ id: UUID) -> String { game.players[id]?.name ?? "a player who left" }

    /// What a tick produced, turned into feedback. Called from the scene each frame.
    func report(_ events: [Game.Event]) {
        guard !events.isEmpty else { return }
        let names = game.players.mapValues(\.name)
        for event in events {
            for addressed in Feedback.cues(for: event, names: names) {
                emit(addressed.cue, to: addressed.player)
            }
            switch event {
            case .destroyed(let victim, let cause, _):
                switch cause {
                case .shell(let by) where by == victim: Log.info("\(name(victim)) hit themself")
                case .shell(let by): Log.info("\(name(by)) destroyed \(name(victim))")
                case .crushed: Log.info("\(name(victim)) was crushed")
                case .pit: Log.info("\(name(victim)) fell in")
                }
            case .eliminated(let player):
                Log.info("\(name(player)) is out")
            case .mapChanged(let map):
                Log.info("next map: \(map.title) — \(map.summary)")
            case .bounced, .respawned, .expired, .brickBroken, .teleported:
                break
            }
        }
    }

    /// One pulse per second of the countdown, and for the last seconds of a round, so the
    /// clock is felt rather than watched.
    private func emitCountdownBeats() {
        let now = Date().timeIntervalSince1970
        guard let remaining = game.remaining(at: now) else {
            lastTickSecond = nil
            return
        }
        let second = Int(ceil(remaining))
        guard second != lastTickSecond else { return }
        lastTickSecond = second

        switch game.phase {
        case .countdown:
            if let cue = Feedback.countdownTick(secondsLeft: second) { emit(cue) }
        case .playing:
            if let cue = Feedback.roundEndingTick(secondsLeft: second) { emit(cue) }
        case .lobby, .results, .paused:
            break
        }
    }

    /// Narrates the match to the terminal. Called from the scene each frame.
    func logPhaseChanges() {
        emitCountdownBeats()

        let phase = game.phase
        guard phase != announcedPhase else { return }
        let previous = announcedPhase
        announcedPhase = phase

        if let cue = Feedback.cue(movingTo: phase, from: previous) { emit(cue) }

        switch phase {
        case .paused:
            Log.info("paused")
        case .lobby:
            let waiting = game.players.values.filter { !$0.isReady }.count
            Log.info(game.players.isEmpty
                     ? "lobby — waiting for players to join"
                     : "lobby — waiting for \(waiting) of \(game.players.count) to ready up")
        case .countdown:
            Log.info("all ready — starting in \(Int(game.settings.countdownDuration))s")
        case .playing:
            Log.info("round started (\(game.mode.title), \(game.players.count) playing)")
        case .results:
            for (index, player) in game.lastResults.enumerated() {
                Log.info(String(format: "  %d. %@  %d kills, %d deaths, %.0f%% of %d shots",
                                index + 1, player.name, player.kills, player.deaths,
                                player.accuracy * 100, player.shots))
            }
        }
    }

    // MARK: - Capabilities

    func features(for session: RemoteSession) -> [String] {
        // No pointer, no keyboard, no media: a gamepad. Advertising only what exists lets
        // the controller hide the rest rather than offering dead UI.
        ["pad", "fire", "ready", "modes", "bots", "pause"]
    }

    func displays(for session: RemoteSession) -> [DisplayInfo] {
        [DisplayInfo(id: 1, w: Int(game.arena.width), h: Int(game.arena.height), scale: 1, main: true)]
    }

    func isReady(for session: RemoteSession) -> Bool {
        // Always. This needs no OS permission at all: the game draws its own tanks.
        true
    }

    func permissions(for session: RemoteSession) -> [String: Bool] {
        ["ready": true]
    }

    // MARK: - Lifecycle

    func sessionDidBegin(_ session: RemoteSession) {
        let name = session.deviceName ?? "Player"
        queue.async { [weak self] in
            guard let self else { return }
            self.sessions[session.id] = session
            self.game.addPlayer(id: session.id, name: name, at: Date().timeIntervalSince1970)
            Log.info("\(name) joined — \(self.game.players.count) playing")
            self.onRosterChange?()
        }
    }

    func sessionDidEnd(_ session: RemoteSession) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sessions.removeValue(forKey: session.id)
            self.game.removePlayer(id: session.id)
            Log.info("\(session.deviceName ?? "a player") left — \(self.game.players.count) playing")
            self.onRosterChange?()
        }
    }

    // MARK: - Events

    /// The pad, as the rules understand it. Up is the throttle and down is reverse, so a
    /// tank is driven the way it faces rather than the way the screen is oriented — the
    /// choice every top-down tank game since Combat has made, because the alternative
    /// means working out which way is "up" for a tank pointing left.
    static func controls(for held: [PadButton]) -> Controls {
        var controls: Controls = []
        for button in held {
            switch button {
            case .up: controls.insert(.forward)
            case .down: controls.insert(.reverse)
            case .left: controls.insert(.left)
            case .right: controls.insert(.right)
            case .a, .b, .x, .y, .l, .r, .start, .select: break
            }
        }
        return controls
    }

    /// The lettered buttons, shared with the Mac keyboard: B bots, N map, P pause, E end.
    func handleLobbyKey(_ key: KeyName, from session: RemoteSession?) {
        func refuse(_ text: String) {
            if let session { emit(CuePayload(kind: .failure, intensity: 0.3, text: text), to: session.id) }
        }
        switch key {
        case .b:
            if addBot() == nil { refuse("Not mid-round") }
        case .n:
            if !reshuffleMap() { refuse("Not mid-round") }
        case .p:
            if togglePause() == nil { refuse("No round to pause") }
        case .e, .escape:
            if !endRound() { refuse("No round to end") }
        default:
            break
        }
    }

    /// Pauses or resumes. Returns whether the round is now paused, or nil if there is no
    /// round. The cue comes from the phase change.
    @discardableResult
    func togglePause() -> Bool? {
        let paused = game.togglePause(at: Date().timeIntervalSince1970)
        if let paused { Log.info(paused ? "paused" : "resumed") }
        return paused
    }

    /// Ends the round with the scores as they stand.
    @discardableResult
    func endRound() -> Bool {
        guard game.endRoundEarly(at: Date().timeIntervalSince1970) else { return false }
        Log.info("round ended early")
        return true
    }

    /// One more bot, wrapping to none. Returns the new count, or nil if refused.
    @discardableResult
    func addBot() -> Int? {
        guard !game.phase.isInRound else { return nil }
        let count = game.cycleBots(at: Date().timeIntervalSince1970)
        Log.info("bots: \(count) of up to \(game.maxBots)")
        emit(CuePayload(kind: .info, intensity: 0.4, text: count == 0 ? "No bots" : "\(count) bot\(count == 1 ? "" : "s")"))
        onRosterChange?()
        return count
    }

    /// A different map, if we are between rounds. The cue comes from the game's event.
    @discardableResult
    func reshuffleMap() -> Bool {
        guard game.reshuffleMap() else { return false }
        Log.info("map: \(game.map?.title ?? "custom")")
        return true
    }

    func handle(_ event: ClientEvent, from session: RemoteSession) {
        switch event {
        case .padState(let pad):
            let controls = Self.controls(for: pad.held)
            queue.async { [weak self] in
                self?.game.setControls(player: session.id, controls, at: Date().timeIntervalSince1970)
            }

        // A tap is the trigger. Reusing `left_click` rather than inventing a `fire` event
        // keeps the vocabulary the same as Reticle's: it means "shoot" mid-round and "I'm
        // ready" in the lobby or on the results screen, so a match runs from the sofa.
        case .leftClick:
            queue.async { [weak self] in
                guard let self else { return }
                let result = self.game.pullTrigger(player: session.id,
                                                  at: Date().timeIntervalSince1970)
                if case .readied(let ready) = result {
                    Log.info("\(session.deviceName ?? "a player") is \(ready ? "ready" : "not ready")")
                }
                if let cue = Feedback.cue(for: result) { self.emit(cue, to: session.id) }
                self.onTrigger?(session.id, result)
            }

        // The Mode button cycles the rules, from the sofa.
        case .rightClick:
            queue.async { [weak self] in
                guard let self else { return }
                let modes = Mode.allCases
                guard let index = modes.firstIndex(of: self.game.mode) else { return }
                let next = modes[(index + 1) % modes.count]
                guard self.game.setMode(next) else {
                    self.emit(CuePayload(kind: .failure, intensity: 0.3, text: "Not mid-round"),
                              to: session.id)
                    return
                }
                Log.info("mode: \(next.title) — \(next.summary)")
                self.emit(CuePayload(kind: .info, intensity: 0.5, text: next.title))
            }

        // Lobby buttons that are taps rather than holds: B adds a bot, N reshuffles the
        // map. A key press is what they are — a lettered button, pressed once.
        case .keyPress(let key):
            queue.async { [weak self] in self?.handleLobbyKey(key.key, from: session) }

        // Everything else is a cursor-remote concern with no meaning here. Ignored rather
        // than rejected: the phone may legitimately offer buttons this host does not use.
        case .pointerMove, .dragStart, .dragEnd, .scroll, .textInput,
             .mediaCommand, .recenter, .calibration, .hello, .ping, .disconnect:
            break
        }
    }
}
