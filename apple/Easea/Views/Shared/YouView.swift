import SwiftUI
import UserNotifications
import EaseaCore

/// Settings: how aggressive the automatic cut is, and notifications.
struct YouView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProjectStore.self) private var store
    @State private var notificationsAllowed: Bool?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("Editor", selection: $settings.editorMode) {
                        ForEach(EditorMode.allCases) { Text($0.label).tag($0) }
                    }
                    if settings.editorMode == .claude {
                        Picker("Pace", selection: $settings.pace) {
                            ForEach(EditPace.allCases) { Text($0.label).tag($0) }
                        }
                        TextField("Server address", text: $settings.plannerURL, prompt: Text("https://…workers.dev"))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                        SecureField("App token", text: $settings.appToken)
                        if ClaudeEditor(settings: settings) == nil {
                            Label("Add your Easea server address to use Claude. Until then, cuts use the on-device editor.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("AI editor")
                } footer: {
                    Text(settings.editorMode == .claude
                         ? "Claude reads your transcript and decides what to cut: retakes, false starts, filler and rambling. Only the text and word timings are sent, never your video. If Claude can't be reached, Easea uses its on-device editor."
                         : "Edits are made on this device with rules for retakes, filler words and pauses. Nothing is sent anywhere.")
                }

                Section {
                    Toggle("Remove retakes", isOn: $settings.cutOptions.removeRetakes)
                    Toggle("Remove filler words (um, uh)", isOn: $settings.cutOptions.removeFillers)
                    LabeledContent("Longest pause kept") {
                        Slider(value: $settings.cutOptions.maxPause, in: 0.1...1.0) {
                            Text("Longest pause")
                        } minimumValueLabel: { Text("Tight") } maximumValueLabel: { Text("Relaxed") }
                    }
                    LabeledContent("Breathing room") {
                        Slider(value: $settings.cutOptions.padding, in: 0...0.3)
                    }
                    LabeledContent("Silence level") {
                        Slider(value: $settings.cutOptions.silenceThreshold, in: -55 ... -25) {
                            Text("Silence level")
                        } minimumValueLabel: { Text("Quiet room") } maximumValueLabel: { Text("Noisy") }
                    }
                    Toggle("Overlap audio by default", isOn: $settings.defaultOverlapAudio)
                    Button("Reset to defaults") {
                        settings.cutOptions = CutOptions()
                    }
                } header: {
                    Text("Automatic cut")
                } footer: {
                    Text("These apply to both editors. Pause and silence settings shape the final clips; use “Rebuild with current settings” in the editor to apply them to an existing cut.")
                }

                Section("Notifications") {
                    if notificationsAllowed == true {
                        Label("You'll be notified when cuts are ready", systemImage: "bell.badge.fill")
                    } else {
                        Button("Notify me when cuts are ready") {
                            Task { notificationsAllowed = await Notifications.requestPermission() }
                        }
                    }
                }

                Section("Privacy") {
                    Label(settings.editorMode == .claude
                          ? "Transcription runs on this device. Your videos are never uploaded; only transcripts go to Claude for editing."
                          : "Transcription and editing run on this device. Nothing is uploaded.",
                          systemImage: "lock.shield")
                        .font(.footnote)
                }

                Section("Storage") {
                    LabeledContent("Cuts", value: "\(store.projects.count)")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("You")
            .task {
                let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                notificationsAllowed = status == .authorized || status == .provisional
            }
        }
    }
}
