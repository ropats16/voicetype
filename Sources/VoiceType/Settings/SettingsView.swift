import SwiftUI
import AppKit

/// Native settings form for VoiceType. Bound to a `SettingsViewModel` via
/// intent methods (no two-way Binding with didSet) so the view stays simple
/// and initial load never re-persists config values.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    /// The recorder is now owned by `SettingsViewModel` so `SettingsWindowController`
    /// can reach it via `viewModel.cancelCapture()` from `windowWillClose(_:)`.
    /// Passed explicitly so SwiftUI observes its `@Published` properties.
    @ObservedObject var recorder: HotkeyRecorder

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

            // MARK: Dictation
            Section {
                Picker("Max dictation length",
                       selection: Binding(
                           get: { viewModel.maxDictationSeconds },
                           set: { viewModel.setMaxDictationSeconds($0) }
                       )) {
                    ForEach(viewModel.maxDictationChoices, id: \.seconds) { choice in
                        Text(choice.label).tag(choice.seconds)
                    }
                }
            } header: {
                Text("Dictation")
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
                           get: { viewModel.selectedModelID },
                           set: { viewModel.selectModel($0) }
                       )) {
                    Text("Automatic (\(viewModel.recommendedModel.label))").tag(ModelSelection.automatic)
                    if let custom = viewModel.customModelName {
                        Text("Custom file: \(custom)").tag(SettingsViewModel.customModelID)
                    }
                    ForEach(viewModel.downloadedModels) { model in
                        Text(model.label).tag(model.id)
                    }
                    Section("Not downloaded — run: make model MODEL=<name>") {
                        ForEach(viewModel.notDownloadedModels) { model in
                            Text(model.label).tag(model.id).disabled(true)
                        }
                    }
                }

                Picker("Language",
                       selection: Binding(
                           get: { viewModel.isLanguageSelectable ? viewModel.language : "en" },
                           set: { viewModel.setLanguage($0) }
                       )) {
                    ForEach(viewModel.languageOptions, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .disabled(!viewModel.isLanguageSelectable)

                Toggle("Keep model loaded",
                       isOn: Binding(
                           get: { viewModel.keepModelWarm },
                           set: { viewModel.setKeepModelWarm($0) }
                       ))
                Text(viewModel.keepModelWarm
                     ? "Fastest dictation; the model stays in memory."
                     : "Frees memory when idle; the next dictation reloads the model first.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let hint = viewModel.modelStatusHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(viewModel.modelStatus == .loading ? .secondary : .red)
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
            // Hide Reset while this row is in "Recording…" mode so there is no
            // path that leaves the recorder's monitor active while the VM thinks
            // capture has ended (I2). The edge case of the OTHER row capturing is
            // handled inside SettingsViewModel.resetHotkey, which calls
            // recorder.cancelCapture first.
            if !isCapturing {
                Button("Reset to default") { onReset() }
            }
        }
    }
}
