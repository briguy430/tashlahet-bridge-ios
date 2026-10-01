import Foundation

/// A value-type, 16 kHz mono VAD. Call it from one executor at a time.
/// Audio is framed by sample count, so arbitrary converter buffer sizes are safe.
struct VoiceActivitySegmenter {
    struct Output {
        let chunks: [[Float]]
        let meter: AudioMeter?
    }

    static let sampleRate = 16_000
    static let frameSampleCount = 320                 // 20 ms
    static let preRollSampleCount = 3_200              // 200 ms
    static let minimumSpeechSampleCount = 2_560        // 160 ms
    static let silenceSampleCount = 6_400              // 400 ms
    static let maximumChunkSampleCount = 80_000        // 5 seconds

    private let speechThreshold: Float
    private var pendingFrame: [Float] = []
    private var preRoll: [Float] = []
    private var utterance: [Float] = []
    private var active = false
    private var speechSamples = 0
    private var trailingSilenceSamples = 0
    private var continuingConfirmedSpeech = false

    init(speechThreshold: Float = 0.009) {
        self.speechThreshold = speechThreshold.isFinite && speechThreshold > 0
            ? speechThreshold : 0.009
        pendingFrame.reserveCapacity(Self.frameSampleCount)
        preRoll.reserveCapacity(Self.preRollSampleCount)
        utterance.reserveCapacity(Self.maximumChunkSampleCount)
    }

    mutating func append(_ samples: [Float]) -> Output {
        var chunks: [[Float]] = []
        var meter: AudioMeter?
        var offset = 0
        while offset < samples.count {
            let count = min(Self.frameSampleCount - pendingFrame.count, samples.count - offset)
            pendingFrame.append(contentsOf: samples[offset..<(offset + count)])
            offset += count
            if pendingFrame.count == Self.frameSampleCount {
                meter = consume(pendingFrame, chunks: &chunks)
                pendingFrame.removeAll(keepingCapacity: true)
            }
        }
        return Output(chunks: chunks, meter: meter)
    }

    /// Called after the converter has received endOfStream. Emits a meaningful
    /// partial utterance even if its usual 400 ms pause has not yet occurred.
    mutating func flush() -> [[Float]] {
        var chunks: [[Float]] = []
        if !pendingFrame.isEmpty {
            _ = consume(pendingFrame, chunks: &chunks)
            pendingFrame.removeAll(keepingCapacity: true)
        }
        if hasMeaningfulSpeech && !utterance.isEmpty {
            chunks.append(utterance)
        }
        resetUtterance()
        preRoll.removeAll(keepingCapacity: true)
        return chunks
    }

    private var hasMeaningfulSpeech: Bool {
        speechSamples >= Self.minimumSpeechSampleCount
            || (continuingConfirmedSpeech && speechSamples > 0)
    }

    private mutating func consume(_ frame: [Float], chunks: inout [[Float]]) -> AudioMeter {
        var energy: Double = 0
        for sample in frame {
            if sample.isFinite {
                energy += Double(sample) * Double(sample)
            }
        }
        let rms = Float(sqrt(energy / Double(max(frame.count, 1))))
        let speech = rms >= speechThreshold
        let meter = AudioMeter(level: min(1, max(0, rms)), isSpeech: speech)

        if !active {
            if !speech {
                rememberPreRoll(frame)
                return meter
            }
            active = true
            utterance.append(contentsOf: preRoll)
            preRoll.removeAll(keepingCapacity: true)
        }

        utterance.append(contentsOf: frame)
        if speech {
            speechSamples += frame.count
            trailingSilenceSamples = 0
        } else {
            trailingSilenceSamples += frame.count
        }

        if trailingSilenceSamples >= Self.silenceSampleCount {
            if hasMeaningfulSpeech {
                chunks.append(utterance)
            }
            // A new utterance receives only the recent silence as its preroll.
            let recentSilence = Array(utterance.suffix(Self.preRollSampleCount))
            resetUtterance()
            preRoll = recentSilence
        } else if utterance.count >= Self.maximumChunkSampleCount {
            if hasMeaningfulSpeech {
                chunks.append(utterance)
            }
            // Continue the same speech without duplicating its previous samples.
            utterance.removeAll(keepingCapacity: true)
            speechSamples = 0
            trailingSilenceSamples = 0
            continuingConfirmedSpeech = true
            active = true
        }
        return meter
    }

    private mutating func rememberPreRoll(_ frame: [Float]) {
        preRoll.append(contentsOf: frame)
        if preRoll.count > Self.preRollSampleCount {
            preRoll = Array(preRoll.suffix(Self.preRollSampleCount))
        }
    }

    private mutating func resetUtterance() {
        utterance.removeAll(keepingCapacity: true)
        active = false
        speechSamples = 0
        trailingSilenceSamples = 0
        continuingConfirmedSpeech = false
    }
}
