import Foundation
import RemoteKit
import RicochetCore

/// What the game remembers about a phone between evenings: its lifetime kills and the gun
/// it was using. One JSON file in the state directory, keyed by the identity the phone
/// generated once and keeps, rewritten whole on every change because it is tiny and a
/// half-written score file is worse than a slightly late one.
final class Progress {

    struct Record: Codable {
        var name: String
        var points: Int
        var weapon: String
        var updated: Date
    }

    private struct File: Codable {
        var devices: [String: Record]
    }

    private let url: URL
    private var records: [String: Record]

    init(directory: URL) {
        url = directory.appendingPathComponent("progress.json")
        if let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            records = file.devices
        } else {
            records = [:]
        }
    }

    /// How many devices have a score on file.
    var count: Int { records.count }

    func lookup(_ deviceId: String) -> (points: Int, weapon: Weapon?)? {
        guard let record = records[deviceId] else { return nil }
        return (record.points, Weapon(rawValue: record.weapon))
    }

    func record(_ deviceId: String, name: String, points: Int, weapon: Weapon) {
        let current = records[deviceId]
        // Points only ever go up. A stale write from a reconnecting session must not
        // take a kill away.
        let kept = max(points, current?.points ?? 0)
        guard current?.points != kept || current?.weapon != weapon.rawValue || current?.name != name else { return }
        records[deviceId] = Record(name: name, points: kept, weapon: weapon.rawValue, updated: Date())
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(File(devices: records)).write(to: url, options: .atomic)
        } catch {
            Log.warn("could not save progress: \(error.localizedDescription)")
        }
    }
}
