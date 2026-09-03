import AppKit
import SpriteKit
import RicochetCore

/// Draws the tanks, the shells, and whatever just happened to either. In arena
/// coordinates, like the field.
final class TankLayer: SKNode {

    private var tanks: [UUID: TankNode] = [:]
    private var shells: [UUID: SKNode] = [:]
    private var seats: [UUID: Int] = [:]
    private var names: [UUID: String] = [:]

    func sync(players: [PlayerState], shells live: [Shell], at now: TimeInterval) {
        let livePlayers = Set(players.map(\.id))
        for (id, node) in tanks where !livePlayers.contains(id) {
            node.removeFromParent()
            tanks.removeValue(forKey: id)
            seats.removeValue(forKey: id)
            names.removeValue(forKey: id)
        }
        for player in players {
            seats[player.id] = player.seat
            names[player.id] = player.name
            let node = tanks[player.id] ?? make(player)
            node.position = CGPoint(x: player.position.x, y: player.position.y)
            node.hull.zRotation = player.heading
            node.isHidden = !player.isAlive
            // A shield blinks rather than tints: at television distance a dimmer tank is a
            // tank in shadow, a blinking one is unmistakably not yet in play.
            if player.isShielded(at: now) {
                node.hull.alpha = Int(now * 8) % 2 == 0 ? 0.35 : 0.85
            } else {
                node.hull.alpha = player.isEliminated ? 0.3 : 1
            }
        }

        let liveShells = Set(live.map(\.id))
        for (id, node) in shells where !liveShells.contains(id) {
            node.removeFromParent()
            shells.removeValue(forKey: id)
        }
        for shell in live {
            let node = shells[shell.id] ?? makeShell(shell)
            node.position = CGPoint(x: shell.position.x, y: shell.position.y)
        }
    }

    private func color(of id: UUID) -> NSColor {
        SceneStyle.color(seat: seats[id] ?? 0)
    }

    private func make(_ player: PlayerState) -> TankNode {
        let node = TankNode(color: SceneStyle.color(seat: player.seat), name: player.name,
                            radius: 22)
        node.zPosition = 10
        addChild(node)
        tanks[player.id] = node
        return node
    }

    private func makeShell(_ shell: Shell) -> SKNode {
        let color = color(of: shell.owner)
        let node = SKNode()
        let glow = SKShapeNode(circleOfRadius: 11)
        glow.fillColor = color.withAlphaComponent(0.25)
        glow.strokeColor = .clear
        node.addChild(glow)
        let core = SKShapeNode(circleOfRadius: 5)
        core.fillColor = color
        core.strokeColor = .white
        core.lineWidth = 1.5
        node.addChild(core)
        node.zPosition = 12
        addChild(node)
        shells[shell.id] = node
        return node
    }

    // MARK: - What happened

    func show(_ events: [Game.Event]) {
        for event in events {
            switch event {
            case .bounced(_, let at):
                spark(at: CGPoint(x: at.x, y: at.y))
            case .destroyed(let victim, let cause, let at):
                explode(at: CGPoint(x: at.x, y: at.y), color: color(of: victim))
                let point = clampedToArena(CGPoint(x: at.x, y: at.y))
                switch cause {
                case .shell(let by) where by == victim:
                    floatText("OWN GOAL", at: point, color: .systemRed, size: 26)
                case .shell(let by):
                    floatText("+1 \(names[by] ?? "")", at: point, color: color(of: by), size: 26)
                case .crushed:
                    floatText("CRUSHED", at: point, color: .systemOrange, size: 26)
                case .pit:
                    floatText("FELL IN", at: point, color: .systemOrange, size: 26)
                }
            case .brickBroken(let rect):
                crumble(at: CGPoint(x: rect.center.x, y: rect.center.y))
            case .teleported(_, let to):
                arrive(at: CGPoint(x: to.x, y: to.y), color: NSColor(calibratedRed: 0.8, green: 0.6, blue: 1, alpha: 1))
            case .mapChanged:
                break   // the field rebuilds itself; the HUD says the name
            case .respawned(let player, let at):
                arrive(at: CGPoint(x: at.x, y: at.y), color: color(of: player))
            case .eliminated(let player):
                if let node = tanks[player] {
                    floatText("OUT", at: clampedToArena(node.position), color: .systemRed, size: 30)
                }
            case .expired(_, let at):
                fizzle(at: CGPoint(x: at.x, y: at.y))
            }
        }
    }

    func show(_ result: TriggerResult, for id: UUID) {
        guard let node = tanks[id] else { return }
        switch result {
        case .fired:
            node.flash()
        case .readied(let ready):
            node.hull.run(.sequence([.scale(to: ready ? 1.3 : 0.8, duration: 0.08),
                                     .scale(to: 1, duration: 0.12)]))
            floatText(ready ? "READY" : "not ready", at: node.position,
                      color: ready ? .systemGreen : NSColor(calibratedWhite: 0.6, alpha: 1), size: 24)
        case .refused, .ignored, .noSuchPlayer:
            break   // nothing happened, so nothing is drawn
        }
    }

    /// The arena's size, for keeping text on screen. Set by the scene.
    var arenaSize = CGSize(width: Map.width, height: Map.height)

    /// Floating text near an edge would rise off the arena, so it is pulled in.
    private func clampedToArena(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 90), arenaSize.width - 90),
                y: min(max(point.y, 20), arenaSize.height - 90))
    }

    private func crumble(at point: CGPoint) {
        for i in 0..<6 {
            let piece = SKShapeNode(rectOf: CGSize(width: 10, height: 10))
            piece.fillColor = NSColor(calibratedRed: 0.65, green: 0.45, blue: 0.30, alpha: 1)
            piece.strokeColor = .clear
            piece.position = point
            piece.zPosition = 16
            addChild(piece)
            let angle = Double(i) / 6 * 2 * .pi
            piece.run(.sequence([
                .group([.moveBy(x: cos(angle) * 40, y: sin(angle) * 40, duration: 0.35),
                        .rotate(byAngle: 2, duration: 0.35), .fadeOut(withDuration: 0.35)]),
                .removeFromParent(),
            ]))
        }
    }

    private func spark(at point: CGPoint) {
        let ring = SKShapeNode(circleOfRadius: 8)
        ring.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.8)
        ring.lineWidth = 2
        ring.position = point
        ring.zPosition = 15
        ring.setScale(0.4)
        addChild(ring)
        ring.run(.sequence([.group([.scale(to: 1.4, duration: 0.15), .fadeOut(withDuration: 0.15)]),
                            .removeFromParent()]))
    }

    private func fizzle(at point: CGPoint) {
        let dot = SKShapeNode(circleOfRadius: 5)
        dot.fillColor = NSColor(calibratedWhite: 0.6, alpha: 0.6)
        dot.strokeColor = .clear
        dot.position = point
        dot.zPosition = 15
        addChild(dot)
        dot.run(.sequence([.group([.scale(to: 0.2, duration: 0.2), .fadeOut(withDuration: 0.2)]),
                           .removeFromParent()]))
    }

    /// A ring and a scatter of the tank's own colour, so from across the room it is clear
    /// whose tank that was.
    private func explode(at point: CGPoint, color: NSColor) {
        let ring = SKShapeNode(circleOfRadius: 24)
        ring.strokeColor = color
        ring.lineWidth = 4
        ring.position = point
        ring.zPosition = 16
        ring.setScale(0.3)
        addChild(ring)
        ring.run(.sequence([.group([.scale(to: 2.6, duration: 0.45), .fadeOut(withDuration: 0.45)]),
                            .removeFromParent()]))

        for i in 0..<10 {
            let piece = SKShapeNode(rectOf: CGSize(width: 8, height: 8))
            piece.fillColor = i % 3 == 0 ? .white : color
            piece.strokeColor = .clear
            piece.position = point
            piece.zPosition = 16
            addChild(piece)
            let angle = Double(i) / 10 * 2 * .pi + 0.3
            let distance = 60.0 + Double(i % 4) * 18
            piece.run(.sequence([
                .group([
                    .moveBy(x: cos(angle) * distance, y: sin(angle) * distance, duration: 0.5),
                    .rotate(byAngle: 3, duration: 0.5),
                    .fadeOut(withDuration: 0.5),
                ]),
                .removeFromParent(),
            ]))
        }
    }

    private func arrive(at point: CGPoint, color: NSColor) {
        let ring = SKShapeNode(circleOfRadius: 40)
        ring.strokeColor = color
        ring.lineWidth = 3
        ring.position = point
        ring.zPosition = 9
        addChild(ring)
        ring.run(.sequence([.group([.scale(to: 0.5, duration: 0.35), .fadeOut(withDuration: 0.35)]),
                            .removeFromParent()]))
    }
}

/// One tank: a hull that rotates with the heading, and a name that does not.
final class TankNode: SKNode {

    let hull = SKNode()
    private let barrelLength: CGFloat = 30

    init(color: NSColor, name: String, radius: CGFloat) {
        super.init()

        let body = SKShapeNode(rectOf: CGSize(width: radius * 2, height: radius * 1.6), cornerRadius: 6)
        body.fillColor = color.withAlphaComponent(0.35)
        body.strokeColor = color
        body.lineWidth = 3
        hull.addChild(body)

        // Tracks either side, so a hull reads as a vehicle rather than a badge.
        for side in [-1.0, 1.0] {
            let track = SKShapeNode(rectOf: CGSize(width: radius * 2.1, height: 6), cornerRadius: 2)
            track.fillColor = color.withAlphaComponent(0.8)
            track.strokeColor = .clear
            track.position = CGPoint(x: 0, y: side * radius * 0.85)
            hull.addChild(track)
        }

        let barrel = SKShapeNode(rectOf: CGSize(width: barrelLength, height: 7), cornerRadius: 2)
        barrel.fillColor = color
        barrel.strokeColor = .clear
        barrel.position = CGPoint(x: radius * 0.5 + barrelLength / 2, y: 0)
        hull.addChild(barrel)

        let turret = SKShapeNode(circleOfRadius: radius * 0.5)
        turret.fillColor = color
        turret.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.6)
        turret.lineWidth = 2
        hull.addChild(turret)

        addChild(hull)

        let label = SceneStyle.label(size: 15, color: color)
        label.text = name
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .bottom
        label.position = CGPoint(x: 0, y: radius + 8)
        addChild(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A muzzle flash at the end of the barrel.
    func flash() {
        let flash = SKShapeNode(circleOfRadius: 9)
        flash.fillColor = NSColor(calibratedRed: 1, green: 0.9, blue: 0.6, alpha: 1)
        flash.strokeColor = .clear
        flash.position = CGPoint(x: 11 + barrelLength + 6, y: 0)
        flash.zPosition = 1
        hull.addChild(flash)
        flash.run(.sequence([.group([.scale(to: 1.8, duration: 0.08), .fadeOut(withDuration: 0.08)]),
                             .removeFromParent()]))
        hull.run(.sequence([.moveBy(x: -3, y: 0, duration: 0.03), .moveBy(x: 3, y: 0, duration: 0.06)]))
    }
}
