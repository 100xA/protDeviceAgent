import XCTest
@testable import protDeviceAgent

@MainActor
final class ScenarioTests: XCTestCase {
    func test_Scenarios_TableSummary() async {
        // Arrange
        let runtime = AgentRuntime()
        runtime.confirmer.autoApprove = true
        let logger = AppLogger()
        let runner = ScenarioRunner(runtime: runtime, logger: logger)

        // Start MetricKit subscriber to receive OS-level aggregates (asynchronously)
        startMetricKit(logger: logger)

        let scenarios: [ScenarioRunner.Scenario] = [
            .init(name: "Chat-short", input: "What is on-device AI?", warmModel: true, repetitions: 10),
            .init(name: "Open URL", input: "open https://example.com", warmModel: true, repetitions: 10),
            .init(name: "Search Web and share Notes", input: "search mobile edge ai and share Notes", warmModel: true, repetitions: 10)
        ]

        // Act
        var results: [ScenarioRunner.ScenarioResult] = []
        for s in scenarios {
            let r = await runner.run(s)
            results.append(r)
        }

        // Produce Markdown summary
        let md = ScenarioRunner.markdownTable(results)
        let mdAttachment = XCTAttachment(string: md)
        mdAttachment.name = "Scenario Summary (Markdown)"
        mdAttachment.lifetime = .keepAlways
        add(mdAttachment)

        // Produce CSV summary (expanded schema)
        let header = "scenario,cold,runs,p50_ms,p90_ms,p95_ms,avg_ttft_ms,success_rate,llm_used_pct,avg_cpu_s,p95_cpu_s,worst_thermal,thermal_nominal_pct,thermal_serious_plus_pct,avg_rss_before_bytes,avg_rss_after_bytes,avg_rss_delta_bytes,peak_rss_bytes\n"
        let rows = results.map { r in
            "\(r.name),\(r.cold),\(r.runs),\(r.p50_ms),\(r.p90_ms),\(r.p95_ms),\(Int(r.avgTTFT_ms)),\(String(format: "%.3f", r.successRate)),\(String(format: "%.3f", r.llmUsedPct)),\(String(format: "%.3f", r.avgCPU_s)),\(String(format: "%.3f", r.p95CPU_s)),\(r.worstThermal),\(String(format: "%.3f", r.thermalNominalPct)),\(String(format: "%.3f", r.thermalSeriousPlusPct)),\(r.avgRSSBefore_bytes),\(r.avgRSSAfter_bytes),\(r.avgRSSDelta_bytes),\(r.peakRSS_bytes)"
        }.joined(separator: "\n")
        let csvAttachment = XCTAttachment(data: Data((header + rows).utf8), uniformTypeIdentifier: "public.comma-separated-values-text")
        csvAttachment.name = "Scenario Summary (CSV)"
        csvAttachment.lifetime = .keepAlways
        add(csvAttachment)

        // Assert (sanity)
        XCTAssertFalse(results.isEmpty)
    }
}


