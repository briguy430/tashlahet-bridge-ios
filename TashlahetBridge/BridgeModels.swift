import Foundation

struct PCMChunk: Sendable {
    let id: UUID
    let samples: [Float]
    let capturedAt: Date
}

struct AudioMeter: Sendable {
    let level: Float
    let isSpeech: Bool
}

struct TranslationEntry: Identifiable {
    let id: UUID
    let createdAt: Date
    var text = ""
    var isPending = true
    var errorMessage: String?
    var latencyMilliseconds: Double?
    var canRetry = false
}

enum TranslationState: Equatable {
    case idle, connecting, listening, stopping, failed
}

protocol TranslationNetworking: Sendable {
    func checkCapabilities(configuration: TranslationConfiguration) async throws -> ServerCapabilities
    func translate(_ chunk: PCMChunk, configuration: TranslationConfiguration) async throws -> TranslationResult
}

extension TranslationClient: TranslationNetworking {}

@MainActor
protocol AudioCapturing: AnyObject {
    /// Invoke all callbacks on the main queue. stop() delivers final chunks
    /// before returning; clients reject callbacks from older recordings.
    func start(
        onChunk: @escaping @Sendable (PCMChunk) -> Void,
        onMeter: @escaping @Sendable (AudioMeter) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws
    func stop() async
}

extension AudioCaptureEngine: AudioCapturing {}
