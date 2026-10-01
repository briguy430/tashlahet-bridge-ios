import XCTest
@testable import TashlahetBridge

@MainActor
final class TranslationServiceTests: XCTestCase {
    func testUnsupportedServerNeverOpensMicrophone() async {
        let audio = ControlledAudio()
        let client = ControlledClient(supported: false)
        let service = TranslationService(audio: audio, client: client, defaults: nil, tokenStore: MemoryTokenStore())
        service.endpoint = "https://example.test/inference"
        await service.start()
        XCTAssertEqual(service.state, .failed)
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertNotNil(service.alertMessage)
    }

    func testStopTranslatesFinalSpeechTailAndRetainsOrder() async {
        let audio = ControlledAudio()
        let service = TranslationService(audio: audio, client: ControlledClient(), defaults: nil, tokenStore: MemoryTokenStore())
        service.endpoint = "https://example.test/inference"
        await service.start()
        XCTAssertTrue(service.isRecording)
        audio.emit(samples: [0.1])
        audio.finalSamples = [0.2]
        await service.stop()
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertEqual(service.translations.map(\.text), ["First phrase", "Second phrase"])
        XCTAssertTrue(service.translations.allSatisfy { !$0.isPending })
    }

    func testLateAudioAfterStopDoesNotCreateTranslation() async {
        let audio = ControlledAudio()
        let service = TranslationService(audio: audio, client: ControlledClient(), defaults: nil, tokenStore: MemoryTokenStore())
        service.endpoint = "https://example.test/inference"
        await service.start()
        await service.stop()
        audio.emit(samples: [0.1])
        XCTAssertTrue(service.translations.isEmpty)
    }

    func testEmptyConfigurationDoesNotOpenMicrophone() async {
        let audio = ControlledAudio()
        let service = TranslationService(audio: audio, client: ControlledClient(), defaults: nil, tokenStore: MemoryTokenStore())
        await service.start()
        XCTAssertFalse(service.canStart)
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertNotNil(service.alertMessage)
    }

    func testStopDuringCapabilityCheckCannotStartMicrophoneLater() async {
        let audio = ControlledAudio()
        let client = DelayedCapabilityClient()
        let service = TranslationService(audio: audio, client: client, defaults: nil, tokenStore: MemoryTokenStore())
        service.endpoint = "https://example.test/inference"
        let starting = Task { await service.start() }
        await client.waitUntilChecking()
        await service.stop()
        await client.finishCheck()
        await starting.value
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertNil(service.alertMessage)
    }

    func testFailedPhraseCanBeRetriedWithoutChangingItsPosition() async {
        let audio = ControlledAudio()
        let client = RetryClient()
        let service = TranslationService(audio: audio, client: client, defaults: nil, tokenStore: MemoryTokenStore())
        service.endpoint = "https://example.test/inference"
        await service.start()
        audio.emit(samples: [0.1])
        await service.stop()
        let failed = try! XCTUnwrap(service.translations.first)
        XCTAssertNotNil(failed.errorMessage)
        service.retry(failed)
        await service.stop()
        XCTAssertEqual(service.translations.count, 1)
        XCTAssertEqual(service.translations.first?.id, failed.id)
        XCTAssertEqual(service.translations.first?.text, "Recovered phrase")
        XCTAssertNil(service.translations.first?.errorMessage)
        XCTAssertEqual(service.pendingCount, 0)
    }

    func testAudioFailureDuringStopRemainsVisibleAfterQueueDrains() async {
        let audio = ControlledAudio()
        let service = TranslationService(audio: audio, client: ControlledClient(), defaults: nil, tokenStore: MemoryTokenStore())
        service.endpoint = "https://example.test/inference"
        await service.start()
        audio.finalSamples = [0.1]
        audio.finalFailure = "Final audio conversion failed"
        await service.stop()
        XCTAssertEqual(service.state, .failed)
        XCTAssertEqual(service.alertMessage, "Final audio conversion failed")
        XCTAssertEqual(service.translations.first?.text, "First phrase")
        XCTAssertFalse(service.isRecording)
    }

    func testEditingEndpointClearsPreviouslyTestedModel() async {
        let service = TranslationService(audio: ControlledAudio(), client: ControlledClient(), defaults: nil, tokenStore: MemoryTokenStore())
        service.endpoint = "https://first.example.test/inference"
        await service.testConnection()
        XCTAssertFalse(service.serverModel.isEmpty)
        service.endpoint = "https://second.example.test/inference"
        XCTAssertTrue(service.serverModel.isEmpty)
    }

    func testExperimentalCapabilitiesPublishWarningAndEndpointEditClearsIt() async {
        let service = TranslationService(
            audio: ControlledAudio(),
            client: ExperimentalCapabilityClient(),
            defaults: nil,
            tokenStore: MemoryTokenStore()
        )
        service.endpoint = "https://first.example.test/inference"

        await service.testConnection()

        XCTAssertEqual(
            service.qualityWarning,
            "Accuracy is experimental and still needs native-speaker review."
        )
        service.endpoint = "https://second.example.test/inference"
        XCTAssertNil(service.qualityWarning)
    }

    func testSecureTokenReadFailureSurfacesActionableAlert() {
        let tokenStore = FailingLoadTokenStore()
        let service = TranslationService(
            audio: ControlledAudio(),
            client: ControlledClient(),
            defaults: nil,
            tokenStore: tokenStore
        )

        XCTAssertTrue(service.authToken.isEmpty)
        XCTAssertEqual(tokenStore.token, "still-stored-token")
        XCTAssertTrue(tokenStore.attemptedTokens.isEmpty)
        XCTAssertNil(service.alertMessage)
        XCTAssertEqual(
            service.credentialPersistenceError,
            "The saved access token could not be read from this iPhone’s Keychain. Re-enter it in Connection settings."
        )
    }

    func testFailedCredentialUpdateRevertsAndSurvivesConnectionAndRelaunch() async {
        let tokenStore = MemoryTokenStore(token: "stored-private-token")
        tokenStore.rejectsSaves = true
        let client = RecordingConfigurationClient()
        let service = TranslationService(
            audio: ControlledAudio(),
            client: client,
            defaults: nil,
            tokenStore: tokenStore
        )
        service.endpoint = "https://example.test/inference"

        service.authToken = "replacement-private-token"

        XCTAssertEqual(service.authToken, "stored-private-token")
        XCTAssertEqual(tokenStore.token, "stored-private-token")
        XCTAssertEqual(tokenStore.attemptedTokens, ["replacement-private-token"])
        XCTAssertNil(service.alertMessage)
        XCTAssertEqual(
            service.credentialPersistenceError,
            "The access token could not be saved to this iPhone’s Keychain. Your previous token is still active; try again."
        )

        await service.testConnection()

        let recorded = await client.recordedConfigurations()
        XCTAssertEqual(recorded.capabilities.map(\.authToken), ["stored-private-token"])
        XCTAssertFalse(service.serverModel.isEmpty)
        XCTAssertEqual(
            service.credentialPersistenceError,
            "The access token could not be saved to this iPhone’s Keychain. Your previous token is still active; try again."
        )

        let relaunched = TranslationService(
            audio: ControlledAudio(),
            client: ControlledClient(),
            defaults: nil,
            tokenStore: tokenStore
        )
        XCTAssertEqual(relaunched.authToken, "stored-private-token")
        XCTAssertEqual(tokenStore.attemptedTokens, ["replacement-private-token"])
    }

    func testFailedCredentialDeleteRevertsAndSurvivesStartAndRelaunch() async {
        let tokenStore = MemoryTokenStore(token: "stored-private-token")
        tokenStore.rejectsSaves = true
        let client = RecordingConfigurationClient()
        let service = TranslationService(
            audio: ControlledAudio(),
            client: client,
            defaults: nil,
            tokenStore: tokenStore
        )
        service.endpoint = "https://example.test/inference"

        service.authToken = ""

        XCTAssertEqual(service.authToken, "stored-private-token")
        XCTAssertEqual(tokenStore.token, "stored-private-token")
        XCTAssertEqual(tokenStore.attemptedTokens, [""])
        XCTAssertEqual(
            service.credentialPersistenceError,
            "The access token could not be saved to this iPhone’s Keychain. Your previous token is still active; try again."
        )

        await service.start()

        let recorded = await client.recordedConfigurations()
        XCTAssertEqual(recorded.capabilities.map(\.authToken), ["stored-private-token"])
        XCTAssertTrue(service.isRecording)
        XCTAssertFalse(service.serverModel.isEmpty)
        XCTAssertEqual(
            service.credentialPersistenceError,
            "The access token could not be saved to this iPhone’s Keychain. Your previous token is still active; try again."
        )
        await service.stop()

        let relaunched = TranslationService(
            audio: ControlledAudio(),
            client: ControlledClient(),
            defaults: nil,
            tokenStore: tokenStore
        )
        XCTAssertEqual(relaunched.authToken, "stored-private-token")
        XCTAssertEqual(tokenStore.attemptedTokens, [""])
    }

    func testSuccessfulCredentialSaveAndDeleteClearPersistenceError() {
        let tokenStore = MemoryTokenStore(token: "stored-private-token")
        tokenStore.rejectsSaves = true
        let service = TranslationService(
            audio: ControlledAudio(),
            client: ControlledClient(),
            defaults: nil,
            tokenStore: tokenStore
        )

        service.authToken = "replacement-private-token"
        XCTAssertNotNil(service.credentialPersistenceError)

        tokenStore.rejectsSaves = false
        service.authToken = "replacement-private-token"
        XCTAssertEqual(service.authToken, "replacement-private-token")
        XCTAssertEqual(tokenStore.token, "replacement-private-token")
        XCTAssertNil(service.credentialPersistenceError)

        tokenStore.rejectsSaves = true
        service.authToken = ""
        XCTAssertEqual(service.authToken, "replacement-private-token")
        XCTAssertNotNil(service.credentialPersistenceError)

        tokenStore.rejectsSaves = false
        service.authToken = ""
        XCTAssertTrue(service.authToken.isEmpty)
        XCTAssertTrue(tokenStore.token.isEmpty)
        XCTAssertNil(service.credentialPersistenceError)
    }

    func testBearerTokenLoadsFromSecureStoreAndReachesCapabilityAndInferenceRequests() async {
        let audio = ControlledAudio()
        let client = RecordingConfigurationClient()
        let tokenStore = MemoryTokenStore(token: "stored-private-token")
        let service = TranslationService(
            audio: audio,
            client: client,
            defaults: nil,
            tokenStore: tokenStore
        )
        service.endpoint = "https://example.test/inference"

        await service.start()
        audio.emit(samples: [0.1])
        await service.stop()

        let recorded = await client.recordedConfigurations()
        XCTAssertEqual(service.authToken, "stored-private-token")
        XCTAssertEqual(recorded.capabilities.map(\.authToken), ["stored-private-token"])
        XCTAssertEqual(recorded.translations.map(\.authToken), ["stored-private-token"])
    }

    func testChangingBearerTokenStoresTrimmedValueOutsideUserDefaults() {
        let suiteName = "TranslationServiceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://example.test/inference", forKey: "translationEndpoint")
        let defaultsBeforeTokenChange = defaults.persistentDomain(forName: suiteName)
        let tokenStore = MemoryTokenStore()
        let service = TranslationService(
            audio: ControlledAudio(),
            client: ControlledClient(),
            defaults: defaults,
            tokenStore: tokenStore
        )

        service.authToken = "  replacement-private-token  "

        XCTAssertEqual(service.authToken, "replacement-private-token")
        XCTAssertEqual(tokenStore.token, "replacement-private-token")
        XCTAssertEqual(tokenStore.savedTokens, ["replacement-private-token"])
        XCTAssertTrue(
            NSDictionary(dictionary: defaults.persistentDomain(forName: suiteName) ?? [:])
                .isEqual(to: defaultsBeforeTokenChange ?? [:])
        )
    }

    func testRetryUsesCurrentBearerToken() async {
        let audio = ControlledAudio()
        let client = RecordingRetryClient()
        let service = TranslationService(
            audio: audio,
            client: client,
            defaults: nil,
            tokenStore: MemoryTokenStore(token: "first-private-token")
        )
        service.endpoint = "https://example.test/inference"
        await service.start()
        audio.emit(samples: [0.1])
        await service.stop()
        let failed = try! XCTUnwrap(service.translations.first)

        service.authToken = "second-private-token"
        service.retry(failed)
        await service.stop()

        let translationTokens = await client.translationTokens()
        XCTAssertEqual(translationTokens, ["first-private-token", "second-private-token"])
    }

    func testReleasedRetryAudioDoesNotOfferRetry() async {
        let audio = ControlledAudio()
        let service = TranslationService(audio: audio, client: FailingClient(), defaults: nil, tokenStore: MemoryTokenStore())
        service.endpoint = "https://example.test/inference"
        for _ in 0..<9 {
            await service.start()
            audio.emit(samples: [0.1])
            await service.stop()
        }
        XCTAssertEqual(service.translations.count, 9)
        XCTAssertFalse(service.translations[0].canRetry)
        XCTAssertTrue(service.translations[8].canRetry)
    }
}

@MainActor
private final class ControlledAudio: AudioCapturing {
    var startCount = 0
    var callback: (@Sendable (PCMChunk) -> Void)?
    var failureCallback: (@Sendable (String) -> Void)?
    var finalSamples: [Float]?
    var finalFailure: String?
    func start(onChunk: @escaping @Sendable (PCMChunk) -> Void, onMeter: @escaping @Sendable (AudioMeter) -> Void, onFailure: @escaping @Sendable (String) -> Void) async throws {
        startCount += 1
        callback = onChunk
        failureCallback = onFailure
    }
    func stop() async {
        if let finalSamples {
            emit(samples: finalSamples)
            self.finalSamples = nil
        }
        if let finalFailure {
            failureCallback?(finalFailure)
            self.finalFailure = nil
        }
    }
    func emit(samples: [Float]) {
        callback?(PCMChunk(id: UUID(), samples: samples, capturedAt: Date()))
    }
}

private struct ControlledClient: TranslationNetworking {
    var supported = true
    func checkCapabilities(configuration: TranslationConfiguration) async throws -> ServerCapabilities {
        let capabilities = ServerCapabilities(model: "Controlled test fixture", sourceLanguages: supported ? ["shi"] : ["ar"], tasks: ["translate"], targetLanguages: ["en"], audioFormats: ["f32le"], sampleRates: [16000], channels: [1])
        try capabilities.validateForTashelhitTranslation()
        return capabilities
    }
    func translate(_ chunk: PCMChunk, configuration: TranslationConfiguration) async throws -> TranslationResult {
        TranslationResult(text: chunk.samples.first == 0.1 ? "First phrase" : "Second phrase", serverMilliseconds: 12)
    }
}

private struct ExperimentalCapabilityClient: TranslationNetworking {
    func checkCapabilities(configuration: TranslationConfiguration) async throws -> ServerCapabilities {
        ServerCapabilities(
            model: "Experimental test fixture",
            sourceLanguages: ["shi"],
            tasks: ["translate"],
            targetLanguages: ["en"],
            audioFormats: ["f32le"],
            sampleRates: [16_000],
            channels: [1],
            qualityStatus: "experimental",
            qualityWarning: "Accuracy is experimental and still needs native-speaker review."
        )
    }

    func translate(_ chunk: PCMChunk, configuration: TranslationConfiguration) async throws -> TranslationResult {
        TranslationResult(text: "Translated phrase", serverMilliseconds: 1)
    }
}

private final class MemoryTokenStore: TokenStoring {
    private(set) var token: String
    private(set) var savedTokens: [String] = []
    private(set) var attemptedTokens: [String] = []
    var rejectsSaves = false

    init(token: String = "") {
        self.token = token
    }

    func loadToken() throws -> String {
        token
    }

    func saveToken(_ token: String) throws {
        attemptedTokens.append(token)
        if rejectsSaves { throw TestTokenStoreError.unavailable }
        self.token = token
        savedTokens.append(token)
    }
}

private final class FailingLoadTokenStore: TokenStoring {
    private(set) var token = "still-stored-token"
    private(set) var attemptedTokens: [String] = []

    func loadToken() throws -> String {
        throw TestTokenStoreError.unavailable
    }

    func saveToken(_ token: String) throws {
        attemptedTokens.append(token)
        self.token = token
    }
}

private enum TestTokenStoreError: Error {
    case unavailable
}

private actor RecordingConfigurationClient: TranslationNetworking {
    private var capabilities: [TranslationConfiguration] = []
    private var translations: [TranslationConfiguration] = []

    func checkCapabilities(configuration: TranslationConfiguration) async throws -> ServerCapabilities {
        capabilities.append(configuration)
        return ServerCapabilities(model: "Test fixture", sourceLanguages: ["shi"], tasks: ["translate"], targetLanguages: ["en"], audioFormats: ["f32le"], sampleRates: [16000], channels: [1])
    }

    func translate(_ chunk: PCMChunk, configuration: TranslationConfiguration) async throws -> TranslationResult {
        translations.append(configuration)
        return TranslationResult(text: "Translated phrase", serverMilliseconds: 1)
    }

    func recordedConfigurations() -> (capabilities: [TranslationConfiguration], translations: [TranslationConfiguration]) {
        (capabilities, translations)
    }
}

private actor RecordingRetryClient: TranslationNetworking {
    private var tokens: [String] = []

    func checkCapabilities(configuration: TranslationConfiguration) async throws -> ServerCapabilities {
        ServerCapabilities(model: "Test fixture", sourceLanguages: ["shi"], tasks: ["translate"], targetLanguages: ["en"], audioFormats: ["f32le"], sampleRates: [16000], channels: [1])
    }

    func translate(_ chunk: PCMChunk, configuration: TranslationConfiguration) async throws -> TranslationResult {
        tokens.append(configuration.authToken)
        if tokens.count == 1 {
            throw TranslationError.server(status: 503, message: "Temporary test failure")
        }
        return TranslationResult(text: "Recovered phrase", serverMilliseconds: 1)
    }

    func translationTokens() -> [String] {
        tokens
    }
}

private actor DelayedCapabilityClient: TranslationNetworking {
    private var checking: CheckedContinuation<ServerCapabilities, Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    func checkCapabilities(configuration: TranslationConfiguration) async throws -> ServerCapabilities {
        try await withCheckedThrowingContinuation { continuation in
            checking = continuation
            waiter?.resume()
            waiter = nil
        }
    }
    func waitUntilChecking() async {
        if checking != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finishCheck() {
        checking?.resume(returning: ServerCapabilities(model: "Test fixture", sourceLanguages: ["shi"], tasks: ["translate"], targetLanguages: ["en"], audioFormats: ["f32le"], sampleRates: [16000], channels: [1]))
        checking = nil
    }
    func translate(_ chunk: PCMChunk, configuration: TranslationConfiguration) async throws -> TranslationResult {
        XCTFail("Stopped capability check must never dispatch audio")
        throw CancellationError()
    }
}

private actor RetryClient: TranslationNetworking {
    private var attempts = 0
    func checkCapabilities(configuration: TranslationConfiguration) async throws -> ServerCapabilities {
        ServerCapabilities(model: "Test fixture", sourceLanguages: ["shi"], tasks: ["translate"], targetLanguages: ["en"], audioFormats: ["f32le"], sampleRates: [16000], channels: [1])
    }
    func translate(_ chunk: PCMChunk, configuration: TranslationConfiguration) async throws -> TranslationResult {
        attempts += 1
        if attempts == 1 { throw TranslationError.server(status: 503, message: "Temporary test failure") }
        return TranslationResult(text: "Recovered phrase", serverMilliseconds: 1)
    }
}

private struct FailingClient: TranslationNetworking {
    func checkCapabilities(configuration: TranslationConfiguration) async throws -> ServerCapabilities {
        ServerCapabilities(model: "Test fixture", sourceLanguages: ["shi"], tasks: ["translate"], targetLanguages: ["en"], audioFormats: ["f32le"], sampleRates: [16000], channels: [1])
    }
    func translate(_ chunk: PCMChunk, configuration: TranslationConfiguration) async throws -> TranslationResult {
        throw TranslationError.server(status: 503, message: "Test failure")
    }
}
