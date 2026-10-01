import AVFoundation
import XCTest
@testable import TashlahetBridge

final class AudioProcessingPipelineTests: XCTestCase {
    func testFinishDrainsFortyEightKilohertzStereoIntoFiniteSixteenKilohertzAudio() async throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let callbacks = LockedAudioCallbacks()
        let pipeline = try AudioProcessingPipeline(
            inputFormat: inputFormat,
            onChunk: callbacks.record(chunk:),
            onMeter: callbacks.record(meter:),
            onFailure: callbacks.record(failure:)
        )
        let buffer = try makeBuffer(
            format: inputFormat,
            frameCount: 14_400,
            channelValues: [0.04, 0.06]
        )

        pipeline.enqueue(buffer)
        let failure = await pipeline.finish()

        XCTAssertNil(failure)
        let snapshot = callbacks.snapshot()
        XCTAssertTrue(snapshot.failures.isEmpty)
        XCTAssertTrue(snapshot.callbacksWereOnMainThread)
        XCTAssertEqual(snapshot.chunks.count, 1)
        let samples = try XCTUnwrap(snapshot.chunks.first?.samples)
        XCTAssertTrue((4_700...4_900).contains(samples.count))
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.009)
        XCTAssertEqual(snapshot.meters.last?.level, 0)
        XCTAssertEqual(snapshot.meters.last?.isSpeech, false)
    }

    func testFinishReturnsTheFirstFormatFailureAndReportsItOnce() async throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let wrongFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ))
        let callbacks = LockedAudioCallbacks()
        let pipeline = try AudioProcessingPipeline(
            inputFormat: inputFormat,
            onChunk: callbacks.record(chunk:),
            onMeter: callbacks.record(meter:),
            onFailure: callbacks.record(failure:)
        )

        pipeline.enqueue(try makeBuffer(
            format: wrongFormat,
            frameCount: 1_024,
            channelValues: [0.05]
        ))
        let failure = await pipeline.finish()

        let message = try XCTUnwrap(failure)
        let snapshot = callbacks.snapshot()
        XCTAssertEqual(snapshot.failures, [message])
        XCTAssertTrue(snapshot.callbacksWereOnMainThread)
        XCTAssertTrue(snapshot.chunks.isEmpty)
    }

    private func makeBuffer(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount,
        channelValues: [Float]
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        let channels = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(channelValues.count, Int(format.channelCount))
        for channelIndex in 0..<Int(format.channelCount) {
            let channel = channels[channelIndex]
            for frameIndex in 0..<Int(frameCount) {
                channel[frameIndex] = channelValues[channelIndex]
            }
        }
        return buffer
    }
}

private struct AudioCallbackSnapshot {
    let chunks: [PCMChunk]
    let meters: [AudioMeter]
    let failures: [String]
    let callbacksWereOnMainThread: Bool
}

private final class LockedAudioCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [PCMChunk] = []
    private var meters: [AudioMeter] = []
    private var failures: [String] = []
    private var callbacksWereOnMainThread = true

    func record(chunk: PCMChunk) {
        lock.withLock {
            callbacksWereOnMainThread = callbacksWereOnMainThread && Thread.isMainThread
            chunks.append(chunk)
        }
    }

    func record(meter: AudioMeter) {
        lock.withLock {
            callbacksWereOnMainThread = callbacksWereOnMainThread && Thread.isMainThread
            meters.append(meter)
        }
    }

    func record(failure: String) {
        lock.withLock {
            callbacksWereOnMainThread = callbacksWereOnMainThread && Thread.isMainThread
            failures.append(failure)
        }
    }

    func snapshot() -> AudioCallbackSnapshot {
        lock.withLock {
            AudioCallbackSnapshot(
                chunks: chunks,
                meters: meters,
                failures: failures,
                callbacksWereOnMainThread: callbacksWereOnMainThread
            )
        }
    }
}
