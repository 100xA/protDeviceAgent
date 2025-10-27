import Foundation
import os
import Darwin.Mach

// Lightweight helpers for timing and process telemetry.

struct Stopwatch {
    private let startTime: TimeInterval = Date().timeIntervalSince1970
    func elapsedMs() -> Int {
        let now = Date().timeIntervalSince1970
        return Int((now - startTime) * 1000.0)
    }
}

enum ThermalState: String {
    case nominal, fair, serious, critical, unknown

    static func current() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }
}

import MetricKit

func currentResidentMemoryBytes() -> UInt64 {
    // Use task_info to read current process RSS in bytes.
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
        }
    }
    if kerr == KERN_SUCCESS {
        return UInt64(info.resident_size)
    }
    return 0
}

// Returns cumulative CPU time (user + system) for the current process in seconds.
func currentProcessCPUSeconds() -> Double {
    var info = task_thread_times_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.stride / MemoryLayout<natural_t>.stride)
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), intPtr, &count)
        }
    }
    guard kerr == KERN_SUCCESS else { return 0 }
    let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000.0
    let sys  = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000.0
    return user + sys
}

@MainActor
final class DeviceMetricsObserver: NSObject, MXMetricManagerSubscriber {
    private let logger: AppLogger
    init(logger: AppLogger) { self.logger = logger }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            let ts = ISO8601DateFormatter().string(from: p.timeStampBegin)
            if let cpu = p.cpuMetrics?.cumulativeCPUTime { logger.log(.info, "metrics", "mx_cpu", context: ["begin": ts, "cumulative_s": String(describing: cpu)]) }
            if let mem = p.memoryMetrics?.peakMemoryUsage { logger.log(.info, "metrics", "mx_mem", context: ["begin": ts, "peak": String(describing: mem)]) }
            logger.log(.info, "metrics", "mx_thermal_snapshot", context: [
                "begin": ts,
                "thermal_state": ThermalState.current().rawValue
            ])
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { }
}

@MainActor
func startMetricKit(logger: AppLogger) {
    MXMetricManager.shared.add(DeviceMetricsObserver(logger: logger))
}

func formatBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(bytes)
    var idx = 0
    while value >= 1024.0 && idx < units.count - 1 {
        value /= 1024.0
        idx += 1
    }
    return String(format: "%.1f%@", value, units[idx])
}


