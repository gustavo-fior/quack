import SwiftUI

/// The panel under the menu bar duck. It is laid out like the system's own menu bar panels:
/// one sheet of glass, section titles, rows that highlight in the accent colour.
struct MenuPanel: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var stats: Stats

    private var groups: [(name: String, packs: [PackInfo])] {
        var order: [String] = []
        var map: [String: [PackInfo]] = [:]
        for pack in Packs.all {
            if map[pack.group] == nil { order.append(pack.group) }
            map[pack.group, default: []].append(pack)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !state.hasPermission { permissionBanner }
            volume
            separator

            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.name) { group in
                    Text(group.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .padding(.bottom, 3)
                    ForEach(group.packs) { pack in
                        PackRow(pack: pack)
                    }
                }
            }
            .padding(.horizontal, 5)
            .padding(.bottom, 5)

            separator
            footer
        }
        .frame(width: 300)
    }

    private var separator: some View {
        Divider().padding(.horizontal, 14)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: DuckIcon.image(.filled, size: 18))
                .renderingMode(.template)
                .foregroundStyle(state.isActive ? Color.black.opacity(0.8) : Color.secondary)
                .frame(width: 30, height: 30)
                .glassEffect(state.isActive ? .regular.tint(.yellow) : .regular, in: .circle)
            VStack(alignment: .leading, spacing: 0) {
                Text("Quack").font(.system(size: 13, weight: .semibold))
                Text(state.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("Enable Quack", isOn: $state.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var permissionBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quack can't hear your keyboard yet")
                    .font(.system(size: 12, weight: .semibold))
                Text("Allow Input Monitoring so it knows when a key moves.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Set Up…") { Windows.shared.showOnboarding() }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
        }
        .padding(10)
        .glassEffect(.regular.tint(.yellow.opacity(0.25)), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
            Slider(value: $state.volume, in: 0...1)
                .accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(stats.today.formatted()) keys today")
                Spacer()
                if let shortcut = state.shortcut {
                    Text("On/Off  \(shortcut.display)")
                        .help("Shortcut to turn Quack on or off")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)

            VStack(spacing: 0) {
                MenuRow(title: "Settings…", shortcut: "⌘,") { Windows.shared.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                MenuRow(title: "Quit Quack", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(5)
        }
    }
}

/// The accent-coloured highlight a menu item gets under the pointer.
private struct MenuHighlight: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Color.accentColor : .clear)
            )
    }
}

private struct PackRow: View {
    @EnvironmentObject var state: AppState
    let pack: PackInfo
    @State private var hovering = false

    private var selected: Bool { state.packID == pack.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .opacity(selected ? 1 : 0)
                .frame(width: 14)
            Text(pack.name).font(.system(size: 13))
            Spacer()
            Text(pack.blurb)
                .font(.system(size: 11))
                .opacity(0.6)
            Button {
                state.preview(pack)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 8))
                    .frame(width: 10, height: 12)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .help("Preview \(pack.name)")
            .accessibilityLabel("Preview \(pack.name)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .modifier(MenuHighlight(active: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            state.select(pack)
            state.player.playSample(pack: Packs.index(of: pack.id), up: false, keyCode: 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct MenuRow: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).opacity(0.5)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .modifier(MenuHighlight(active: hovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
