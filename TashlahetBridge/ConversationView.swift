import SwiftUI
import UIKit

/// The iPhone conversation surface. All service state is isolated to the main actor.
@MainActor
struct ConversationView: View {
    @EnvironmentObject private var service: TranslationService
    @State private var showsSettings = false
    @State private var confirmsClear = false

    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width >= 650 {
                    HStack(alignment: .top, spacing: 16) {
                        inputCard(compact: false)
                            .frame(maxWidth: 340, maxHeight: .infinity)
                        translationCard
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 16) {
                        inputCard(compact: true)
                        translationCard
                            .frame(maxHeight: .infinity)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 1_100, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(BridgeStyle.background.ignoresSafeArea())
        .navigationTitle("Tashlahet Bridge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(BridgeStyle.teal)
                    .accessibilityHidden(true)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        confirmsClear = true
                    } label: {
                        Label("Clear conversation", systemImage: "trash")
                    }
                    .disabled(service.translations.isEmpty || service.isBusy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Conversation actions")

                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .disabled(service.isBusy)
                .accessibilityLabel("Connection settings")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            recordingControls
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                ConnectionSettingsView()
                    .environmentObject(service)
            }
        }
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear conversation", role: .destructive) {
                service.clearHistory()
            }
        } message: {
            Text("The translations shown here will be removed.")
        }
        .alert("Translation needs attention", isPresented: Binding(
            get: { service.alertMessage != nil },
            set: { if !$0 { service.dismissAlert() } }
        )) {
            Button("OK") { service.dismissAlert() }
        } message: {
            Text(service.alertMessage ?? "Please check the connection and try again.")
        }
        .tint(BridgeStyle.teal)
    }

    private func inputCard(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 22) {
            HStack(alignment: .firstTextBaseline) {
                Label("Tashlahet Feed", systemImage: "mic.fill")
                    .font(.headline)
                Spacer(minLength: 8)
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }

            if !compact {
                Text("ⵜⴰⵛⵍⵃⵉⵜ")
                    .font(.largeTitle.weight(.medium))
                    .foregroundStyle(BridgeStyle.teal)
                    .accessibilityLabel("Tashlahet")
                Text("A voice from home.\nWords you can understand.")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(BridgeStyle.ink)
            }

            HStack(spacing: 10) {
                if service.state == .connecting || service.state == .stopping {
                    ProgressView()
                        .tint(BridgeStyle.teal)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: service.speechDetected ? "waveform" : "ear")
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)
                }
                Text(statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BridgeStyle.ink)
            }

            AudioLevelMeter(
                level: service.meterLevel,
                enabled: service.isRecording,
                speechDetected: service.speechDetected
            )
            .frame(height: compact ? 34 : 64)

            Text(compact
                 ? "Tashlahet → English · pause naturally between phrases"
                 : "Speak naturally and pause briefly between phrases. English appears as each phrase is translated.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !compact {
                Spacer(minLength: 0)
                Label("Audio activity is detected here. The server identifies and translates the language.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(compact ? 18 : 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BridgeStyle.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(BridgeStyle.teal.opacity(0.12), lineWidth: 1)
        }
    }

    private var translationCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("English Translation", systemImage: "text.bubble.fill")
                    .font(.headline)
                    .foregroundStyle(BridgeStyle.ink)
                Spacer(minLength: 0)
                if service.pendingCount > 0 {
                    Text("\(service.pendingCount) waiting")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(BridgeStyle.teal)
                        .accessibilityLabel("\(service.pendingCount) phrases awaiting translation")
                }
            }
            .padding(18)

            if let warning = service.qualityWarning {
                Divider()
                    .overlay(Color.orange.opacity(0.2))
                ExperimentalQualityWarningBanner(message: warning)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
            }

            Divider()
                .overlay(BridgeStyle.teal.opacity(0.08))

            if service.translations.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(BridgeStyle.teal.opacity(0.6))
                        .accessibilityHidden(true)
                    Text("A conversation starts with a voice")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(service.endpoint.isEmpty
                         ? "Connect a Tashelhit translation server to begin. English phrases will appear here."
                         : "Tap Start Live Feed. Translated phrases will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(service.translations) { entry in
                                TranslationRow(entry: entry) {
                                    service.retry(entry)
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("latest-translation")
                        }
                        .padding(16)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: translationRevision) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("latest-translation", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BridgeStyle.card, in: RoundedRectangle(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(BridgeStyle.teal.opacity(0.12), lineWidth: 1)
        }
    }

    private var recordingControls: some View {
        VStack(spacing: 8) {
            if service.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    showsSettings = true
                } label: {
                    Label("Set up translation server", systemImage: "network")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
            }
            Button {
                Task {
                    if service.isRecording || service.state == .connecting {
                        await service.stop()
                    } else {
                        await service.start()
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    if service.state == .stopping {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: service.isRecording || service.state == .connecting
                              ? "stop.fill" : "mic.fill")
                    }
                    Text(controlTitle)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(.white)
                .background(controlColor, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .disabled(service.state == .stopping || (!service.canStart && !service.isRecording && service.state != .connecting))
            .opacity(service.state == .stopping ? 0.65 : 1)
            .accessibilityHint(service.isRecording || service.state == .connecting
                               ? "Stops the microphone and finishes queued phrases."
                               : "Connects to your translation server and starts the microphone.")

            Text(service.isRecording
                 ? "Listening on your iPhone microphone"
                 : service.endpoint.isEmpty ? "A compatible Tashelhit model is required" : "Audio is sent to the translation server you choose")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var translationRevision: [String] {
        service.translations.map {
            "\($0.id.uuidString)|\($0.isPending)|\($0.text)|\($0.errorMessage ?? "")"
        }
    }

    private var statusText: String {
        switch service.state {
        case .idle: return service.endpoint.isEmpty ? "Connect a translation server" : "Ready when you are"
        case .connecting: return "Connecting to your server…"
        case .listening: return service.speechDetected ? "Speech detected" : "Listening for a voice"
        case .stopping: return "Finishing translations…"
        case .failed: return "Connection needs attention"
        }
    }

    private var statusColor: Color {
        switch service.state {
        case .listening: return service.speechDetected ? BridgeStyle.teal : .green
        case .connecting, .stopping: return .orange
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    private var controlTitle: String {
        switch service.state {
        case .connecting, .listening: return "Stop Translation"
        case .stopping: return "Finishing…"
        case .idle, .failed: return "Start Live Feed"
        }
    }

    private var controlColor: Color {
        service.isRecording || service.state == .connecting
        ? Color(red: 0.73, green: 0.24, blue: 0.22)
        : BridgeStyle.teal
    }
}

private struct TranslationRow: View {
    let entry: TranslationEntry
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let latency = entry.latencyMilliseconds, !entry.isPending {
                    Text("\(latency / 1_000, specifier: "%.1f")s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(format: "Translated in %.1f seconds", latency / 1_000))
                }
            }

            if entry.isPending {
                HStack(spacing: 10) {
                    ProgressView().tint(BridgeStyle.teal)
                    Text("Translating this phrase…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let error = entry.errorMessage {
                Label("This phrase could not be translated", systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.canRetry {
                    Button(action: retry) {
                        Label("Retry phrase", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .tint(BridgeStyle.teal)
                }
            } else {
                Text(entry.text.isEmpty ? "No translated speech was returned." : entry.text)
                    .font(.title3)
                    .foregroundStyle(BridgeStyle.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BridgeStyle.translation, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct AudioLevelMeter: View {
    let level: Float
    let enabled: Bool
    let speechDetected: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<28, id: \.self) { index in
                    Capsule()
                        .fill(BridgeStyle.teal.opacity(enabled ? 0.7 : 0.18))
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight(index: index, maximum: geometry.size.height))
                }
            }
            .frame(height: geometry.size.height)
        }
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone activity")
        .accessibilityValue(!enabled ? "Microphone stopped" : speechDetected ? "Speech detected" : "Waiting for speech")
    }

    private func barHeight(index: Int, maximum: CGFloat) -> CGFloat {
        let amplitude = enabled ? CGFloat(max(0, min(1, level))) : 0
        let profile = 0.3 + 0.7 * abs(sin(CGFloat(index) * 0.73))
        return min(maximum, max(4, 4 + amplitude * profile * (maximum - 4)))
    }
}

enum BridgeStyle {
    static let teal = Color(red: 0.04, green: 0.45, blue: 0.44)
    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.91, green: 0.95, blue: 0.97, alpha: 1)
        : UIColor(red: 0.12, green: 0.20, blue: 0.25, alpha: 1)
    })
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.07, green: 0.11, blue: 0.13, alpha: 1)
        : UIColor(red: 0.96, green: 0.96, blue: 0.93, alpha: 1)
    })
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let translation = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.10, green: 0.17, blue: 0.18, alpha: 1)
        : UIColor(red: 0.92, green: 0.96, blue: 0.94, alpha: 1)
    })
}
