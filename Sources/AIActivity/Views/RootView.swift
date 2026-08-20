import SwiftUI
import Combine
import Telemetry

enum Tab: String, CaseIterable, Identifiable {
    case timeline = "Timeline"
    case slots = "Slots"
    case engines = "Engines"
    var id: String { rawValue }
}

struct RootView: View {
    @Environment(TelemetryHub.self) private var hub
    @State private var tab: Tab = .timeline
    @State private var showSources = false

    var body: some View {
        VStack(spacing: 0) {
            // "Overview" is not a destination — it is context you want WHILE
            // looking at something else, so it lives here permanently.
            StatusRail()
            Hairline()
            Group {
                switch tab {
                case .timeline: GenerationTimelineView()
                case .slots:    SlotsView()
                case .engines:  EnginesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(T.plane)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSources.toggle() } label: {
                    Label("Sources", systemImage: "waveform.path.ecg")
                }
                .help("Per-source health, measured rates, and observer cost")
            }
        }
        .inspector(isPresented: $showSources) {
            SourcesInspector()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
        .preferredColorScheme(.dark)
        .onChange(of: hub.revision) { _, _ in hub.noteIdleFloor() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeOcclusionStateNotification)) { _ in
            hub.setVisible(NSApp.occlusionState.contains(.visible))
        }
    }
}
