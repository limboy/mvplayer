import AppKit
import SwiftUI

struct LibMPVSetupView: View {
    let errorMessage: String?
    let retry: () -> Void

    private let command = "brew install mpv"

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Owl needs libmpv")
                    .font(.title2.weight(.semibold))
                Text("Install mpv with Homebrew, then retry. Owl never runs installation commands for you.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 470)
            }

            HStack(spacing: 12) {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560)
            }

            Button("Retry") {
                retry()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
