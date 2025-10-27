import Foundation

struct ToolValidationResult {
    let isValid: Bool
    let errors: [String]
}

enum ToolParameterType: String {
    case string
    case int
    case url
    case phone
}

func validateParameters(for tool: ToolDefinition, parameters: [String: AnyCodable]) -> ToolValidationResult {
    var errors: [String] = []

    for spec in tool.parameters {
        let value = parameters[spec.name]?.value

        if value == nil && !spec.optional {
            errors.append("Missing required parameter: \(spec.name)")
            continue
        }

        guard let value else { continue }

        switch ToolParameterType(rawValue: spec.type) ?? .string {
        case .string:
            if let s = value as? String, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Parameter \(spec.name) must be a non-empty string")
            }
        case .int:
            if !(value is Int) { errors.append("Parameter \(spec.name) must be an integer") }
        case .url:
            if let s = value as? String, URL(string: s) == nil {
                errors.append("Parameter \(spec.name) must be a valid URL string")
            }
        case .phone:
            if let s = value as? String {
                let digits = s.filter { "+0123456789".contains($0) }
                if digits.isEmpty { errors.append("Parameter \(spec.name) must be a phone-like string") }
            } else {
                errors.append("Parameter \(spec.name) must be a phone-like string")
            }
        }
    }

    return ToolValidationResult(isValid: errors.isEmpty, errors: errors)
}


