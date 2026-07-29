import AppKit
import SwiftUI

// MARK: - Layout constants

private enum Metrics {
    static let cardCorner: CGFloat = 10
    static let rowMinHeight: CGFloat = 34
    static let pageWidth: CGFloat = 460
}

// MARK: - Root

/// System-Settings-style window: source-list sidebar on the left, grouped cards on the right.
struct SettingsRootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Appearance"
        case shortcuts = "Shortcuts"
        case hiddenApps = "Hidden Apps"
        case permissions = "Permissions"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            case .shortcuts: return "command"
            case .hiddenApps: return "eye.slash"
            case .permissions: return "lock.shield"
            }
        }

        var tint: Color {
            switch self {
            case .general: return .gray
            case .appearance: return .indigo
            case .shortcuts: return .blue
            case .hiddenApps: return .orange
            case .permissions: return .green
            }
        }
    }

    @ObservedObject private var store = SettingsStore.shared
    @State private var selection: Section = .general

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label {
                        Text(section.rawValue)
                    } icon: {
                        SidebarIcon(symbol: section.symbol, tint: section.tint)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 186, ideal: 196, max: 240)
        } detail: {
            ScrollView {
                page
                    .frame(maxWidth: Metrics.pageWidth, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .navigationTitle(selection.rawValue)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private var page: some View {
        switch selection {
        case .general: GeneralPage(store: store)
        case .appearance: AppearancePage(store: store)
        case .shortcuts: ShortcutsPage(store: store)
        case .hiddenApps: HiddenAppsPage(store: store)
        case .permissions: PermissionsPage(store: store)
        }
    }
}

/// Rounded tinted glyph — the System Settings sidebar treatment.
private struct SidebarIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 20, height: 20)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Reusable chrome

/// A titled group of rows drawn as one inset card with hairline dividers.
private struct Card<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.leading, 4)
            }

            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One card row: label + optional explanatory subtitle on the left, control on the right.
private struct Row<Control: View>: View {
    let title: String
    var subtitle: String?
    var isLast = false
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                control
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: Metrics.rowMinHeight)

            if !isLast {
                Divider().padding(.leading, 12)
            }
        }
    }
}

private extension View {
    /// Compact switch styling used for every boolean row.
    func settingsToggle() -> some View {
        toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }
}

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Startup") {
                Row(
                    title: "Launch at login",
                    subtitle: "Start Better Mac Taskbar automatically when you sign in.",
                    isLast: true
                ) {
                    Toggle("", isOn: $store.launchAtLogin).settingsToggle()
                }
            }

            Card(
                title: "Dock",
                footer: "Hiding the Dock frees the bottom of the screen for the taskbar."
            ) {
                Row(
                    title: "Hide the Dock",
                    subtitle: "Use the taskbar instead of the macOS Dock.",
                    isLast: true
                ) {
                    Toggle("", isOn: $store.replaceDock).settingsToggle()
                }
            }

            AboutCard()
        }
    }
}

private struct AboutCard: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("Better Mac Taskbar")
                    .font(.system(size: 13, weight: .semibold))
                Text(version)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Appearance

private struct AppearancePage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Taskbar") {
                Row(
                    title: "Center icons",
                    subtitle: "Place app icons in the middle of the bar instead of the left edge."
                ) {
                    Toggle("", isOn: $store.centerIcons).settingsToggle()
                }
                Row(
                    title: "Automatically hide",
                    subtitle: "Slide the taskbar off-screen until the pointer reaches the bottom edge."
                ) {
                    Toggle("", isOn: $store.autoHideTaskbar).settingsToggle()
                }
                Row(
                    title: "Button style",
                    subtitle: "Wide buttons show each window's title next to its icon, like Windows 10.",
                    isLast: true
                ) {
                    Picker("", selection: $store.buttonStyle) {
                        ForEach(TaskbarButtonStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 190)
                }
            }

            TaskbarPreview(centered: store.centerIcons)
        }
    }
}

/// Miniature taskbar so icon alignment is visible without closing Settings.
private struct TaskbarPreview: View {
    let centered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))

                HStack(spacing: 6) {
                    if centered { Spacer(minLength: 0) }
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.secondary.opacity(0.55))
                            .frame(width: 14, height: 14)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color.primary.opacity(0.10))
                .animation(.easeInOut(duration: 0.18), value: centered)
            }
            .frame(height: 78)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPage: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var recorder = HotkeyRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(
                title: "Start Menu",
                footer: "Click the shortcut, then press the keys you want. A modifier on its own works too — press ⎋ to cancel."
            ) {
                Row(
                    title: "Enable shortcut",
                    subtitle: "The taskbar Start button keeps working when this is off."
                ) {
                    Toggle("", isOn: $store.hotkeyEnabled).settingsToggle()
                }
                Row(title: "Shortcut", isLast: true) {
                    HStack(spacing: 8) {
                        KeyRecorderField(
                            display: store.hotkeyDisplay,
                            isRecording: recorder.isRecording,
                            isEnabled: store.hotkeyEnabled
                        ) {
                            recorder.toggle()
                        }
                        Button("Reset") { store.resetHotkey() }
                            .controlSize(.small)
                            .disabled(!store.hotkeyEnabled)
                            .help("Reset to ⌘ / Windows key")
                    }
                }
            }
            .onDisappear { recorder.cancel() }
        }
    }
}

/// Shortcut well that reads as a recorder rather than a plain push button.
private struct KeyRecorderField: View {
    let display: String
    let isRecording: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isRecording ? "Press keys…" : display)
                .font(.system(size: 12, weight: isRecording ? .regular : .medium))
                .foregroundStyle(foreground)
                .frame(minWidth: 96)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isRecording ? Color.accentColor : Color.primary.opacity(0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help("Click, then press the shortcut you want for Start")
    }

    private var foreground: Color {
        if !isEnabled { return .secondary }
        return isRecording ? .accentColor : .primary
    }
}

// MARK: - Hidden apps

private struct HiddenAppsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if store.hiddenApps.isEmpty {
                EmptyStateCard(
                    symbol: "eye.slash",
                    title: "No hidden apps",
                    message: "Right-click any taskbar icon and choose Hide to keep it off the bar."
                )
            } else {
                Card(title: "Always hide on the taskbar") {
                    ForEach(Array(store.hiddenApps.enumerated()), id: \.element.id) { index, app in
                        HiddenAppRow(
                            app: app,
                            isLast: index == store.hiddenApps.count - 1,
                            show: { store.show(bundleID: app.bundleID) }
                        )
                    }
                }

                Button("Show All") { store.showAllHiddenApps() }
                    .controlSize(.regular)
                    .padding(.leading, 2)
            }
        }
    }
}

private struct HiddenAppRow: View {
    let app: SettingsStore.HiddenApp
    let isLast: Bool
    let show: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 20, height: 20)
                }
                Text(app.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button("Show", action: show)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: Metrics.rowMinHeight)

            if !isLast {
                Divider().padding(.leading, 42)
            }
        }
    }
}

private struct EmptyStateCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 30)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Permissions

private struct PermissionsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(
                title: "Accessibility",
                footer: "Without Accessibility, apps that manage their own windows (like Chrome) collapse into a single taskbar icon."
            ) {
                Row(
                    title: "Accessibility access",
                    subtitle: "Lets each window appear as its own taskbar icon.",
                    isLast: true
                ) {
                    HStack(spacing: 10) {
                        StatusBadge(ok: store.accessibilityTrusted)
                        if !store.accessibilityTrusted {
                            Button("Open Settings…") { store.openAccessibilitySettings() }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

private struct StatusBadge: View {
    let ok: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(ok ? "Granted" : "Not granted")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
