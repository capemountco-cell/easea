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
                    Picker("Editing style", selection: $settings.pace) {
                        ForEach(EditPace.allCases) { Text($0.label).tag($0) }
                    }
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
                    Text("Tight cuts rambling and filler hard; Relaxed only removes mistakes. Use “Rebuild with current settings” in the editor to apply pause and silence changes to an existing cut.")
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
                    Label("Your videos never leave your device. To make your edit, Easea sends the transcript of what you said to its servers.",
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
