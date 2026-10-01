import XCTest
@testable import TashlahetBridge

@MainActor
final class TranslationServiceTests: XCTestCase {
    func testUnsupportedServerNeverOpensMicrophone() async {
        let audio = ControlledAudio()
        let client = ControlledClient(supported: false)
        let service = TranslationService(audio: audio, client: client, defaults: nil)
        service.endpoint = "https://example.test/inference"
        await service.start()
        XCTAssertEqual(service.state, .failed)
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertNotNil(service.alertMessage)
    }

    func testStopTranslatesFinalSpeechTailAndRetainsOrder() async {
        let audio = ControlledAudio()
        let service = TranslationService(audio: audio, client: ControlledClient(), defaults: nil)
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
        let service = TranslationService(audio: audio, client: ControlledClient(), defaults: nil)
        service.endpoint = "https://example.test/inference"
        await service.start()
        await service.stop()
        audio.emit(samples: [0.1])
        XCTAssertTrue(service.translations.isEmpty)
    }

    func testEmptyConfigurationDoesNotOpenMicrophone() async {
        let audio = ControlledAudio()
        let service = TranslationService(audio: audio, client: ControlledClient(), defaults: nil)
        await service.start()
        XCTAssertFalse(service.canStart)
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertNotNil(service.alertMessage)
    }

    func testStopDuringCapabilityCheckCannotStartMicrophoneLater() async {
        let audio = ControlledAudio()
        let client = DelayedCapabilityClient()
        let service = TranslationService(audio: audio, client: client, defaults: nil)
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
        let service = TranslationService(audio: audio, client: client, defaults: nil)
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
        let service = TranslationService(audio: audio, client: ControlledClient(), defaults: nil)
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
        let service = TranslationService(audio: ControlledAudio(), client: ControlledClient(), defaults: nil)
        service.endpoint = "https://first.example.test/inference"
        await service.testConnection()
        XCTAssertFalse(service.serverModel.isEmpty)
        service.endpoint = "https://second.example.test/inference"
        XCTAssertTrue(service.serverModel.isEmpty)
    }

    func testReleasedRetryAudioDoesNotOfferRetry() async {
        let audio = ControlledAudio()
        let service = TranslationService(audio: audio, client: FailingClient(), defaults: nil)
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
