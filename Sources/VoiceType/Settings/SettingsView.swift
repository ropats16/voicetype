import SwiftUI
import AppKit

/// Native settings form for VoiceType. Bound to a `SettingsViewModel` via
/// intent methods (no two-way Binding with didSet) so the view stays simple
/// and initial load never re-persists config values.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    /// Manages the NSEvent local monitor for live hotkey capture. Its lifetime
    /// is tied to this view (window); when the window closes, `onDisappear`
    /// cancels any in-progress capture, removing the monitor.
    @StateObject private var recorder = HotkeyRecorder()

    var body: some View {
        Form {
            // MARK: Dictation Sounds
            Section {
                Toggle("Play start/stop sounds",
                       isOn: Binding(
                           get: { viewModel.soundCues },
                           set: { viewModel.setSoundCues($0) }
                       ))
            } header: {
                Text("Dictation Sounds")
            }

            // MARK: Startup
            Section {
                Toggle("Launch VoiceType at login",
                       isOn: Binding(
                           get: { viewModel.launchAtLogin },
                           set: { viewModel.setLaunchAtLogin($0) }
                       ))
                if let err = viewModel.loginError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } header: {
                Text("Startup")
            }

            // MARK: Microphone
            Section {
                Picker("Microphone",
                       selection: Binding(
                           get: { viewModel.selectedMicUID },
                           set: { viewModel.selectMic($0) }
                       )) {
                    Text("System Default").tag(String?.none)
                    ForEach(viewModel.micOptions, id: \.uid) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
            } header: {
                Text("Microphone")
            }

            // MARK: Model
            Section {
                Picker("Model",
                       selection: Binding(
                           get: { viewModel.selectedModelSize },
                           set: { if let size = $0 { viewModel.selectModel(size) } }
                       )) {
                    ForEach(viewModel.modelEntries, id: \.size) { entry in
                        if entry.isDownloaded {
                            Text(entry.size).tag(Optional(entry.size))
                        } else {
                            Text("\(entry.size)  —  run: make model MODEL=\(entry.size)")
                                .foregroundColor(.secondary)
                                .tag(Optional(entry.size))
                        }
                    }
                }
                .disabled(viewModel.modelEntries.allSatisfy { !$0.isDownloaded })

                if viewModel.modelChangeNeedsRestart {
                    Text("Restart VoiceType to load the new model.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Model")
            }

            // MARK: Hotkeys
            Section {
                HotkeyRow(
                    label: "Hold to talk",
                    description: viewModel.holdDescription,
                    isCapturing: recorder.captureTarget == .hold,
                    onRecord: { recorder.startCapture(for: .hold, vm: viewModel) },
                    onReset:  { viewModel.resetHotkey(.hold) }
                )
                HotkeyRow(
                    label: "Toggle to talk",
                    description: viewModel.toggleDescription,
                    isCapturing: recorder.captureTarget == .toggle,
                    onRecord: { recorder.startCapture(for: .toggle, vm: viewModel) },
                    onReset:  { viewModel.resetHotkey(.toggle) }
                )
                if let warning = viewModel.hotkeyWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } header: {
                Text("Hotkeys")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 380)
        .padding()
        .onDisappear {
            // Window closed mid-capture: remove the monitor and resume the tap.
            recorder.cancelCapture(vm: viewModel)
        }
    }
}

// MARK: - HotkeyRow

/// A single row in the Hotkeys section: shows the current binding, a Record
/// button to start live capture, and a Reset-to-default fallback button.
private struct HotkeyRow: View {
    let label: String
    let description: String
    let isCapturing: Bool
    let onRecord: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if isCapturing {
                Text("Recording… press keys (Esc to cancel)")
                    .foregroundColor(.secondary)
                    .font(.callout)
            } else {
                Text(description)
                    .foregroundColor(.secondary)
                Button("Record") { onRecord() }
            }
            Button("Reset to default") { onReset() }
        }
    }
}
