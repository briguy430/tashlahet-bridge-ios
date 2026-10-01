import SwiftUI
import UIKit

@MainActor
struct ConnectionSettingsView: View {
    @EnvironmentObject private var service: TranslationService
    @Environment(\.dismiss) private var dismiss
    @State private var isTesting = false
    @State private var didTest = false

    var body: some View {
        Form {
            Section {
                TextField("http://your-mac.local:8080/inference", text: $service.endpoint)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(service.isBusy || isTesting)
                    .accessibilityLabel("Translation server address")
                    .onChange(of: service.endpoint) { _, _ in didTest = false }

                Button {
                    Task {
                        isTesting = true
                        didTest = false
                        await service.testConnection()
                        didTest = true
                        isTesting = false
                    }
                } label: {
                    HStack {
                        Label("Test Connection", systemImage: "network")
                        Spacer()
                        if isTesting {
                            ProgressView()
                        }
                    }
                    .frame(minHeight: 32)
                }
                .disabled(service.isBusy || isTesting || service.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if didTest, service.alertMessage == nil, !service.serverModel.isEmpty {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(BridgeStyle.teal)
                    LabeledContent("Translation model", value: service.serverModel)
                        .font(.footnote)
                }
                if didTest, let message = service.alertMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Translation server")
            } footer: {
                Text("Connect your iPhone and server to the same Wi-Fi network. Enter your Mac’s local hostname or network address. “localhost” on an iPhone refers to the iPhone.")
            }

            Section {
                Label("Tashlahet → English", systemImage: "globe")
                Text("Your server needs a model trained for Tashelhit. Standard Whisper does not support the shi language code.")
                    .font(.subheadline)
                Text("Audio is sent to the server you choose. A local server keeps it on your network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Language & privacy")
            }

            Section {
                Text("Allow microphone and local network access when your iPhone asks. If access was denied, enable it in Settings.")
                    .font(.subheadline)
                Button {
                    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(settingsURL)
                } label: {
                    Label("Open iPhone Settings", systemImage: "gear")
                        .frame(minHeight: 32)
                }
            } header: {
                Text("Permissions")
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .disabled(isTesting)
            }
        }
        .interactiveDismissDisabled(isTesting)
        .tint(BridgeStyle.teal)
    }
}
