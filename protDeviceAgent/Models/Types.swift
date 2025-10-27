import Foundation

enum AgentState: Equatable {
    case idle
    case listening
    case processing
    case executing
    case waitingForConfirmation
    case awaitingClarification
    case repairingParameters
    case error(String)
}

enum IntentType: String, Codable {
    case question
    case toolUse
    case conversation
    case chatPlusTool
    case needsClarification
    case unknown
}

struct IntentClassification: Codable {
    let type: IntentType
    let confidence: Double
    let reasoning: String
}

struct ToolCall: Identifiable, Codable {
    let id: String
    let name: String
    let parameters: [String: AnyCodable]
}

struct ToolResult: Codable {
    let toolCallId: String
    let success: Bool
    let result: String
    let error: String?
    let artifacts: [String: String]?
}

enum AgentMessage: Identifiable {
    case user(String)
    case assistant(String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case system(String)

    var id: String {
        switch self {
        case .user(let text): return "user_\(text.hashValue)\(UUID().uuidString)"
        case .assistant(let text): return "assistant_\(text.hashValue)\(UUID().uuidString)"
        case .toolCall(let call): return "toolcall_\(call.id)"
        case .toolResult(let res): return "toolresult_\(res.toolCallId)\(UUID().uuidString)"
        case .system(let text): return "system_\(text.hashValue)\(UUID().uuidString)"
        }
    }
}

struct AgentCapability: Identifiable, Codable {
    let id: String
    let name: String
    var enabled: Bool
    var requiresConfirmation: Bool
    let description: String
}

struct MultiStepPlan: Codable {
    let originalRequest: String
    let estimatedDuration: Int
    var steps: [PlannedStep]
}

struct PlannedStep: Identifiable, Codable {
    let id: String
    let toolName: String
    let parameters: [String: AnyCodable]
    let dependsOn: [String]
    var priority: Int
    let description: String
}



