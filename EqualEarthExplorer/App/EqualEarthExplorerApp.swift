import AppKit
import SwiftUI

@main
struct EqualEarthExplorerApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var state = ViewState()
    @State private var imagery = ImageryStore()

    var body: some Scene {
        Window("Equal Earth Explorer", id: "main") {
            ContentView(state: state, imagery: imagery)
                .frame(minWidth: 900, minHeight: 520)
        }
        .defaultSize(width: 1400, height: 760)
        .commands {
            CommandMenu("Globe") {
                Button("North Up") { state.resetNorthUp() }
                    .keyboardShortcut("n")
                Button("Centre 0°, 0°") { state.resetToOrigin() }
                    .keyboardShortcut("0")
                Divider()
                Button("Download Imagery…") { imagery.isSheetPresented = true }
                    .disabled(imagery.phase == .ready)
                Button("Delete Cached Imagery") { imagery.deleteCache() }
                    .disabled(!imagery.isCached && imagery.texture == nil)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
