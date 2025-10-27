import SwiftUI

struct LogsView: View {
    @EnvironmentObject var logger: AppLogger

    var body: some View {
        VStack {
            HStack {
                Text("Logs").font(.headline)
                Spacer()
                Button("Clear") { logger.clear() }
            }
            .padding(.horizontal)
            List(logger.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.level.rawValue.uppercased())
                            .font(.caption)
                            .foregroundColor(color(for: entry.level))
                        Text(entry.category)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(entry.message)
                    if let ctx = entry.context, !ctx.isEmpty {
                        ForEach(ctx.sorted(by: { $0.key < $1.key }), id: \ .key) { key, value in
                            Text("\(key): \(value)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}


