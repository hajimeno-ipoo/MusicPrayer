import AVFoundation
import Speech
import XCTest
@testable import MusicPrayer

final class AppleLyricPCMTests: XCTestCase {
    private func buffer(rate: Double = 48_000, channels: AVAudioChannelCount = 2,
                        frames: AVAudioFrameCount = 96_000, interleaved: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: channels, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            for channel in 0..<Int(channels) {
                if interleaved { buffer.floatChannelData![0][index * Int(channels) + channel] = Float(index * 10 + channel) }
                else { buffer.floatChannelData![channel][index] = Float(index * 10 + channel) }
            }
        }
        return buffer
    }

    func testSpeechConversionPreservesSongOriginAndDuration() throws {
        let pcm = buffer()
        let speech = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let inputs = try AppleLyricTranscriber.analyzerInputs(audioBuffer: pcm, format: speech, startTime: 3.25)
        XCTAssertEqual(try XCTUnwrap(inputs.first?.bufferStartTime).seconds, 3.25, accuracy: 1 / 16_000)
        XCTAssertEqual(inputs.reduce(0) { $0 + $1.bufferDuration.seconds }, 2, accuracy: 1 / 16_000)
        XCTAssertTrue(inputs.allSatisfy { $0.bufferFormat == speech })
        XCTAssertEqual(pcm.frameLength, 96_000)
    }

    func testRecognitionInputIsBoundedAndKeepsEverySampleAcrossChunks() throws {
        for interleaved in [false, true] {
            let pcm = buffer(rate: 16_000, frames: 16_003, interleaved: interleaved)
            for frame in 0..<Int(pcm.frameLength) {
                for channel in 0..<2 {
                    let sample = Float(frame % 1000) / 2000
                    if interleaved { pcm.floatChannelData![0][frame * 2 + channel] = sample }
                    else { pcm.floatChannelData![channel][frame] = sample }
                }
            }
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
            let inputs = try AppleLyricTranscriber.analyzerInputs(audioBuffer: pcm, format: format, startTime: 3.25)
            XCTAssertGreaterThan(inputs.count, 1)
            var position = 3.25
            var frame = 0
            for input in inputs {
                let copy = input.buffer
                XCTAssertLessThanOrEqual(copy.frameLength, 4096)
                if let start = input.bufferStartTime { XCTAssertEqual(start.seconds, position, accuracy: 1 / 16_000) }
                for index in 0..<Int(copy.frameLength) {
                    let sample = Double(copy.int16ChannelData![0][index]) / 32768
                    XCTAssertEqual(sample, Double((frame + index) % 1000) / 2000, accuracy: 2 / 32768)
                }
                frame += Int(copy.frameLength)
                position += input.bufferDuration.seconds
            }
            XCTAssertEqual(frame, Int(pcm.frameLength))
            XCTAssertEqual(position, 3.25 + Double(pcm.frameLength) / 16_000, accuracy: 1 / 16_000)
        }
    }

    func testInvalidOrUnavailablePCMRangeFailsInsteadOfAddingAudio() throws {
        let pcm = buffer(rate: 10, frames: 20)
        XCTAssertThrowsError(try AppleLyricTranscriber.analyzerInputs(audioBuffer: pcm, format: pcm.format, startTime: -1))
        pcm.frameLength = 0
        XCTAssertThrowsError(try AppleLyricTranscriber.analyzerInputs(audioBuffer: pcm, format: pcm.format))
    }
}
