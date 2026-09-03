import Foundation

/// A coarse walkability grid over the arena, for finding a route a tank can drive.
///
/// Forty-point cells: fine enough that every corridor on every map holds a line of them,
/// coarse enough that a search is nothing. Built fresh each time a bot plans, because
/// bricks vanish and sweepers move, and a plan through a wall that is now there is worse
/// than a plan made a moment later.
struct NavGrid {
    static let cell: Double = 40

    let columns: Int
    let rows: Int
    private var walkable: [Bool]

    init(arena: Arena, solids: [Rect], radius: Double) {
        columns = max(1, Int(arena.width / Self.cell))
        rows = max(1, Int(arena.height / Self.cell))
        var cells = [Bool](repeating: false, count: columns * rows)
        for r in 0..<rows {
            for c in 0..<columns {
                let p = Self.center(c, r)
                var clear = p.x - radius >= 0 && p.x + radius <= arena.width
                    && p.y - radius >= 0 && p.y + radius <= arena.height
                if clear { clear = !solids.contains { $0.intersects(center: p, radius: radius) } }
                if clear { clear = !arena.bumpers.contains { $0.center.distance(to: p) < $0.radius + radius } }
                // A pit is fatal at the centre, so a cell whose centre is near one is not
                // somewhere to plan through.
                if clear { clear = !arena.pits.contains { $0.intersects(center: p, radius: radius * 0.6) } }
                cells[r * columns + c] = clear
            }
        }
        walkable = cells
    }

    static func center(_ c: Int, _ r: Int) -> Vec2 {
        Vec2(x: (Double(c) + 0.5) * cell, y: (Double(r) + 0.5) * cell)
    }

    func cell(of point: Vec2) -> (Int, Int) {
        (min(max(Int(point.x / Self.cell), 0), columns - 1),
         min(max(Int(point.y / Self.cell), 0), rows - 1))
    }

    func isWalkable(_ c: Int, _ r: Int) -> Bool {
        c >= 0 && r >= 0 && c < columns && r < rows && walkable[r * columns + c]
    }

    /// The nearest walkable cell to a point, for a start that is somewhere odd — a tank
    /// pressed into a wall, say.
    private func nearestWalkable(to point: Vec2) -> (Int, Int)? {
        let (c0, r0) = cell(of: point)
        if isWalkable(c0, r0) { return (c0, r0) }
        for ring in 1...4 {
            for dc in -ring...ring {
                for dr in -ring...ring where abs(dc) == ring || abs(dr) == ring {
                    if isWalkable(c0 + dc, r0 + dr) { return (c0 + dc, r0 + dr) }
                }
            }
        }
        return nil
    }

    /// A* over eight neighbours. Returns the cell centres to drive through, ending at the
    /// goal's cell, or nothing if there is no way there.
    func path(from start: Vec2, to goal: Vec2) -> [Vec2] {
        guard let s = nearestWalkable(to: start), let g = nearestWalkable(to: goal) else { return [] }
        if s == g { return [Self.center(g.0, g.1)] }
        let count = columns * rows
        func index(_ c: Int, _ r: Int) -> Int { r * columns + c }
        let goalIndex = index(g.0, g.1)
        var cameFrom = [Int](repeating: -1, count: count)
        var cost = [Double](repeating: .infinity, count: count)
        var closed = [Bool](repeating: false, count: count)
        var open: [(index: Int, f: Double)] = []
        let startIndex = index(s.0, s.1)
        cost[startIndex] = 0
        func heuristic(_ i: Int) -> Double {
            let (c, r) = (i % columns, i / columns)
            return Double(abs(c - g.0) + abs(r - g.1))
        }
        open.append((startIndex, heuristic(startIndex)))

        while !open.isEmpty {
            var best = 0
            for i in 1..<open.count where open[i].f < open[best].f { best = i }
            let current = open.remove(at: best).index
            if current == goalIndex { break }
            if closed[current] { continue }
            closed[current] = true
            let (c, r) = (current % columns, current / columns)
            for dc in -1...1 {
                for dr in -1...1 where dc != 0 || dr != 0 {
                    let (nc, nr) = (c + dc, r + dr)
                    guard isWalkable(nc, nr) else { continue }
                    // No cutting corners: a diagonal needs both orthogonal neighbours
                    // clear, or the tank clips the block between them.
                    if dc != 0 && dr != 0 && !(isWalkable(c + dc, r) && isWalkable(c, r + dr)) { continue }
                    let n = index(nc, nr)
                    if closed[n] { continue }
                    let step = dc != 0 && dr != 0 ? 1.414 : 1.0
                    let tentative = cost[current] + step
                    if tentative < cost[n] {
                        cost[n] = tentative
                        cameFrom[n] = current
                        open.append((n, tentative + heuristic(n)))
                    }
                }
            }
        }
        guard cost[goalIndex].isFinite else { return [] }
        var route: [Vec2] = []
        var i = goalIndex
        while i != startIndex && i >= 0 {
            route.append(Self.center(i % columns, i / columns))
            i = cameFrom[i]
        }
        return route.reversed()
    }
}

/// What a bot does with a pad. One per bot; the game asks it every tick.
///
/// Deliberately simple and readable rather than clever: pick the nearest enemy, shoot if
/// there is a clear line, otherwise drive toward them along a planned route, and get out
/// of the way of anything coming. What makes it feel like an opponent rather than a
/// turret is the dodging and the fact that it will come and find you.
struct BotBrain {
    private var rng: SeededGenerator
    private var route: [Vec2] = []
    private var replanAt: TimeInterval = -.infinity
    private var decideAt: TimeInterval = -.infinity
    private var controls: Controls = []
    private var lastPosition: Vec2?
    private var lastProgressAt: TimeInterval = -.infinity
    private var unstickUntil: TimeInterval = -.infinity
    private var unstickTurn: Controls = .left
    private var nextShotAt: TimeInterval = -.infinity
    private var aimError: Double = 0
    /// Shells this bot has decided not to bother about. Rolled once per shell, or a bot
    /// that dodges half the time would re-roll every tenth of a second and dodge always.
    private var ignoredShells: Set<UUID> = []

    static let replanInterval: TimeInterval = 0.5

    init(seed: UInt64) {
        rng = SeededGenerator(seed: seed)
    }

    /// What to hold and whether to fire, this tick.
    mutating func decide(for me: PlayerState, in game: Game, at now: TimeInterval) -> (Controls, fire: Bool) {
        guard now >= decideAt else { return (controls, false) }
        let tuning = game.difficulty.tuning
        decideAt = now + tuning.reactionTime
        let settings = game.settings
        let radius = settings.tankRadius

        // Stuck: driving but not moving. Back out and turn, then think again.
        if let last = lastPosition, controls.drive != 0 {
            if me.position.distance(to: last) > 3 {
                lastProgressAt = now
            } else if now - lastProgressAt > 0.6 {
                unstickUntil = now + 0.5
                unstickTurn = Bool.random(using: &rng) ? .left : .right
                lastProgressAt = now
                route.removeAll()
            }
        } else {
            lastProgressAt = now
        }
        lastPosition = me.position
        if now < unstickUntil {
            controls = [.reverse, unstickTurn]
            return (controls, false)
        }

        // Something coming: get out of its way before anything else — if this bot is
        // the kind that notices.
        if tuning.dodgeHorizon > 0,
           let away = incomingThreat(to: me, shells: game.shells, radius: radius + settings.shellRadius,
                                     horizon: tuning.dodgeHorizon, chance: tuning.dodgeChance) {
            let diff = Self.wrap(away.heading - me.heading)
            controls = abs(diff) < .pi / 2
                ? Self.steer(from: me.heading, to: away.heading, drive: 1, tolerance: 1.2)
                : Self.steer(from: me.heading, to: Self.wrap(away.heading + .pi), drive: -1, tolerance: 1.2)
            return (controls, false)
        }

        let enemies = game.players.values.filter {
            $0.id != me.id && $0.isAlive && !$0.isEliminated && !$0.isShielded(at: now)
        }
        guard let target = enemies.min(by: {
            $0.position.distance(to: me.position) < $1.position.distance(to: me.position)
        }) else {
            // Nobody to fight. Drift toward the middle so a returning player is not met
            // by a bot sitting in a corner.
            controls = drive(toward: game.arena.center, me: me, game: game, at: now)
            return (controls, false)
        }

        let distance = me.position.distance(to: target.position)
        if distance <= tuning.range, game.hasLineOfSight(from: me.position, to: target.position) {
            // Lead the shot by however far they will get while the shell is in the air —
            // as much of that as this level allows for — with an error that changes each
            // time so a bot is not a laser. On Impossible it is a laser.
            let velocity = Vec2(heading: target.heading)
                * (settings.tankSpeed * game.effectiveControls(of: target, at: now).drive)
            let aim = target.position + velocity * (distance / settings.shellSpeed * tuning.lead)
            if now >= nextShotAt {
                aimError = tuning.aimError > 0
                    ? Double.random(in: -tuning.aimError...tuning.aimError, using: &rng) : 0
            }
            let desired = Self.wrap((aim - me.position).heading + aimError)
            // Keep a fighting distance: close in on a distant target, back off from one
            // that is on top of you, hold otherwise.
            let drive: Double = distance > 420 ? 1 : (distance < 160 ? -1 : 0)
            controls = Self.steer(from: me.heading, to: desired, drive: drive, tolerance: 0.9)
            let aligned = abs(Self.wrap(desired - me.heading)) < 0.07
            var fire = false
            if aligned, now >= nextShotAt {
                fire = true
                nextShotAt = now + Double.random(in: tuning.shotInterval, using: &rng)
            }
            route.removeAll()
            return (controls, fire)
        }

        controls = drive(toward: target.position, me: me, game: game, at: now)
        // Nowhere to drive — bricked in, most likely. Shoot the way they are, which on
        // the one map where this happens eats through the bricks.
        if route.isEmpty, now >= nextShotAt {
            let desired = (target.position - me.position).heading
            controls = Self.steer(from: me.heading, to: desired, drive: 0, tolerance: 0.5)
            if abs(Self.wrap(desired - me.heading)) < 0.1 {
                nextShotAt = now + 0.8
                return (controls, true)
            }
        }
        return (controls, false)
    }

    /// Follows a planned route toward a point, re-planning every so often.
    private mutating func drive(toward goal: Vec2, me: PlayerState, game: Game, at now: TimeInterval) -> Controls {
        if now >= replanAt || route.isEmpty {
            replanAt = now + Self.replanInterval
            let grid = NavGrid(arena: game.arena, solids: game.navSolids(), radius: game.settings.tankRadius)
            route = grid.path(from: me.position, to: goal)
        }
        while let next = route.first, me.position.distance(to: next) < 28 { route.removeFirst() }
        guard !route.isEmpty else { return [] }

        // Aim for the farthest waypoint that can be reached in a straight line, so the
        // grid's staircase becomes a drive.
        var waypoint = route[0]
        for candidate in route.prefix(8).reversed()
        where game.isClearDrive(from: me.position, to: candidate) {
            waypoint = candidate
            break
        }
        let desired = (waypoint - me.position).heading
        return Self.steer(from: me.heading, to: desired, drive: 1, tolerance: 0.7)
    }

    /// The direction to move to avoid the most imminent shell, or nil if nothing is
    /// coming. Closest-approach test: where will each shell be nearest to us, and when.
    private mutating func incomingThreat(to me: PlayerState, shells: [Shell], radius: Double,
                                         horizon: Double, chance: Double) -> Vec2? {
        var soonest: (when: Double, away: Vec2)?
        if ignoredShells.count > 64 { ignoredShells.removeAll() }
        for shell in shells where !ignoredShells.contains(shell.id) {
            let relative = shell.position - me.position
            let speedSquared = shell.velocity.dot(shell.velocity)
            guard speedSquared > 0 else { continue }
            let when = -relative.dot(shell.velocity) / speedSquared
            guard when > 0, when < horizon else { continue }
            let closest = relative + shell.velocity * when
            guard closest.length < radius + 34 else { continue }
            if chance < 1, Double.random(in: 0..<1, using: &rng) >= chance {
                ignoredShells.insert(shell.id)
                continue
            }
            if soonest == nil || when < soonest!.when {
                // Step away from where it will pass. If it is dead on, step to one side.
                var away = -closest
                if away.length < 1 { away = Vec2(x: -shell.velocity.y, y: shell.velocity.x) }
                soonest = (when, away.normalized)
            }
        }
        return soonest?.away
    }

    // MARK: - Steering

    /// Turn toward a heading and, once roughly there, drive.
    static func steer(from heading: Double, to desired: Double, drive: Double, tolerance: Double) -> Controls {
        let diff = wrap(desired - heading)
        var controls: Controls = []
        if diff > 0.05 { controls.insert(.left) } else if diff < -0.05 { controls.insert(.right) }
        if abs(diff) < tolerance {
            if drive > 0 { controls.insert(.forward) } else if drive < 0 { controls.insert(.reverse) }
        }
        return controls
    }

    static func wrap(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a < -.pi { a += 2 * .pi }
        return a
    }
}
