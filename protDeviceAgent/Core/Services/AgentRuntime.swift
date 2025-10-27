import Foundation

@MainActor
final class AgentRuntime: ObservableObject {
    @Published var state: AgentState = .idle
    @Published var capabilities: [AgentCapability] = []

    let memory = AgentMemory()
    let router = IntentRouter()
    let confirmer = AlertConfirmationManager()
    let llm = LLMInference()
    lazy var executor = ToolExecutor(llm: llm)
    lazy var planner = AgentPlanner(llm: llm)
    var logger: AppLogger?

    init() {
        capabilities = [
            .init(id: "send_message", name: "Send Message", enabled: true, requiresConfirmation: true, description: "Opens SMS composer"),
            .init(id: "send_whatsapp", name: "Send WhatsApp", enabled: true, requiresConfirmation: true, description: "Opens WhatsApp or wa.me"),
            .init(id: "get_location", name: "Get Location", enabled: true, requiresConfirmation: false, description: "Returns coordinates"),
            .init(id: "open_url", name: "Open URL", enabled: true, requiresConfirmation: false, description: "Open links"),
            .init(id: "search_web", name: "Search Web", enabled: true, requiresConfirmation: false, description: "Open Google search"),
            .init(id: "share_content", name: "Share Content", enabled: true, requiresConfirmation: true, description: "Share sheet"),
        ]
    }

    func processInput(_ text: String) async {
        state = .processing
        let requestId = UUID().uuidString
        let start = Stopwatch()
        let startMem = currentResidentMemoryBytes()
        let startThermal = ThermalState.current()
        if let logger { llm.logger = logger; executor.logger = logger }
        llm.currentRequestId = requestId
        memory.append(.user(text))
        let intent = router.classify(text)
        logger?.log(.info, "runtime", "Received input", context: [
            "request_id": requestId,
            "text": text,
            "intent": intent.type.rawValue,
            "confidence": String(format: "%.2f", intent.confidence),
            "why": intent.reasoning
        ])
        switch intent.type {
        case .needsClarification:
            state = .awaitingClarification
            memory.append(.assistant("Can you make the question more precise"))
            state = .idle
            return
        case .question, .conversation:
            if !llm.isReady {
                let approved = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    confirmer.requestDownloadApproval(modelName: "Gemma 2 2B (4-bit)") { ok in
                        cont.resume(returning: ok)
                    }
                }
                if approved {
                    logger?.log(.info, "runtime", "Starting model warmup")
                    await llm.warmup()
                    logger?.log(.info, "runtime", "Model warmup completed", context: ["ready": String(llm.isReady)])
                } else {
                    memory.append(.assistant("Model download canceled. I can’t answer without the local model."))
                    state = .idle
                    return
                }
            }
            llm.logger = logger
            let reply = await llm.generateResponse(prompt: text, maxTokens: 0)
            memory.append(.assistant(reply))
            state = .idle
            let endMs = start.elapsedMs()
            let endMem = currentResidentMemoryBytes()
            let thermal = ThermalState.current()
            logger?.log(.info, "metrics", "e2e_conversation", context: [
                "request_id": requestId,
                "duration_ms": String(endMs),
                "rss_before": formatBytes(startMem),
                "rss_after": formatBytes(endMem),
                "thermal_before": startThermal.rawValue,
                "thermal_after": thermal.rawValue
            ])
        case .chatPlusTool:
           
            if llm.isReady {
                llm.logger = logger
                llm.currentRequestId = requestId
                let reply = await llm.generateResponse(prompt: text, maxTokens: 1024)
                memory.append(.assistant(reply))
            }
            await handleToolUse(text)
        case .toolUse:
            logger?.log(.info, "runtime", "Handling tool use")
            await handleToolUse(text)
        case .unknown:
            memory.append(.assistant("I’m not sure how to help with that yet."))
            state = .idle
        }
    }

    private func handleToolUse(_ text: String) async {
        state = .executing
        if let plan = await planner.plan(for: text) {
            let risky = plan.steps.contains { isRisky(tool: $0.toolName) }
            logger?.log(.info, "planner", "Created plan", context: ["steps": String(plan.steps.count)])

            if risky {
                let riskyNames = Array(Set(plan.steps.filter { isRisky(tool: $0.toolName) }.map { $0.toolName })).joined(separator: ", ")
                let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    confirmer.requestPlanApproval(description: "Execute \(plan.steps.count) steps including sensitive action(s): \(riskyNames)?") { approved in
                        cont.resume(returning: approved)
                    }
                }
                if !ok {
                    memory.append(.assistant("Canceled."))
                    state = .idle
                    return
                }
            }

            var planOutputs: [String: ToolResult] = [:]
            let steps = plan.steps
            var executed = Set<String>()
            let total = steps.count

            while executed.count < total {
                let ready = steps
                    .filter { !executed.contains($0.id) }
                    .filter { $0.dependsOn.allSatisfy { executed.contains($0) } }
                    .sorted { lhs, rhs in
                        if lhs.priority == rhs.priority { return lhs.id < rhs.id }
                        return lhs.priority < rhs.priority
                    }

                if ready.isEmpty {
                    memory.append(.assistant("Plan halted due to cyclic or unsatisfied dependencies."))
                    logger?.log(.warning, "planner", "No ready steps; possible cycle or missing deps")
                    break
                }

                for step in ready {
                    logger?.log(.debug, "planner", "Execute step", context: ["tool": step.toolName, "desc": step.description])

                    // Resolve templates from previous step artifacts, then validate
                    let resolvedParams = resolveTemplates(step.parameters, using: planOutputs)
                    if let tool = ToolRegistry.tools.first(where: { $0.name == step.toolName }) {
                        let validation = validateParameters(for: tool, parameters: resolvedParams)
                        if !validation.isValid {
                            logger?.log(.warning, "planner", "Step validation failed", context: ["errors": validation.errors.joined(separator: ", ")])
                            memory.append(.assistant("Step skipped due to invalid parameters."))
                            executed.insert(step.id) // prevent deadlock
                            continue
                        }
                    }

                    memory.append(.toolCall(.init(id: UUID().uuidString, name: step.toolName, parameters: resolvedParams)))
                    let res = await executor.execute(name: step.toolName, parameters: resolvedParams)
                    planOutputs[step.id] = res
                    memory.append(.toolResult(res))
                    executed.insert(step.id)
                }
            }
            state = .idle
            memory.append(.assistant("All steps completed."))
            return
        }

        // 1) Try LLM-based tool selection
        if llm.isReady {
            // Timeout wrapper for tool selection to avoid long inference on trivial intents
            func withTimeout<T>(_ nanoseconds: UInt64, _ op: @escaping @Sendable () async -> T?) async -> T? {
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

            let selection = await withTimeout(200_000_000) { // 200ms budget
                await self.llm.inferToolCall(from: text, tools: ToolRegistry.tools)
            }
            switch selection ?? .none {
            case .selected(let name, let parameters, let confidence):
                logger?.log(.info, "tools", "Model selected tool", context: ["name": name, "confidence": String(format: "%.2f", confidence)])
                logger?.log(.info, "tools", "Model selected tool", context: ["name": name])
                if isRisky(tool: name) {
                    let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                        confirmer.requestPlanApproval(description: "Use tool \(name)?") { approved in
                            cont.resume(returning: approved)
                        }
                    }
                    if !ok { memory.append(.assistant("Canceled.")); state = .idle; return }
                }
                // Validate parameters before execution
                if let tool = ToolRegistry.tools.first(where: { $0.name == name }) {
                    let validation = validateParameters(for: tool, parameters: parameters)
                    if !validation.isValid {
                        logger?.log(.warning, "tools", "Parameter validation failed", context: ["errors": validation.errors.joined(separator: ", ")])
                        memory.append(.assistant("Parameters invalid."))
                        state = .repairingParameters
                        state = .idle
                        return
                    }
                }
                memory.append(.toolCall(.init(id: UUID().uuidString, name: name, parameters: parameters)))
                let res = await executor.execute(name: name, parameters: parameters)
                memory.append(.toolResult(res))
                state = .idle
                return
            case .none:
                logger?.log(.debug, "tools", "Model did not select a tool")
                break
            }
        }

        // 2) Heuristic fallbacks
        let lower = text.lowercased()
        if lower.contains("search ") {
            let query = text.replacingOccurrences(of: "search ", with: "")
            let params: [String: AnyCodable] = ["query": AnyCodable(query)]
            logger?.log(.debug, "heuristic", "search_web")
            memory.append(.toolCall(.init(id: UUID().uuidString, name: "search_web", parameters: params)))
            let res = await executor.execute(name: "search_web", parameters: params)
            memory.append(.toolResult(res))
            state = .idle
            memory.append(.assistant("Opened a web search."))
            return
        }
        if let r = text.range(of: "open ", options: [.caseInsensitive]) {
            let urlTail = text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let params: [String: AnyCodable] = ["urlString": AnyCodable(urlTail)]
            logger?.log(.debug, "heuristic", "open_url")
            memory.append(.toolCall(.init(id: UUID().uuidString, name: "open_url", parameters: params)))
            let res = await executor.execute(name: "open_url", parameters: params)
            memory.append(.toolResult(res))
            state = .idle
            memory.append(.assistant(res.success ? "Opened the link." : "Invalid link."))
            return
        }
        if lower.contains("where am i") || lower.contains("my location") || lower.contains("coordinates") {
            logger?.log(.debug, "heuristic", "get_location")
            memory.append(.toolCall(.init(id: UUID().uuidString, name: "get_location", parameters: [:])))
            let res = await executor.execute(name: "get_location", parameters: [:])
            memory.append(.toolResult(res))
            state = .idle
            memory.append(.assistant(res.result))
            return
        }
        if lower.contains("whatsapp") {
            let message = text.replacingOccurrences(of: "whatsapp", with: "").trimmingCharacters(in: .whitespaces)
            let params: [String: AnyCodable] = ["message": AnyCodable(message)]
            logger?.log(.debug, "heuristic", "send_whatsapp")
            memory.append(.toolCall(.init(id: UUID().uuidString, name: "send_whatsapp", parameters: params)))
            let res = await executor.execute(name: "send_whatsapp", parameters: params)
            memory.append(.toolResult(res))
            state = .idle
            memory.append(.assistant(res.success ? "Opened WhatsApp." : "Opened browser fallback."))
            return
        }
        if lower.contains("text ") || lower.contains("sms") || lower.contains("message ") {
            let parsed = parseMessageCommand(text)
            let params: [String: AnyCodable] = [
                "recipient": AnyCodable(parsed.recipient),
                "message": AnyCodable(parsed.message)
            ]
            logger?.log(.debug, "heuristic", "send_message")
            memory.append(.toolCall(.init(id: UUID().uuidString, name: "send_message", parameters: params)))
            let res = await executor.execute(name: "send_message", parameters: params)
            memory.append(.toolResult(res))
            state = .idle
            memory.append(.assistant(res.success ? "Message composer opened." : "Messages composer unavailable."))
            return
        }

        memory.append(.assistant("No applicable tool found."))
        logger?.log(.warning, "tools", "No tool matched heuristics")
        state = .idle
    }

    private func isRisky(tool: String) -> Bool {
        ["send_message", "send_whatsapp", "share_content"].contains(tool)
    }

    private func resolveTemplates(_ params: [String: AnyCodable], using outputs: [String: ToolResult]) -> [String: AnyCodable] {
        func resolveString(_ s: String) -> String {
            var out = s
            let pattern = #"\$\{([a-zA-Z0-9-]+)\.artifacts\.([a-zA-Z0-9_]+)\}"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
            let nsRange = NSRange(out.startIndex..<out.endIndex, in: out)
            let matches = regex.matches(in: out, range: nsRange)
            for m in matches.reversed() {
                guard m.numberOfRanges == 3,
                      let idRange = Range(m.range(at: 1), in: out),
                      let keyRange = Range(m.range(at: 2), in: out) else { continue }
                let stepId = String(out[idRange])
                let key = String(out[keyRange])
                let replacement = outputs[stepId]?.artifacts?[key] ?? ""
                if let fullRange = Range(m.range(at: 0), in: out) {
                    out.replaceSubrange(fullRange, with: replacement)
                }
            }
            return out
        }

        var resolved: [String: AnyCodable] = [:]
        for (k, v) in params {
            if let s = v.value as? String {
                resolved[k] = AnyCodable(resolveString(s))
            } else {
                resolved[k] = v
            }
        }
        return resolved
    }

    private func parseMessageCommand(_ text: String) -> (recipient: String, message: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()

        func trim(_ s: Substring) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let r = lower.range(of: "message to ") ?? lower.range(of: "text to ") ?? lower.range(of: "sms to ") {
            let after = t[r.upperBound...]
            if let sep = after.firstIndex(where: { [":", ",", "-"] .contains($0) }) {
                let name = trim(after[..<sep])
                let body = trim(after[after.index(after: sep)...])
                if !name.isEmpty && !body.isEmpty { return (name, body) }
            } else {
                let comps = after.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if comps.count == 2 {
                    return (trim(comps[0]), trim(comps[1]))
                }
                return ("", trim(after))
            }
        }

        if lower.hasPrefix("text ") || lower.hasPrefix("sms ") || lower.hasPrefix("message ") {
            let words = t.split(separator: " ", omittingEmptySubsequences: true)
            if words.count >= 3 {
                let name = String(words[1])
                let body = words.dropFirst(2).joined(separator: " ")
                return (name, body)
            } else if words.count >= 2 {
                return ("", words.dropFirst(1).joined(separator: " "))
            }
        }

        return ("", t)
    }
}



