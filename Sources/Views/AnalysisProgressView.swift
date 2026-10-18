import SwiftUI

struct AnalysisProgressView: View {
    let status: String
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(status)
                Spacer(minLength: 12)
                if let progress {
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                }
            }
            if let progress {
                ProgressView(value: progress)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .font(.system(size: 14, weight: .medium))
    }
}
