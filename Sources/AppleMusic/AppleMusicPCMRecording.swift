import AVFoundation
import Foundation

/// A single muted 2x pass stays in RAM until its timeline has been restored for the common analyzer.
final class AppleMusicPCMRecording: @unchecked Sendable {
    private let lock = NSLock()
    private var position: Double?
    private var origin: Double?
    private var buffers: [AVAudioPCMBuffer] = []
    private var valid = true
    private var finished = false
    private let gain: Float

    init(volume: Float) { gain = volume > 0 ? 1 / volume : 1 }

    func update(position: Double?) {
        lock.lock(); defer { lock.unlock() }
        self.position = position
    }

    func append(_ list: UnsafePointer<AudioBufferList>, sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, let position, position > 0 else { return }
        guard let buffer = AppleMusicAnalysisInput.copy(list, sampleRate: sampleRate, gain: gain),
              buffers.first.map({ $0.format == buffer.format }) ?? true else { valid = false; return }
        if origin == nil { origin = position }
        buffers.append(buffer)
    }

    func takeAudio(endingAt duration: Double) throws -> (buffer: AVAudioPCMBuffer, origin: Double) {
        lock.lock()
        finished = true
        let values = buffers, origin = self.origin, valid = self.valid
        buffers = []; position = nil
        lock.unlock()
        guard valid, let first = values.first, let origin else { throw RecordingError.missingAudio }
        let capturedFrames = values.reduce(0) { $0 + Int($1.frameLength) }
        // The media clock can wait during Play while the tap already supplies quiet buffers.
        // At natural end, the known 2x source interval bounds the useful suffix of this recording.
        let interval = max(0, duration - origin)
        guard interval.isFinite else { throw RecordingError.missingAudio }
        let expectedFrames = min(Double(capturedFrames), (interval * first.format.sampleRate / 2).rounded())
        let frames = Int(expectedFrames)
        var skip = capturedFrames - frames
        guard frames > 0, frames <= Int(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw RecordingError.missingAudio
        }
        output.frameLength = AVAudioFrameCount(frames)
        var offset = 0
        for value in values {
            let firstFrame = min(skip, Int(value.frameLength))
            skip -= firstFrame
            let count = Int(value.frameLength) - firstFrame
            guard count > 0 else { continue }
            for channel in 0..<Int(first.format.channelCount) {
                memcpy(output.floatChannelData![channel] + offset, value.floatChannelData![channel] + firstFrame, count * 4)
            }
            offset += count
        }
        return (output, origin)
    }

    private enum RecordingError: LocalizedError {
        case missingAudio
        var errorDescription: String? { "事前解析用の音声を取得できませんでした。" }
    }
}
