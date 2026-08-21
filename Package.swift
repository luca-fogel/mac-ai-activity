// swift-tools-version: 6.0
import PackageDescription

// NOTE: PackageDescription on Swift 6.3 has NO .v26 case — verified. Use the string form.
// 14.0 is the real floor (@Observable, .inspector); nothing here needs 26.
let package = Package(
    name: "AIActivity",
    platforms: [.macOS("14.0")],
    targets: [
        .target(name: "Telemetry"),
        .target(name: "TelemetryMock", dependencies: ["Telemetry"]),
        .executableTarget(
            name: "AIActivity",
            dependencies: ["Telemetry", "TelemetryMock"]
        ),
        // Headless verifier: proves the collectors and their cost budget
        // without any UI. `swift run telemetry-probe --cost`
        .executableTarget(name: "telemetry-probe", dependencies: ["Telemetry"]),
        // The CLI. LM Studio already shows tok/s and TTFT well; the one thing it
        // cannot show is energy, so this tool does only that part.
        .executableTarget(name: "aienergy", dependencies: ["Telemetry"]),
        // The privileged half of fan control, and the ONLY thing here that
        // writes to hardware. Runs as a root LaunchDaemon; the app talks to it
        // over a unix socket and is not trusted by it.
        .executableTarget(name: "aithermald", dependencies: ["Telemetry"]),
        .testTarget(name: "TelemetryTests", dependencies: ["Telemetry"]),
    ]
)
