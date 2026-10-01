import Foundation
import XCTest
@testable import TashlahetBridge

final class TranslationClientTests: XCTestCase {
    private var session: URLSession!
    private var client: TranslationClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = TranslationClient(session: session)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        client = nil
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testCapabilitiesRejectServerWithoutTashelhitSupport() async throws {
        StubURLProtocol.enqueueJSON(
            #"""
            {
              "model": "generic-speech-model",
              "source_languages": ["en", "fr"],
              "tasks": ["translate"],
              "target_languages": ["en"],
              "audio_formats": ["f32le"],
              "sample_rates": [16000],
              "channels": [1]
            }
            """#
        )

        do {
            _ = try await client.checkCapabilities(configuration: serverConfiguration)
            XCTFail("Expected a server without shi support to be rejected")
        } catch let error as TranslationError {
            guard case .unsupportedServer(let message) = error else {
                return XCTFail("Expected unsupportedServer, got \(error.localizedDescription)")
            }
            XCTAssertTrue(message.contains("Tashelhit (shi)"))
        }
    }

    func testCapabilitiesRejectIncompatiblePCMFormat() async throws {
        StubURLProtocol.enqueueJSON(
            #"""
            {
              "model": "tashelhit-translator",
              "source_languages": ["shi"],
              "tasks": ["translate"],
              "target_languages": ["en"],
              "audio_formats": ["s16le"],
              "sample_rates": [16000],
              "channels": [1]
            }
            """#
        )

        do {
            _ = try await client.checkCapabilities(configuration: serverConfiguration)
            XCTFail("Expected a server with the wrong PCM format to be rejected")
        } catch let error as TranslationError {
            guard case .unsupportedServer(let message) = error else {
                return XCTFail("Expected unsupportedServer, got \(error.localizedDescription)")
            }
            XCTAssertTrue(message.contains("Float32 PCM"))
        }
    }

    func testCapabilitiesAddsTrimmedBearerToken() async throws {
        StubURLProtocol.enqueueJSON(compatibleCapabilitiesJSON)

        _ = try await client.checkCapabilities(
            configuration: TranslationConfiguration(
                endpoint: "https://translation.example/inference",
                authToken: "  private-access-token  "
            )
        )

        let recorded = try XCTUnwrap(StubURLProtocol.recordedRequests().only)
        XCTAssertEqual(recorded.url?.absoluteString, "https://translation.example/capabilities")
        XCTAssertEqual(recorded.header("Authorization"), "Bearer private-access-token")
    }

    func testCapabilitiesRemainCompatibleWhenQualityFieldsAreMissing() async throws {
        StubURLProtocol.enqueueJSON(compatibleCapabilitiesJSON)

        let capabilities = try await client.checkCapabilities(configuration: serverConfiguration)

        XCTAssertNil(capabilities.qualityStatus)
        XCTAssertNil(capabilities.qualityWarning)
        XCTAssertEqual(
            capabilities.experimentalQualityWarning,
            "Experimental accuracy: translations have not yet been verified by native Tashelhit speakers."
        )
    }

    func testCapabilitiesDecodeExperimentalQualityWarning() async throws {
        StubURLProtocol.enqueueJSON(
            #"{"model":"tashelhit-translator","source_languages":["shi"],"tasks":["translate"],"target_languages":["en"],"audio_formats":["f32le"],"sample_rates":[16000],"channels":[1],"quality_status":"experimental","quality_warning":"Accuracy is experimental and still needs native-speaker review."}"#
        )

        let capabilities = try await client.checkCapabilities(configuration: serverConfiguration)

        XCTAssertEqual(capabilities.qualityStatus, "experimental")
        XCTAssertEqual(
            capabilities.experimentalQualityWarning,
            "Accuracy is experimental and still needs native-speaker review."
        )
    }

    func testExperimentalQualityStatusProvidesCandidFallbackWarning() {
        let capabilities = ServerCapabilities(
            model: "tashelhit-translator",
            sourceLanguages: ["shi"],
            tasks: ["translate"],
            targetLanguages: ["en"],
            audioFormats: ["f32le"],
            sampleRates: [16_000],
            channels: [1],
            qualityStatus: "experimental"
        )

        XCTAssertEqual(
            capabilities.experimentalQualityWarning,
            "Experimental accuracy: translations have not yet been verified by native Tashelhit speakers."
        )
    }

    func testUnknownQualityStatusCannotSuppressClientWarning() {
        let capabilities = ServerCapabilities(
            model: "tashelhit-translator",
            sourceLanguages: ["shi"],
            tasks: ["translate"],
            targetLanguages: ["en"],
            audioFormats: ["f32le"],
            sampleRates: [16_000],
            channels: [1],
            qualityStatus: "preview",
            qualityWarning: "The server says this is ready."
        )

        XCTAssertEqual(
            capabilities.experimentalQualityWarning,
            "Experimental accuracy: translations have not yet been verified by native Tashelhit speakers."
        )
    }

    func testServerClaimedVerifiedStatusCannotSuppressClientWarning() {
        let capabilities = ServerCapabilities(
            model: "tashelhit-translator",
            sourceLanguages: ["shi"],
            tasks: ["translate"],
            targetLanguages: ["en"],
            audioFormats: ["f32le"],
            sampleRates: [16_000],
            channels: [1],
            qualityStatus: "verified",
            qualityWarning: "Native-speaker verified."
        )

        XCTAssertEqual(
            capabilities.experimentalQualityWarning,
            "Experimental accuracy: translations have not yet been verified by native Tashelhit speakers."
        )
    }

    func testMissingCapabilitiesEndpointExplainsThatStockWhisperIsUnsupported() async throws {
        StubURLProtocol.enqueueJSON(#"{"error":"not found"}"#, statusCode: 404)

        do {
            _ = try await client.checkCapabilities(configuration: serverConfiguration)
            XCTFail("Expected a missing capabilities endpoint to be rejected")
        } catch let error as TranslationError {
            guard case .unsupportedServer(let message) = error else {
                return XCTFail("Expected unsupportedServer, got \(error.localizedDescription)")
            }
            XCTAssertTrue(message.contains("missing /capabilities"))
            XCTAssertTrue(message.contains("Stock whisper.cpp is not compatible"))
        }
    }

    func testTranslatePostsRawLittleEndianFloat32WithContractHeaders() async throws {
        let chunkID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        StubURLProtocol.enqueueJSON(
            #"""
            {
              "text": "  Good morning  ",
              "source_language": "shi",
              "target_language": "en",
              "chunk_id": "01234567-89AB-CDEF-0123-456789ABCDEF",
              "task": "translate",
              "inference_ms": 12.5
            }
            """#
        )
        let chunk = PCMChunk(
            id: chunkID,
            samples: [1.0, -2.5, 0.0, 0.15625],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let result = try await client.translate(chunk, configuration: serverConfiguration)

        XCTAssertEqual(result.text, "Good morning")
        XCTAssertEqual(result.serverMilliseconds, 12.5)

        let requests = StubURLProtocol.recordedRequests()
        let recorded = try XCTUnwrap(requests.only)
        XCTAssertEqual(recorded.url?.absoluteString, "https://translation.example/inference")
        XCTAssertEqual(recorded.httpMethod, "POST")
        XCTAssertEqual(recorded.header("Content-Type"), "application/octet-stream")
        XCTAssertEqual(recorded.header("Accept"), "application/json")
        XCTAssertEqual(recorded.header("X-Language"), "shi")
        XCTAssertEqual(recorded.header("X-Source-Language"), "shi")
        XCTAssertEqual(recorded.header("X-Target-Language"), "en")
        XCTAssertEqual(recorded.header("X-Task"), "translate")
        XCTAssertEqual(recorded.header("X-Sample-Rate"), "16000")
        XCTAssertEqual(recorded.header("X-Channels"), "1")
        XCTAssertEqual(recorded.header("X-Audio-Format"), "f32le")
        XCTAssertEqual(recorded.header("X-Chunk-ID"), chunkID.uuidString)
        XCTAssertNil(recorded.header("Authorization"))
        XCTAssertEqual(
            recorded.body,
            Data([
                0x00, 0x00, 0x80, 0x3F,
                0x00, 0x00, 0x20, 0xC0,
                0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x20, 0x3E,
            ])
        )
    }

    func testTranslateAddsBearerToken() async throws {
        StubURLProtocol.enqueueJSON(
            #"{"text":"Hello","source_language":"shi","target_language":"en","chunk_id":"01234567-89AB-CDEF-0123-456789ABCDEF","task":"translate"}"#
        )

        _ = try await client.translate(
            chunk,
            configuration: TranslationConfiguration(
                endpoint: "https://translation.example/inference",
                authToken: "private-access-token"
            )
        )

        let recorded = try XCTUnwrap(StubURLProtocol.recordedRequests().only)
        XCTAssertEqual(recorded.header("Authorization"), "Bearer private-access-token")
    }

    func testTranslateRejectsResponseForDifferentChunk() async throws {
        StubURLProtocol.enqueueJSON(
            #"""
            {
              "text": "Wrong segment",
              "source_language": "shi",
              "target_language": "en",
              "chunk_id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
              "task": "translate"
            }
            """#
        )

        do {
            _ = try await client.translate(chunk, configuration: serverConfiguration)
            XCTFail("Expected a mismatched chunk ID to be rejected")
        } catch let error as TranslationError {
            guard case .invalidResponse(let message) = error else {
                return XCTFail("Expected invalidResponse, got \(error.localizedDescription)")
            }
            XCTAssertTrue(message.contains("different audio chunk"))
        }
    }

    func testTranslateRejectsWrongSourceOrTargetLanguage() async throws {
        StubURLProtocol.enqueueJSON(
            #"""
            {
              "text": "Wrong source",
              "source_language": "ar",
              "target_language": "en",
              "chunk_id": "01234567-89AB-CDEF-0123-456789ABCDEF",
              "task": "translate"
            }
            """#
        )
        StubURLProtocol.enqueueJSON(
            #"""
            {
              "text": "Wrong target",
              "source_language": "shi",
              "target_language": "fr",
              "chunk_id": "01234567-89AB-CDEF-0123-456789ABCDEF",
              "task": "translate"
            }
            """#
        )

        for expectedMismatch in ["source", "target"] {
            do {
                _ = try await client.translate(chunk, configuration: serverConfiguration)
                XCTFail("Expected the wrong \(expectedMismatch) language to be rejected")
            } catch let error as TranslationError {
                guard case .invalidResponse(let message) = error else {
                    return XCTFail("Expected invalidResponse, got \(error.localizedDescription)")
                }
                XCTAssertTrue(message.contains("different language pair"))
            }
        }
    }

    func testTranslateRejectsMalformedJSON() async throws {
        StubURLProtocol.enqueueJSON(#"{"text":42,"chunk_id":null}"#)

        do {
            _ = try await client.translate(chunk, configuration: serverConfiguration)
            XCTFail("Expected malformed translation JSON to be rejected")
        } catch let error as TranslationError {
            guard case .invalidResponse(let message) = error else {
                return XCTFail("Expected invalidResponse, got \(error.localizedDescription)")
            }
            XCTAssertTrue(message.contains("invalid translation JSON"))
        }
    }

    func testTranslatePreservesServerStatusAndMessage() async throws {
        StubURLProtocol.enqueueJSON(#"{"message":"model is not loaded"}"#, statusCode: 503)

        do {
            _ = try await client.translate(chunk, configuration: serverConfiguration)
            XCTFail("Expected an HTTP server error")
        } catch let error as TranslationError {
            guard case .server(let status, let message) = error else {
                return XCTFail("Expected server error, got \(error.localizedDescription)")
            }
            XCTAssertEqual(status, 503)
            XCTAssertEqual(message, "model is not loaded")
            XCTAssertEqual(
                error.localizedDescription,
                "Translation server error (HTTP 503): model is not loaded"
            )
        }
    }

    func testTranslateRejectsOversizedSuccessfulResponse() async throws {
        StubURLProtocol.enqueueResponse(
            statusCode: 200,
            body: Data(repeating: 0x20, count: 1_048_577)
        )

        do {
            _ = try await client.translate(chunk, configuration: serverConfiguration)
            XCTFail("Expected an oversized successful response to be rejected")
        } catch let error as TranslationError {
            guard case .invalidResponse(let message) = error else {
                return XCTFail("Expected invalidResponse, got \(error.localizedDescription)")
            }
            XCTAssertTrue(message.contains("unexpectedly large response"))
        }
    }

    func testTranslateRejectsOversizedServerErrorResponseBeforeParsingIt() async throws {
        StubURLProtocol.enqueueResponse(
            statusCode: 503,
            body: Data(repeating: 0x41, count: 1_048_577)
        )

        do {
            _ = try await client.translate(chunk, configuration: serverConfiguration)
            XCTFail("Expected an oversized error response to be rejected")
        } catch let error as TranslationError {
            guard case .invalidResponse(let message) = error else {
                return XCTFail("Expected invalidResponse, got \(error.localizedDescription)")
            }
            XCTAssertTrue(message.contains("unexpectedly large response"))
        }
    }

    func testTranslateRejectsAdvertisedOversizedResponseWithSmallBody() async throws {
        StubURLProtocol.enqueueResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "application/json",
                "Content-Length": "1048577",
            ],
            body: Data(
                #"{"text":"hello","source_language":"shi","target_language":"en","chunk_id":"01234567-89AB-CDEF-0123-456789ABCDEF"}"#.utf8
            )
        )

        do {
            _ = try await client.translate(chunk, configuration: serverConfiguration)
            XCTFail("Expected an advertised oversized response to be rejected")
        } catch let error as TranslationError {
            guard case .invalidResponse(let message) = error else {
                return XCTFail("Expected invalidResponse, got \(error.localizedDescription)")
            }
            XCTAssertTrue(message.contains("unexpectedly large response"))
        }
    }

    func testTranslateRejectsEmptyOrNonFiniteAudioBeforeNetworkRequest() async throws {
        for samples in [[], [Float.nan], [Float.infinity], [-Float.infinity]] {
            let invalidChunk = PCMChunk(
                id: UUID(),
                samples: samples,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            do {
                _ = try await client.translate(invalidChunk, configuration: serverConfiguration)
                XCTFail("Expected invalid audio to be rejected")
            } catch let error as TranslationError {
                guard case .invalidAudio = error else {
                    return XCTFail("Expected invalidAudio, got \(error.localizedDescription)")
                }
            }
        }

        XCTAssertTrue(StubURLProtocol.recordedRequests().isEmpty)
    }

    func testValidatedEndpointTrimsWhitespaceAroundValidURL() throws {
        let url = try TranslationConfiguration(
            endpoint: "  https://translation.example:8443/api/inference\n"
        ).validatedEndpoint()

        XCTAssertEqual(url.absoluteString, "https://translation.example:8443/api/inference")
    }

    func testValidatedEndpointRejectsMalformedOrUnsafeURLs() {
        let invalidEndpoints = [
            "",
            "ftp://translation.example/inference",
            "https://user:secret@translation.example/inference",
            "https://translation.example/inference?mode=fast",
            "https://translation.example/inference#result",
            "https://translation.example/api",
            "https://translation.example:0/inference",
            "https://translation.example:65536/inference",
            "https://translation.example:999999999999999999999/inference",
        ]

        for endpoint in invalidEndpoints {
            XCTAssertThrowsError(try TranslationConfiguration(endpoint: endpoint).validatedEndpoint()) { error in
                guard case TranslationError.configuration = error else {
                    return XCTFail("Expected configuration error for \(endpoint), got \(error.localizedDescription)")
                }
            }
        }
    }

    func testBearerTokenRequiresHTTPS() {
        XCTAssertThrowsError(
            try TranslationConfiguration(
                endpoint: "http://translation.example/inference",
                authToken: "private-access-token"
            ).validatedEndpoint()
        ) { error in
            guard case TranslationError.configuration(let message) = error else {
                return XCTFail("Expected configuration error, got \(error.localizedDescription)")
            }
            XCTAssertTrue(message.contains("HTTPS"))
        }
    }

    func testBearerTokenRejectsEmbeddedWhitespaceAndHeaderLineBreaks() {
        for token in ["private access token", "private-token\r\nX-Injected: true"] {
            XCTAssertThrowsError(
                try TranslationConfiguration(
                    endpoint: "https://translation.example/inference",
                    authToken: token
                ).validatedEndpoint()
            ) { error in
                guard case TranslationError.configuration = error else {
                    return XCTFail("Expected configuration error, got \(error.localizedDescription)")
                }
            }
        }
    }

    private var serverConfiguration: TranslationConfiguration {
        TranslationConfiguration(endpoint: "https://translation.example/inference")
    }

    private var compatibleCapabilitiesJSON: String {
        #"{"model":"tashelhit-translator","source_languages":["shi"],"tasks":["translate"],"target_languages":["en"],"audio_formats":["f32le"],"sample_rates":[16000],"channels":[1]}"#
    }

    private var chunk: PCMChunk {
        PCMChunk(
            id: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
            samples: [0.25, -0.5],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private struct RecordedRequest: @unchecked Sendable {
    let request: URLRequest
    let body: Data?

    var url: URL? { request.url }
    var httpMethod: String? { request.httpMethod }

    func header(_ field: String) -> String? {
        request.value(forHTTPHeaderField: field)
    }
}

private struct StubbedResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

private final class StubExchange: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [StubbedResponse] = []
    private var requests: [RecordedRequest] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        responses.removeAll()
        requests.removeAll()
    }

    func enqueue(_ response: StubbedResponse) {
        lock.lock()
        defer { lock.unlock() }
        responses.append(response)
    }

    func takeResponse(for request: URLRequest) throws -> StubbedResponse {
        let recorded = RecordedRequest(request: request, body: Self.readBody(from: request))

        lock.lock()
        defer { lock.unlock() }
        requests.append(recorded)
        guard !responses.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let exchange = StubExchange()

    static func reset() {
        exchange.reset()
    }

    static func enqueueJSON(_ json: String, statusCode: Int = 200) {
        enqueueResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: Data(json.utf8)
        )
    }

    static func enqueueResponse(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data
    ) {
        exchange.enqueue(
            StubbedResponse(
                statusCode: statusCode,
                headers: headers,
                body: body
            )
        )
    }

    static func recordedRequests() -> [RecordedRequest] {
        exchange.recordedRequests()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let stub = try Self.exchange.takeResponse(for: request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: stub.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: stub.headers
                  ) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
