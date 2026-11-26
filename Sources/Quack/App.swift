import IOKit.hid
import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--icons"), CommandLine.arguments.indices.contains(i + 1) {
            DuckIcon.writePreviews(to: CommandLine.arguments[i + 1])
            exit(0)
        }
        if CommandLine.arguments.contains("--permission") {
            print("bundle:", Bundle.main.bundleIdentifier ?? "none")
            print("before: CG", CGPreflightListenEventAccess(), "IOHID", IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue)
            print("CG request:", CGRequestListenEventAccess())
            print("IOHID request:", IOHIDRequestAccess(kIOHIDRequestTypeListenEvent))
            print("after: CG", CGPreflightListenEventAccess(), "IOHID", IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue)
            exit(0)
        }
        if CommandLine.arguments.contains("--bench") {
            Bench.run()
            exit(0)
        }
        QuackApp.main()
    }
}

struct QuackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(state)
                .environmentObject(state.stats)
        } label: {
            Image(nsImage: DuckIcon.image(state.menuIcon))
                .accessibilityLabel("Quack")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.start()
        silenceTypingInPanel()
        if !AppState.shared.hasPermission || CommandLine.arguments.contains("--onboarding") {
            Windows.shared.showOnboarding()
        }
        if CommandLine.arguments.contains("--settings") {
            Windows.shared.showSettings()
        }
        if CommandLine.arguments.contains("--panel") {
            // Shows the menu bar panel in a normal window, for checking the UI from a script.
            Windows.shared.showPanelPreview()
        }
    }

    /// Typing while the menu panel is open is how people try out a switch, but the panel has
    /// nowhere for the letters to go, so macOS would play its error beep for each key. The
    /// keys are dropped here instead. Quack's own sound still plays: the tap hears keys
    /// before they reach any window.
    private func silenceTypingInPanel() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window, !Windows.shared.owns(window) else { return event }
            // Shortcuts, Escape and Tab keep working.
            if event.modifierFlags.contains(.command) || event.keyCode == 53 || event.keyCode == 48 { return event }
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.flush()
    }
}

/// Plain AppKit windows. A menu bar app has no main window for SwiftUI scenes to hang off.
final class Windows {
    static let shared = Windows()
    private var settings: NSWindow?
    private var onboarding: NSWindow?
    private var panelPreview: NSWindow?

    /// True for the settings and welcome windows, which have real text fields.
    func owns(_ window: NSWindow) -> Bool {
        window === settings || window === onboarding || window === panelPreview
    }

    private func make<V: View>(_ title: String, _ view: V) -> NSWindow {
        let root = view
            .environmentObject(AppState.shared)
            .environmentObject(AppState.shared.stats)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        if settings == nil { settings = make("Quack Settings", SettingsView()) }
        present(settings!)
    }

    func showOnboarding() {
        if onboarding == nil { onboarding = make("Welcome to Quack", OnboardingView()) }
        present(onboarding!)
    }

    func showPanelPreview() {
        if panelPreview == nil { panelPreview = make("Quack", MenuPanel()) }
        present(panelPreview!)
    }

    func closeOnboarding() {
        onboarding?.close()
    }
}

struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @State private var asked = false
    @State private var scratch = ""

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text(state.hasPermission ? "You're all set" : "Let Quack hear your keys")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            if state.hasPermission {
                Text("Quack lives in your menu bar. Type below to try it, then pick a switch from the duck icon.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                TextField("Type here", text: $scratch, prompt: Text("Type something…"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                Button("Done") { Windows.shared.closeOnboarding() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            } else {
                Text("To play a sound when a key moves, Quack needs Input Monitoring. It only listens for which key moved. It can't change what you type, and nothing is stored or sent anywhere.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Label("Open Privacy & Security, then Input Monitoring", systemImage: "1.circle.fill")
                    Label("Turn on Quack", systemImage: "2.circle.fill")
                    Label("Come back here. If macOS asks, let it reopen Quack", systemImage: "3.circle.fill")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack {
                    if asked {
                        Button("Reopen Quack") { state.relaunch() }
                            .help("Use this if you turned Quack on but it still isn't picking up keys")
                    }
                    Button("Open System Settings") {
                        asked = true
                        state.requestPermission()
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                }
            }
        }
        .padding(28)
        .frame(width: 440)
    }
}
