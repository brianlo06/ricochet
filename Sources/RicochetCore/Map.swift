import Foundation

/// The arenas a round can be played on. One is picked at random each round.
///
/// Each is a builder rather than data, because some of them are different every time —
/// the maze most of all — and all of them are laid out in fractions of the arena so one
/// logical size serves every screen. Every map is checked by the same tests: spawns clear,
/// every spawn reachable from every other with a tank's radius, nothing off the edge.
public enum Map: String, CaseIterable, Sendable {
    /// A pillar, four bars, two stubs. The original.
    case crossfire
    /// A maze with a few loops knocked through, so a dead end is a risk rather than a rule.
    case labyrinth
    /// Round bumpers. A shell coming off one keeps its bounces.
    case pinball
    /// A field of bricks. Shells eat them.
    case crumble
    /// Conveyor strips that carry tanks along whether they like it or not.
    case currents
    /// Two pairs of portals. What goes in one comes out the other.
    case portals
    /// Gates that open and close on a clock.
    case shutters
    /// A keep in the middle with a door in each wall.
    case fortress
    /// A bar that sweeps the arena. Do not be between it and a wall.
    case sweeper
    /// A chasm down the middle. Shells cross it; tanks use the bridges.
    case chasm

    public var title: String {
        switch self {
        case .crossfire: return "Crossfire"
        case .labyrinth: return "Labyrinth"
        case .pinball: return "Pinball"
        case .crumble: return "Crumble"
        case .currents: return "Currents"
        case .portals: return "Portals"
        case .shutters: return "Shutters"
        case .fortress: return "Fortress"
        case .sweeper: return "Sweeper"
        case .chasm: return "Chasm"
        }
    }

    public var summary: String {
        switch self {
        case .crossfire: return "a pillar, four bars, two stubs"
        case .labyrinth: return "a maze, different every time, with dead ends"
        case .pinball: return "bumpers — shells come off them for free"
        case .crumble: return "bricks — shells eat them"
        case .currents: return "conveyors push you along; mind the edges"
        case .portals: return "what goes in one comes out the other"
        case .shutters: return "gates open and close on a clock"
        case .fortress: return "a keep with a door in each wall"
        case .sweeper: return "the bar moves — do not be between it and a wall"
        case .chasm: return "shells cross the gap; tanks take the bridges"
        }
    }

    public static let width: Double = 1600
    public static let height: Double = 900

    /// Lays the map out. The generator is used only by the maps that vary.
    public func build(using rng: inout some RandomNumberGenerator) -> Arena {
        let (w, h) = (Map.width, Map.height)
        func block(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Rect {
            Rect(minX: x0 * w, minY: y0 * h, maxX: x1 * w, maxY: y1 * h)
        }
        func at(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x * w, y: y * h) }
        let corners = [at(0.08, 0.12), at(0.92, 0.88), at(0.92, 0.12), at(0.08, 0.88)]
        let edges = [at(0.50, 0.08), at(0.50, 0.92), at(0.06, 0.50), at(0.94, 0.50)]
        let cornerStubs = [
            block(0.18, 0.66, 0.34, 0.69), block(0.66, 0.66, 0.82, 0.69),
            block(0.18, 0.31, 0.34, 0.34), block(0.66, 0.31, 0.82, 0.34),
        ]

        var arena: Arena
        switch self {
        case .crossfire:
            arena = Arena(width: w, height: h,
                          walls: [block(0.465, 0.38, 0.535, 0.62)] + cornerStubs
                              + [block(0.30, 0.44, 0.33, 0.56), block(0.67, 0.44, 0.70, 0.56)],
                          spawns: corners + edges)

        case .labyrinth:
            arena = Map.maze(width: w, height: h, columns: 8, rows: 5, using: &rng)

        case .pinball:
            arena = Arena(width: w, height: h,
                          walls: [block(0.20, 0.20, 0.23, 0.32), block(0.77, 0.20, 0.80, 0.32),
                                  block(0.20, 0.68, 0.23, 0.80), block(0.77, 0.68, 0.80, 0.80)],
                          spawns: corners + edges)
            arena.bumpers = [
                Bumper(center: at(0.50, 0.50), radius: 62),
                Bumper(center: at(0.30, 0.50), radius: 42), Bumper(center: at(0.70, 0.50), radius: 42),
                Bumper(center: at(0.50, 0.22), radius: 42), Bumper(center: at(0.50, 0.78), radius: 42),
                Bumper(center: at(0.36, 0.26), radius: 28), Bumper(center: at(0.64, 0.26), radius: 28),
                Bumper(center: at(0.36, 0.74), radius: 28), Bumper(center: at(0.64, 0.74), radius: 28),
            ]

        case .crumble:
            arena = Arena(width: w, height: h, walls: cornerStubs, spawns: corners + edges)
            // A cross of bricks through the middle, 50 points on a side, and a ring of
            // them further out. Enough to hide behind and not enough to last the round.
            var bricks: [Rect] = []
            let side = 50.0
            for i in 0..<12 {
                let x = w / 2 - side * 6 + Double(i) * side
                bricks.append(Rect(minX: x, minY: h / 2 - side, maxX: x + side, maxY: h / 2 + side))
            }
            for j in 0..<8 where j < 3 || j > 4 {
                let y = h / 2 - side * 4 + Double(j) * side
                bricks.append(Rect(minX: w / 2 - side, minY: y, maxX: w / 2 + side, maxY: y + side))
            }
            for (cx, cy) in [(0.25, 0.50), (0.75, 0.50), (0.50, 0.14), (0.50, 0.86)] {
                for k in 0..<3 {
                    let x = cx * w - side * 1.5 + Double(k) * side
                    bricks.append(Rect(minX: x, minY: cy * h - side / 2, maxX: x + side, maxY: cy * h + side / 2))
                }
            }
            arena.bricks = bricks

        case .currents:
            arena = Arena(width: w, height: h,
                          walls: [block(0.465, 0.40, 0.535, 0.60),
                                  block(0.12, 0.48, 0.22, 0.52), block(0.78, 0.48, 0.88, 0.52)],
                          spawns: corners + edges)
            arena.conveyors = [
                Conveyor(rect: block(0.10, 0.62, 0.90, 0.72), push: Vec2(x: 150, y: 0)),
                Conveyor(rect: block(0.10, 0.28, 0.90, 0.38), push: Vec2(x: -150, y: 0)),
                Conveyor(rect: block(0.40, 0.72, 0.46, 0.92), push: Vec2(x: 0, y: 130)),
                Conveyor(rect: block(0.54, 0.08, 0.60, 0.28), push: Vec2(x: 0, y: -130)),
            ]

        case .portals:
            arena = Arena(width: w, height: h,
                          walls: [block(0.465, 0.30, 0.535, 0.70),
                                  block(0.24, 0.48, 0.40, 0.52), block(0.60, 0.48, 0.76, 0.52)],
                          spawns: corners + edges)
            arena.portals = [
                Portal(a: at(0.18, 0.80), b: at(0.82, 0.20), radius: 34),
                Portal(a: at(0.82, 0.80), b: at(0.18, 0.20), radius: 34),
            ]

        case .shutters:
            // Four rooms around a central chamber, with a gate in each wall of it and a
            // gate at each corner of the outer ring. Different phases, so a route that is
            // closed now is open in a moment and vice versa.
            arena = Arena(width: w, height: h,
                          walls: [block(0.35, 0.30, 0.65, 0.33), block(0.35, 0.67, 0.65, 0.70),
                                  block(0.35, 0.33, 0.38, 0.44), block(0.35, 0.56, 0.38, 0.67),
                                  block(0.62, 0.33, 0.65, 0.44), block(0.62, 0.56, 0.65, 0.67),
                                  block(0.12, 0.44, 0.24, 0.47), block(0.76, 0.44, 0.88, 0.47),
                                  block(0.12, 0.53, 0.24, 0.56), block(0.76, 0.53, 0.88, 0.56)],
                          spawns: corners + edges)
            arena.gates = [
                Gate(rect: block(0.35, 0.44, 0.38, 0.56), period: 7, openFor: 3.5, phase: 0),
                Gate(rect: block(0.62, 0.44, 0.65, 0.56), period: 7, openFor: 3.5, phase: 3.5),
                Gate(rect: block(0.12, 0.47, 0.24, 0.53), period: 9, openFor: 4, phase: 2),
                Gate(rect: block(0.76, 0.47, 0.88, 0.53), period: 9, openFor: 4, phase: 6.5),
            ]

        case .fortress:
            // A keep: a ring 40% wide and 46% tall, 20 points thick, a 100-point door in
            // the middle of each wall. Corner stubs outside for cover on the approach.
            let (x0, x1, y0, y1) = (0.30, 0.70, 0.27, 0.73)
            let t = 20.0 / w
            let door = 0.06
            arena = Arena(width: w, height: h,
                          walls: [
                              block(x0, y1 - t, 0.5 - door, y1), block(0.5 + door, y1 - t, x1, y1),
                              block(x0, y0, 0.5 - door, y0 + t), block(0.5 + door, y0, x1, y0 + t),
                              block(x0, y0, x0 + t, 0.5 - door * 1.6), block(x0, 0.5 + door * 1.6, x0 + t, y1),
                              block(x1 - t, y0, x1, 0.5 - door * 1.6), block(x1 - t, 0.5 + door * 1.6, x1, y1),
                              block(0.10, 0.20, 0.13, 0.30), block(0.87, 0.20, 0.90, 0.30),
                              block(0.10, 0.70, 0.13, 0.80), block(0.87, 0.70, 0.90, 0.80),
                          ],
                          spawns: corners + edges)

        case .sweeper:
            arena = Arena(width: w, height: h,
                          walls: [block(0.10, 0.48, 0.20, 0.52), block(0.80, 0.48, 0.90, 0.52)],
                          spawns: corners + edges)
            arena.sweepers = [
                Sweeper(home: block(0.25, 0.12, 0.75, 0.16), travel: Vec2(x: 0, y: 0.72 * h), period: 14),
                Sweeper(home: block(0.22, 0.30, 0.25, 0.70), travel: Vec2(x: 0.53 * w, y: 0), period: 20),
            ]

        case .chasm:
            // The mid-edge spawns move off the strip, which runs the full height.
            arena = Arena(width: w, height: h,
                          walls: [block(0.20, 0.20, 0.23, 0.32), block(0.77, 0.68, 0.80, 0.80),
                                  block(0.36, 0.58, 0.40, 0.66), block(0.60, 0.34, 0.64, 0.42)],
                          spawns: corners + [at(0.32, 0.06), at(0.68, 0.94), at(0.06, 0.50), at(0.94, 0.50)])
            // A gap down the middle, crossed by two bridges: the pit is everything in the
            // strip except the bridges.
            arena.pits = [
                block(0.44, 0.00, 0.56, 0.18), block(0.44, 0.28, 0.56, 0.72), block(0.44, 0.82, 0.56, 1.00),
            ]
        }
        return arena
    }

    // MARK: - The maze

    /// A recursive-backtracker maze on a coarse grid, with a share of the remaining walls
    /// knocked through afterwards so there are loops. A perfect maze has one route between
    /// any two points, which for a tank battle means a chase down a corridor with no way
    /// out; the loops are what make it a battle.
    static func maze(width w: Double, height h: Double, columns: Int, rows: Int,
                     using rng: inout some RandomNumberGenerator) -> Arena {
        let cellW = w / Double(columns)
        let cellH = h / Double(rows)
        let thickness = 18.0

        // Walls between cells: `vertical[c][r]` is the wall on the right of cell (c, r),
        // `horizontal[c][r]` the wall above it. Everything starts closed.
        var vertical = Array(repeating: Array(repeating: true, count: rows), count: columns - 1)
        var horizontal = Array(repeating: Array(repeating: true, count: rows - 1), count: columns)
        var visited = Array(repeating: Array(repeating: false, count: rows), count: columns)

        var stack = [(Int, Int)]()
        var current = (Int.random(in: 0..<columns, using: &rng), Int.random(in: 0..<rows, using: &rng))
        visited[current.0][current.1] = true
        repeat {
            let (c, r) = current
            var options = [(Int, Int)]()
            if c > 0, !visited[c - 1][r] { options.append((c - 1, r)) }
            if c < columns - 1, !visited[c + 1][r] { options.append((c + 1, r)) }
            if r > 0, !visited[c][r - 1] { options.append((c, r - 1)) }
            if r < rows - 1, !visited[c][r + 1] { options.append((c, r + 1)) }
            if let next = options.randomElement(using: &rng) {
                stack.append(current)
                if next.0 != c { vertical[min(c, next.0)][r] = false }
                else { horizontal[c][min(r, next.1)] = false }
                visited[next.0][next.1] = true
                current = next
            } else if let back = stack.popLast() {
                current = back
            } else {
                break
            }
        } while true

        // Knock through about a fifth of what is left.
        for c in 0..<(columns - 1) {
            for r in 0..<rows where vertical[c][r] && Double.random(in: 0..<1, using: &rng) < 0.22 {
                vertical[c][r] = false
            }
        }
        for c in 0..<columns {
            for r in 0..<(rows - 1) where horizontal[c][r] && Double.random(in: 0..<1, using: &rng) < 0.22 {
                horizontal[c][r] = false
            }
        }

        var walls: [Rect] = []
        for c in 0..<(columns - 1) {
            for r in 0..<rows where vertical[c][r] {
                let x = Double(c + 1) * cellW
                walls.append(Rect(minX: x - thickness / 2, minY: Double(r) * cellH,
                                  maxX: x + thickness / 2, maxY: Double(r + 1) * cellH))
            }
        }
        for c in 0..<columns {
            for r in 0..<(rows - 1) where horizontal[c][r] {
                let y = Double(r + 1) * cellH
                walls.append(Rect(minX: Double(c) * cellW, minY: y - thickness / 2,
                                  maxX: Double(c + 1) * cellW, maxY: y + thickness / 2))
            }
        }

        func cellCenter(_ c: Int, _ r: Int) -> Vec2 {
            Vec2(x: (Double(c) + 0.5) * cellW, y: (Double(r) + 0.5) * cellH)
        }
        let spawns = [
            cellCenter(0, 0), cellCenter(columns - 1, rows - 1),
            cellCenter(columns - 1, 0), cellCenter(0, rows - 1),
            cellCenter(columns / 2, 0), cellCenter(columns / 2, rows - 1),
            cellCenter(0, rows / 2), cellCenter(columns - 1, rows / 2),
        ]
        return Arena(width: w, height: h, walls: walls, spawns: spawns)
    }
}
