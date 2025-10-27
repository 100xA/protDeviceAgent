import Foundation

struct ToolParameterSpec: Codable {
    let name: String
    let type: String
    let optional: Bool
}

struct ToolDefinition: Codable {
    let name: String
    let description: String
    let parameters: [ToolParameterSpec]
    let requiresConfirmation: Bool
}

enum ToolSelection {
    case selected(name: String, parameters: [String: AnyCodable], confidence: Double)
    case none
}

enum ToolSelectionError: Error {
    case invalidJSON
}


