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
                TextField("https://your-server/inference", text: $service.endpoint)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(service.isBusy || isTesting)
                    .accessibilityLabel("Translation server address")
                    .onChange(of: service.endpoint) { _, _ in didTest = false }

                SecureField("Optional access token", text: $service.authToken)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(service.isBusy || isTesting)
                    .privacySensitive()
                    .accessibilityLabel("Translation server access token")
                    .onChange(of: service.authToken) { _, _ in didTest = false }

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
                if let warning = service.qualityWarning {
                    ExperimentalQualityWarningBanner(message: warning)
                }
                if didTest, let message = service.alertMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Translation server")
            } footer: {
                Text("Use HTTPS with an access token to connect over the internet or a private network such as Tailscale. If your Mac hosts the server, it must stay powered on. The token is stored only in this iPhone’s Keychain. “localhost” on an iPhone refers to the iPhone.")
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

struct ExperimentalQualityWarningBanner: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Experimental accuracy", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
            Text(message)
                .font(.footnote)
        }
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("experimental-quality-warning")
    }
}
