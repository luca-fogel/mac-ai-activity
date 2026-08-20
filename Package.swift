// swift-tools-version: 6.0
import PackageDescription

// NOTE: PackageDescription on Swift 6.3 has NO .v26 case — verified. Use the string form.
// 14.0 is the floor for the concurrency features used here.
let package = Package(
    name: "aienergy",
    platforms: [.macOS("14.0")],
    targets: [
        // Collection. No third-party dependencies, by design: IOKit, mach and
        // libproc only.
        .target(name: "Telemetry"),
        // The tool. Reports joules per token, which is the one figure LM Studio
        // has no data for — it already reports tok/s and TTFT, and better.
        .executableTarget(name: "aienergy", dependencies: ["Telemetry"]),
        // Headless verifier for the collectors and their cost budget:
        // `swift run telemetry-probe --cost` / `--live` / `--predictions`
        .executableTarget(name: "telemetry-probe", dependencies: ["Telemetry"]),
        .testTarget(name: "TelemetryTests", dependencies: ["Telemetry"]),
    ]
)
