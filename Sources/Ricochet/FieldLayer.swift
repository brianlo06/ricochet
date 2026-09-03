import AppKit
import SpriteKit
import RicochetCore

/// The floor and everything fixed to it: blocks, bricks, bumpers, gates, sweepers,
/// conveyors, portals and pits. Built when the arena changes, nudged every frame for the
/// parts that move. In arena coordinates; the scene scales the node it lives in.
final class FieldLayer: SKNode {

    private var generation = -1
    private var bricks: [Rect: SKShapeNode] = [:]
    private var gates: [SKShapeNode] = []
    private var sweepers: [SKShapeNode] = []

    private static let block = NSColor(calibratedWhite: 0.26, alpha: 1)
    private static let edge = NSColor(calibratedWhite: 0.5, alpha: 1)

    func sync(_ game: Game, at now: TimeInterval) {
        if game.arenaGeneration != generation {
            generation = game.arenaGeneration
            build(game.arena)
        }
        let arena = game.arena

        // Bricks that have gone.
        let live = Set(arena.bricks)
        for (rect, node) in bricks where !live.contains(rect) {
            bricks.removeValue(forKey: rect)
            node.run(.sequence([.group([.fadeOut(withDuration: 0.15), .scale(to: 1.3, duration: 0.15)]),
                                .removeFromParent()]))
        }

        // Gates: solid when closed, an outline when open, and a warning flicker just
        // before they close, because a door that shuts on you without notice is unfair.
        let t = game.arenaTime(at: now)
        for (gate, node) in zip(arena.gates, gates) {
            let open = gate.isOpen(at: t)
            let soon = gate.timeUntilChange(at: t) < 0.8
            if open {
                node.fillColor = NSColor(calibratedWhite: 0.26, alpha: soon && Int(t * 10) % 2 == 0 ? 0.5 : 0.08)
                node.strokeColor = NSColor(calibratedRed: 0.4, green: 0.8, blue: 0.5, alpha: 0.7)
            } else {
                node.fillColor = NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.22, alpha: 1)
                node.strokeColor = NSColor(calibratedRed: 0.9, green: 0.4, blue: 0.4, alpha: soon && Int(t * 10) % 2 == 0 ? 1 : 0.7)
            }
        }
        for (sweeper, node) in zip(arena.sweepers, sweepers) {
            let rect = sweeper.rect(at: t)
            node.position = CGPoint(x: rect.center.x, y: rect.center.y)
        }
    }

    private func build(_ arena: Arena) {
        removeAllChildren()
        bricks.removeAll()
        gates.removeAll()
        sweepers.removeAll()

        let floor = SKShapeNode(rect: CGRect(x: 0, y: 0, width: arena.width, height: arena.height))
        floor.fillColor = NSColor(calibratedWhite: 0.075, alpha: 1)
        floor.strokeColor = NSColor(calibratedWhite: 0.32, alpha: 1)
        floor.lineWidth = 3
        floor.zPosition = 0
        addChild(floor)

        // A faint grid, because a tank on a plain floor has nothing to be seen moving
        // against, and the whole game is judging where a slow shell is going.
        let grid = CGMutablePath()
        let pitch = 100.0
        var x = pitch
        while x < arena.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: arena.height)); x += pitch }
        var y = pitch
        while y < arena.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: arena.width, y: y)); y += pitch }
        let gridNode = SKShapeNode(path: grid)
        gridNode.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.035)
        gridNode.lineWidth = 1
        gridNode.zPosition = 1
        addChild(gridNode)

        for pit in arena.pits {
            let node = shape(pit)
            node.fillColor = NSColor(calibratedWhite: 0.0, alpha: 1)
            node.strokeColor = NSColor(calibratedRed: 0.5, green: 0.15, blue: 0.15, alpha: 1)
            node.lineWidth = 3
            node.zPosition = 1
            addChild(node)
        }

        for conveyor in arena.conveyors {
            let node = shape(conveyor.rect)
            node.fillColor = NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.24, alpha: 1)
            node.strokeColor = NSColor(calibratedRed: 0.3, green: 0.5, blue: 0.8, alpha: 0.6)
            node.lineWidth = 2
            node.zPosition = 1
            addChild(node)
            // Chevrons that march the way the belt runs.
            let direction = conveyor.push.normalized
            let along = max(conveyor.rect.width, conveyor.rect.height)
            let count = Int(along / 60)
            for i in 0..<count {
                let chevron = SKLabelNode(fontNamed: SceneStyle.font)
                chevron.text = "›"
                chevron.fontSize = 30
                chevron.fontColor = NSColor(calibratedRed: 0.4, green: 0.6, blue: 0.9, alpha: 0.5)
                chevron.verticalAlignmentMode = .center
                let offset = (Double(i) + 0.5) / Double(count) - 0.5
                let center = conveyor.rect.center + direction * (offset * along)
                chevron.position = CGPoint(x: center.x, y: center.y)
                chevron.zRotation = direction.heading
                chevron.zPosition = 2
                addChild(chevron)
                chevron.run(.repeatForever(.sequence([
                    .moveBy(x: direction.x * 20, y: direction.y * 20, duration: 0.6),
                    .moveBy(x: -direction.x * 20, y: -direction.y * 20, duration: 0),
                ])))
            }
        }

        for wall in arena.walls {
            let node = shape(wall)
            node.fillColor = Self.block
            node.strokeColor = Self.edge
            node.lineWidth = 2
            node.zPosition = 2
            addChild(node)
        }

        for brick in arena.bricks {
            let node = shape(brick)
            node.fillColor = NSColor(calibratedRed: 0.40, green: 0.28, blue: 0.20, alpha: 1)
            node.strokeColor = NSColor(calibratedRed: 0.65, green: 0.45, blue: 0.30, alpha: 1)
            node.lineWidth = 2
            node.zPosition = 2
            addChild(node)
            bricks[brick] = node
        }

        for gate in arena.gates {
            let node = shape(gate.rect)
            node.lineWidth = 2
            node.zPosition = 2
            addChild(node)
            gates.append(node)
        }

        for sweeper in arena.sweepers {
            let node = SKShapeNode(rectOf: CGSize(width: sweeper.home.width, height: sweeper.home.height))
            node.fillColor = NSColor(calibratedRed: 0.45, green: 0.35, blue: 0.15, alpha: 1)
            node.strokeColor = NSColor(calibratedRed: 1, green: 0.8, blue: 0.3, alpha: 1)
            node.lineWidth = 3
            node.zPosition = 3
            addChild(node)
            sweepers.append(node)
        }

        for bumper in arena.bumpers {
            let node = SKShapeNode(circleOfRadius: bumper.radius)
            node.position = CGPoint(x: bumper.center.x, y: bumper.center.y)
            node.fillColor = NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.30, alpha: 1)
            node.strokeColor = NSColor(calibratedRed: 0.7, green: 0.7, blue: 1, alpha: 0.9)
            node.lineWidth = 4
            node.zPosition = 2
            addChild(node)
            let inner = SKShapeNode(circleOfRadius: bumper.radius * 0.45)
            inner.strokeColor = NSColor(calibratedRed: 0.7, green: 0.7, blue: 1, alpha: 0.4)
            inner.lineWidth = 2
            node.addChild(inner)
        }

        for portal in arena.portals {
            for end in [portal.a, portal.b] {
                let ring = SKShapeNode(circleOfRadius: portal.radius)
                ring.position = CGPoint(x: end.x, y: end.y)
                ring.fillColor = NSColor(calibratedRed: 0.15, green: 0.05, blue: 0.25, alpha: 0.9)
                ring.strokeColor = NSColor(calibratedRed: 0.7, green: 0.4, blue: 1, alpha: 1)
                ring.lineWidth = 3
                ring.zPosition = 1
                addChild(ring)
                let swirl = SKShapeNode(path: Self.spiral(radius: portal.radius * 0.8))
                swirl.strokeColor = NSColor(calibratedRed: 0.8, green: 0.6, blue: 1, alpha: 0.7)
                swirl.lineWidth = 2
                ring.addChild(swirl)
                swirl.run(.repeatForever(.rotate(byAngle: -2 * .pi, duration: 3)))
            }
        }
    }

    private func shape(_ rect: Rect) -> SKShapeNode {
        SKShapeNode(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
    }

    private static func spiral(radius: Double) -> CGPath {
        let path = CGMutablePath()
        let turns = 2.0
        var first = true
        for step in 0...60 {
            let fraction = Double(step) / 60
            let angle = fraction * turns * 2 * .pi
            let r = radius * fraction
            let point = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
            if first { path.move(to: point); first = false } else { path.addLine(to: point) }
        }
        return path
    }
}
