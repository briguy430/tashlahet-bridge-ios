import Combine
import Foundation

@MainActor
final class TranslationService: ObservableObject {
    @Published var endpoint = "" {
        didSet {
            defaults?.set(endpoint, forKey: "translationEndpoint")
            if oldValue != endpoint {
                serverModel = ""
                qualityWarning = nil
            }
        }
    }
    @Published var authToken = "" {
        didSet {
            persistAuthTokenEdit()
        }
    }
    @Published private(set) var state: TranslationState = .idle
    @Published private(set) var translations: [TranslationEntry] = []
    @Published private(set) var meterLevel: Float = 0
    @Published private(set) var speechDetected = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var serverModel = ""
    @Published private(set) var qualityWarning: String?
    @Published private(set) var credentialPersistenceError: String?
    @Published private(set) var alertMessage: String?

    private let audio: any AudioCapturing
    private let client: any TranslationNetworking
    private let defaults: UserDefaults?
    private let tokenStore: any TokenStoring
    private var isApplyingAuthTokenInternally = true
    private var lastPersistedAuthToken = ""
    private var generation = UUID()
    private var capabilityTask: Task<ServerCapabilities, Error>?
    private var worker: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var queue: [(PCMChunk, TranslationConfiguration)] = []
    private var retryAudio: [UUID: PCMChunk] = [:]
    private var retryOrder: [UUID] = []
    private var sessionConfiguration: TranslationConfiguration?
    private var terminalAudioFailure: String?
    private static let maximumPending = 4
    private static let maximumHistory = 200
    private static let maximumRetries = 8

    init(
        audio: (any AudioCapturing)? = nil,
        client: any TranslationNetworking = TranslationClient(),
        defaults: UserDefaults? = .standard,
        tokenStore: any TokenStoring = KeychainTokenStore()
    ) {
        self.audio = audio ?? AudioCaptureEngine()
        self.client = client
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.endpoint = defaults?.string(forKey: "translationEndpoint") ?? ""
        do {
            let loadedToken = try tokenStore.loadToken()
            let normalized = try TranslationConfiguration.normalizedAuthToken(loadedToken) ?? ""
            self.authToken = normalized
            self.lastPersistedAuthToken = normalized
        } catch {
            self.authToken = ""
            self.lastPersistedAuthToken = ""
            self.credentialPersistenceError = "The saved access token could not be read from this iPhone’s Keychain. Re-enter it in Connection settings."
        }
        self.isApplyingAuthTokenInternally = false
    }

    var isRecording: Bool { state == .listening }
    var isBusy: Bool { state == .connecting || state == .listening || state == .stopping || pendingCount > 0 }
    var canStart: Bool { !isBusy && !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func start() async {
        guard !isBusy else { return }
        let configuration = currentConfiguration
        do { _ = try configuration.validatedEndpoint() }
        catch { fail(error.localizedDescription); return }
        let token = UUID()
        generation = token
        state = .connecting
        alertMessage = nil
        serverModel = ""
        qualityWarning = nil
        terminalAudioFailure = nil
        let task = Task { try await client.checkCapabilities(configuration: configuration) }
        capabilityTask = task
        do {
            let capabilities = try await task.value
            guard generation == token, state == .connecting else { return }
            try capabilities.validateForTashelhitTranslation()
            capabilityTask = nil
            serverModel = capabilities.model
            qualityWarning = capabilities.experimentalQualityWarning
            sessionConfiguration = configuration
            try await audio.start(
                onChunk: { [weak self] chunk in
                    // AudioCapturing delivers callbacks on the main queue.
                    MainActor.assumeIsolated { self?.receive(chunk, token: token) }
                },
                onMeter: { [weak self] meter in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == token,
                              self.state == .listening || self.state == .connecting else { return }
                        self.meterLevel = meter.level
                        self.speechDetected = meter.isSpeech
                    }
                },
                onFailure: { [weak self] message in
                    MainActor.assumeIsolated {
                        self?.handleAudioFailure(message, token: token)
                    }
                }
            )
            guard generation == token, state == .connecting else { return }
            state = .listening
        } catch {
            guard generation == token else { return }
            capabilityTask = nil
            await audio.stop()
            generation = UUID()
            sessionConfiguration = nil
            fail(error.localizedDescription)
        }
    }

    func stop() async {
        if let stopTask { await stopTask.value; return }
        guard state == .connecting || state == .listening || pendingCount > 0 else { return }
        let wasConnecting = state == .connecting
        state = .stopping
        capabilityTask?.cancel()
        capabilityTask = nil
        if wasConnecting { generation = UUID() }
        let task = Task { @MainActor in
            // The engine drains its final PCM and synchronously delivers the tail
            // callbacks before returning. Accept them while in .stopping.
            await audio.stop()
            generation = UUID()
            meterLevel = 0
            speechDetected = false
            if let worker { await worker.value }
            sessionConfiguration = nil
            if let terminalAudioFailure { fail(terminalAudioFailure) }
            else { state = .idle }
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    func testConnection() async {
        guard !isBusy else { return }
        state = .connecting
        alertMessage = nil
        serverModel = ""
        qualityWarning = nil
        let token = UUID()
        generation = token
        let configuration = currentConfiguration
        let task = Task { try await client.checkCapabilities(configuration: configuration) }
        capabilityTask = task
        do {
            let capabilities = try await task.value
            guard generation == token else { return }
            try capabilities.validateForTashelhitTranslation()
            serverModel = capabilities.model
            qualityWarning = capabilities.experimentalQualityWarning
            state = .idle
        } catch {
            guard generation == token else { return }
            fail(error.localizedDescription)
        }
        capabilityTask = nil
    }

    func retry(_ entry: TranslationEntry) {
        guard state != .connecting, state != .stopping,
              !entry.isPending, entry.canRetry, pendingCount < Self.maximumPending,
              let chunk = retryAudio[entry.id],
              let index = translations.firstIndex(where: { $0.id == entry.id }),
              !translations[index].isPending else { return }
        let configuration = currentConfiguration
        do { _ = try configuration.validatedEndpoint() }
        catch { fail(error.localizedDescription); return }
        translations[index].errorMessage = nil
        translations[index].isPending = true
        pendingCount += 1
        queue.append((chunk, configuration))
        beginWorker()
    }

    func clearHistory() {
        guard !isBusy else { return }
        translations.removeAll()
        retryAudio.removeAll()
        retryOrder.removeAll()
    }
    func dismissAlert() { alertMessage = nil }

    private var currentConfiguration: TranslationConfiguration {
        TranslationConfiguration(endpoint: endpoint, authToken: authToken)
    }

    private func persistAuthTokenEdit() {
        guard !isApplyingAuthTokenInternally else { return }

        let normalized: String
        do {
            normalized = try TranslationConfiguration.normalizedAuthToken(authToken) ?? ""
        } catch {
            applyAuthTokenInternally(lastPersistedAuthToken)
            credentialPersistenceError = error.localizedDescription
            return
        }

        do {
            try tokenStore.saveToken(normalized)
        } catch {
            applyAuthTokenInternally(lastPersistedAuthToken)
            credentialPersistenceError = "The access token could not be saved to this iPhone’s Keychain. Your previous token is still active; try again."
            return
        }

        let changed = lastPersistedAuthToken != normalized
        lastPersistedAuthToken = normalized
        if authToken != normalized {
            applyAuthTokenInternally(normalized)
        }
        credentialPersistenceError = nil
        if changed {
            serverModel = ""
            qualityWarning = nil
        }
    }

    private func applyAuthTokenInternally(_ token: String) {
        isApplyingAuthTokenInternally = true
        authToken = token
        isApplyingAuthTokenInternally = false
    }

    private func receive(_ chunk: PCMChunk, token: UUID) {
        guard generation == token, let configuration = sessionConfiguration,
              state == .listening || state == .stopping || state == .connecting else { return }
        var entry = TranslationEntry(id: chunk.id, createdAt: chunk.capturedAt)
        if pendingCount >= Self.maximumPending {
            entry.isPending = false
            entry.canRetry = true
            entry.errorMessage = "The server fell behind. Recording stopped; retry this phrase when the queue has finished."
            rememberForRetry(chunk)
            translations.append(entry)
            trimHistory()
            if state != .stopping {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    await self.stop()
                    self.fail("The server could not keep up with the conversation. Try shorter phrases or a faster server.")
                }
            }
            return
        }
        translations.append(entry)
        trimHistory()
        pendingCount += 1
        queue.append((chunk, configuration))
        beginWorker()
    }

    private func beginWorker() {
        guard worker == nil else { return }
        worker = Task { @MainActor in
            while !queue.isEmpty {
                let (chunk, configuration) = queue.removeFirst()
                let started = Date()
                do {
                    let result = try await client.translate(chunk, configuration: configuration)
                    update(chunk.id) {
                        $0.text = result.text
                        $0.isPending = false
                        $0.errorMessage = nil
                        $0.canRetry = false
                        $0.latencyMilliseconds = Date().timeIntervalSince(started) * 1_000
                    }
                    retryAudio.removeValue(forKey: chunk.id)
                    retryOrder.removeAll { $0 == chunk.id }
                } catch {
                    rememberForRetry(chunk)
                    update(chunk.id) {
                        $0.isPending = false
                        $0.errorMessage = error.localizedDescription
                        $0.canRetry = true
                    }
                }
                pendingCount -= 1
            }
            worker = nil
        }
    }

    private func rememberForRetry(_ chunk: PCMChunk) {
        retryOrder.removeAll { $0 == chunk.id }
        retryOrder.append(chunk.id)
        retryAudio[chunk.id] = chunk
        while retryOrder.count > Self.maximumRetries {
            let expired = retryOrder.removeFirst()
            retryAudio.removeValue(forKey: expired)
            update(expired) {
                $0.errorMessage = "This phrase could not be translated. Its audio was released to limit memory use; please repeat it."
                $0.canRetry = false
            }
        }
    }

    private func update(_ id: UUID, _ body: (inout TranslationEntry) -> Void) {
        guard let index = translations.firstIndex(where: { $0.id == id }) else { return }
        body(&translations[index])
    }

    private func trimHistory() {
        while translations.count > Self.maximumHistory,
              let index = translations.firstIndex(where: { !$0.isPending }) {
            let removed = translations.remove(at: index)
            retryAudio.removeValue(forKey: removed.id)
            retryOrder.removeAll { $0 == removed.id }
        }
    }

    private func fail(_ message: String) {
        state = .failed
        alertMessage = message
        meterLevel = 0
        speechDetected = false
    }

    private func handleAudioFailure(_ message: String, token: UUID) {
        guard generation == token else { return }
        terminalAudioFailure = terminalAudioFailure ?? message
        if state == .stopping {
            alertMessage = terminalAudioFailure
        } else {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                await self.stop()
                self.fail(self.terminalAudioFailure ?? message)
            }
        }
    }
}
