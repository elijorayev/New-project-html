import Foundation
import OralBKit

private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

/// Local brushing history, kept as JSON in the app's Documents folder (visible in the Files app).
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var sessions: [SessionRecord] = []
    let url = documents.appendingPathComponent("history.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([SessionRecord].self, from: data) {
            sessions = saved
        }
    }

    func add(_ session: SessionRecord) { merge([session]) }

    /// Adds sessions, skipping any that start within a minute of one already stored.
    func merge(_ new: [SessionRecord]) {
        for s in new where !sessions.contains(where: { abs($0.start.timeIntervalSince(s.start)) < 60 }) {
            sessions.append(s)
        }
        sessions.sort { $0.start > $1.start }
        try? JSONEncoder().encode(sessions).write(to: url, options: .atomic)
    }
}

struct Backup: Codable {
    let taken: Date
    let modelType: UInt8
    let availableModes: Data
}

/// One available-modes backup per brush. Saving again never overwrites the first backup;
/// the original is what you restore to.
enum BackupStore {
    static func url(_ id: UUID) -> URL { documents.appendingPathComponent("backup-\(id.uuidString).json") }

    static func load(_ id: UUID) -> Backup? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder().decode(Backup.self, from: data)
    }

    static func save(_ backup: Backup, for id: UUID) throws {
        guard load(id) == nil else { return }
        try JSONEncoder().encode(backup).write(to: url(id), options: .atomic)
    }
}
