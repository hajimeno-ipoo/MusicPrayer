import AVFoundation
import XCTest
@testable import MusicPrayer

final class AppleMusicFastInputTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func buffer(seconds: Double, channels: AVAudioChannelCount,
                        sample: (Double, Int) -> Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let frames = AVAudioFrameCount((seconds * sampleRate).rounded())
        let value = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        value.frameLength = frames
        for channel in 0..<Int(channels) {
            let output = try XCTUnwrap(value.floatChannelData?[channel])
            for frame in 0..<Int(frames) { output[frame] = sample(Double(frame) / sampleRate, channel) }
        }
        return value
    }

    private func frequency(_ buffer: AVAudioPCMBuffer, channel: Int, from: Double, to: Double) -> Double {
        let rate = buffer.format.sampleRate
        let first = Int((from * rate).rounded()), last = Int((to * rate).rounded())
        let samples = buffer.floatChannelData![channel]
        var positiveCrossings = 0
        for frame in (first + 1)..<last where samples[frame - 1] <= 0 && samples[frame] > 0 {
            positiveCrossings += 1
        }
        return Double(positiveCrossings) / (Double(last - first) / rate)
    }

    private func rms(_ buffer: AVAudioPCMBuffer, channel: Int, first: Int, count: Int) -> Double {
        let samples = buffer.floatChannelData![channel]
        var power = 0.0
        for frame in first..<(first + count) { power += Double(samples[frame]) * Double(samples[frame]) }
        return sqrt(power / Double(count))
    }

    func testExpansionRestoresDurationWithoutLoweringPitchOrDelayingVocalOnset() throws {
        let source = try buffer(seconds: 3, channels: 1) { time, _ in
            (time >= 0.5 && time < 2.5) ? Float(0.5 * sin(2 * .pi * 440 * time)) : 0
        }
        let output = try AppleMusicTimeExpansion.expand(source)
        XCTAssertEqual(output.frameLength, source.frameLength * 2)
        XCTAssertEqual(output.format.sampleRate, source.format.sampleRate)
        XCTAssertEqual(Double(output.frameLength) / output.format.sampleRate, 6, accuracy: 0.000001)
        XCTAssertEqual(frequency(output, channel: 0, from: 2, to: 4), 440, accuracy: 2,
                       "時間を2倍へ戻しても、音程を1オクターブ下げない")
        let window = Int(sampleRate * 0.01)
        let audible = stride(from: 0, to: Int(output.frameLength) - window, by: window).filter {
            rms(output, channel: 0, first: $0, count: window) > 0.05
        }
        let first = try XCTUnwrap(audible.first)
        let last = try XCTUnwrap(audible.last)
        XCTAssertEqual(Double(first) / sampleRate, 1, accuracy: 0.05,
                       "0.5秒から歌い始める2倍速入力は、元の時間軸の1秒から出る")
        XCTAssertEqual(Double(last + window) / sampleRate, 5, accuracy: 0.05,
                       "元の時間軸の末尾を、伸長器のウィンドウ処理で切り落とさない")
    }

    func testStereoExpansionRetainsHighFrequencyInsteadOfHalvingItsPitch() throws {
        let source = try buffer(seconds: 3, channels: 2) { time, channel in
            Float(0.25 * sin(2 * .pi * (channel == 0 ? 440.0 : 10_000.0) * time))
        }
        let output = try AppleMusicTimeExpansion.expand(source)
        XCTAssertEqual(output.format.channelCount, 2)
        XCTAssertEqual(output.frameLength, source.frameLength * 2)
        XCTAssertEqual(frequency(output, channel: 0, from: 1, to: 5), 440, accuracy: 2)
        XCTAssertEqual(frequency(output, channel: 1, from: 1, to: 5), 10_000, accuracy: 4,
                       "右チャンネルの10 kHzを5 kHzへ下げるサンプルレート再宣言にしない")
        XCTAssertGreaterThan(rms(output, channel: 1, first: Int(sampleRate), count: Int(sampleRate * 4)), 0.08,
                             "高域の周波数だけでなく、解析へ渡せる強さの信号が残る")
    }

    func testAlreadyCancelledTaskDoesNotCompleteOfflineExpansion() async throws {
        let source = try buffer(seconds: 3, channels: 1) { time, _ in Float(0.25 * sin(2 * .pi * 440 * time)) }
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AppleMusicTimeExpansion.expand(source)
        }
        do {
            _ = try await work.value
            XCTFail("再生操作へ譲るためキャンセルされた伸長処理を、そのまま完了させない")
        } catch is CancellationError {
            // Expected; the offline render loop must observe cancellation.
        }
    }
}
