import Foundation

/// What a player is holding on the pad, as the rules see it.
///
/// A phone reports pad buttons; a tank has a throttle and a steering direction. The host
/// maps one onto the other, so the rules never learn what an `a` button is and the
/// controller never learns what a tank is.
public struct Controls: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let forward = Controls(rawValue: 1 << 0)
    public static let reverse = Controls(rawValue: 1 << 1)
    public static let left = Controls(rawValue: 1 << 2)
    public static let right = Controls(rawValue: 1 << 3)

    /// +1 anticlockwise, -1 clockwise, 0 for neither or both.
    public var turn: Double { (contains(.left) ? 1 : 0) - (contains(.right) ? 1 : 0) }
    /// +1 forward, -1 reverse, 0 for neither or both.
    public var drive: Double { (contains(.forward) ? 1 : 0) - (contains(.reverse) ? 1 : 0) }
}

public struct PlayerState: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Which seat this player holds, counted from zero and held for as long as they are
    /// connected. It decides their colour and their starting corner, so it must not move.
    public let seat: Int
    public var name: String
    /// Driven by the game rather than by a phone. Always ready, never waited for.
    public var isBot: Bool = false

    public var position: Vec2
    /// Radians anticlockwise from +x, the way SpriteKit rotates things.
    public var heading: Double
    public var isAlive: Bool = true
    /// When a destroyed tank comes back. `nil` while alive, or when it is not coming back.
    public var respawnAt: TimeInterval?
    /// A tank that has just appeared cannot be hit until this passes, so a respawn is not
    /// a free kill for whoever happens to be facing the corner.
    public var shieldedUntil: TimeInterval = 0
    /// Lives remaining, or `nil` when the mode respawns without limit.
    public var livesLeft: Int?
    public var isEliminated: Bool = false

    public var kills: Int = 0
    public var deaths: Int = 0
    /// Destroyed by your own shell. Counted as a death, not as a kill for anybody.
    public var ownGoals: Int = 0
    public var shots: Int = 0
    /// Said they are ready to start. Meaningless outside the lobby and results screens.
    public var isReady: Bool = false

    /// What the pad currently says, and when it last said it. A state that is not renewed
    /// is treated as released — see `Game.Settings.inputTimeout`.
    public var controls: Controls = []
    public var controlsAt: TimeInterval = -.infinity

    public var score: Int { kills }
    public var accuracy: Double { shots == 0 ? 0 : Double(kills) / Double(shots) }

    public func isShielded(at now: TimeInterval) -> Bool { now < shieldedUntil }

    public init(id: UUID, seat: Int, name: String, position: Vec2, heading: Double) {
        self.id = id
        self.seat = seat
        self.name = name
        self.position = position
        self.heading = heading
    }
}

/// A shell in flight.
public struct Shell: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let owner: UUID
    public var position: Vec2
    public var velocity: Vec2
    /// Walls it may still come off. When this is zero the next wall absorbs it.
    public var bouncesLeft: Int
    public let firedAt: TimeInterval
    public let expiresAt: TimeInterval

    public init(id: UUID = UUID(), owner: UUID, position: Vec2, velocity: Vec2,
                bouncesLeft: Int, firedAt: TimeInterval, expiresAt: TimeInterval) {
        self.id = id
        self.owner = owner
        self.position = position
        self.velocity = velocity
        self.bouncesLeft = bouncesLeft
        self.firedAt = firedAt
        self.expiresAt = expiresAt
    }
}

/// Everything the game does, with no rendering, no network and no clock of its own.
///
/// Time is passed in rather than read, and the one source of randomness — which map comes
/// next, how the maze is laid out, what a bot decides — is seeded. That makes a whole
/// round replayable from a seed and a log of button states, which is how the rules are
/// tested, and it matters more here than in a shooting gallery because the interesting
/// behaviour is several things moving at once.
public final class Game {

    /// Where the next map comes from.
    public enum MapPolicy: Equatable, Sendable {
        /// A different one each round, never the same one twice running.
        case random
        /// The same one every round.
        case fixed(Map)
        /// A layout supplied directly, for tests and for anyone who builds their own.
        case arena(Arena)
    }

    public private(set) var arena: Arena
    /// The arena as it was built, before a round's shells ate any of it.
    private var arenaTemplate: Arena
    /// Which map the arena is, or nil for one supplied directly.
    public private(set) var map: Map?
    /// Counts up each time a new arena is installed, so a renderer knows to rebuild.
    public private(set) var arenaGeneration = 0
    public var mapPolicy: MapPolicy

    public private(set) var players: [UUID: PlayerState] = [:]
    public private(set) var shells: [Shell] = []
    public private(set) var phase: Phase = .lobby
    public private(set) var mode: Mode = .skirmish
    /// Scores from the round that just finished, kept for the results screen after the
    /// live scores are cleared for the next one.
    public private(set) var lastResults: [PlayerState] = []

    public var settings: Settings

    /// How many players — people and bots together — the room seats. Bots only take what
    /// people leave, and give it back when somebody joins.
    public var seatLimit: Int = SeatPalette.capacity {
        didSet { reconcileBots(at: lastTickAt ?? 0) }
    }
    /// How many bots were asked for. What actually plays is this or the free seats,
    /// whichever is fewer — see `botCount`.
    public private(set) var desiredBots = 0
    /// How good the bots are. Medium by default: Hard is what the first players called
    /// "a bit too good", and it is still there for them.
    public private(set) var difficulty: Difficulty = .medium

    public struct Settings: Sendable {
        public var tankRadius: Double = 22
        /// Points per second, driving forward.
        public var tankSpeed: Double = 230
        /// Reverse is slower. Backing out of trouble should be possible, not free.
        public var reverseFactor: Double = 0.6
        /// Radians per second.
        public var turnRate: Double = 3.0

        public var shellSpeed: Double = 460
        public var shellRadius: Double = 5
        /// Walls a shell comes off before the next one absorbs it.
        public var shellBounces: Int = 1
        public var shellLifetime: Double = 6
        /// How many of one player's shells may be in the air at once. The thing that makes
        /// a shot a decision rather than a stream.
        public var shellsInFlight: Int = 3
        public var fireCooldown: Double = 0.3

        public var respawnDelay: Double = 2.5
        /// Seconds of invulnerability after appearing. Firing ends it early.
        public var spawnShield: Double = 1.2
        /// Lives per round. Zero respawns without limit.
        public var lives: Int = 0

        /// A pad state older than this is treated as released. The controller re-sends a
        /// held state a few times a second, so this only ever fires for a phone that has
        /// gone quiet — locked, backgrounded, dropped — and a tank that drives into a wall
        /// forever because a release went missing is the failure this exists to prevent.
        public var inputTimeout: Double = 1.0

        public var roundDuration: Double = 90
        public var countdownDuration: Double = 3
        public var resultsDuration: Double = 12

        public init() {}
    }

    /// Why a tank was destroyed.
    public enum Cause: Equatable, Sendable {
        /// `owner` is the shell's owner: the victim themself for an own goal, and possibly
        /// a player who has since left.
        case shell(owner: UUID)
        /// Caught between a sweeper and something solid.
        case crushed
        /// Drove into a pit.
        case pit
    }

    /// Something that happened during a tick that somebody might want to draw or hear.
    public enum Event: Equatable, Sendable {
        case bounced(shell: UUID, at: Vec2)
        case destroyed(victim: UUID, cause: Cause, at: Vec2)
        case respawned(player: UUID, at: Vec2)
        case eliminated(player: UUID)
        /// Timed out, or absorbed by a wall with no bounces left.
        case expired(shell: UUID, at: Vec2)
        case brickBroken(Rect)
        case teleported(from: Vec2, to: Vec2)
        case mapChanged(Map)
    }

    private var rng: SeededGenerator
    private var lastTickAt: TimeInterval?
    private var lastShotAt: [UUID: TimeInterval] = [:]
    private var brains: [UUID: BotBrain] = [:]
    /// When the current arena was installed, so gates and sweepers have a clock.
    private var arenaStartedAt: TimeInterval?
    /// What is solid this substep: the arena's solids, less any closed gate with a tank
    /// in it. Recomputed every step, read by everything that moves.
    private var currentSolids: [Rect] = []

    /// The largest step the simulation takes at once. A frame longer than this is split,
    /// so a shell cannot pass through a bar between two positions.
    private static let maxStep: Double = 1.0 / 60

    static let botNames = ["Rusty", "Clank", "Sprocket", "Gizmo", "Bolt", "Widget", "Cog", "Piston"]

    /// A game on random maps. The seed decides which maps and how the mazes are laid out.
    public init(settings: Settings = Settings(), mapPolicy: MapPolicy = .random,
                seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.settings = settings
        self.mapPolicy = mapPolicy
        self.rng = SeededGenerator(seed: seed)
        // Placeholders, replaced by the first pick below.
        self.arena = Arena(width: Map.width, height: Map.height)
        self.arenaTemplate = self.arena
        pickMap(announcing: false)
    }

    /// A game on one layout, supplied directly.
    public convenience init(arena: Arena, settings: Settings = Settings()) {
        self.init(settings: settings, mapPolicy: .arena(arena), seed: 1)
    }

    /// Switches mode. Refused mid-round, since changing the rules under a running match
    /// would invalidate the scores it is about to report.
    @discardableResult
    public func setMode(_ mode: Mode) -> Bool {
        guard !phase.isInRound else { return false }
        self.mode = mode
        self.settings = mode.settings
        return true
    }

    // MARK: - Maps

    /// Seconds the current arena has been in place, which is what its gates and sweepers
    /// run on.
    public func arenaTime(at now: TimeInterval) -> Double {
        now - (arenaStartedAt ?? now)
    }

    /// Picks the next map under the policy and puts everyone on it. Refused mid-round.
    @discardableResult
    public func reshuffleMap() -> Bool {
        guard !phase.isInRound else { return false }
        if case .fixed(let current) = mapPolicy {
            let all = Map.allCases
            let next = all[((all.firstIndex(of: current) ?? 0) + 1) % all.count]
            mapPolicy = .fixed(next)
        }
        pickMap(announcing: true)
        return true
    }

    /// The events a map change raised, for the next tick to hand out.
    private var pendingEvents: [Event] = []

    private func pickMap(announcing: Bool) {
        let built: Arena
        let chosen: Map?
        switch mapPolicy {
        case .arena(let arena):
            built = arena
            chosen = nil
        case .fixed(let map):
            built = map.build(using: &rng)
            chosen = map
        case .random:
            // Never the same one twice running: a party that gets the maze three times in
            // a row assumes the random is broken, and it is not wrong to.
            let current = self.map
            let choices = Map.allCases.filter { $0 != current }
            let next = choices.randomElement(using: &rng) ?? .crossfire
            built = next.build(using: &rng)
            chosen = next
        }
        install(built, map: chosen)
        if announcing, let chosen { pendingEvents.append(.mapChanged(chosen)) }
    }

    private func install(_ built: Arena, map: Map?) {
        arenaTemplate = built
        arena = built
        self.map = map
        arenaGeneration += 1
        arenaStartedAt = lastTickAt
        shells.removeAll()
        for (id, player) in players {
            var moved = player
            moved.position = spawn(forSeat: player.seat)
            moved.heading = heading(from: moved.position, toward: arena.center)
            moved.isAlive = true
            moved.respawnAt = nil
            players[id] = moved
        }
    }

    private func spawn(forSeat seat: Int) -> Vec2 {
        arena.spawns[seat % arena.spawns.count]
    }

    // MARK: - Players

    public var humanCount: Int { players.values.filter { !$0.isBot }.count }
    public var botCount: Int { players.values.filter(\.isBot).count }
    /// How many bots could play right now: the seats people are not in.
    public var maxBots: Int { max(0, seatLimit - humanCount) }

    @discardableResult
    public func addPlayer(id: UUID, name: String, at now: TimeInterval) -> PlayerState {
        // A person arriving at a full table takes a bot's seat, not a refusal.
        if players[id] == nil, players.count >= seatLimit, let bot = highestSeatedBot() {
            removeBot(bot)
        }
        // Reuse the seat if this player is already in — a reconnect should not walk them
        // down the palette — otherwise take the lowest free one.
        let seat = players[id]?.seat ?? lowestFreeSeat()
        let spawn = phase.isPlaying ? bestSpawn(excluding: id, awayFrom: nil) : self.spawn(forSeat: seat)
        var player = PlayerState(id: id, seat: seat, name: name, position: spawn,
                                 heading: heading(from: spawn, toward: arena.center))
        // Someone arriving mid-round joins the round in progress rather than waiting it
        // out: a party game that makes a latecomer watch is a party game nobody finishes.
        player.isReady = phase.isPlaying
        player.shieldedUntil = now + settings.spawnShield
        player.livesLeft = settings.lives > 0 ? settings.lives : nil
        players[id] = player
        reconcileBots(at: now)
        return player
    }

    private func lowestFreeSeat() -> Int {
        let taken = Set(players.values.map(\.seat))
        var seat = 0
        while taken.contains(seat) { seat += 1 }
        return seat
    }

    public func removePlayer(id: UUID) {
        players.removeValue(forKey: id)
        lastShotAt.removeValue(forKey: id)
        brains.removeValue(forKey: id)
        // Their shells stay: a shot already in the air is part of the world now.
        reconcileBots(at: lastTickAt ?? 0)
        // If the last person leaves mid-round, drop back to the lobby rather than running
        // a match nobody is in. Bots do not count as somebody.
        if humanCount == 0, phase.isInRound || phase == .lobby {
            shells.removeAll()
            phase = .lobby
        }
    }

    // MARK: - Pausing and ending

    /// Stops the round where it is. Everything with a deadline — the round, shells,
    /// respawns, shields, gates — is pushed on by the length of the pause when it resumes,
    /// so a pause is invisible to the rules. Refused outside a round.
    @discardableResult
    public func pause(at now: TimeInterval) -> Bool {
        guard phase.isPlaying else { return false }
        phase = .paused(resuming: phase, since: now)
        return true
    }

    @discardableResult
    public func resume(at now: TimeInterval) -> Bool {
        guard case .paused(let resuming, let since) = phase else { return false }
        let gap = max(0, now - since)
        if case .playing(let endsAt) = resuming {
            phase = .playing(endsAt: endsAt + gap)
        } else {
            phase = resuming
        }
        shells = shells.map { shell in
            Shell(id: shell.id, owner: shell.owner, position: shell.position,
                  velocity: shell.velocity, bouncesLeft: shell.bouncesLeft,
                  firedAt: shell.firedAt + gap, expiresAt: shell.expiresAt + gap)
        }
        for (id, player) in players {
            var moved = player
            if let due = moved.respawnAt { moved.respawnAt = due + gap }
            if moved.shieldedUntil > since { moved.shieldedUntil += gap }
            players[id] = moved
        }
        for id in lastShotAt.keys { lastShotAt[id]! += gap }
        if let started = arenaStartedAt { arenaStartedAt = started + gap }
        return true
    }

    /// Pauses a running round, resumes a paused one. Returns the new state, or nil if
    /// there is no round to do either to.
    public func togglePause(at now: TimeInterval) -> Bool? {
        if phase.isPlaying { pause(at: now); return true }
        if phase.isPaused { resume(at: now); return false }
        return nil
    }

    /// Ends the round now, scores as they stand. Refused outside a round.
    @discardableResult
    public func endRoundEarly(at now: TimeInterval) -> Bool {
        guard phase.isInRound else { return false }
        endRound(at: now)
        return true
    }

    // MARK: Bots

    /// Asks for this many bots. What plays is this or the free seats, whichever is fewer,
    /// and it is revisited as people come and go.
    public func setBots(_ count: Int, at now: TimeInterval) {
        desiredBots = max(0, count)
        reconcileBots(at: now)
    }

    /// One more bot, wrapping round to none. Bound to a button, so it has to be one press.
    @discardableResult
    public func cycleBots(at now: TimeInterval) -> Int {
        setBots((botCount + 1) % (maxBots + 1), at: now)
        return botCount
    }

    /// Changes how good the bots are. Refused mid-round: bots that get worse when you are
    /// losing is a cheat, and one that gets better is a complaint.
    @discardableResult
    public func setDifficulty(_ difficulty: Difficulty) -> Bool {
        guard !phase.isInRound else { return false }
        self.difficulty = difficulty
        return true
    }

    /// The next level up, wrapping round to Easy. Returns it, or nil if refused.
    public func cycleDifficulty() -> Difficulty? {
        setDifficulty(difficulty.next) ? difficulty : nil
    }

    private func reconcileBots(at now: TimeInterval) {
        // Bots play with people, not instead of them.
        let target = humanCount == 0 ? 0 : min(desiredBots, maxBots)
        while botCount > target, let bot = highestSeatedBot() { removeBot(bot) }
        while botCount < target { addBot(at: now) }
    }

    private func highestSeatedBot() -> UUID? {
        players.values.filter(\.isBot).max { $0.seat < $1.seat }?.id
    }

    private func removeBot(_ id: UUID) {
        players.removeValue(forKey: id)
        brains.removeValue(forKey: id)
        lastShotAt.removeValue(forKey: id)
    }

    private func addBot(at now: TimeInterval) {
        let id = UUID()
        let seat = lowestFreeSeat()
        let taken = Set(players.values.map(\.name))
        let name = Self.botNames.first { !taken.contains($0) } ?? "Bot \(seat + 1)"
        let spawn = phase.isPlaying ? bestSpawn(excluding: id, awayFrom: nil) : self.spawn(forSeat: seat)
        var bot = PlayerState(id: id, seat: seat, name: name, position: spawn,
                              heading: heading(from: spawn, toward: arena.center))
        bot.isBot = true
        bot.isReady = true
        bot.shieldedUntil = now + settings.spawnShield
        bot.livesLeft = settings.lives > 0 ? settings.lives : nil
        players[id] = bot
        brains[id] = BotBrain(seed: rng.next())
    }

    /// The pad, as the phone last reported it.
    public func setControls(player id: UUID, _ controls: Controls, at now: TimeInterval) {
        guard players[id] != nil else { return }
        players[id]?.controls = controls
        players[id]?.controlsAt = now
    }

    /// What a player is effectively holding: what they said, unless they said it too long
    /// ago to be trusted.
    func effectiveControls(of player: PlayerState, at now: TimeInterval) -> Controls {
        now - player.controlsAt <= settings.inputTimeout ? player.controls : []
    }

    // MARK: - Firing

    /// A trigger pull, interpreted for the current phase.
    public func pullTrigger(player id: UUID, at now: TimeInterval) -> TriggerResult {
        guard players[id] != nil else { return .noSuchPlayer }
        switch phase {
        case .playing:
            return fire(player: id, at: now)
        case .lobby, .results:
            let ready = !(players[id]?.isReady ?? false)
            players[id]?.isReady = ready
            return .readied(ready)
        case .countdown, .paused:
            return .ignored
        }
    }

    public func fire(player id: UUID, at now: TimeInterval) -> TriggerResult {
        guard var player = players[id] else { return .noSuchPlayer }
        guard player.isAlive, !player.isEliminated else { return .refused(.destroyed) }
        if let last = lastShotAt[id], now - last < settings.fireCooldown { return .refused(.tooSoon) }
        guard shells.filter({ $0.owner == id }).count < settings.shellsInFlight else {
            return .refused(.outOfShells)
        }
        lastShotAt[id] = now
        player.shots += 1
        // A shield is for arriving, not for fighting from behind. The first shot drops it.
        player.shieldedUntil = 0

        let direction = Vec2(heading: player.heading)
        // Out past the hull, so a shell never starts inside the tank that fired it. It can
        // still come straight back off a wall you are hugging, which is the game.
        let muzzle = player.position + direction * (settings.tankRadius + settings.shellRadius + 2)
        let shell = Shell(owner: id, position: muzzle,
                          velocity: direction * settings.shellSpeed,
                          bouncesLeft: settings.shellBounces,
                          firedAt: now, expiresAt: now + settings.shellLifetime)
        shells.append(shell)
        players[id] = player
        return .fired(shellID: shell.id)
    }

    // MARK: - Simulation

    /// Advances the world. Returns what happened, for effects and cues.
    @discardableResult
    public func tick(at now: TimeInterval) -> [Event] {
        if arenaStartedAt == nil { arenaStartedAt = now }
        advancePhase(at: now)
        defer { lastTickAt = now }
        var events = pendingEvents
        pendingEvents.removeAll()

        // Everyone out — or everyone but one — ends an elimination round early. So does
        // every person being out: bots fighting each other is nothing to watch, and the
        // people watching it cannot do anything but wait.
        if phase.isPlaying, settings.lives > 0, !players.isEmpty {
            let standing = players.values.filter { !$0.isEliminated }.count
            let peopleStanding = players.values.filter { !$0.isBot && !$0.isEliminated }.count
            if standing <= (players.count >= 2 ? 1 : 0) || peopleStanding == 0 {
                endRound(at: now)
                return events
            }
        }

        guard let last = lastTickAt else { return events }
        var remaining = now - last
        // A long gap means the app was occluded or the machine slept. Simulating it would
        // fling every shell across the arena; skipping it loses nothing anyone saw.
        guard remaining > 0, remaining < 0.25 else { return events }

        guard !phase.isPaused else { return events }

        var clock = last
        while remaining > 0 {
            let step = min(remaining, Self.maxStep)
            clock += step
            remaining -= step
            let t = arenaTime(at: clock)
            currentSolids = solidsNow(at: t)
            events += sweep(at: t, now: clock)
            driveBots(at: clock)
            events += moveTanks(by: step, at: clock)
            if phase.isPlaying {
                events += moveShells(by: step, at: clock)
            }
            events += respawn(at: clock)
        }
        return events
    }

    private func advancePhase(at now: TimeInterval) {
        switch phase {
        case .lobby:
            // Everyone present has to agree. One player alone can start on their own.
            // Bots are always ready, so they never hold anybody up.
            guard humanCount > 0, players.values.allSatisfy(\.isReady) else { return }
            phase = .countdown(startsAt: now + settings.countdownDuration)

        case .countdown(let startsAt):
            guard now >= startsAt else { return }
            beginRound(at: now)

        case .playing(let endsAt):
            guard now >= endsAt else { return }
            endRound(at: now)

        case .results(let until):
            guard now >= until else { return }
            phase = .lobby
            for (id, player) in players where !player.isBot { players[id]?.isReady = false }
            pickMap(announcing: true)

        case .paused:
            break   // time does not pass
        }
    }

    private func beginRound(at now: TimeInterval) {
        // A fresh copy of the arena: every brick back, every gate on its first cycle.
        arena = arenaTemplate
        arenaStartedAt = now
        shells.removeAll()
        lastShotAt.removeAll()
        for (id, player) in players {
            let spawn = self.spawn(forSeat: player.seat)
            var fresh = PlayerState(id: id, seat: player.seat, name: player.name,
                                    position: spawn,
                                    heading: heading(from: spawn, toward: arena.center))
            fresh.isBot = player.isBot
            fresh.isReady = true
            fresh.livesLeft = settings.lives > 0 ? settings.lives : nil
            // What they are holding carries over: a thumb already on the pad when the
            // countdown ends should move the tank on the first frame.
            fresh.controls = player.controls
            fresh.controlsAt = player.controlsAt
            players[id] = fresh
        }
        phase = .playing(endsAt: now + settings.roundDuration)
    }

    private func endRound(at now: TimeInterval) {
        shells.removeAll()
        lastResults = leaderboard
        for (id, player) in players {
            players[id]?.isReady = player.isBot
            // Nobody sits out the results screen as a wreck.
            players[id]?.isAlive = true
            players[id]?.respawnAt = nil
        }
        phase = .results(until: now + settings.resultsDuration)
    }

    /// Seconds left in whatever the current phase is counting down to, or nil in the lobby.
    public func remaining(at now: TimeInterval) -> Double? {
        switch phase {
        case .lobby: return nil
        case .countdown(let at): return max(at - now, 0)
        case .playing(let at): return max(at - now, 0)
        case .results(let at): return max(at - now, 0)
        case .paused(let resuming, let since):
            // Frozen at the moment of the pause.
            if case .playing(let at) = resuming { return max(at - since, 0) }
            return nil
        }
    }

    // MARK: The arena, right now

    /// Solid things this instant. A closed gate with a tank inside it counts as open:
    /// closing on a tank would pin it, and the gate is a door, not a press.
    private func solidsNow(at t: Double) -> [Rect] {
        var all = arena.walls + arena.bricks
        for gate in arena.gates where !gate.isOpen(at: t) {
            let occupied = players.values.contains {
                $0.isAlive && gate.rect.intersects(center: $0.position, radius: settings.tankRadius)
            }
            if !occupied { all.append(gate.rect) }
        }
        all += arena.sweepers.map { $0.rect(at: t) }
        return all
    }

    /// Whether a gate is passable right now, for a renderer.
    public func isGateOpen(_ gate: Gate, at now: TimeInterval) -> Bool {
        gate.isOpen(at: arenaTime(at: now))
    }

    /// What a route planner should treat as solid: the arena's walls, bricks and sweepers,
    /// but not its gates, which will open.
    func navSolids() -> [Rect] {
        arena.walls + arena.bricks + arena.sweepers.map { $0.rect(at: arenaTime(at: lastTickAt ?? 0)) }
    }

    /// Whether a shell fired from `a` at `b` would get there without meeting anything.
    func hasLineOfSight(from a: Vec2, to b: Vec2) -> Bool {
        var snapshot = arena
        snapshot.walls = currentSolids
        snapshot.bricks = []
        snapshot.gates = []
        snapshot.sweepers = []
        return snapshot.hasLineOfSight(from: a, to: b, at: 0)
    }

    /// Whether a tank can drive straight from `a` to `b`: nothing solid within a hull's
    /// width of the line, and no pit under it.
    func isClearDrive(from a: Vec2, to b: Vec2) -> Bool {
        let r = settings.tankRadius
        if currentSolids.contains(where: { $0.intersects(segmentFrom: a, to: b, margin: r) }) { return false }
        if arena.pits.contains(where: { $0.intersects(segmentFrom: a, to: b, margin: r * 0.6) }) { return false }
        let d = b - a
        let lengthSquared = d.dot(d)
        return !arena.bumpers.contains { bumper in
            let u = lengthSquared > 0 ? min(max((bumper.center - a).dot(d) / lengthSquared, 0), 1) : 0
            return (a + d * u).distance(to: bumper.center) < bumper.radius + r
        }
    }

    // MARK: Tanks

    /// Seat order, so that when two tanks push on the same gap the same one wins every
    /// time: a dictionary's order is whatever the hashing gave, and a replay has to agree
    /// with the round it is replaying.
    private var orderedPlayerIDs: [UUID] {
        players.values.sorted { $0.seat < $1.seat }.map(\.id)
    }

    private func driveBots(at now: TimeInterval) {
        for id in orderedPlayerIDs {
            guard let bot = players[id], bot.isBot, bot.isAlive, var brain = brains[id] else { continue }
            let (controls, wantsFire) = brain.decide(for: bot, in: self, at: now)
            brains[id] = brain
            setControls(player: id, controls, at: now)
            if wantsFire, phase.isPlaying { _ = fire(player: id, at: now) }
        }
    }

    private func moveTanks(by dt: Double, at now: TimeInterval) -> [Event] {
        var events: [Event] = []
        for id in orderedPlayerIDs {
            guard var player = players[id], player.isAlive else { continue }
            let controls = effectiveControls(of: player, at: now)

            player.heading = Self.wrap(player.heading + controls.turn * settings.turnRate * dt)

            var step = Vec2.zero
            let drive = controls.drive
            if drive != 0 {
                let speed = settings.tankSpeed * (drive > 0 ? 1 : settings.reverseFactor) * drive
                step = Vec2(heading: player.heading) * (speed * dt)
            }
            // The floor may be moving too.
            for conveyor in arena.conveyors where conveyor.rect.contains(player.position) {
                step += conveyor.push * dt
            }
            if step != .zero {
                // One axis at a time, so a tank driven into a wall at an angle slides
                // along it rather than sticking. It is the difference between steering
                // round a bar and being glued to it.
                let alongX = Vec2(x: player.position.x + step.x, y: player.position.y)
                if !isBlocked(alongX, for: id) { player.position = alongX }
                let alongY = Vec2(x: player.position.x, y: player.position.y + step.y)
                if !isBlocked(alongY, for: id) { player.position = alongY }
            }
            players[id] = player

            if arena.pits.contains(where: { $0.contains(player.position) }) {
                events += destroy(id, cause: .pit, at: now)
                continue
            }
            events += teleportIfEntering(tank: id, at: now)
        }
        return events
    }

    private func isBlocked(_ center: Vec2, for id: UUID) -> Bool {
        let r = settings.tankRadius
        if center.x - r < 0 || center.x + r > arena.width || center.y - r < 0 || center.y + r > arena.height {
            return true
        }
        if currentSolids.contains(where: { $0.intersects(center: center, radius: r) }) { return true }
        if arena.bumpers.contains(where: { $0.center.distance(to: center) < $0.radius + r }) { return true }
        return players.values.contains {
            $0.id != id && $0.isAlive && $0.position.distance(to: center) < r * 2
        }
    }

    /// A sweeper shoves whatever is in its way. Whatever cannot be shoved is crushed.
    private func sweep(at t: Double, now: TimeInterval) -> [Event] {
        var events: [Event] = []
        let r = settings.tankRadius
        for sweeper in arena.sweepers {
            let rect = sweeper.rect(at: t)
            let velocity = sweeper.velocity(at: t)
            for id in orderedPlayerIDs {
                guard let player = players[id], player.isAlive,
                      rect.intersects(center: player.position, radius: r) else { continue }
                var pushed = player.position
                if abs(velocity.x) >= abs(velocity.y) {
                    pushed.x = velocity.x >= 0 ? rect.maxX + r : rect.minX - r
                } else {
                    pushed.y = velocity.y >= 0 ? rect.maxY + r : rect.minY - r
                }
                if isBlocked(pushed, for: id) {
                    events += destroy(id, cause: .crushed, at: now)
                } else {
                    players[id]?.position = pushed
                }
            }
        }
        return events
    }

    private func teleportIfEntering(tank id: UUID, at now: TimeInterval) -> [Event] {
        guard let player = players[id] else { return [] }
        for portal in arena.portals {
            for (entry, exit) in [(portal.a, portal.b), (portal.b, portal.a)]
            where player.position.distance(to: entry) < portal.radius {
                let landing = exit + Vec2(heading: player.heading) * (portal.radius + settings.tankRadius + 4)
                guard !isBlocked(landing, for: id) else { continue }
                players[id]?.position = landing
                return [.teleported(from: entry, to: exit)]
            }
        }
        return []
    }

    // MARK: Shells

    private func moveShells(by dt: Double, at now: TimeInterval) -> [Event] {
        var events: [Event] = []
        var kept: [Shell] = []
        let r = settings.shellRadius

        for var shell in shells {
            if now >= shell.expiresAt {
                events.append(.expired(shell: shell.id, at: shell.position))
                continue
            }
            shell.position += shell.velocity * dt

            // A brick takes the shell with it.
            if let index = arena.bricks.firstIndex(where: { $0.intersects(center: shell.position, radius: r) }) {
                let brick = arena.bricks.remove(at: index)
                events.append(.brickBroken(brick))
                events.append(.expired(shell: shell.id, at: shell.position))
                continue
            }

            var bounced = false
            // The border first, then the blocks. Each is a reflection about one axis: the
            // one the shell is more deeply through, which for a moving shell is the face
            // it came in by.
            if shell.position.x - r < 0 {
                shell.position.x = r; shell.velocity.x = abs(shell.velocity.x); bounced = true
            } else if shell.position.x + r > arena.width {
                shell.position.x = arena.width - r; shell.velocity.x = -abs(shell.velocity.x); bounced = true
            }
            if shell.position.y - r < 0 {
                shell.position.y = r; shell.velocity.y = abs(shell.velocity.y); bounced = true
            } else if shell.position.y + r > arena.height {
                shell.position.y = arena.height - r; shell.velocity.y = -abs(shell.velocity.y); bounced = true
            }
            for wall in currentSolids where wall.intersects(center: shell.position, radius: r) {
                let depthX = min(shell.position.x + r - wall.minX, wall.maxX - (shell.position.x - r))
                let depthY = min(shell.position.y + r - wall.minY, wall.maxY - (shell.position.y - r))
                if depthX < depthY {
                    if shell.position.x < wall.center.x {
                        shell.position.x = wall.minX - r; shell.velocity.x = -abs(shell.velocity.x)
                    } else {
                        shell.position.x = wall.maxX + r; shell.velocity.x = abs(shell.velocity.x)
                    }
                } else {
                    if shell.position.y < wall.center.y {
                        shell.position.y = wall.minY - r; shell.velocity.y = -abs(shell.velocity.y)
                    } else {
                        shell.position.y = wall.maxY + r; shell.velocity.y = abs(shell.velocity.y)
                    }
                }
                bounced = true
            }
            if bounced {
                guard shell.bouncesLeft > 0 else {
                    events.append(.expired(shell: shell.id, at: shell.position))
                    continue
                }
                shell.bouncesLeft -= 1
                events.append(.bounced(shell: shell.id, at: shell.position))
            }

            // A bumper reflects along the normal and, unlike a wall, costs nothing.
            for bumper in arena.bumpers where shell.position.distance(to: bumper.center) < bumper.radius + r {
                let normal = (shell.position - bumper.center).normalized
                shell.velocity = shell.velocity - normal * (2 * shell.velocity.dot(normal))
                shell.position = bumper.center + normal * (bumper.radius + r)
                events.append(.bounced(shell: shell.id, at: shell.position))
            }

            for portal in arena.portals {
                for (entry, exit) in [(portal.a, portal.b), (portal.b, portal.a)]
                where shell.position.distance(to: entry) < portal.radius {
                    shell.position = exit + shell.velocity.normalized * (portal.radius + r + 1)
                    events.append(.teleported(from: entry, to: exit))
                    break
                }
            }

            // Nearest tank wins when a shell lands between two, so it is never arbitrary.
            let victim = players.values
                .filter { $0.isAlive && !$0.isShielded(at: now)
                    && $0.position.distance(to: shell.position) < settings.tankRadius + r }
                .min { $0.position.distance(to: shell.position) < $1.position.distance(to: shell.position) }
            if let victim {
                events += destroy(victim.id, cause: .shell(owner: shell.owner), at: now)
                continue
            }
            kept.append(shell)
        }
        shells = kept
        return events
    }

    private func destroy(_ victimID: UUID, cause: Cause, at now: TimeInterval) -> [Event] {
        guard var victim = players[victimID], victim.isAlive else { return [] }
        var events: [Event] = []
        victim.isAlive = false
        // Outside a round nothing counts; the tank simply comes back. A sweeper in the
        // lobby is something to learn from, not something to lose a life to.
        if phase.isPlaying {
            victim.deaths += 1
            if case .shell(let shooterID) = cause {
                if shooterID == victimID {
                    victim.ownGoals += 1
                } else {
                    // The shooter may have left since firing. Their shell still counts
                    // against you; it just counts for nobody.
                    players[shooterID]?.kills += 1
                }
            }
            if let lives = victim.livesLeft {
                victim.livesLeft = lives - 1
                if lives - 1 <= 0 {
                    victim.isEliminated = true
                    events.append(.eliminated(player: victimID))
                }
            }
        }
        if !victim.isEliminated { victim.respawnAt = now + settings.respawnDelay }
        players[victimID] = victim
        events.append(.destroyed(victim: victimID, cause: cause, at: victim.position))
        return events
    }

    private func respawn(at now: TimeInterval) -> [Event] {
        var events: [Event] = []
        for id in orderedPlayerIDs {
            guard var player = players[id], let due = player.respawnAt, now >= due else { continue }
            let spawn = bestSpawn(excluding: id, awayFrom: player.position)
            player.position = spawn
            player.heading = heading(from: spawn, toward: arena.center)
            player.isAlive = true
            player.respawnAt = nil
            player.shieldedUntil = now + settings.spawnShield
            players[id] = player
            events.append(.respawned(player: id, at: spawn))
        }
        return events
    }

    /// The spawn farthest from everybody else, so nobody comes back under a gun. Ties go
    /// to the one farthest from where they died, which is where the gun probably still is.
    func bestSpawn(excluding id: UUID, awayFrom death: Vec2?) -> Vec2 {
        let others = players.values.filter { $0.id != id && $0.isAlive }.map(\.position)
        func nearestOther(to spawn: Vec2) -> Double {
            others.map { $0.distance(to: spawn) }.min() ?? .infinity
        }
        return arena.spawns.max { a, b in
            let (da, db) = (nearestOther(to: a), nearestOther(to: b))
            if da != db { return da < db }
            guard let death else { return false }
            return a.distance(to: death) < b.distance(to: death)
        } ?? arena.center
    }

    private func heading(from: Vec2, toward: Vec2) -> Double {
        atan2(toward.y - from.y, toward.x - from.x)
    }

    private static func wrap(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a < -.pi { a += 2 * .pi }
        return a
    }

    /// Most kills first; ties broken by fewest deaths, so a careful player beats a
    /// reckless one, and then by seat, which is the one ordering that never moves.
    public var leaderboard: [PlayerState] {
        players.values.sorted {
            if $0.kills != $1.kills { return $0.kills > $1.kills }
            if $0.deaths != $1.deaths { return $0.deaths < $1.deaths }
            return $0.seat < $1.seat
        }
    }
}
