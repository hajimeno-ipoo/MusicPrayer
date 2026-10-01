import AVFoundation
import Accelerate
import Foundation

/// Owned by the audio tap. Only immutable snapshots cross to the UI.
final class AudioFeatureAnalyzer: @unchecked Sendable {
    static let fftSize = 2048
    static let hopSize = 512
    private let snapshotLock = NSLock()
    private var latest = AudioFeatures()
    private var history = [AudioFeatures](repeating: AudioFeatures(), count: 256)
    private var historyIndex = 0
    private var historyCount = 0
    private var resetRequested = false
    private var samples = [Float](repeating: 0, count: fftSize)
    private var filled = 0
    private var sinceTransform = 0
    private var window = [Float](repeating: 0, count: fftSize)
    private var real = [Float](repeating: 0, count: fftSize)
    private var imaginary = [Float](repeating: 0, count: fftSize)
    private var realOutput = [Float](repeating: 0, count: fftSize)
    private var imaginaryOutput = [Float](repeating: 0, count: fftSize)
    private var magnitudes = [Float](repeating: 0, count: fftSize / 2)
    private var previous = [Float](repeating: 0, count: fftSize / 2)
    private let transform: vDSP_DFT_Setup
    private let sampleRate: Double
    private var normalization: Float = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        transform = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD)!
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        var sum: Float = 0
        vDSP_sve(window, 1, &sum, vDSP_Length(Self.fftSize))
        normalization = 2 / sum
    }
    deinit { vDSP_DFT_DestroySetup(transform) }

    func snapshot() -> AudioFeatures {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return latest
    }

    func snapshot(atOrBefore hostTime: UInt64) -> AudioFeatures {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        for age in 0..<historyCount {
            let index = (historyIndex - 1 - age + history.count) % history.count
            let value = history[index]
            if value.hostTime <= hostTime { return value }
        }
        return AudioFeatures()
    }

    func reset() {
        snapshotLock.lock()
        historyCount = 0; historyIndex = 0; latest = AudioFeatures()
        resetRequested = true
        snapshotLock.unlock()
    }

    func process(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        processFrames(count: Int(buffer.frameLength), channelCount: Int(buffer.format.channelCount), time: time) { channel, frame in
            buffer.floatChannelData![channel][frame]
        }
    }

    func process(_ buffer: AVReadOnlyAudioPCMBuffer, at time: AVAudioTime) {
        buffer.withUnsafeAudioBufferList { list in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            processFrames(count: buffer.frameLength, channelCount: buffers.count, time: time) { channel, frame in
                buffers[channel].mData!.assumingMemoryBound(to: Float.self)[frame]
            }
        }
    }

    private func processFrames(count: Int, channelCount: Int, time: AVAudioTime, sample: (Int, Int) -> Float) {
        guard channelCount > 0 else { return }
        snapshotLock.lock()
        let reset = resetRequested
        resetRequested = false
        snapshotLock.unlock()
        if reset {
            filled = 0; sinceTransform = 0
            vDSP_vclr(&previous, 1, vDSP_Length(previous.count))
        }
        for frame in 0..<count {
            var mono: Float = 0
            for channel in 0..<channelCount { mono += sample(channel, frame) }
            mono /= Float(channelCount)
            if filled < Self.fftSize {
                samples[filled] = mono
                filled += 1
                if filled < Self.fftSize { continue }
            } else {
                // Overlapping Hann windows, 512-sample steps.
                if sinceTransform == 0 {
                    _ = samples.withUnsafeMutableBufferPointer { p in
                        memmove(p.baseAddress!, p.baseAddress!.advanced(by: Self.hopSize), (Self.fftSize - Self.hopSize) * MemoryLayout<Float>.size)
                    }
                }
                samples[Self.fftSize - Self.hopSize + sinceTransform] = mono
                sinceTransform += 1
                if sinceTransform < Self.hopSize { continue }
            }
            sinceTransform = 0
            let end = time.hostTime + AVAudioTime.hostTime(forSeconds: Double(frame) / sampleRate)
            let halfWindow = AVAudioTime.hostTime(forSeconds: Double(Self.fftSize / 2) / sampleRate)
            let stamp = end >= halfWindow ? end - halfWindow : 0
            analyze(hostTime: stamp)
        }
    }

    private func analyze(hostTime: UInt64) {
        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(Self.fftSize))
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(Self.fftSize))
        vDSP_vmul(samples, 1, window, 1, &real, 1, vDSP_Length(Self.fftSize))
        vDSP_DFT_Execute(transform, real, imaginary, &realOutput, &imaginaryOutput)
        var total: Float = 0
        var weighted: Float = 0
        var flux: Float = 0
        for bin in magnitudes.indices {
            let magnitude = hypotf(realOutput[bin], imaginaryOutput[bin]) * normalization
            magnitudes[bin] = magnitude
            flux += max(0, magnitude - previous[bin])
            previous[bin] = magnitude
            total += magnitude
            weighted += magnitude * Float(Double(bin) * sampleRate / Double(Self.fftSize))
        }
        var value = AudioFeatures()
        value.hostTime = hostTime; value.rms = rms; value.peak = peak
        value.spectralFlux = flux
        value.spectralCentroid = total > 0.000001 ? weighted / total : 0
        value.bass = band(30, 120); value.lowMid = band(120, 500)
        value.mid = band(500, 2_000); value.highMid = band(2_000, 6_000)
        value.treble = band(6_000, min(16_000, sampleRate / 2))
        let upper = min(16_000, sampleRate / 2)
        for index in 0..<64 {
            let low = 30 * pow(upper / 30, Double(index) / 64)
            let high = 30 * pow(upper / 30, Double(index + 1) / 64)
            // Visual spectrum uses a fixed -80...0 dBFS range; five broad bands stay linear.
            let amplitude = band(low, high)
            let decibels = 20 * log10f(max(amplitude, 0.0001))
            value.spectrum[index] = min(1, max(0, (decibels + 80) / 80))
        }
        snapshotLock.lock()
        if !resetRequested {
            latest = value
            history[historyIndex] = value
            historyIndex = (historyIndex + 1) % history.count
            historyCount = min(historyCount + 1, history.count)
        }
        snapshotLock.unlock()
    }

    private func band(_ low: Double, _ high: Double) -> Float {
        let first = max(1, Int((low * Double(Self.fftSize) / sampleRate).rounded(.down)))
        let last = min(magnitudes.count - 1, max(first, Int((high * Double(Self.fftSize) / sampleRate).rounded(.up)) - 1))
        guard first <= last else { return 0 }
        var energy: Float = 0
        for bin in first...last { energy += magnitudes[bin] * magnitudes[bin] }
        return sqrtf(energy)
    }
}
