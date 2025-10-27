import Foundation
import MLXLLM
import MLXLMCommon
import os

// Metrics
import Foundation

@MainActor
final class LLMInference: ObservableObject {
    private var container: ModelContainer?
    @Published var downloadProgress: Progress?
    @Published var errorMessage: String?
    @Published var isDownloading: Bool = false
    @Published var isDownloaded: Bool = false
    let modelConfiguration: ModelConfiguration = ModelRegistry.gemma_2_2b_it_4bit
    var isReady: Bool { container != nil }
    var logger: AppLogger?
    var currentRequestId: String?

    private var downloadedFlagDefaultsKey: String {
        // Persist per-model-id to reflect whether assets have been fetched before
        "mlx_model_downloaded_\(modelConfiguration.id)"
    }

    init() {
        // Initialize from previously persisted state so Settings can reflect cached downloads on launch
        isDownloaded = UserDefaults.standard.bool(forKey: downloadedFlagDefaultsKey)
    }

    func warmup() async {
        if container != nil { return }
        do {
            let factory = LLMModelFactory.shared
            isDownloading = true
            container = try await factory.loadContainer(
                configuration: modelConfiguration
            ) { progress in
                Task { @MainActor in
                    self.downloadProgress = progress
                }
            }
            isDownloading = false
            // Mark as downloaded for subsequent app launches
            isDownloaded = true
            UserDefaults.standard.set(true, forKey: downloadedFlagDefaultsKey)
        } catch {
            isDownloading = false
            errorMessage = error.localizedDescription
        }
    }

    func generateResponse(prompt: String, maxTokens: Int = 256) async -> String {
        guard let container else { return "" }
        do {
            let sw = Stopwatch()
            var firstTokenMs: Int? = nil
            let result = try await container.perform { context in
                let input = try await context.processor.prepare(input: .init(prompt: .text(prompt)))
                var generated = 0
                var partial = ""
                // Allow more content before considering a graceful stop at sentence boundary
                let unlimited = maxTokens <= 0
                let minTokensForEOS = unlimited ? 1024 : max(1024, (maxTokens * 3))
                func endsWithSentence(_ s: String) -> Bool {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let last = t.last else { return false }
                    return ".?!…".contains(last)
                }
                return try MLXLMCommon.generate(input: input, parameters: .init(), context: context) { tokens in
                    if firstTokenMs == nil { firstTokenMs = sw.elapsedMs() }
                    generated += tokens.count
                    // accumulate partial text for sentence boundary detection
                    let chunk = context.tokenizer.decode(tokens: tokens)
                    partial += chunk
                    // hard cap only when a positive limit is set
                    if !unlimited && generated >= maxTokens { return .stop }
                    // graceful stop at sentence boundary after minimum tokens
                    if generated >= minTokensForEOS && endsWithSentence(partial) { return .stop }
                    return .more
                }
            }
            let durationMs = sw.elapsedMs()
            let ttft = firstTokenMs ?? durationMs
            let tps = result.tokensPerSecond
            var ctx: [String: String] = [
                "duration_ms": String(durationMs),
                "ttft_ms": String(ttft),
                "tps": String(format: "%.2f", tps)
            ]
            if let rid = currentRequestId { ctx["request_id"] = rid }
            logger?.log(.info, "inference", "generateResponse", context: ctx)
            return result.output
        } catch {
            return "I’m having trouble generating a response locally right now."
        }
    }
}

struct ToolCallProposal: Codable {
    let name: String
    let parameters: [String: String]
    let confidence: Double
}

extension LLMInference {
    func inferToolCall(from input: String, tools: [ToolDefinition]) async -> ToolSelection {
        guard isReady else { return .none }

        let toolsJSON: String = {
            let encoder = JSONEncoder()
            let data = try? encoder.encode(tools)
            return String(data: data ?? Data(), encoding: .utf8) ?? "[]"
        }()

        let system = """
        You are a tool selector. Choose the best tool and fill parameters.
        Only output compact JSON: {"name":"...","parameters":{...},"confidence":0.0-1.0}
        Use the given tool list and their parameter specs strictly.
        If no tool applies, output {"name":"","parameters":{},"confidence":0.0}
        Tools:
        \(toolsJSON)
        """
        let user = "User input: \(input)"
        let prompt = system + "\n" + user

        let jsonText = await generateResponse(prompt: prompt, maxTokens: 516)
        guard let data = jsonText.data(using: .utf8),
              let proposal = try? JSONDecoder().decode(ToolCallProposal.self, from: data) else {
            return .none
        }

        guard let tool = tools.first(where: { $0.name == proposal.name }), proposal.confidence >= 0.5 else {
            return .none
        }

        var coerced: [String: AnyCodable] = [:]
        for spec in tool.parameters {
            if let raw = proposal.parameters[spec.name] {
                switch spec.type {
                case "int":
                    coerced[spec.name] = AnyCodable(Int(raw) ?? 0)
                case "url":
                    coerced[spec.name] = AnyCodable(raw)
                case "phone":
                    coerced[spec.name] = AnyCodable(raw.filter { "+0123456789".contains($0) })
                default:
                    coerced[spec.name] = AnyCodable(raw)
                }
            } else if !spec.optional {
                return .none
            }
        }

        return .selected(name: tool.name, parameters: coerced, confidence: proposal.confidence)
    }
}

// MARK: - Generic multi-step plan proposal
extension LLMInference {
    private struct PlanStepProposal: Codable {
        let name: String
        let parameters: [String: String]
        let dependsOn: [Int]
        let description: String
        let priority: Int?
    }

    private struct PlanProposal: Codable {
        let steps: [PlanStepProposal]
        let confidence: Double
    }

    func proposePlan(for input: String, tools: [ToolDefinition], maxSteps: Int = 5) async -> MultiStepPlan? {
        guard isReady else { return nil }

        let toolsJSON: String = {
            let encoder = JSONEncoder()
            let data = try? encoder.encode(tools)
            return String(data: data ?? Data(), encoding: .utf8) ?? "[]"
        }()

        let system = """
        You are a planner for an on-device iOS agent. Decompose the user's request into ATOMIC, independent intents, and create a minimal multi-step plan using ONLY the provided tools.

        OUTPUT STRICT JSON with this shape:
        {"steps":[{"name":"...","parameters":{"k":"v"},"dependsOn":[indices],"description":"...","priority":1}...],"confidence":0.0-1.0}

        RULES:
        - Decompose into separate steps for unrelated intents (e.g., "search X" and "give me Y" become two steps).
        - NEVER include full original input in any parameter. Scope parameters ONLY to their own intent.
        - For "search_web": "query" MUST be only the topic keywords (2–6 words), not the whole sentence.
        - For "produce_text": "prompt" MUST be a concise imperative instruction about its intent only.
        - Use only tools listed in Tools; parameter keys MUST match the schema exactly.
        - Insert a small WAIT step between multiple share or compose actions.
        - Keep steps <= \(maxSteps).
        - Use dependsOn indices (0-based) ONLY when a later step needs artifacts from earlier steps. Avoid artificial dependencies.
        Tools:
        \(toolsJSON)
        """
        let user = "User request: \(input)"
        let prompt = system + "\n" + user

        let jsonText = await generateResponse(prompt: prompt, maxTokens: 1024)
        guard let data = jsonText.data(using: .utf8),
              let proposal = try? JSONDecoder().decode(PlanProposal.self, from: data),
              proposal.confidence >= 0.5,
              !proposal.steps.isEmpty else {
            return nil
        }

        func sanitizeQuery(_ raw: String, fullInput: String) -> String {
            var q = raw
            q = q.replacingOccurrences(of: "search for ", with: "", options: .caseInsensitive)
                 .replacingOccurrences(of: "search ", with: "", options: .caseInsensitive)
                 .trimmingCharacters(in: .whitespacesAndNewlines)
            let cuts = [" and then ", " then ", " and ", ", then ", ", and "]
            for c in cuts {
                if let r = q.range(of: c) { q = String(q[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            let words = q.split(separator: " ").prefix(6)
            q = words.joined(separator: " ")
            if q.isEmpty {
                if let m = fullInput.lowercased().range(of: #"search( for)? (.+?)(,| and | then |$)"#, options: .regularExpression) {
                    var cand = String(fullInput.lowercased()[m])
                    cand = cand.replacingOccurrences(of: "search", with: "", options: .caseInsensitive)
                               .replacingOccurrences(of: "for", with: "", options: .caseInsensitive)
                               .trimmingCharacters(in: .whitespacesAndNewlines)
                    q = cand.split(separator: " ").prefix(6).joined(separator: " ")
                }
            }
            return q
        }

        var steps: [PlannedStep] = []
        var ids: [String] = [] // previously created step ids in order

        for (idx, s) in proposal.steps.enumerated() {
            guard let tool = tools.first(where: { $0.name == s.name }) else { continue }

            var coerced: [String: AnyCodable] = [:]
            var valid = true
            for spec in tool.parameters {
                if let raw = s.parameters[spec.name] {
                    switch spec.type {
                    case "int":
                        coerced[spec.name] = AnyCodable(Int(raw) ?? 0)
                    case "url":
                        coerced[spec.name] = AnyCodable(raw)
                    case "phone":
                        coerced[spec.name] = AnyCodable(raw.filter { "+0123456789".contains($0) })
                    default:
                        coerced[spec.name] = AnyCodable(raw)
                    }
                } else if !spec.optional {
                    valid = false
                    break
                }
            }
            if !valid { continue }

            // Post-normalization guardrails
            if tool.name == "search_web" {
                let raw = (s.parameters["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = sanitizeQuery(raw, fullInput: input)
                if cleaned.isEmpty { continue }
                coerced["query"] = AnyCodable(cleaned)
            } else if tool.name == "produce_text" {
                if var p = s.parameters["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                    if !p.hasSuffix(".") { p += "." }
                    if let range = p.range(of: #"(\s+and\s+|\s+then\s+).*$"#, options: .regularExpression) {
                        p = String(p[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !p.hasSuffix(".") { p += "." }
                    }
                    coerced["prompt"] = AnyCodable(p)
                } else {
                    continue
                }
            }

            let id = UUID().uuidString
            let deps = s.dependsOn.compactMap { ($0 >= 0 && $0 < ids.count) ? ids[$0] : nil }
            steps.append(.init(
                id: id,
                toolName: tool.name,
                parameters: coerced,
                dependsOn: deps,
                priority: s.priority ?? (idx + 1),
                description: s.description
            ))
            ids.append(id)
        }

        guard !steps.isEmpty else { return nil }
        return MultiStepPlan(originalRequest: input, estimatedDuration: max(steps.count * 2, 4), steps: steps)
    }
}
