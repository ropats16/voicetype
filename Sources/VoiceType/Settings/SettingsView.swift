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
    /// The Download list starts open: a missing model's hint points at it.
    @State private var showsDownloads = true

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
                // Only worth a picker once this Mac has a choice of engines.
                if viewModel.engineChoices.count > 1 {
                    Picker("Engine",
                           selection: Binding(
                               get: { viewModel.engine },
                               set: { viewModel.selectEngine($0) }
                           )) {
                        ForEach(viewModel.engineChoices, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                }
                if let note = viewModel.engineNote {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                let lists = viewModel.modelLists
                Picker("Model",
                       selection: Binding(
                           get: { viewModel.modelRow },
                           set: { viewModel.selectModel($0) }
                       )) {
                    Text(viewModel.automaticLabel).tag(ModelRow.automatic)
                    if let custom = viewModel.customModelName {
                        Text("Custom file: \(custom)").tag(ModelRow.custom)
                    }
                    ForEach(lists.downloaded) { model in
                        Text(model.label).tag(ModelRow.catalog(model.id))
                    }
                    Section(viewModel.notDownloadedHeading) {
                        ForEach(lists.notDownloaded) { model in
                            Text(model.label).tag(ModelRow.catalog(model.id)).disabled(true)
                        }
                    }
                }

                // WhisperKit, Parakeet: a Download button per model not yet installed.
                let downloadable = viewModel.inAppDownloadableModels
                if !downloadable.isEmpty {
                    DisclosureGroup("Download a model", isExpanded: $showsDownloads) {
                        ForEach(downloadable) { model in
                            ModelDownloadRow(model: model, viewModel: viewModel)
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

                // Apple Speech: the OS-managed model for the language.
                if let state = viewModel.speechAssetLabel {
                    HStack {
                        Text("Speech model")
                        Spacer()
                        Text(state).foregroundColor(.secondary)
                        if viewModel.canDownloadSpeechModel {
                            Button("Download") { Task { await viewModel.downloadSpeechModel() } }
                        }
                    }
                    if let error = viewModel.speechAssetError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Picker("Keep model loaded",
                       selection: Binding(
                           get: { viewModel.keepWarm },
                           set: { viewModel.setKeepWarm($0) }
                       )) {
                    ForEach(KeepWarmChoice.allCases, id: \.self) { choice in
                        Text(viewModel.label(for: choice)).tag(choice)
                    }
                }

                if let hint = viewModel.modelStatusHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundColor([.loading, .verifying].contains(viewModel.modelStatus) ? .secondary : .red)
                }
            } header: {
                Text("Model")
            }
            .task(id: "\(viewModel.engine.rawValue)|\(viewModel.language)") {
                await viewModel.refreshSpeechAssets()
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

// MARK: - ModelDownloadRow

/// One not-downloaded model: Download, or its progress and Cancel while it
/// downloads, and why the last try failed.
private struct ModelDownloadRow: View {
    let model: EngineModelOption
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        HStack {
            Text(model.label)
            Spacer()
            if let progress = viewModel.modelDownloadLabel(model.id) {
                Text(progress).foregroundColor(.secondary).monospacedDigit()
                Button("Cancel") { viewModel.cancelModelDownload(model.id) }
            } else {
                Button("Download") { viewModel.downloadModel(model.id) }
                    .disabled(!viewModel.canDownloadModel(model.id))
            }
        }
        if let error = viewModel.modelDownloadError(model.id) {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
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
