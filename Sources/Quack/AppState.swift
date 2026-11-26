import AppKit
import ServiceManagement
import SwiftUI

struct SleepApp: Identifiable, Hashable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

final class AppState: ObservableObject {
    static let shared = AppState()

    let stats = Stats()
    let player: Player
    private let tap = KeyTap()
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var ticks = 0

    // MARK: Settings

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled"); push() } }
    @Published var volume: Double { didSet { defaults.set(volume, forKey: "volume"); push() } }
    @Published var packID: String { didSet { defaults.set(packID, forKey: "pack"); push() } }
    @Published var keyUpSounds: Bool { didSet { defaults.set(keyUpSounds, forKey: "keyUp"); push() } }
    @Published var modifierSounds: Bool { didSet { defaults.set(modifierSounds, forKey: "modifiers"); push() } }
    @Published var repeatSounds: Bool { didSet { defaults.set(repeatSounds, forKey: "repeats"); push() } }
    @Published var mouseSounds: Bool { didSet { defaults.set(mouseSounds, forKey: "mouse"); push() } }
    @Published var scrollSounds: Bool { didSet { defaults.set(scrollSounds, forKey: "scroll"); push() } }
    @Published var stereoWidth: Double { didSet { defaults.set(stereoWidth, forKey: "stereoWidth"); push() } }
    @Published var pitchVariation: Double { didSet { defaults.set(pitchVariation, forKey: "pitchVariation"); push() } }
    /// Tone pad position per pack: x is pitch, y is brightness, both -1...1.
    @Published var tones: [String: [Double]] { didSet { defaults.set(tones, forKey: "tones"); push() } }
    @Published var outputUID: String? {
        didSet {
            defaults.set(outputUID, forKey: "outputUID")
            player.mixer.setOutputDevice(uid: outputUID)
        }
    }
    @Published var sleepOnMic: Bool { didSet { defaults.set(sleepOnMic, forKey: "sleepOnMic"); refreshSleep() } }
    @Published var sleepApps: [SleepApp] {
        didSet {
            defaults.set(sleepApps.map { "\($0.bundleID)|\($0.name)" }, forKey: "sleepApps")
            refreshSleep()
        }
    }
    @Published var shortcut: Shortcut? {
        didSet {
            if let shortcut {
                defaults.set([shortcut.keyCode, Int(shortcut.modifiers)], forKey: "shortcut")
                defaults.set(shortcut.label, forKey: "shortcutLabel")
            } else {
                defaults.set([Int](), forKey: "shortcut")
            }
            HotKey.shared.register(shortcut)
        }
    }

    // MARK: Live state

    @Published private(set) var hasPermission = false
    @Published private(set) var sleepReason: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var outputDevices: [OutputDevice] = []

    var isActive: Bool { enabled && hasPermission && sleepReason == nil }

    var statusText: String {
        if !hasPermission { return "Needs permission" }
        if !enabled { return "Off" }
        if let sleepReason { return "Asleep: \(sleepReason)" }
        return "Listening"
    }

    var menuIcon: DuckIcon.Style {
        if enabled && hasPermission && sleepReason != nil { return .asleep }
        return isActive ? .filled : .outline
    }

    var pack: PackInfo { Packs.all[Packs.index(of: packID)] }

    var tone: CGPoint {
        get {
            let t = tones[packID] ?? [0, 0]
            return CGPoint(x: t.first ?? 0, y: t.last ?? 0)
        }
        set { tones[packID] = [Double(newValue.x), Double(newValue.y)] }
    }

    private init() {
        defaults.register(defaults: [
            "enabled": true, "volume": 0.7, "pack": Packs.defaultID, "keyUp": true, "modifiers": true,
            "repeats": false, "mouse": false, "scroll": false, "stereoWidth": 0.6,
            "pitchVariation": 0.03, "sleepOnMic": false,
        ])
        enabled = defaults.bool(forKey: "enabled")
        volume = defaults.double(forKey: "volume")
        let savedPack = defaults.string(forKey: "pack") ?? Packs.defaultID
        packID = Packs.all.contains { $0.id == savedPack } ? savedPack : Packs.defaultID
        keyUpSounds = defaults.bool(forKey: "keyUp")
        modifierSounds = defaults.bool(forKey: "modifiers")
        repeatSounds = defaults.bool(forKey: "repeats")
        mouseSounds = defaults.bool(forKey: "mouse")
        scrollSounds = defaults.bool(forKey: "scroll")
        stereoWidth = defaults.double(forKey: "stereoWidth")
        pitchVariation = defaults.double(forKey: "pitchVariation")
        tones = (defaults.dictionary(forKey: "tones") as? [String: [Double]]) ?? [:]
        outputUID = defaults.string(forKey: "outputUID")
        sleepOnMic = defaults.bool(forKey: "sleepOnMic")
        sleepApps = (defaults.stringArray(forKey: "sleepApps") ?? []).compactMap { entry in
            let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 ? SleepApp(bundleID: parts[0], name: parts[1]) : nil
        }
        if let saved = defaults.array(forKey: "shortcut") as? [Int] {
            shortcut = saved.count == 2
                ? Shortcut(keyCode: saved[0], modifiers: UInt(saved[1]), label: defaults.string(forKey: "shortcutLabel") ?? "?")
                : nil
        } else {
            shortcut = .standard
        }

        player = Player(mixer: AudioMixer(), packs: Packs.loadAll())
    }

    /// Called once the app has finished launching.
    func start() {
        player.mixer.setOutputDevice(uid: outputUID)
        tap.handler = { [player] event in player.handle(event) }
        HotKey.shared.handler = { [weak self] in self?.toggle() }
        HotKey.shared.register(shortcut)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshSleep() }

        refreshLaunchAtLogin()
        refreshDevices()
        checkPermission()
        // Asking at launch is what puts Quack in the Input Monitoring list, so there is
        // always a switch to turn on there.
        if !hasPermission { KeyTap.requestPermission() }
        refreshSleep()
        if isActive { player.mixer.warm() }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func toggle() {
        enabled.toggle()
        if enabled && isActive {
            player.playSample(pack: Packs.index(of: packID), up: false, keyCode: 40)
        }
    }

    func select(_ pack: PackInfo) {
        packID = pack.id
    }

    func preview(_ pack: PackInfo) {
        player.preview(pack: Packs.index(of: pack.id))
    }

    func flush() {
        stats.add(player.drainKeyCount())
        stats.save()
    }

    // MARK: Permission

    func checkPermission() {
        let granted = KeyTap.hasPermission
        if granted && !tap.isInstalled {
            // Creating the tap can still fail right after the grant; the next tick retries.
            tap.install()
        }
        let ready = granted && tap.isInstalled
        if ready != hasPermission {
            hasPermission = ready
            push()
        }
    }

    func requestPermission() {
        KeyTap.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunch() {
        flush()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Quack: launch at login failed: \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
    }

    private func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refreshDevices() {
        outputDevices = AudioDevices.outputDevices()
    }

    // MARK: Internals

    private func tick() {
        ticks += 1
        let typed = player.drainKeyCount()
        if typed > 0 { stats.add(typed) }
        if ticks % 5 == 0 { stats.save() }
        if !hasPermission { checkPermission() }
        if sleepOnMic && ticks % 2 == 0 { refreshSleep() }
    }

    private func refreshSleep() {
        var reason: String?
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let app = sleepApps.first(where: { $0.bundleID == front }) {
            reason = "\(app.name) is in front"
        } else if sleepOnMic && AudioDevices.microphoneInUse() {
            reason = "microphone in use"
        }
        if reason != sleepReason {
            sleepReason = reason
            push()
        }
    }

    private func push() {
        let t = tones[packID] ?? [0, 0]
        player.update(LiveConfig(
            active: isActive,
            packIndex: Packs.index(of: packID),
            volume: Float(volume),
            keyUp: keyUpSounds,
            modifiers: modifierSounds,
            repeats: repeatSounds,
            mouse: mouseSounds,
            scroll: scrollSounds,
            stereoWidth: Float(stereoWidth),
            pitchVariation: Float(pitchVariation),
            toneX: Float(t.first ?? 0),
            toneY: Float(t.last ?? 0)))
        tap.setEnabled(isActive)
    }
}
