import AVFoundation
import XCTest
@testable import MusicPrayer

final class AppleMusicVisualizerTests: XCTestCase {
    func testWebOutputGainIsRemovedBeforeExistingFeatureCalculation() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        func buffer(volume: Float) throws -> AVAudioPCMBuffer {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
            buffer.frameLength = 4_096
            for frame in 0..<4_096 {
                buffer.floatChannelData![0][frame] = Float(0.5 * sin(2 * .pi * 120 * Double(frame) / 48_000)) * volume
            }
            return buffer
        }
        let reference = AudioFeatureAnalyzer(sampleRate: 48_000)
        let stamp = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 3))
        reference.process(try buffer(volume: 1), at: stamp)
        let expected = reference.snapshot()
        for volume: Float in [0.75, 0.22, 0.12, 0.01] {
            let analyzer = AudioFeatureAnalyzer(sampleRate: 48_000)
            analyzer.setInputGain(1 / volume)
            analyzer.process(try buffer(volume: volume).audioBufferList, at: stamp)
            let actual = analyzer.snapshot()
            XCTAssertEqual(actual.rms, expected.rms, accuracy: 0.000001)
            XCTAssertEqual(actual.bass, expected.bass, accuracy: 0.000001)
            for (a, b) in zip(actual.spectrum, expected.spectrum) {
                XCTAssertEqual(a, b, accuracy: 0.00001)
            }
        }
    }

    func testTapPCMLayoutsProduceTheSameExistingFFTFeatures() throws {
        let reference = AudioFeatureAnalyzer(sampleRate: 48_000)
        let planar = AudioFeatureAnalyzer(sampleRate: 48_000)
        let interleaved = AudioFeatureAnalyzer(sampleRate: 48_000)
        let stamp = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 3))
        let planarFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let interleavedFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                         sampleRate: 48_000, channels: 2, interleaved: true))
        // More than one FFT window, and different tones in the two channels.
        let first = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: planarFormat, frameCapacity: 4_096))
        let second = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: interleavedFormat, frameCapacity: 4_096))
        first.frameLength = 4_096
        second.frameLength = 4_096
        let packed = try XCTUnwrap(second.mutableAudioBufferList.pointee.mBuffers.mData).assumingMemoryBound(to: Float.self)
        for frame in 0..<4_096 {
            for channel in 0..<2 {
                let frequency = channel == 0 ? 120.0 : 1_000.0
                let value = Float(0.25 * sin(2 * .pi * frequency * Double(frame) / 48_000))
                first.floatChannelData![channel][frame] = value
                packed[frame * 2 + channel] = value
            }
        }
        reference.process(first, at: stamp)
        planar.process(first.audioBufferList, at: stamp)
        interleaved.process(second.audioBufferList, at: stamp)
        let expected = reference.snapshot()
        XCTAssertGreaterThan(expected.rms, 0.1)
        XCTAssertGreaterThan(expected.mid, 0)
        for actual in [planar.snapshot(), interleaved.snapshot()] {
            XCTAssertEqual(actual.hostTime, expected.hostTime)
            XCTAssertEqual(actual.rms, expected.rms, accuracy: 0.000001)
            XCTAssertEqual(actual.peak, expected.peak, accuracy: 0.000001)
            XCTAssertEqual(actual.spectralCentroid, expected.spectralCentroid, accuracy: 0.01)
            for (a, b) in zip(actual.spectrum, expected.spectrum) {
                XCTAssertEqual(a, b, accuracy: 0.000001)
            }
        }
    }

    func testCapturedAudioDrivesExistingComposerWithoutInventingMusicAnalysis() {
        var composer = VisualComposer()
        var audio = AudioFeatures()
        audio.rms = 0.2
        audio.bass = 0.3
        audio.mid = 0.2
        audio.treble = 0.1
        audio.spectrum[10] = 0.5
        let frame = composer.compose(time: 60, audio: audio, moment: MusicalMoment(), scene: nil,
                                     analyzed: false, presence: 1, dt: 1 / 60)
        XCTAssertGreaterThan(frame.rms, 0)
        XCTAssertGreaterThan(frame.bass, frame.treble)
        XCTAssertGreaterThan(frame.spectrum[10], 0)
        XCTAssertEqual(frame.hasAnalysis, 0)
        XCTAssertEqual(frame.beat, 0)
        XCTAssertEqual(frame.vocal, 0)
        var paused = frame
        for _ in 0..<240 {
            paused = composer.compose(time: 60, audio: AudioFeatures(), moment: MusicalMoment(), scene: nil,
                                      analyzed: false, presence: 1, dt: 1 / 60)
        }
        XCTAssertLessThan(paused.rms, 0.000001)
        XCTAssertLessThan(paused.spectrum[10], 0.000001)
    }
}
