import Foundation

@MainActor
final class ScenarioRunner {
    struct Scenario {
        let name: String
        let input: String
        let warmModel: Bool
        let repetitions: Int
    }

    struct ScenarioResult: Codable {
        let name: String
        let cold: Bool
        let runs: Int
        let p50_ms: Int
        let p90_ms: Int
        let p95_ms: Int
        let successRate: Double
        let avgTTFT_ms: Double
        let avgOutputTokens: Double
        let peakRSS_bytes: UInt64
        // Extended metrics
        let avgCPU_s: Double
        let p95CPU_s: Double
        let worstThermal: String
        let thermalNominalPct: Double
        let thermalSeriousPlusPct: Double
        let avgRSSBefore_bytes: UInt64
        let avgRSSAfter_bytes: UInt64
        let avgRSSDelta_bytes: Int64
        let llmUsedPct: Double
    }

    private let runtime: AgentRuntime
    private let logger: AppLogger

    init(runtime: AgentRuntime, logger: AppLogger) {
        self.runtime = runtime
        self.logger = logger
        runtime.logger = logger
        runtime.executor.logger = logger
        runtime.llm.logger = logger
    }

    func run(_ s: Scenario) async -> ScenarioResult {
        var durations: [Int] = []
        var successes = 0
        var ttfts: [Int] = []
        var outTokens: [Int] = []
        var peakRSS: UInt64 = 0
        var cpuDeltas: [Double] = []
        var thermalBefores: [ThermalState] = []
        var thermalAfters: [ThermalState] = []
        var rssBefores: [UInt64] = []
        var rssAfters: [UInt64] = []
        var tpsList: [Double] = []
        var llmUses: Int = 0

        if s.warmModel { await runtime.llm.warmup() }

        for i in 0..<s.repetitions {
            if !s.warmModel && i == 0 {
                // simulate cold start by reinitializing model
                runtime.llm.downloadProgress = nil
            }
            let cpuBefore = currentProcessCPUSeconds()
            let thermalBefore = ThermalState.current()
            let rssBefore = currentResidentMemoryBytes()

            let start = Date()
            await runtime.processInput(s.input)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            durations.append(ms)

            let cpuAfter = currentProcessCPUSeconds()
            let thermalAfter = ThermalState.current()
            let rssAfter = currentResidentMemoryBytes()

            cpuDeltas.append(max(0, cpuAfter - cpuBefore))
            thermalBefores.append(thermalBefore)
            thermalAfters.append(thermalAfter)
            rssBefores.append(rssBefore)
            rssAfters.append(rssAfter)

            // tie metrics to the current request via request_id
            if let lastRuntime = logger.entries.last(where: { $0.category == "runtime" && $0.message == "Received input" })?.context,
               let rid = lastRuntime["request_id"] ?? runtime.memory.messages.last?.id,
               let inf = logger.entries.last(where: { $0.category == "inference" && ($0.context?["request_id"] == rid) })?.context {
                if let ttft = Int(inf["ttft_ms"] ?? "") { ttfts.append(ttft) } else { ttfts.append(0) }
                if let tps = Double(inf["tps"] ?? "") { tpsList.append(tps) }
                llmUses += 1
            } else {
                // No inference for this request: pad with 0 to keep averages consistent
                ttfts.append(0)
            }

            if case .assistant(let text) = runtime.memory.messages.last {
                if !text.lowercased().contains("canceled") && !text.lowercased().contains("invalid") {
                    successes += 1
                }
            }
            peakRSS = max(peakRSS, currentResidentMemoryBytes())

            // Cool-down to reduce thermal throttling across repetitions
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        }

        func percentile(_ xs: [Int], _ p: Double) -> Int {
            guard !xs.isEmpty else { return 0 }
            let s = xs.sorted()
            let i = min(max(Int(Double(s.count - 1) * p), 0), s.count - 1)
            return s[i]
        }

        func percentileD(_ xs: [Double], _ p: Double) -> Double {
            guard !xs.isEmpty else { return 0 }
            let s = xs.sorted()
            let i = min(max(Int(Double(s.count - 1) * p), 0), s.count - 1)
            return s[i]
        }
        func avgU64(_ xs: [UInt64]) -> UInt64 {
            guard !xs.isEmpty else { return 0 }
            return UInt64(xs.reduce(0 as UInt64, +) / UInt64(xs.count))
        }
        func avgI64(_ xs: [Int64]) -> Int64 {
            guard !xs.isEmpty else { return 0 }
            return xs.reduce(0, +) / Int64(xs.count)
        }

        let avgTTFT = ttfts.isEmpty ? 0 : Double(ttfts.reduce(0,+)) / Double(ttfts.count)
        let avgOutTok = outTokens.isEmpty ? 0 : Double(outTokens.reduce(0,+)) / Double(outTokens.count)
        let avgCPU = cpuDeltas.isEmpty ? 0 : cpuDeltas.reduce(0,+) / Double(cpuDeltas.count)
        let p95CPU = percentileD(cpuDeltas, 0.95)

        let nominalCount = thermalAfters.filter { $0 == .nominal }.count
        let seriousPlusCount = thermalAfters.filter { $0 == .serious || $0 == .critical }.count
        func rank(_ t: ThermalState) -> Int { switch t { case .nominal: return 0; case .fair: return 1; case .serious: return 2; case .critical: return 3; case .unknown: return 4 } }
        let worst = thermalAfters.max(by: { rank($0) < rank($1) }) ?? .unknown

        let avgRSSBefore = avgU64(rssBefores)
        let avgRSSAfter  = avgU64(rssAfters)
        let avgRSSDelta  = avgI64(zip(rssAfters, rssBefores).map { Int64($0.0) - Int64($0.1) })

        return ScenarioResult(
            name: s.name,
            cold: !s.warmModel,
            runs: s.repetitions,
            p50_ms: percentile(durations, 0.5),
            p90_ms: percentile(durations, 0.9),
            p95_ms: percentile(durations, 0.95),
            successRate: s.repetitions == 0 ? 0 : Double(successes) / Double(s.repetitions),
            avgTTFT_ms: avgTTFT,
            avgOutputTokens: avgOutTok,
            peakRSS_bytes: peakRSS,
            avgCPU_s: avgCPU,
            p95CPU_s: p95CPU,
            worstThermal: worst.rawValue,
            thermalNominalPct: thermalAfters.isEmpty ? 0 : Double(nominalCount) / Double(thermalAfters.count),
            thermalSeriousPlusPct: thermalAfters.isEmpty ? 0 : Double(seriousPlusCount) / Double(thermalAfters.count),
            avgRSSBefore_bytes: avgRSSBefore,
            avgRSSAfter_bytes: avgRSSAfter,
            avgRSSDelta_bytes: avgRSSDelta,
            llmUsedPct: s.repetitions == 0 ? 0 : Double(llmUses) / Double(s.repetitions)
        )
    }

    static func markdownTable(_ results: [ScenarioResult]) -> String {
        var lines: [String] = []
        lines.append("| Scenario | Cold | Runs | p50 (ms) | p90 (ms) | p95 (ms) | Avg TTFT (ms) | LLM Used (%) | Avg CPU (s) | Worst Thermal | Avg RSS Δ | Peak RSS |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|")
        for r in results {
            let ttft = String(format: "%.0f", r.avgTTFT_ms)
            let llm = String(format: "%.0f", r.llmUsedPct * 100)
            let cpu  = String(format: "%.2f", r.avgCPU_s)
            let rssDelta = formatBytes(UInt64(max(0, r.avgRSSDelta_bytes)))
            let rssPeak  = formatBytes(r.peakRSS_bytes)
            lines.append("| \(r.name) | \(r.cold ? "Yes" : "No") | \(r.runs) | \(r.p50_ms) | \(r.p90_ms) | \(r.p95_ms) | \(ttft) | \(llm) | \(cpu) | \(r.worstThermal) | \(rssDelta) | \(rssPeak) |")
        }
        return lines.joined(separator: "\n")
    }
}


