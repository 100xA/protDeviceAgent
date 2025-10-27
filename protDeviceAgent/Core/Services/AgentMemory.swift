import Foundation

@MainActor
final class AgentMemory: ObservableObject {
    @Published private(set) var messages: [AgentMessage] = []
    @Published private(set) var lastUpdated: Date = Date()

    private let maxMessages: Int = 200

    func append(_ message: AgentMessage) {
        messages.append(message)
        if messages.count > maxMessages {
            messages.removeFirst(messages.count - maxMessages)
        }
        lastUpdated = Date()
    }

    func recent(limit: Int) -> [AgentMessage] {
        Array(messages.suffix(limit))
    }

    func clear() {
        messages.removeAll()
        lastUpdated = Date()
    }
}



