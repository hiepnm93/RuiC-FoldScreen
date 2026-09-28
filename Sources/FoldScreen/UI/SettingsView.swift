import AppKit
import SwiftUI

/// Which pane the settings window is showing.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case appearance
    case lid
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .lid: return "Lid"
        case .about: return "About"
        }
    }

    /// SF Symbols is the platform's own icon set, so the sidebar matches every
    /// other settings window on the system.
    var symbol: String {
        switch self {
        case .general: return "switch.2"
        case .appearance: return "square.on.square.dashed"
        case .lid: return "laptopcomputer"
        case .about: return "info.circle"
        }
    }
}

/// The settings window.
///
/// Built on a `NavigationSplitView` with grouped forms, which is the layout
/// macOS users already know from System Settings. The unusual part of this app
/// is the effect itself, so the settings deliberately stay conventional.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var effect: LiveFold
    @ObservedObject var preview: FoldPreview

    @State private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.symbol)
                }
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 176, max: 200)
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                statusFooter
            }
        } detail: {
            ScrollView {
                detail
                    .padding(20)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: generalPane
        case .appearance: appearancePane
        case .lid: lidPane
        case .about: aboutPane
        }
    }

    // MARK: - Footer

    /// A persistent state line, so the window always answers "is it on?" without
    /// the user having to find the right pane.
    private var statusFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(effect.state.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(effect.state.isRunning ? "Effect enabled" : "Effect paused")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - General

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionCard("Desktop Effect") {
                VStack(alignment: .leading, spacing: 0) {
                    LabeledRow(
                        title: effect.state == .starting ? "Connecting…" : "Enable Fold Screen",
                        detail: "Bend the desktop along with the lid angle."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { effect.isEnabled },
                            set: { effect.setEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(effect.state == .starting)
                    }
                    Divider()
                    LabeledRow(
                        title: "Open at Login",
                        detail: "Starts in the menu bar and restores your last on/off state."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { effect.openAtLogin },
                            set: { effect.setOpenAtLogin($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    Divider()
                    Text(effect.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }

            SectionCard("Screen Recording Permission") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledRow(
                        title: effect.hasScreenRecordingPermission ? "Permission granted" : "Permission not granted yet",
                        detail: effect.hasScreenRecordingPermission
                            ? "The system allows screen access; the effect can start normally."
                            : "The effect must read the screen to bend it. Enable this app in System Settings."
                    ) {
                        Image(systemName: effect.hasScreenRecordingPermission
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(effect.hasScreenRecordingPermission
                                ? Color.green : Color.orange)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            "Frames live in memory for an instant only — never written to disk, never uploaded, no audio captured."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button("Open Screen Recording Settings…") {
                                guard
                                    let url = URL(
                                        string:
                                            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                                    )
                                else { return }
                                NSWorkspace.shared.open(url)
                            }
                            Button("Recheck") {
                                effect.refreshPermissionStatus()
                                effect.recheckPermission()
                            }
                            .disabled(!effect.isEnabled)
                            Button("Reopen") {
                                effect.relaunch()
                            }
                            .help("macOS sometimes needs an app restart for a freshly granted permission to take effect.")
                        }
                        .controlSize(.regular)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SectionCard("How to Use") {
                VStack(alignment: .leading, spacing: 0) {
                    InfoRow(
                        symbol: "escape", title: "Pause anytime",
                        detail: "Press Escape while the effect is up to instantly restore the desktop.")
                    Divider()
                    InfoRow(
                        symbol: "menubar.rectangle", title: "Lives in the menu bar",
                        detail: "Closing this window doesn't quit; the app keeps running in the menu bar.")
                    Divider()
                    InfoRow(
                        symbol: "display", title: "Built-in display only",
                        detail: "External displays are untouched; it reconnects automatically after sleep or display changes.")
                }
            }
        }
    }

    // MARK: - Appearance

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionCard("Preview") {
                VStack(spacing: 14) {
                    Text("Preview the fold with the built-in capture — no screen recording permission needed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ZStack(alignment: .bottom) {
                        FoldPreviewView(preview: preview)
                            .aspectRatio(1.6, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button {
                            if preview.isPlaying { preview.pause() } else { preview.play() }
                        } label: {
                            Label(
                                preview.isPlaying ? "Pause" : "Play fold",
                                systemImage: preview.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom, 14)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.separator)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "laptopcomputer")
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { preview.angle },
                            set: { preview.angle = $0; preview.scrub() }
                        ), in: 12...135)
                        .accessibilityLabel("Preview lid angle")
                        Text("\(Int(preview.angle))°")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                .padding(14)
            }

            SectionCard("Appearance") {
                VStack(alignment: .leading, spacing: 0) {
                    LabeledRow(title: "Style", detail: store.settings.preset.detail) {
                        Picker("", selection: Binding(
                            get: { store.settings.preset },
                            set: { store.settings.preset = $0 }))
                        {
                            ForEach(FoldPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                    }
                    Divider()
                    SliderRow(
                        title: "Perspective", detail: "How much the top corners pull inward.",
                        value: Binding(
                            get: { store.settings.perspective },
                            set: { store.settings.perspective = $0 }))
                    Divider()
                    SliderRow(
                        title: "Blur", detail: "How strongly the desktop blurs toward the top.",
                        value: Binding(
                            get: { store.settings.blur },
                            set: { store.settings.blur = $0 }))
                    Divider()
                    SliderRow(
                        title: "Shadow", detail: "How deep the shadows are on the folded sides.",
                        value: Binding(
                            get: { store.settings.shade },
                            set: { store.settings.shade = $0 }))
                }
            }

            Button {
                store.reset()
            } label: {
                Label("Reset Appearance", systemImage: "arrow.uturn.backward")
            }
            .controlSize(.regular)
        }
    }

    // MARK: - Lid

    private var lidPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionCard("Lid Sensor") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(effect.lidAngle == nil ? "No sensor detected" : "Sensor connected")
                                .font(.callout.weight(.medium))
                            Text("Current lid angle. If it can't be read, use the manual angle below.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Text(effect.lidAngle.map { "\(Int($0))°" } ?? "—")
                            .font(.system(size: 26, weight: .light).monospacedDigit())
                    }
                    .padding(14)

                    Divider()
                    LabeledRow(title: "Follow Physical Lid", detail: "Turn off to drive the effect with a fixed desktop angle instead.") {
                        Toggle("", isOn: Binding(
                            get: { store.settings.followLid },
                            set: { store.settings.followLid = $0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    if !store.settings.followLid {
                        Divider()
                        SliderRow(
                            title: "Desktop angle", detail: "When on, the effect is driven by this fixed angle.",
                            range: 12...135, showsDegrees: true,
                            value: Binding(
                                get: { store.settings.manualAngle },
                                set: { store.settings.manualAngle = $0 }))
                    }
                }
            }

            SectionCard("Actions & Sound") {
                VStack(alignment: .leading, spacing: 0) {
                    SliderRow(
                        title: "Fully open angle",
                        detail: "Above this angle the desktop stays untouched — no fold, no blur.",
                        range: 80...135, showsDegrees: true,
                        value: Binding(
                            get: { store.settings.clearAngle },
                            set: { store.settings.clearAngle = $0 }))
                    Divider()
                    LabeledRow(title: "Chime when fully open", detail: "Play a soft sound once the desktop is fully restored.") {
                        Toggle("", isOn: Binding(
                            get: { store.settings.sound },
                            set: { store.settings.sound = $0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }

            Text("Apple hasn't documented the lid sensor's report format, so some models and OS versions can't read it. If so, the Preview in Appearance shows the effect just as well.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - About

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fold Screen")
                        .font(.title2.weight(.semibold))
                    Text("RuiC-FoldScreen \(Self.version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("As you close the lid, the desktop bends down with it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            SectionCard("How It Works") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        "The lid angle comes from the built-in HID sensor, the desktop is captured with ScreenCaptureKit, and a Metal shader projects the fold with perspective and progressive blur. The whole pipeline is read-only and never touches disk."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SectionCard("License") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MIT licensed — free to use and modify.")
                        .font(.callout)
                    Text("Bendy was the first public take on the folding-desktop idea; this project is an independent rewrite, unaffiliated with Bendy or Apple.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

// MARK: - Building blocks

/// A titled group of rows, matching the grouped-card look of System Settings.
private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator)
            }
        }
    }
}

/// Label on the left, control on the right.
private struct LabeledRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: Control

    init(title: String, detail: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(14)
    }
}

/// A labelled slider with a live numeric readout.
private struct SliderRow: View {
    let title: String
    let detail: String
    var range: ClosedRange<Double> = 0...1
    var showsDegrees: Bool = false
    @Binding var value: Double

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Slider(value: $value, in: range)
                .frame(width: 150)
                .accessibilityLabel(title)
            Text(showsDegrees ? "\(Int(value))°" : "\(Int(value * 100))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(14)
    }
}

/// An icon, a title, and one line of explanation. Read-only.
private struct InfoRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}
