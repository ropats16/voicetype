import SwiftUI

/// Native settings form for VoiceType. Bound to a `SettingsViewModel` via
/// intent methods (no two-way Binding with didSet) so the view stays simple
/// and initial load never re-persists config values.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

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

            // MARK: Hotkeys (placeholder for Task 4b)
            // TODO: Task 4b will add the hotkey-capture controls here.
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 380)
        .padding()
    }
}
