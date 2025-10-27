import Foundation

enum LogLevel: String, Codable, CaseIterable {
    case debug
    case info
    case warning
    case error
}

struct LogEntry: Identifiable, Codable {
    let id: String
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String
    let context: [String: String]?
}

@MainActor
final class AppLogger: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    var enabledLevels: Set<LogLevel> = Set(LogLevel.allCases)
    var maxEntries: Int = 500

    func log(_ level: LogLevel, _ category: String, _ message: String, context: [String: String]? = nil) {
        guard enabledLevels.contains(level) else { return }
        let entry = LogEntry(
            id: UUID().uuidString,
            timestamp: Date(),
            level: level,
            category: category,
            message: message,
            context: context
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        // Print to console (terminal) without emojis
        let dateFormatter = ISO8601DateFormatter()
        let ts = dateFormatter.string(from: entry.timestamp)
        if let ctx = context, !ctx.isEmpty {
            let ctxStr = ctx.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            print("[\(ts)] [\(level.rawValue.uppercased())] [\(category)] \(message) | \(ctxStr)")
        } else {
            print("[\(ts)] [\(level.rawValue.uppercased())] [\(category)] \(message)")
        }
    }

    func clear() {
        entries.removeAll()
    }
}


