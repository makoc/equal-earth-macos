import SwiftUI

/// Asks for consent before downloading the imagery, then shows the progress.
struct DownloadSheet: View {
    let imagery: ImageryStore
    let state: ViewState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Download Earth Imagery", systemImage: "globe.europe.africa")
                .font(.title2.bold())

            Text("The satellite base map uses NASA's Blue Marble Next Generation image (topography and bathymetry, July 2004, 21 600 × 10 800 pixels). It is in the public domain and is downloaded once, then kept on this Mac. The political base map needs no download.")
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Source").foregroundStyle(.secondary)
                    Text(ImageryStore.sourceURL.absoluteString)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    Text(Format.bytes(ImageryStore.expectedBytes))
                }
                GridRow {
                    Text("Saved to").foregroundStyle(.secondary)
                    Text(imagery.cacheURL.path(percentEncoded: false))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Text("About").foregroundStyle(.secondary)
                    Link("NASA Earth Observatory page", destination: ImageryStore.sourcePage)
                }
            }

            status

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder
    private var status: some View {
        switch imagery.phase {
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: imagery.fraction)
                Text("\(Format.bytes(imagery.receivedBytes)) of \(Format.bytes(imagery.totalBytes))")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .decoding:
            HStack {
                ProgressView().controlSize(.small)
                Text("Preparing the texture…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .missing, .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch imagery.phase {
        case .missing:
            Button("Use Political Map") {
                state.baseMap = .political
                dismiss()
            }
            Button("Not Now") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Download") { imagery.download() }
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Not Now") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Try Again") { imagery.download() }
                .keyboardShortcut(.defaultAction)
        case .downloading:
            Button("Cancel Download") { imagery.cancelDownload() }
                .keyboardShortcut(.cancelAction)
            Button("Continue in Background") { dismiss() }
                .keyboardShortcut(.defaultAction)
        case .decoding, .ready:
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
