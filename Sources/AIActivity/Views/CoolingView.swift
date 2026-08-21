import SwiftUI
import Telemetry

/// Heat, air, and who is deciding.
///
/// The one view in this app with actuators in it, so it is built to make the
/// state of control unmissable: what is being held, by whom, for how much
/// longer, and what will take it away.
struct CoolingView: View {
    @Environment(TelemetryHub.self) private var hub

    private var thermal: ThermalSample? { hub.latestThermal }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.gutter) {
                DieTemperaturePanel(sample: thermal)
                FansPanel(sample: thermal)
                CoolingControlPanel()
                SensorInventory(sample: thermal)
            }
            .padding(T.padSection)
        }
    }
}

// MARK: - Temperatures

struct DieTemperaturePanel: View {
    let sample: ThermalSample?

    var body: some View {
        Panel(title: "Die temperature",
              trailing: sample.map { String(format: "%d sensors · %.1f ms/sweep",
                                            $0.sensorsRead, $0.sampleCostMicros / 1000) }) {
            HStack(alignment: .top, spacing: T.padSection) {
                hotspotTile
                Divider().frame(height: 46)
                ForEach(ThermalDomain.allCases, id: \.self) { d in
                    domainTile(d)
                }
                Spacer(minLength: 0)
                pressureTile
            }
            if let parked = sample?.parkedDomains, !parked.isEmpty {
                Note(icon: "powersleep",
                     text: "\(parked.map(\.displayName).joined(separator: " and ")) "
                         + "\(parked.count == 1 ? "is" : "are") power-gated — its sensors read "
                         + "below \(Int(ThermalSensors.parkedFloorC)) °C, which is the cluster "
                         + "being off rather than cold. Excluded from the hotspot.")
            }
        }
    }

    private var hotspotTile: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel("Hotspot")
            if let h = sample?.hotspot {
                EstimateView(estimate: h.estimate, unit: "°C", font: T.metric, decimals: 1)
                Text("hottest sensor · \(h.domain.displayName)")
                    .font(.system(size: 10)).foregroundStyle(T.inkMuted)
            } else {
                Text(Fmt.dash).font(T.metric).foregroundStyle(T.inkDisabled)
                Text("no die sensor readable")
                    .font(.system(size: 10)).foregroundStyle(T.inkDisabled)
            }
        }
        .frame(minWidth: 120, alignment: .leading)
    }

    @ViewBuilder
    private func domainTile(_ d: ThermalDomain) -> some View {
        let g = sample?.group(d)
        MetricTile(
            label: d.displayName,
            value: g?.hottest.value.map { Fmt.celsius($0, decimals: 1) } ?? Fmt.dash,
            tint: tint(g?.hottest.value),
            caption: caption(g))
        .help(g?.hottest.confidence.reason ?? "\(g?.live.count ?? 0) sensors")
    }

    private func caption(_ g: SensorGroup?) -> String? {
        guard let g else { return nil }
        if g.live.isEmpty && !g.parked.isEmpty { return "\(g.parked.count) parked" }
        var s = "\(g.live.count) sensors"
        if !g.parked.isEmpty { s += " · \(g.parked.count) parked" }
        if let m = g.mean { s += String(format: " · mean %.0f", m) }
        return s
    }

    /// Temperature earns ink, not hue, until it is genuinely notable — the
    /// palette's warning colours are already spoken for by source health, and a
    /// permanently amber CPU would train the eye to ignore them.
    private func tint(_ c: Double?) -> Color {
        guard let c else { return T.inkDisabled }
        if c >= 95 { return T.critical }
        if c >= 85 { return T.serious }
        return T.inkPrimary
    }

    private var pressureTile: some View {
        let s = sample
        return MetricTile(
            label: "OS pressure",
            value: s?.pressure.rawValue ?? Fmt.dash,
            tint: s?.pressure.tint ?? T.inkDisabled,
            caption: s.map { st in
                let age = st.t - st.pressureSince
                return age > 1 ? "for \(Fmt.secs(age))" : "just changed"
            })
        .help("""
        ProcessInfo.thermalState. Coarse, but it is the kernel's own judgement \
        and it accounts for whatever it knows that the die sensors do not.
        """)
    }
}

// MARK: - Fans

struct FansPanel: View {
    let sample: ThermalSample?

    var body: some View {
        Panel(title: "Fans", trailing: sample.map { "\($0.fans.count) fitted" }) {
            if let fans = sample?.fans, !fans.isEmpty {
                VStack(spacing: 10) {
                    ForEach(fans) { FanRow(fan: $0) }
                }
                if fans.contains(where: { ($0.actualRPM ?? 0) < 1 }) {
                    Note(icon: "info.circle",
                         text: "A stopped fan is a reading, not a gap: the SMC parks both fans "
                             + "at 0 rpm when the machine is cool. Manual control cannot go that "
                             + "low — the hardware's minimum forced target is "
                             + "\(Fmt.rpm(fans.first?.minRPM)), so any manual policy is LOUDER "
                             + "than automatic at idle.")
                }
            } else {
                Text("No fans reported by the SMC.")
                    .font(T.body).foregroundStyle(T.inkDisabled)
            }
        }
    }
}

struct FanRow: View {
    let fan: FanSample

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Fan \(fan.index)").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(T.inkPrimary)
                Chip(text: fan.mode.rawValue,
                     tint: fan.mode == .forced ? T.warning : T.inkMuted,
                     filled: fan.mode == .forced)
            }
            .frame(width: 74, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(T.surfaceRaise).frame(height: 8)
                    Capsule()
                        .fill(fan.mode == .forced ? T.warning : T.phaseDecode)
                        .frame(width: geo.size.width * CGFloat(fan.dutyFraction ?? 0), height: 8)
                    // The commanded target as a tick, so "asked for" and
                    // "actually spinning" are never merged into one bar.
                    if let t = fan.targetRPM, let lo = fan.minRPM, let hi = fan.maxRPM,
                       hi > lo, t > 0 {
                        let x = geo.size.width * CGFloat(min(1, max(0, (t - lo) / (hi - lo))))
                        Rectangle().fill(T.inkPrimary).frame(width: 2, height: 14)
                            .offset(x: x - 1)
                    }
                }
                .frame(height: 14)
            }
            .frame(height: 14)

            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.rpm(fan.actualRPM))
                    .font(T.metricS).foregroundStyle(T.inkPrimary).monospacedDigit()
                Text("target \(Fmt.rpm(fan.targetRPM)) · range \(Int(fan.minRPM ?? 0))–\(Int(fan.maxRPM ?? 0))")
                    .font(.system(size: 10)).foregroundStyle(T.inkMuted)
            }
            .frame(width: 210, alignment: .trailing)

            if fan.mode == .forced && !fan.isTracking {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(T.warning)
                    .help("commanded rpm not reached — spinning up, or the fan is not responding")
            }
        }
    }
}

// MARK: - Control

struct CoolingControlPanel: View {
    @Environment(TelemetryHub.self) private var hub

    @State private var mode: Mode = .automatic
    @State private var fixedRPM: Double = 3200
    @State private var boostRPM: Double = 4200
    @State private var trailing: Double = 20
    @State private var quietBelow: Double = 55
    @State private var fullAbove: Double = 85

    enum Mode: String, CaseIterable, Identifiable {
        case automatic = "Automatic"
        case boost = "Boost while generating"
        case curve = "Temperature curve"
        case fixed = "Fixed"
        var id: String { rawValue }
    }

    private var status: CoolingStatus? { hub.cooling }
    private var limits: (lo: Double, hi: Double) {
        guard let l = status?.limits.values.first, l.count == 2 else { return (2000, 6800) }
        return (l[0], l[1])
    }

    var body: some View {
        Panel(title: "Control", trailing: status.map { "helper v\($0.helperVersion)" }) {
            if !hub.coolingAvailable {
                notInstalled
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let trip = status?.trip { tripBanner(trip) }
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { _, _ in push() }

                    switch mode {
                    case .automatic:
                        Text("The SMC's own control loop owns both fans. This app writes nothing.")
                            .font(T.body).foregroundStyle(T.inkSecondary)
                    case .boost:
                        rpmSlider("While generating", value: $boostRPM)
                        stepperRow
                        Text("""
                        Spun up when a generation STARTS rather than when the die gets hot. \
                        The app can see the request; a temperature curve can only chase it.
                        """)
                        .font(.system(size: 11)).foregroundStyle(T.inkMuted)
                    case .curve:
                        curveEditor
                    case .fixed:
                        rpmSlider("Hold at", value: $fixedRPM)
                    }

                    Hairline()
                    leaseReadout
                    safetySummary
                }
            }
            if let e = hub.coolingError {
                Note(icon: "exclamationmark.triangle.fill", text: e, tint: T.warning)
            }
        }
        .onAppear { syncFromHub() }
    }

    private var notInstalled: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Read-only. No fan helper installed.")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(T.inkPrimary)
            Text("""
            SMC reads are unprivileged; SMC writes are not. Fan control therefore \
            needs a small root helper, which is installed deliberately and never \
            automatically:
            """)
            .font(T.body).foregroundStyle(T.inkSecondary)
            Text("sudo ./tools/install-cooling-helper.sh")
                .font(T.mono).foregroundStyle(T.inkPrimary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(T.surfaceRaise)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Text("""
            Everything above this panel works without it. The helper adds exactly one \
            capability: writing F<n>Md and F<n>Tg.
            """)
            .font(.system(size: 11)).foregroundStyle(T.inkMuted)
        }
    }

    private func tripBanner(_ trip: GuardTrip) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(T.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text(trip.explanation)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(T.warning)
                if let until = status?.tripUntil, until > 0 {
                    Text("manual control refused for another \(Int(until))s")
                        .font(.system(size: 10)).foregroundStyle(T.inkMuted)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(T.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func rpmSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(label).font(T.body).foregroundStyle(T.inkSecondary)
                .frame(width: 110, alignment: .leading)
            Slider(value: value, in: limits.lo...limits.hi, step: 100) { editing in
                if !editing { push() }
            }
            Text(Fmt.rpm(value.wrappedValue))
                .font(T.mono).foregroundStyle(T.inkPrimary).frame(width: 78, alignment: .trailing)
        }
    }

    private var stepperRow: some View {
        HStack(spacing: 10) {
            Text("Keep boosting for").font(T.body).foregroundStyle(T.inkSecondary)
            Stepper(value: $trailing, in: 0...120, step: 5) {
                Text("\(Int(trailing)) s after work stops")
                    .font(T.mono).foregroundStyle(T.inkPrimary)
            }
            .onChange(of: trailing) { _, _ in push() }
            Spacer()
        }
    }

    private var curveEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Quiet below").font(T.body).foregroundStyle(T.inkSecondary)
                    .frame(width: 110, alignment: .leading)
                Slider(value: $quietBelow, in: 40...80, step: 1) { if !$0 { push() } }
                Text(Fmt.celsius(quietBelow)).font(T.mono).foregroundStyle(T.inkPrimary)
                    .frame(width: 78, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text("Full above").font(T.body).foregroundStyle(T.inkSecondary)
                    .frame(width: 110, alignment: .leading)
                Slider(value: $fullAbove, in: 60...100, step: 1) { if !$0 { push() } }
                Text(Fmt.celsius(fullAbove)).font(T.mono).foregroundStyle(T.inkPrimary)
                    .frame(width: 78, alignment: .trailing)
            }
            Text("Evaluated against the die hotspot at 1 Hz. With no readable sensor the "
                 + "curve yields nothing and the fans stay on the SMC's loop.")
                .font(.system(size: 11)).foregroundStyle(T.inkMuted)
        }
    }

    private var leaseReadout: some View {
        HStack(spacing: 14) {
            if let s = status, s.forcing {
                Chip(text: "holding", tint: T.warning, filled: true)
                Text(s.targets.sorted { $0.key < $1.key }
                        .map { "fan \($0.key) → \(Int($0.value)) rpm" }
                        .joined(separator: " · "))
                    .font(T.mono).foregroundStyle(T.inkSecondary)
                if let l = s.leaseRemaining {
                    Text("lease \(String(format: "%.0f", l))s")
                        .font(T.mono).foregroundStyle(l < 5 ? T.warning : T.inkMuted)
                        .help("""
                        The helper hands the fans back if the app stops renewing. \
                        A crashed or killed app therefore cannot leave a fan stuck.
                        """)
                }
            } else {
                Chip(text: "not holding", tint: T.inkMuted)
                Text("fans are on the SMC's own loop")
                    .font(T.mono).foregroundStyle(T.inkMuted)
            }
            Spacer()
            if let c = status?.lastClamp {
                Text(c).font(.system(size: 10)).foregroundStyle(T.warning)
                    .lineLimit(1)
                    .help("Your request was outside what the hardware reports; the helper clamped it.")
            }
        }
    }

    private var safetySummary: some View {
        Text("""
        The helper releases every fan to automatic if the hotspot reaches \
        \(Int(status?.hardCeilingC ?? FanGuard.defaultCeilingC)) °C, if the OS reports serious \
        thermal pressure, if this app stops renewing within \
        \(Int(FanGuard.maxLeaseSeconds))s, or if it is stopped. It enforces those against its \
        own sensor readings, not ours.
        """)
        .font(.system(size: 11)).foregroundStyle(T.inkMuted)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func syncFromHub() {
        switch hub.coolingPolicy {
        case .system: mode = .automatic
        case .fixed(let r): mode = .fixed; fixedRPM = r
        case .curve(let c): mode = .curve; quietBelow = c.quietBelowC; fullAbove = c.fullAboveC
        case .boostWhileGenerating(let b):
            mode = .boost; boostRPM = b.generatingRPM; trailing = b.trailingSeconds
        }
    }

    private func push() {
        let curve = CoolingCurve(quietBelowC: quietBelow,
                                 fullAboveC: max(quietBelow + 1, fullAbove),
                                 minRPM: limits.lo, maxRPM: limits.hi)
        switch mode {
        case .automatic: hub.setCoolingPolicy(.system)
        case .fixed:     hub.setCoolingPolicy(.fixed(rpm: fixedRPM))
        case .curve:     hub.setCoolingPolicy(.curve(curve))
        case .boost:
            hub.setCoolingPolicy(.boostWhileGenerating(
                BoostSettings(generatingRPM: boostRPM, trailingSeconds: trailing,
                              idleRPM: nil, curve: curve)))
        }
    }
}

// MARK: - Inventory

/// Every sensor, including the ones the app refuses to put in a headline.
///
/// The unattributed group is the honest part: 67 more plausible `T*` sensors
/// exist whose domain could not be established by load response, and hiding
/// them would imply the map above is complete.
struct SensorInventory: View {
    let sample: ThermalSample?
    @State private var expanded = false

    var body: some View {
        Panel(title: "Sensor inventory") {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sample?.groups ?? [], id: \.domain) { g in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(g.domain.displayName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(T.inkPrimary)
                                Text("\(g.domain.keyPrefixes.joined(separator: ", "))*")
                                    .font(T.mono).foregroundStyle(T.inkMuted)
                            }
                            Text(g.live.map { "\($0.key) \(String(format: "%.1f", $0.celsius))" }
                                    .joined(separator: "   "))
                                .font(T.mono).foregroundStyle(T.inkSecondary)
                                .textSelection(.enabled)
                            if !g.parked.isEmpty {
                                Text("parked: " + g.parked.map(\.key).joined(separator: " "))
                                    .font(T.mono).foregroundStyle(T.inkDisabled)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("\(sample?.sensorsRead ?? 0) sensors across \(sample?.groups.count ?? 0) domains")
                    .font(T.body).foregroundStyle(T.inkSecondary)
            }
            Text("""
            The CPU/GPU split was established by load response, not by naming \
            convention: three phases (idle, CPU burn, GPU burn) over every flt key in \
            the T* space. Tp* rose 40–52 °C under CPU load and FELL up to 38 °C under \
            GPU load; Tg* did the opposite. Prefixes that could not be attributed that \
            way are excluded from every headline on this screen.
            """)
            .font(.system(size: 11)).foregroundStyle(T.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An inline explanatory line. Not an alert: nothing here is a fault.
struct Note: View {
    let icon: String
    let text: String
    var tint: Color = T.inkMuted

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint)
                .padding(.top, 1)
            Text(text).font(.system(size: 11)).foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
