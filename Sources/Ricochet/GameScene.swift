import AppKit
import SpriteKit
import RicochetCore

/// Puts the game on the television.
///
/// Owns no rules — it reads `Game` each frame and hands what it finds to the things that
/// draw: the HUD, the join panel, the field and the tanks. The arena is a fixed logical
/// size, so the field and the tanks live in one node that is scaled to fit whatever window
/// or television this is, and the HUD is laid out in screen space over the top.
final class GameScene: SKScene {

    private let game: Game
    private let hud = HUD()
    private let joinPanel = JoinPanel()
    private let world = SKNode()
    private let field = FieldLayer()
    private let tanks = TankLayer()

    /// Called once per frame so the host can narrate phase changes to the terminal.
    var onFrame: (() -> Void)?
    /// Called with whatever a tick produced, so the host can turn it into cues.
    var onEvents: (([Game.Event]) -> Void)?
    /// Flips the sound and reports the new state, or `nil` if this Mac has no sound.
    var onToggleMute: (() -> Bool?)?
    /// One more bot, wrapping to none. Returns the count, or nil when refused.
    var onAddBot: (() -> Int?)?
    /// Another map, between rounds.
    var onReshuffleMap: (() -> Bool)?
    /// Pause or resume. Returns whether the round is now paused, or nil with no round.
    var onTogglePause: (() -> Bool?)?
    /// End the round with the scores as they stand.
    var onEndRound: (() -> Bool)?

    var joinHint: String = "" {
        didSet { hud.hint = joinHint }
    }

    init(game: Game, size: CGSize) {
        self.game = game
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMove(to view: SKView) {
        addChild(hud)
        addChild(joinPanel)
        world.addChild(field)
        world.addChild(tanks)
        addChild(world)
        layout()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        layout()
    }

    /// Height of the band above the arena that the score column needs. Grows with the
    /// roster, so eight names do not run down over the top-left spawn.
    private var topBand: CGFloat = 0

    private func layout() {
        // Room for the scores and the clock above, the hint below.
        let bottom: CGFloat = 40
        let scale = min((size.width - 40) / game.arena.width,
                        (size.height - topBand - bottom) / game.arena.height)
        world.setScale(max(scale, 0.05))
        let arenaHeight = game.arena.height * scale
        world.position = CGPoint(x: (size.width - game.arena.width * scale) / 2,
                                 y: bottom + (size.height - topBand - bottom - arenaHeight) / 2)
        hud.layout(in: size)
        joinPanel.layout(in: size)
    }

    /// Re-lays out when the roster changes how much room the scores need.
    private func fitRoster(_ count: Int) {
        let needed = max(70, 34 + CGFloat(count) * 24)
        guard needed != topBand else { return }
        topBand = needed
        layout()
    }

    func showJoinCode(url: String, address: String, code: String) {
        joinPanel.show(url: url, address: address, pairingCode: code)
    }

    override func update(_ currentTime: TimeInterval) {
        advance()
    }

    /// Advances the game and redraws from what it finds.
    ///
    /// Separate from `update(_:)` because it is also driven by a timer while the window is
    /// occluded. Rendering may stop when nobody can see the screen; the round may not.
    func advance() {
        let now = Date().timeIntervalSince1970
        let events = game.tick(at: now)
        let leaderboard = game.leaderboard
        fitRoster(leaderboard.count)
        field.sync(game, at: now)
        tanks.sync(players: leaderboard, shells: game.shells, at: now)
        tanks.show(events)
        hud.update(scores: leaderboard, in: size)

        let screen = Scoreboard.screen(for: game, at: now)
        hud.update(screen)
        hud.mapTag = Scoreboard.mapTag(for: game)
        joinPanel.isHidden = !screen.showsJoinPanel

        onEvents?(events)
        onFrame?()
    }

    func showTrigger(player id: UUID, result: TriggerResult) {
        tanks.show(result, for: id)
    }

    // MARK: - The keyboard

    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "m":
            guard let muted = onToggleMute?() else { return }
            announce(muted ? "SOUND OFF" : "SOUND ON")
        case "f":
            view?.window?.toggleFullScreen(nil)
        case "b":
            guard let count = onAddBot?() else { return announce("NOT MID-ROUND") }
            announce(count == 0 ? "NO BOTS" : "\(count) BOT\(count == 1 ? "" : "S")")
        case "n":
            if onReshuffleMap?() != true { announce("NOT MID-ROUND") }
        case "p":
            if onTogglePause?() == nil { announce("NO ROUND") }
        case "e", "\u{1B}":
            if onEndRound?() != true { announce("NO ROUND") }
        default:
            super.keyDown(with: event)
        }
    }

    private func announce(_ text: String) {
        floatText(text, at: CGPoint(x: size.width / 2, y: size.height * 0.42),
                  color: NSColor(calibratedWhite: 0.8, alpha: 1))
    }
}
