import AppKit
import SwiftUI

@main
struct FlashKitApp: App {
    @State private var model = AppModel()

    init() {
        FlashKitCommandLineTool.runIfRequested()
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("FlashKit") {
            ContentView(model: model)
                .frame(minWidth: 825, idealWidth: 1500, minHeight: 570, idealHeight: 820)
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)
    }
}
