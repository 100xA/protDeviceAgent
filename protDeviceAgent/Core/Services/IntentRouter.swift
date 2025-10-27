import Foundation

struct IntentThresholds {
    static let high: Double = 0.80
    static let low: Double = 0.55
}

struct IntentRouter {
    func classify(_ text: String) -> IntentClassification {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .init(type: .unknown, confidence: 0.0, reasoning: "Empty input") }

        let lower = trimmed.lowercased()
        var scores: [(IntentType, Double, String)] = []

        // Quick keyword-based scoring
        if lower.hasSuffix("?") {
            scores.append((.question, 0.75, "Ends with question mark"))
        }
        if lower.contains("explain") || lower.contains("help") || lower.contains("tell me") {
            scores.append((.conversation, 0.65, "Conversation keywords"))
        }
        if lower.contains("search ") || lower.contains("google ") || lower.contains("open ") || lower.contains("screenshot") || lower.contains("sms") || lower.contains("message ") || lower.contains("whatsapp") || lower.contains("where am i") || lower.contains("my location") || lower.contains("coordinates") || lower.contains("note") || lower.contains("notizen") || lower.contains("notes app") || lower.contains("write into notes") || lower.contains("schreibe ") {
            scores.append((.toolUse, 0.70, "Tool keywords"))
        }
        if lower.contains("and then") || lower.contains("and afterwards") || lower.contains("then ") {
            scores.append((.chatPlusTool, 0.65, "Hybrid phrasing"))
        }

        if scores.isEmpty {
            scores.append((.conversation, 0.55, "Default to conversation"))
        }

        let best = scores.max(by: { $0.1 < $1.1 })!
        let (type, conf, why) = best
        if conf < IntentThresholds.low {
            return .init(type: .needsClarification, confidence: conf, reasoning: "Low confidence: \(why)")
        }
        return .init(type: type, confidence: conf, reasoning: why)
    }
}



