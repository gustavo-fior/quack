import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    /// `--tab sound` opens a specific tab, which is handy when checking the UI from a script.
    @State private var tab: String = {
        let args = CommandLine.arguments
        return args.firstIndex(of: "--tab").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "general"
    }()

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            SoundTab().tabItem { Label("Sound", systemImage: "waveform") }.tag("sound")
            SleepTab().tabItem { Label("Sleep", systemImage: "moon.zzz") }.tag("sleep")
            StatsTab().tabItem { Label("Stats", systemImage: "chart.bar") }.tag("stats")
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 520, height: 620)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var state: AppState
    @State private var scratch = ""

    var body: some View {
        Form {
            Section {
                Toggle("Enable Quack", isOn: $state.enabled)
                Toggle("Open at login", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }))
                LabeledContent("Toggle shortcut") {
                    ShortcutRecorder(shortcut: $state.shortcut)
                }
            }
            Section("Keys") {
                Toggle("Key release sounds", isOn: $state.keyUpSounds)
                Toggle("Modifier keys", isOn: $state.modifierSounds)
                Toggle("Repeat while a key is held", isOn: $state.repeatSounds)
            }
            Section("Mouse") {
                Toggle("Click sounds", isOn: $state.mouseSounds)
                Toggle("Scroll ticks", isOn: $state.scrollSounds)
            }
            Section("Try it") {
                TextField("Type here", text: $scratch, prompt: Text("Type here to hear the current switch"))
                    .labelsHidden()
            }
            if !state.hasPermission {
                Section {
                    LabeledContent("Input Monitoring is off") {
                        Button("Set Up…") { Windows.shared.showOnboarding() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Press keys…" : (shortcut?.display ?? "None")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 90)
            if shortcut != nil && !recording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove shortcut")
                .accessibilityLabel("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        HotKey.shared.register(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
            // Require a real modifier so the shortcut can't swallow ordinary typing.
            guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
            let label = Self.label(for: event)
            stop(restore: false)
            shortcut = Shortcut(keyCode: Int(event.keyCode), modifiers: flags.rawValue, label: label)
            return nil
        }
    }

    private func stop() { stop(restore: true) }

    private func stop(restore: Bool) {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if restore { HotKey.shared.register(shortcut) }
    }

    private static func label(for event: NSEvent) -> String {
        let named: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = named[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

// MARK: - Sound

private struct SoundTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Picker("Switch", selection: $state.packID) {
                    ForEach(Packs.all) { pack in
                        Text("\(pack.name)  ·  \(pack.blurb)").tag(pack.id)
                    }
                }
                LabeledContent("Volume") {
                    Slider(value: $state.volume, in: 0...1).frame(width: 220)
                }
            }
            Section {
                HStack(alignment: .top, spacing: 18) {
                    TonePad(point: Binding(get: { state.tone }, set: { state.tone = $0 })) {
                        state.player.playSample(
                            pack: Packs.index(of: state.packID), up: false, keyCode: 40)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tone pad").font(.headline)
                        Text("Drag to tune \(state.pack.name). Left and right change the pitch, up and down change the brightness. Each switch remembers its own tuning.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Reset") { state.tone = .zero }
                                .disabled(state.tone == .zero)
                            Button("Preview") { state.preview(state.pack) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Character") {
                LabeledContent("Stereo width") {
                    Slider(value: $state.stereoWidth, in: 0...1).frame(width: 220)
                }
                .help("Keys on the left of the keyboard play from the left, and so on")
                LabeledContent("Pitch variation") {
                    Slider(value: $state.pitchVariation, in: 0...0.12).frame(width: 220)
                }
            }
            Section("Output") {
                Picker("Play through", selection: Binding(
                    get: { state.outputUID ?? "" },
                    set: { state.outputUID = $0.isEmpty ? nil : $0 })
                ) {
                    Text("System default").tag("")
                    Divider()
                    ForEach(state.outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refreshDevices() }
    }
}

struct TonePad: View {
    @Binding var point: CGPoint
    var onChange: () -> Void
    @State private var lastTick = Date.distantPast
    private let size: CGFloat = 170

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.yellow.opacity(0.35), Color.orange.opacity(0.18), Color.brown.opacity(0.25)],
                    startPoint: .top, endPoint: .bottom))
            Path { path in
                path.move(to: CGPoint(x: size / 2, y: 10))
                path.addLine(to: CGPoint(x: size / 2, y: size - 10))
                path.move(to: CGPoint(x: 10, y: size / 2))
                path.addLine(to: CGPoint(x: size - 10, y: size / 2))
            }
            .stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            Text("Brighter").modifier(PadLabel()).position(x: size / 2, y: 12)
            Text("Darker").modifier(PadLabel()).position(x: size / 2, y: size - 12)
            Text("Lower").modifier(PadLabel()).position(x: 24, y: size / 2 - 10)
            Text("Higher").modifier(PadLabel()).position(x: size - 26, y: size / 2 - 10)

            Circle()
                .fill(.white)
                .frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .overlay(Circle().stroke(Color.orange, lineWidth: 2))
                .position(
                    x: size / 2 + point.x * (size / 2 - 14),
                    y: size / 2 - point.y * (size / 2 - 14))
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { value in
                let half = size / 2 - 14
                var x = min(max((value.location.x - size / 2) / half, -1), 1)
                var y = min(max((size / 2 - value.location.y) / half, -1), 1)
                // Snap to the neutral axes so the default is easy to find again.
                if abs(x) < 0.06 { x = 0 }
                if abs(y) < 0.06 { y = 0 }
                let crossed = (x == 0) != (point.x == 0) || (y == 0) != (point.y == 0)
                point = CGPoint(x: x, y: y)
                if crossed {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                if Date().timeIntervalSince(lastTick) > 0.11 {
                    lastTick = Date()
                    onChange()
                }
            }
        )
        .accessibilityElement()
        .accessibilityLabel("Tone pad")
        .accessibilityValue("Pitch \(Int(point.x * 100)) percent, brightness \(Int(point.y * 100)) percent")
    }
}

private struct PadLabel: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
    }
}

// MARK: - Sleep

private struct SleepTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("While the microphone is in use", isOn: $state.sleepOnMic)
            } header: {
                Text("Quack goes quiet on its own")
            } footer: {
                Text("Covers calls, meetings and voice recordings, so nobody else hears your typing twice.")
            }
            Section {
                if state.sleepApps.isEmpty {
                    Text("No apps yet").foregroundStyle(.secondary)
                }
                ForEach(state.sleepApps) { app in
                    HStack {
                        Text(app.name)
                        Spacer()
                        Button {
                            state.sleepApps.removeAll { $0.bundleID == app.bundleID }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(app.name)")
                    }
                }
                Button("Add App…", action: addApp)
            } header: {
                Text("While these apps are in front")
            } footer: {
                Text("Useful for games and anything else where key sounds get in the way.")
            }
            if let reason = state.sleepReason {
                Section {
                    Label("Asleep right now: \(reason)", systemImage: "moon.zzz.fill")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            guard !state.sleepApps.contains(where: { $0.bundleID == id }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            state.sleepApps.append(SleepApp(bundleID: id, name: name))
        }
    }
}

// MARK: - Stats

private struct StatsTab: View {
    @EnvironmentObject var stats: Stats
    @State private var confirmReset = false

    var body: some View {
        let recent = stats.recent(14)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                StatCard(title: "Today", value: stats.today.formatted())
                StatCard(title: "All time", value: stats.total.formatted())
                StatCard(title: "Best day", value: stats.bestDay.formatted())
                StatCard(title: "Streak", value: "\(stats.streak) \(stats.streak == 1 ? "day" : "days")")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Last 14 days").font(.headline)
                Chart(recent, id: \.date) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Keys", day.keys))
                    .foregroundStyle(Color.orange.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .frame(height: 220)
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Text("Quack counts key presses. It never records which keys you press.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset…") { confirmReset = true }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .confirmationDialog("Reset all typing stats?", isPresented: $confirmReset) {
            Button("Reset Stats", role: .destructive) { stats.reset() }
        } message: {
            Text("This can't be undone.")
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Quack").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Satisfying switch sounds for every key.\nNothing you type is stored or sent anywhere.\n\nSwitch recordings from kbsim by Thomas Lai, used under the MIT license.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }
}
