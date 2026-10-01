import XCTest
@testable import TashlahetBridge

final class VoiceActivitySegmenterTests: XCTestCase {
    func testSilenceProducesNoChunksAndReportsSilentMeter() {
        var segmenter = VoiceActivitySegmenter()

        let output = segmenter.append(Array(repeating: Float.zero, count: 640))

        XCTAssertTrue(output.chunks.isEmpty)
        XCTAssertEqual(output.meter?.level, 0)
        XCTAssertEqual(output.meter?.isSpeech, false)
        XCTAssertTrue(segmenter.flush().isEmpty)
    }

    func testShortNoiseBelowMinimumSpeechIsRejectedAfterClosingPause() {
        var segmenter = VoiceActivitySegmenter()
        let shortNoise = Array(repeating: Float(0.05), count: 2_240)
        let closingPause = Array(repeating: Float.zero, count: 6_400)

        let output = segmenter.append(shortNoise + closingPause)

        XCTAssertTrue(output.chunks.isEmpty)
        XCTAssertTrue(segmenter.flush().isEmpty)
    }

    func testConfirmedSpeechEmitsWhenFourHundredMillisecondPauseCompletes() {
        var segmenter = VoiceActivitySegmenter()
        let preRoll = Array(repeating: Float.zero, count: 3_200)
        let speech = Array(repeating: Float(0.05), count: 2_560)
        let pause = Array(repeating: Float.zero, count: 6_400)

        let beforeLastPauseSample = segmenter.append(preRoll + speech + pause.dropLast())
        XCTAssertTrue(beforeLastPauseSample.chunks.isEmpty)

        let completedPause = segmenter.append([0])

        XCTAssertEqual(completedPause.chunks, [preRoll + speech + pause])
        XCTAssertEqual(completedPause.meter?.isSpeech, false)
    }

    func testArbitraryAppendSizesPreserveEverySampleInOrder() {
        var segmenter = VoiceActivitySegmenter()
        let preRoll = Array(repeating: Float.zero, count: 1_280)
        let speech = Array(repeating: Float(0.05), count: 2_880)
        let pause = Array(repeating: Float.zero, count: 6_400)
        let input = preRoll + speech + pause
        let appendSizes = [1, 17, 503, 29, 2_048, 3, 777]
        var emitted: [[Float]] = []
        var offset = 0
        var sizeIndex = 0

        while offset < input.count {
            let end = min(input.count, offset + appendSizes[sizeIndex % appendSizes.count])
            emitted.append(contentsOf: segmenter.append(Array(input[offset..<end])).chunks)
            offset = end
            sizeIndex += 1
        }

        XCTAssertEqual(emitted, [input])
        XCTAssertTrue(segmenter.flush().isEmpty)
    }

    func testContinuousSpeechSplitsAtFiveSecondsWithoutDuplication() {
        var segmenter = VoiceActivitySegmenter()
        let input = Array(repeating: Float(0.05), count: 160_640)

        let output = segmenter.append(input)
        let finalChunks = segmenter.flush()

        XCTAssertEqual(output.chunks.map(\.count), [80_000, 80_000])
        XCTAssertEqual(finalChunks.map(\.count), [640])
        XCTAssertEqual((output.chunks + finalChunks).flatMap { $0 }, input)
    }

    func testFlushPreservesConfirmedSpeechWithoutAClosingPause() {
        var segmenter = VoiceActivitySegmenter()
        let preRoll = Array(repeating: Float.zero, count: 640)
        let speech = Array(repeating: Float(0.05), count: 2_687)
        let input = preRoll + speech

        XCTAssertTrue(segmenter.append(input).chunks.isEmpty)

        XCTAssertEqual(segmenter.flush(), [input])
        XCTAssertTrue(segmenter.flush().isEmpty)
    }
}
