import Foundation

@MainActor
final class AgentPlanner: ObservableObject {
    private let llm: LLMInference
    init(llm: LLMInference) { self.llm = llm }

    func plan(for input: String) async -> MultiStepPlan? {
        let lower = input.lowercased()
        var steps: [PlannedStep] = []
        var prio = 1

        // 1) Extract clauses (lightweight, punctuation and connectors)
        let clauses = extractClauses(from: input)
        var unmatched: [String] = []
        var lastGeneratedTextStepIdByClauseIndex: [Int: String] = [:]

        // 2) Rule-based intents for known tools
        for (idx, rawClause) in clauses.enumerated() {
            let clause = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerClause = clause.lowercased()
            var producedAny = false

            // search_web
            if lowerClause.hasPrefix("search for ") || lowerClause.hasPrefix("search ") {
                var term = lowerClause
                    .replacingOccurrences(of: "search for ", with: "")
                    .replacingOccurrences(of: "search ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !term.isEmpty {
                    steps.append(.init(
                        id: UUID().uuidString,
                        toolName: "search_web",
                        parameters: ["query": AnyCodable(term)],
                        dependsOn: [],
                        priority: prio,
                        description: "Web search for: \(term)"
                    ))
                    prio += 1
                    producedAny = true
                }
            }

            // get_location
            if lowerClause.contains("where am i") || lowerClause.contains("where i am") || lowerClause.contains("my location") || lowerClause.contains("coordinates") {
                steps.append(.init(
                    id: UUID().uuidString,
                    toolName: "get_location",
                    parameters: [:],
                    dependsOn: [],
                    priority: prio,
                    description: "Get current location"
                ))
                prio += 1
                producedAny = true
            }

            // share to notes / produce_text
            if lowerClause.contains("note") || lowerClause.contains("notizen") || lowerClause.contains("notes app") || lowerClause.contains("write into notes") {
                if let quoted = extractQuoted(rawClause), !quoted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    steps.append(.init(
                        id: UUID().uuidString,
                        toolName: "share_content",
                        parameters: ["text": AnyCodable(quoted)],
                        dependsOn: [],
                        priority: prio,
                        description: "Share provided text to Notes via share sheet"
                    ))
                    prio += 1
                } else {
                    let genId = UUID().uuidString
                    let prompt = ensureSentence(from: clause)
                    let gen = PlannedStep(
                        id: genId,
                        toolName: "produce_text",
                        parameters: ["prompt": AnyCodable("Write a short note summarizing: \(prompt)")],
                        dependsOn: [],
                        priority: prio,
                        description: "Generate note content"
                    )
                    let share = PlannedStep(
                        id: UUID().uuidString,
                        toolName: "share_content",
                        parameters: ["text": AnyCodable("${\(genId).artifacts.text}")],
                        dependsOn: [genId],
                        priority: prio + 1,
                        description: "Open share sheet to save to Notes"
                    )
                    steps.append(gen)
                    steps.append(share)
                    lastGeneratedTextStepIdByClauseIndex[idx] = genId
                    prio += 2
                }
                producedAny = true
            } else if lowerClause.hasPrefix("give me") || lowerClause.hasPrefix("list") || lowerClause.hasPrefix("write") || lowerClause.hasPrefix("summarize") || lowerClause.hasPrefix("explain") {
                let prompt = ensureSentence(from: clause)
                let genId = UUID().uuidString
                steps.append(.init(
                    id: genId,
                    toolName: "produce_text",
                    parameters: ["prompt": AnyCodable(prompt)],
                    dependsOn: [],
                    priority: prio,
                    description: "Generate text: \(prompt)"
                ))
                lastGeneratedTextStepIdByClauseIndex[idx] = genId
                prio += 1
                producedAny = true
            }

            if !producedAny { unmatched.append(clause) }
        }

        // 3) LLM backfill only for unmatched clauses
        if !unmatched.isEmpty {
            if let auto = await withTimeout(5_000_000_000, { 
                await self.llm.proposePlan(for: unmatched.joined(separator: ". "), tools: ToolRegistry.tools, maxSteps: 5)
            }) {
                // Merge while keeping priorities increasing
                for s in auto.steps {
                    var merged = s
                    merged.priority = prio
                    prio += 1
                    steps.append(merged)
                }
            }
        }

        // 4) Guardrails: dedupe simple duplicates (same tool+desc) and cap steps
        var seen: Set<String> = []
        var unique: [PlannedStep] = []
        for s in steps {
            let key = "\(s.toolName)|\(s.description)"
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(s)
            }
        }
        steps = Array(unique.prefix(8))

        guard !steps.isEmpty else { return nil }
        return MultiStepPlan(originalRequest: input, estimatedDuration: max(steps.count * 3, 4), steps: steps)
    }

    // MARK: - Helpers
    private func extractClauses(from input: String) -> [String] {
        let lowered = input.replacingOccurrences(of: "\n", with: " ")
        let separators = [" and then ", " then ", " and ", ", then ", ", and ", ". ", "? ", "! "]
        var parts: [String] = [lowered]
        for sep in separators { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func extractQuoted(_ text: String) -> String? {
        if let start = text.firstIndex(of: "\""), let end = text.index(start, offsetBy: 1, limitedBy: text.endIndex).flatMap({ _ in text[text.index(after: start)...].firstIndex(of: "\"") }) {
            return String(text[text.index(after: start)..<end])
        }
        return nil
    }

    private func ensureSentence(from s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasSuffix(".") ? t : (t + ".")
    }

    private func withTimeout<T>(_ nanoseconds: UInt64, _ op: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }
}



