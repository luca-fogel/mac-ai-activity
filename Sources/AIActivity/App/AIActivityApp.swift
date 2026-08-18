import SwiftUI
import Telemetry
import TelemetryMock

@main
struct AIActivityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var hub = TelemetryHub()

    var body: some Scene {
        Window("AI Activity", id: "main") {
            RootView()
                .environment(hub)
                .frame(minWidth: 940, minHeight: 620)
                .task {
                    // A real .app gets live data; `swift run` in a sandbox or
                    // with no engines present falls back to the mock so the UI
                    // is always inspectable.
                    if ProcessInfo.processInfo.environment["AIACTIVITY_MOCK"] != nil {
                        hub.attach(MockFeed())
                    } else {
                        hub.attach(LiveTelemetryFeed())
                    }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1180, height: 780)

        MenuBarExtra {
            MenuBarReadout().environment(hub)
        } label: {
            MenuBarLabel().environment(hub)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        // .regular, NOT .accessory: unlike QwenMenu and LLMMenu this app is a
        // window-first tool that must be Spotlight-launchable and Cmd-Tabbable.
        NSApp.setActivationPolicy(.regular)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}
