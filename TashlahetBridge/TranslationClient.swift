import Foundation

/// The URL belongs to the inference server, not to the iPhone.
/// A device can reach a Mac on the same Wi-Fi at e.g. http://192.168.1.20:8080/inference.
struct TranslationConfiguration: Sendable, Equatable {
    var endpoint: String
    var authToken: String

    init(endpoint: String = "", authToken: String = "") {
        self.endpoint = endpoint
        self.authToken = authToken
    }

    static func normalizedAuthToken(_ input: String) throws -> String? {
        guard !input.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else {
            throw TranslationError.configuration("The access token cannot contain line breaks.")
        }
        let token = input.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return nil }
        guard !token.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }) else {
            throw TranslationError.configuration(
                "The access token cannot contain spaces, tabs, line breaks, or control characters."
            )
        }
        return token
    }

    func validatedAuthToken() throws -> String? {
        try Self.normalizedAuthToken(authToken)
    }

    func validatedEndpoint() throws -> URL {
        let input = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw TranslationError.configuration("Enter the translation server URL in Settings.")
        }
        guard let components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else {
            throw TranslationError.configuration(
                "Use an HTTP or HTTPS server URL without a username, password, query, or fragment."
            )
        }
        if try validatedAuthToken() != nil, scheme != "https" {
            throw TranslationError.configuration(
                "Access tokens require an HTTPS translation server address."
            )
        }
        guard url.lastPathComponent == "inference",
              !components.path.hasSuffix("/") else {
            throw TranslationError.configuration("The server URL must end with /inference.")
        }
        if components.rangeOfPort != nil {
            guard let port = components.port, (1...65535).contains(port) else {
                throw TranslationError.configuration("The server port must be between 1 and 65535.")
            }
        }
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let loopback = normalizedHost == "localhost"
            || normalizedHost.hasSuffix(".localhost")
            || normalizedHost == "::1"
            || normalizedHost.hasPrefix("127.")
            || normalizedHost == "0.0.0.0"
            || normalizedHost == "::"
            || normalizedHost == "::ffff:127.0.0.1"
        #if !targetEnvironment(simulator)
        if loopback {
            throw TranslationError.configuration(
                "On an iPhone, localhost points to the iPhone. Enter your Mac's LAN address or an HTTPS server address instead."
            )
        }
        #endif
        return url
    }
}

struct TranslationResult: Sendable {
    let text: String
    let serverMilliseconds: Double?
}

struct ServerCapabilities: Codable, Sendable {
    let model: String
    let sourceLanguages: [String]
    let tasks: [String]
    let targetLanguages: [String]
    let audioFormats: [String]
    let sampleRates: [Int]
    let channels: [Int]
    let qualityStatus: String?
    let qualityWarning: String?

    init(
        model: String,
        sourceLanguages: [String],
        tasks: [String],
        targetLanguages: [String],
        audioFormats: [String],
        sampleRates: [Int],
        channels: [Int],
        qualityStatus: String? = nil,
        qualityWarning: String? = nil
    ) {
        self.model = model
        self.sourceLanguages = sourceLanguages
        self.tasks = tasks
        self.targetLanguages = targetLanguages
        self.audioFormats = audioFormats
        self.sampleRates = sampleRates
        self.channels = channels
        self.qualityStatus = qualityStatus
        self.qualityWarning = qualityWarning
    }

    enum CodingKeys: String, CodingKey {
        case model, tasks, channels
        case sourceLanguages = "source_languages"
        case targetLanguages = "target_languages"
        case audioFormats = "audio_formats"
        case sampleRates = "sample_rates"
        case qualityStatus = "quality_status"
        case qualityWarning = "quality_warning"
    }

    var experimentalQualityWarning: String {
        if qualityStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == "experimental",
           let warning = qualityWarning?.trimmingCharacters(in: .whitespacesAndNewlines),
           !warning.isEmpty {
            return String(warning.prefix(240))
        }
        return "Experimental accuracy: translations have not yet been verified by native Tashelhit speakers."
    }

    func validateForTashelhitTranslation() throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.unsupportedServer("The server did not identify its model.")
        }
        guard sourceLanguages.contains("shi") else {
            throw TranslationError.unsupportedServer(
                "This model does not advertise Tashelhit (shi) support. Standard Whisper does not support shi; use a model trained for Tashelhit-to-English translation."
            )
        }
        guard tasks.contains("translate"), targetLanguages.contains("en") else {
            throw TranslationError.unsupportedServer(
                "The server must support direct translation from Tashelhit into English."
            )
        }
        guard audioFormats.contains("f32le"), sampleRates.contains(16_000), channels.contains(1) else {
            throw TranslationError.unsupportedServer(
                "The server must accept raw little-endian Float32 PCM at 16 kHz with one channel."
            )
        }
    }
}

enum TranslationError: LocalizedError {
    case configuration(String)
    case unsupportedServer(String)
    case invalidAudio
    case invalidResponse(String)
    case server(status: Int, message: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .unsupportedServer(let message),
             .invalidResponse(let message), .transport(let message):
            return message
        case .invalidAudio:
            return "The recorded audio chunk is empty or contains invalid sample values."
        case .server(let status, let message):
            return "Translation server error (HTTP \(status)): \(message)"
        }
    }
}

/// Requests contain raw PCM, not a WAV file or multipart form.
/// Stock whisper.cpp's /inference endpoint requires a different request format and
/// does not support shi. See the repository's server contract for a compatible backend.
final class TranslationClient: @unchecked Sendable {
    private static let maximumResponseBytes = 1_048_576
    private static let oversizedResponseMessage =
        "The translation server returned an unexpectedly large response."

    private let session: URLSession

    init(session: URLSession = TranslationClient.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func checkCapabilities(configuration: TranslationConfiguration) async throws -> ServerCapabilities {
        let endpoint = try configuration.validatedEndpoint()
        let url = endpoint.deletingLastPathComponent().appendingPathComponent("capabilities")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try Self.addAuthorization(to: &request, configuration: configuration)
        let data = try await send(request)
        let capabilities: ServerCapabilities
        do {
            capabilities = try JSONDecoder().decode(ServerCapabilities.self, from: data)
        } catch {
            throw TranslationError.unsupportedServer(
                "The server's /capabilities response is not compatible. Configure a Tashelhit translation backend that implements the documented API."
            )
        }
        try capabilities.validateForTashelhitTranslation()
        return capabilities
    }

    func translate(_ chunk: PCMChunk, configuration: TranslationConfiguration) async throws -> TranslationResult {
        try Task.checkCancellation()
        let url = try configuration.validatedEndpoint()
        guard !chunk.samples.isEmpty, chunk.samples.allSatisfy({ $0.isFinite }) else {
            throw TranslationError.invalidAudio
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("shi", forHTTPHeaderField: "X-Language")
        request.setValue("shi", forHTTPHeaderField: "X-Source-Language")
        request.setValue("en", forHTTPHeaderField: "X-Target-Language")
        request.setValue("translate", forHTTPHeaderField: "X-Task")
        request.setValue("16000", forHTTPHeaderField: "X-Sample-Rate")
        request.setValue("1", forHTTPHeaderField: "X-Channels")
        request.setValue("f32le", forHTTPHeaderField: "X-Audio-Format")
        request.setValue(chunk.id.uuidString, forHTTPHeaderField: "X-Chunk-ID")
        try Self.addAuthorization(to: &request, configuration: configuration)
        request.httpBody = Self.pcmData(chunk.samples)
        let data = try await send(request)
        let response: TranslationResponse
        do {
            response = try JSONDecoder().decode(TranslationResponse.self, from: data)
        } catch {
            throw TranslationError.invalidResponse(
                "The server returned invalid translation JSON. It must include text, source_language, target_language, and chunk_id."
            )
        }
        guard response.sourceLanguage == "shi", response.targetLanguage == "en" else {
            throw TranslationError.invalidResponse(
                "The server returned a different language pair. Expected Tashelhit (shi) to English (en)."
            )
        }
        guard UUID(uuidString: response.chunkID) == chunk.id else {
            throw TranslationError.invalidResponse("The server returned a translation for a different audio chunk.")
        }
        if let task = response.task, task != "translate" {
            throw TranslationError.invalidResponse("The server returned transcription instead of translation.")
        }
        if let milliseconds = response.inferenceMilliseconds, !milliseconds.isFinite || milliseconds < 0 {
            throw TranslationError.invalidResponse("The server returned an invalid inference duration.")
        }
        // Empty text is valid: a server may classify a chunk as silence.
        return TranslationResult(
            text: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
            serverMilliseconds: response.inferenceMilliseconds
        )
    }

    private static func addAuthorization(
        to request: inout URLRequest,
        configuration: TranslationConfiguration
    ) throws {
        guard let token = try configuration.validatedAuthToken() else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private static func pcmData(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * MemoryLayout<UInt32>.size)
        data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for (index, sample) in samples.enumerated() {
                bytes.storeBytes(
                    of: sample.bitPattern.littleEndian,
                    toByteOffset: index * MemoryLayout<UInt32>.size,
                    as: UInt32.self
                )
            }
        }
        return data
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(
                for: request,
                delegate: NoRedirectDelegate()
            )
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw TranslationError.invalidResponse("The translation server returned a non-HTTP response.")
            }
            guard http.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
                bytes.task.cancel()
                throw TranslationError.invalidResponse(Self.oversizedResponseMessage)
            }
            let data = try await Self.collectBoundedResponse(bytes)
            try Task.checkCancellation()
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 404, request.url?.lastPathComponent == "capabilities" {
                    throw TranslationError.unsupportedServer(
                        "The server is missing /capabilities. Stock whisper.cpp is not compatible with this app's Tashelhit API; see the server setup guide."
                    )
                }
                let message = Self.serverMessage(data: data, status: http.statusCode)
                throw TranslationError.server(status: http.statusCode, message: message)
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw TranslationError.transport(Self.transportMessage(error))
        }
    }

    private static func collectBoundedResponse(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            var data = Data()
            let expectedLength = bytes.task.countOfBytesExpectedToReceive
            if expectedLength > 0, expectedLength <= Int64(maximumResponseBytes) {
                data.reserveCapacity(Int(expectedLength))
            }

            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    bytes.task.cancel()
                    throw TranslationError.invalidResponse(oversizedResponseMessage)
                }
                data.append(byte)
                if data.count.isMultiple(of: 16_384) {
                    try Task.checkCancellation()
                }
            }
            try Task.checkCancellation()
            return data
        } onCancel: {
            bytes.task.cancel()
        }
    }

    private static func serverMessage(data: Data, status: Int) -> String {
        if let payload = try? JSONDecoder().decode(ServerErrorPayload.self, from: data) {
            if let message = payload.message ?? payload.error, !message.isEmpty {
                return String(message.prefix(400))
            }
        }
        switch status {
        case 300...399:
            return "Redirects are disabled to keep microphone audio on the server you selected. Enter its final /inference URL."
        case 401, 403:
            return "The server refused access. Check its access settings."
        case 413:
            return "The server rejected the audio chunk as too large."
        case 429:
            return "The server is busy. Retry the failed segment when it is ready."
        case 500...599:
            return "The inference backend failed. Check the server and model logs."
        default:
            return HTTPURLResponse.localizedString(forStatusCode: status)
        }
    }

    private static func transportMessage(_ error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "The translation server timed out. Check that the model is running, then retry the failed segment."
        case .notConnectedToInternet, .networkConnectionLost:
            return "The server is unreachable. Check Wi-Fi and enable Local Network for this app in iPhone Settings."
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "Cannot reach the translation server. Check its address, port, firewall, and that it is listening on your LAN."
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS blocked this connection. Use HTTPS, or a local-network HTTP address allowed by this app's network settings."
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return "The server's HTTPS certificate could not be verified. Use a server with a trusted, valid certificate."
        case .dataNotAllowed:
            return "Network access is disabled. Check Local Network and cellular permissions in iPhone Settings."
        default:
            return "Translation network error: \(error.localizedDescription)"
        }
    }

    private struct TranslationResponse: Decodable {
        let text: String
        let sourceLanguage: String
        let targetLanguage: String
        let chunkID: String
        let task: String?
        let inferenceMilliseconds: Double?

        enum CodingKeys: String, CodingKey {
            case text, task
            case sourceLanguage = "source_language"
            case targetLanguage = "target_language"
            case chunkID = "chunk_id"
            case inferenceMilliseconds = "inference_ms"
        }
    }

    private struct ServerErrorPayload: Decodable {
        let message: String?
        let error: String?
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
