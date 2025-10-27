import SwiftUI

struct TokensPerSecondView: View {
    let value: Double

    var body: some View {
        Text("\(value, format: .number.precision(.fractionLength(2))) tokens/s")
            .foregroundStyle(.secondary)
    }
}

#Preview {
    TokensPerSecondView(value: 58.5834)
}
