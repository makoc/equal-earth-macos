import SwiftUI

struct ContentView: View {
    let state: ViewState
    @Bindable var imagery: ImageryStore
    private let metal = MetalContext.shared

    var body: some View {
        HStack(spacing: 0) {
            EarthView(mode: .map, state: state, imagery: imagery)
                .overlay {
                    if state.showLabels {
                        LabelLayer(state: state, labels: metal.labels)
                    }
                }
                .overlay(alignment: .bottomLeading) { StatusLine(state: state, imagery: imagery) }
                .accessibilityLabel("Equal Earth map. Drag to rotate the globe underneath.")
            Divider()
            SidePanel(state: state, imagery: imagery)
                .frame(width: 280)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $imagery.isSheetPresented) {
            DownloadSheet(imagery: imagery, state: state)
        }
        .task { imagery.start() }
        .onChange(of: state.baseMap, initial: true) {
            if state.baseMap == .political { metal.requestPoliticalMap() }
        }
    }
}

/// Pointer position and download progress, in the lower-left corner of the map.
private struct StatusLine: View {
    let state: ViewState
    let imagery: ImageryStore
    private let metal = MetalContext.shared

    var body: some View {
        HStack(spacing: 12) {
            if let cursor = state.cursor {
                Label(Format.point(cursor), systemImage: "scope")
                    .monospacedDigit()
            }
            switch imagery.phase {
            case .downloading:
                ProgressView(value: imagery.fraction)
                    .frame(width: 120)
                Text("Downloading imagery \(Int(imagery.fraction * 100)) %")
            case .decoding:
                ProgressView().controlSize(.small)
                Text("Preparing imagery…")
            default:
                EmptyView()
            }
            if metal.isPreparingPoliticalMap {
                ProgressView().controlSize(.small)
                Text("Painting political map…")
            }
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: .rect(cornerRadius: 6))
        .padding(10)
        .opacity(state.cursor == nil && [.missing, .ready].contains(imagery.phase) && !metal.isPreparingPoliticalMap ? 0 : 1)
        .allowsHitTesting(false)
    }
}
