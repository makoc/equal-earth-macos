import SwiftUI

struct SidePanel: View {
    @Bindable var state: ViewState
    let imagery: ImageryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                EarthView(mode: .globe, state: state, imagery: imagery)
                    .frame(height: 248)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityLabel("Globe in the same orientation as the map")

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    row("Centre", Format.point(state.centre))
                    row("Roll", Format.angle(state.roll))
                    row("North Pole on map", Format.point(state.northPoleOnMap))
                }
                .font(.callout)

                HStack {
                    Button {
                        state.resetNorthUp()
                    } label: {
                        Label("North Up", systemImage: "location.north.line")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Keep the map centre and turn the globe so that north points up (⌘N)")
                    Button {
                        state.resetToOrigin()
                    } label: {
                        Label("0°, 0°", systemImage: "scope")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Back to the standard Equal Earth map (⌘0)")
                    .disabled(state.isStandardOrientation)
                }
                .controlSize(.large)

                GroupBox("Overlays") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Graticule (15°)", isOn: $state.showGraticule)
                        Toggle("Coastlines", isOn: $state.showCoastlines)
                        Toggle("Country borders", isOn: $state.showBorders)
                        Toggle("Tissot indicatrices", isOn: $state.showTissot)
                        Toggle("Outline, cut line and poles", isOn: $state.showOutline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("How to use") {
                    Text("""
                    Drag the map or the globe to turn the globe underneath. \
                    Option-drag or the two-finger trackpad rotation changes the roll. \
                    On the globe, the red line is where the map is cut open; \
                    cyan lines are the map's equator and central meridian.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                imagerySection

                Text("Equal Earth projection: Šavrič, Patterson, Jenny (2018). Imagery: NASA Earth Observatory, Blue Marble Next Generation. Vectors: Natural Earth. All public domain.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var imagerySection: some View {
        switch imagery.phase {
        case .ready:
            EmptyView()
        case .missing, .failed:
            Button("Download Imagery…") { imagery.isSheetPresented = true }
        case .downloading, .decoding:
            Button("Show Download Progress…") { imagery.isSheetPresented = true }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }
}
