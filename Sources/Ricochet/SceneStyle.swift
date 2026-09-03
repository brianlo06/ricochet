import AppKit
import SpriteKit
import RicochetCore

/// The few presentation decisions shared by more than one part of the scene.
enum SceneStyle {
    /// One typeface throughout: numbers that line up in a column and letters nobody has to
    /// lean in for.
    static let font = "Menlo-Bold"

    /// Distinct colours per seat, so players can tell their tanks apart at TV distance.
    /// The spacing is `SeatPalette`'s problem, and it is checked there.
    static func color(seat: Int) -> NSColor {
        let (hue, saturation, brightness) = SeatPalette.color(seat: seat)
        return NSColor(calibratedHue: CGFloat(hue), saturation: CGFloat(saturation),
                       brightness: CGFloat(brightness), alpha: 1)
    }

    static func label(size: CGFloat, color: NSColor) -> SKLabelNode {
        let label = SKLabelNode(fontNamed: font)
        label.fontSize = size
        label.fontColor = color
        return label
    }
}

extension SKNode {
    /// A number or a word that rises off the point it happened at and fades.
    func floatText(_ text: String, at point: CGPoint, color: NSColor, size: CGFloat = 20) {
        let label = SceneStyle.label(size: size, color: color)
        label.text = text
        label.position = CGPoint(x: point.x, y: point.y + 30)
        label.zPosition = 30
        addChild(label)
        label.run(.sequence([
            .group([.moveBy(x: 0, y: 40, duration: 0.6), .fadeOut(withDuration: 0.6)]),
            .removeFromParent(),
        ]))
    }
}
