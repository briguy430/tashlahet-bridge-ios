import AVFoundation
import Foundation
import UIKit

enum AudioCaptureError: LocalizedError {
    case microphoneDenied
    case notForeground
    case alreadyRunning
    case cancelled
    case unavailableInput
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is denied. Enable Microphone for Tashlahet Bridge in Settings."
        case .notForeground:
            return "Keep Tashlahet Bridge open while recording a conversation."
        case .alreadyRunning:
            return "The microphone is already starting, recording, or stopping."
        case .cancelled:
            return "Microphone start was cancelled."
        case .unavailableInput:
            return "No usable microphone input is available. Check your audio route and try again."
        case .converterUnavailable:
            return "This microphone format could not be converted to 16 kHz mono audio."
        }
    }
}

/// Owns the foreground microphone session. PCM conversion and VAD run on a
/// separate serial queue; all consumer callbacks are delivered on the main queue.
@MainActor
final class AudioCaptureEngine {
    private var engine: AVAudioEngine?
    private var processor: AudioProcessingPipeline?
    private var observers: [NSObjectProtocol] = []
    private var tapInstalled = false
    private var sessionActive = false
    private var starting = false
    private var generation = UUID()
    private var stoppingTask: Task<Void, Never>?
    private var failureHandler: (@Sendable (String) -> Void)?

    init() {}

    func start(
        onChunk: @escaping @Sendable (PCMChunk) -> Void,
        onMeter: @escaping @Sendable (AudioMeter) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        guard engine == nil, !starting, stoppingTask == nil else {
            throw AudioCaptureError.alreadyRunning
        }
        let token = UUID()
        generation = token
        starting = true
        defer {
            if generation == token {
                starting = false
            }
        }

        let granted = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        // Stop may have run while the permission sheet was visible. A stale
        // permission completion must never activate or stop a newer session.
        guard generation == token else { throw AudioCaptureError.cancelled }
        guard granted else { throw AudioCaptureError.microphoneDenied }
        guard UIApplication.shared.applicationState == .active else {
            throw AudioCaptureError.notForeground
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            sessionActive = true
            failureHandler = onFailure

            let audioEngine = AVAudioEngine()
            engine = audioEngine
            let input = audioEngine.inputNode
            let sourceFormat = input.outputFormat(forBus: 0)
            guard sourceFormat.sampleRate.isFinite, sourceFormat.sampleRate > 0,
                  sourceFormat.channelCount > 0 else {
                throw AudioCaptureError.unavailableInput
            }
            let pipeline = try AudioProcessingPipeline(
                inputFormat: sourceFormat,
                onChunk: onChunk,
                onMeter: onMeter,
                onFailure: { [weak self] message in
                    Task { @MainActor [weak self] in
                        await self?.handleProcessorFailure(message, token: token)
                    }
                }
            )
            processor = pipeline
            input.installTap(onBus: 0, bufferSize: 1_024, format: sourceFormat) {
                buffer, _ in
                pipeline.enqueue(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            installObservers(token: token)
        } catch {
            if generation == token {
                await stop()
            }
            throw error
        }
    }

    /// Stops capture immediately, then drains all accepted PCM and a final VAD
    /// chunk. The final onChunk callbacks execute before this method returns.
    func stop() async {
        generation = UUID()
        starting = false
        if let task = stoppingTask {
            await task.value
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.finishStopping()
        }
        stoppingTask = task
        await task.value
        stoppingTask = nil
    }

    private func finishStopping() async {
        let oldEngine = engine
        let oldProcessor = processor
        let oldFailureHandler = failureHandler
        engine = nil
        processor = nil
        failureHandler = nil
        removeObservers()

        if tapInstalled {
            oldEngine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        oldEngine?.stop()
        if let oldProcessor,
           let drainFailure = await oldProcessor.finish() {
            oldFailureHandler?(drainFailure)
        }
        if sessionActive {
            sessionActive = false
            do {
                try AVAudioSession.sharedInstance().setActive(
                    false, options: [.notifyOthersOnDeactivation]
                )
            } catch {
                oldFailureHandler?(
                    "Recording stopped, but the audio session could not be released: "
                        + error.localizedDescription
                )
            }
        }
    }

    private func handleFailure(_ message: String, token: UUID) async {
        guard generation == token, engine != nil else { return }
        let callback = failureHandler
        await stop()
        callback?(message)
    }

    /// Processor failures are retained by the pipeline and delivered by
    /// finishStopping after every accepted buffer has drained. This callback
    /// only starts shutdown; delivering here as well would report it twice.
    private func handleProcessorFailure(_ message: String, token: UUID) async {
        guard generation == token, engine != nil else { return }
        await stop()
    }

    private func installObservers(token: UUID) {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard value == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in
                await self?.handleFailure(
                    "The microphone was interrupted by a call or another audio app. Tap Start Live Feed to resume.",
                    token: token
                )
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard let value,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: value) else { return }
            // Setting this app's category can itself send a notification. Only
            // changes that may invalidate the input format end this recording.
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange,
                 .noSuitableRouteForCategory, .wakeFromSleep:
                Task { @MainActor [weak self] in
                    await self?.handleFailure(
                        "The microphone route changed. Tap Start Live Feed to use the new input.",
                        token: token
                    )
                }
            default:
                break
            }
        })

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleFailure(
                    "Recording stopped because the app moved to the background. Open the app and start again.",
                    token: token
                )
            }
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }
}

/// Only admission bookkeeping crosses executors. The converter, scratch buffer,
/// timestamps, and VAD state are exclusively used on processingQueue.
final class AudioProcessingPipeline: @unchecked Sendable {
    private enum Admission {
        case accepted
        case closed
        case overflow
    }

    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let outputBuffer: AVAudioPCMBuffer
    private let processingQueue = DispatchQueue(
        label: "TashlahetBridge.audio.processing", qos: .userInitiated
    )
    private let admissionLock = NSLock()
    private let maximumQueuedFrames: Int
    private var accepting = true
    private var pendingFrames = 0
    private var pendingBuffers = 0
    private var failureMessage: String?
    private var converterBroken = false
    private var segmenter = VoiceActivitySegmenter()
    private var nextSampleDate: Date?
    private var meterSamples = 0
    private var lastSpeech: Bool?
    private let onChunk: @Sendable (PCMChunk) -> Void
    private let onMeter: @Sendable (AudioMeter) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(
        inputFormat: AVAudioFormat,
        onChunk: @escaping @Sendable (PCMChunk) -> Void,
        onMeter: @escaping @Sendable (AudioMeter) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat),
        let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4_096) else {
            throw AudioCaptureError.converterUnavailable
        }
        self.inputFormat = inputFormat
        self.converter = converter
        self.outputBuffer = output
        self.maximumQueuedFrames = max(1, Int(inputFormat.sampleRate * 0.75))
        self.onChunk = onChunk
        self.onMeter = onMeter
        self.onFailure = onFailure
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
    }

    /// The tap only reserves a bounded slot, copies PCM whose lifetime belongs
    /// to the engine, and schedules work. It never converts or waits for the UI.
    func enqueue(_ source: AVAudioPCMBuffer) {
        let frames = Int(source.frameLength)
        guard frames > 0 else { return }
        guard frames <= 16_384, source.format.isEqual(inputFormat) else {
            reportFailure("The microphone supplied an unexpected audio format or buffer size. Recording stopped.")
            return
        }

        switch reserve(frames) {
        case .closed:
            return
        case .overflow:
            reportFailure(
                "Audio processing fell behind and a microphone buffer could not be queued. "
                    + "Recording stopped to avoid silently omitting speech."
            )
            return
        case .accepted:
            break
        }

        guard let copy = copyPCM(source) else {
            release(frames)
            reportFailure("The microphone audio buffer could not be copied. Recording stopped.")
            return
        }
        let capturedAt = Date()
        processingQueue.async { [self] in
            defer { release(frames) }
            autoreleasepool {
                if nextSampleDate == nil {
                    nextSampleDate = capturedAt
                }
                if !converterBroken {
                    convert(copy, ending: false)
                }
            }
        }
    }

    func finish() async -> String? {
        admissionLock.withLock {
            accepting = false
        }
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<String?, Never>) in
            processingQueue.async { [self] in
                if !converterBroken {
                    convert(nil, ending: true)
                }
                for samples in segmenter.flush() {
                    emit(samples)
                }
                let drainFailure = admissionLock.withLock { failureMessage }
                let meterCallback = onMeter
                // A FIFO main-queue sentinel also waits for all previously
                // enqueued chunk callbacks, including the final speech tail.
                DispatchQueue.main.async {
                    meterCallback(AudioMeter(level: 0, isSpeech: false))
                    continuation.resume(returning: drainFailure)
                }
            }
        }
    }

    private func reserve(_ frames: Int) -> Admission {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        guard accepting else { return .closed }
        guard pendingBuffers < 16,
              pendingFrames + frames <= maximumQueuedFrames else {
            return .overflow
        }
        pendingFrames += frames
        pendingBuffers += 1
        return .accepted
    }

    private func release(_ frames: Int) {
        admissionLock.lock()
        pendingFrames -= frames
        pendingBuffers -= 1
        admissionLock.unlock()
    }

    private func copyPCM(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: source.frameLength
        ) else { return nil }
        copy.frameLength = source.frameLength
        let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        let bytesToCopy = Int(source.frameLength) * bytesPerFrame
        guard bytesToCopy > 0 else { return nil }
        let input = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let output = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard input.count == output.count, !input.isEmpty else { return nil }
        for index in 0..<input.count {
            guard let sourceData = input[index].mData,
                  let destinationData = output[index].mData,
                  Int(input[index].mDataByteSize) >= bytesToCopy,
                  Int(output[index].mDataByteSize) >= bytesToCopy else { return nil }
            memcpy(destinationData, sourceData, bytesToCopy)
            output[index].mDataByteSize = UInt32(bytesToCopy)
        }
        return copy
    }

    private func convert(_ input: AVAudioPCMBuffer?, ending: Bool) {
        var suppliedInput = false
        // Input taps are capped at 16384 source frames. 64 output buffers allow
        // ample drainage even for low-rate Bluetooth input, while catching a
        // malfunctioning converter instead of spinning forever.
        for _ in 0..<64 {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) {
                _, inputStatus in
                if let input, !suppliedInput {
                    suppliedInput = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = ending ? .endOfStream : .noDataNow
                return nil
            }

            // .inputRanDry can still carry valid output; consume it first.
            if outputBuffer.frameLength > 0 {
                guard let channel = outputBuffer.floatChannelData?[0] else {
                    converterBroken = true
                    reportFailure("The audio converter returned invalid PCM. Recording stopped.")
                    return
                }
                let samples = Array(UnsafeBufferPointer(
                    start: channel, count: Int(outputBuffer.frameLength)
                ))
                guard samples.allSatisfy({ $0.isFinite }) else {
                    converterBroken = true
                    reportFailure("The microphone produced invalid sample values. Recording stopped.")
                    return
                }
                let output = segmenter.append(samples)
                for chunkSamples in output.chunks {
                    emit(chunkSamples)
                }
                meterSamples += samples.count
                if let meter = output.meter,
                   meterSamples >= 800 || lastSpeech != meter.isSpeech {
                    meterSamples = 0
                    lastSpeech = meter.isSpeech
                    let callback = onMeter
                    DispatchQueue.main.async { callback(meter) }
                }
                if let date = nextSampleDate {
                    nextSampleDate = date.addingTimeInterval(Double(samples.count) / 16_000)
                }
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                return
            case .endOfStream:
                return
            case .error:
                converterBroken = true
                reportFailure(
                    "Audio conversion failed: "
                        + (conversionError?.localizedDescription ?? "Unknown converter error.")
                )
                return
            @unknown default:
                converterBroken = true
                reportFailure("The audio converter returned an unsupported status. Recording stopped.")
                return
            }
        }
        converterBroken = true
        reportFailure("The audio converter did not finish processing its bounded input. Recording stopped.")
    }

    private func emit(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        // UTC capture metadata is advisory; PCM duration comes from samples.
        let chunk = PCMChunk(
            id: UUID(),
            samples: samples,
            capturedAt: nextSampleDate ?? Date()
        )
        let callback = onChunk
        DispatchQueue.main.async { callback(chunk) }
    }

    private func reportFailure(_ message: String) {
        let isFirstFailure = admissionLock.withLock {
            guard failureMessage == nil else { return false }
            failureMessage = message
            accepting = false
            return true
        }
        guard isFirstFailure else { return }
        let callback = onFailure
        processingQueue.async {
            DispatchQueue.main.async { callback(message) }
        }
    }
}
