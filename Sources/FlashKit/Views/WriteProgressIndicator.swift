import SwiftUI

struct WriteProgressIndicator: View {
    let progressFraction: Double?
    let isBusy: Bool
    let accessibilityValue: String

    var body: some View {
        progressView
            .accessibilityLabel("Write progress")
            .accessibilityValue(Text(accessibilityValue))
    }

    @ViewBuilder
    private var progressView: some View {
        if let progressFraction {
            ProgressView(value: progressFraction)
        } else if isBusy {
            ProgressView()
        } else {
            ProgressView(value: 0.0)
                .opacity(0.25)
        }
    }
}
