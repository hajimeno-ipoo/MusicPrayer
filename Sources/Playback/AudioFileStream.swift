import AVFoundation
import Foundation

enum PlaybackError: LocalizedError {
    case unsupportedFormat
    case emptyFile
    case conversion(String)
    case outputDevice(OSStatus)
    case invalidPosition
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "この音声形式を再生できません。"
        case .emptyFile: return "音声ファイルに再生できるデータがありません。"
        case .conversion(let detail): return "音声を読み込めませんでした: \(detail)"
        case .invalidPosition: return "再生位置が正しい秒数ではありません。"
        case .outputDevice(let status): return "音声出力先を変更できませんでした（\(status)）。"
        }
    }
}

/// Serial decode queue owns reading after initialization. Storage stays bounded by chunk count.
final class AudioFileStream: @unchecked Sendable {
    static let chunkFrames: AVAudioFrameCount = 32_768
    let url: URL
    let duration: Double
    let offset: Double
    let format: AVAudioFormat
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let expectedOutputFrames: Int64
    private var emittedFrames: Int64 = 0
    private var inputFinished = false
    private(set) var ended = false

    init(url: URL, offset: Double = 0, format: AVAudioFormat) throws {
        guard offset.isFinite else { throw PlaybackError.invalidPosition }
        self.url = url
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.format = format
        guard file.length > 0, file.processingFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else { throw PlaybackError.unsupportedFormat }
        self.converter = converter; self.input = input
        duration = Double(file.length) / file.processingFormat.sampleRate
        self.offset = min(max(offset, 0), duration)
        file.framePosition = AVAudioFramePosition(self.offset * file.processingFormat.sampleRate)
        expectedOutputFrames = Int64((Double(file.length - file.framePosition) * format.sampleRate / file.processingFormat.sampleRate).rounded())
        converter.primeMethod = .none
    }

    func read(maxChunks: Int) throws -> [AVAudioPCMBuffer] {
        var result: [AVAudioPCMBuffer] = []
        while result.count < maxChunks, !ended {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames) else { throw PlaybackError.unsupportedFormat }
            var error: NSError?
            var readError: Error?
            let status = converter.convert(to: output, error: &error) { [self] requested, inputStatus in
                guard !inputFinished else { inputStatus.pointee = .endOfStream; return nil }
                do {
                    let remaining = max(0, file.length - file.framePosition)
                    guard remaining > 0 else {
                        inputFinished = true; inputStatus.pointee = .endOfStream; return nil
                    }
                    let frames = min(input.frameCapacity, requested, AVAudioFrameCount(min(remaining, Int64(input.frameCapacity))))
                    try file.read(into: input, frameCount: frames)
                    if input.frameLength == 0 {
                        inputFinished = true; inputStatus.pointee = .endOfStream; return nil
                    }
                    inputStatus.pointee = .haveData
                    return input
                } catch {
                    readError = error; inputFinished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if status == .error { throw error ?? PlaybackError.conversion("変換エラー") }
            // A rate converter can flush filter tail beyond the source duration.
            // Bound each track to its actual sample count so its successor starts at the boundary.
            output.frameLength = AVAudioFrameCount(min(Int64(output.frameLength), max(0, expectedOutputFrames - emittedFrames)))
            if output.frameLength > 0 {
                emittedFrames += Int64(output.frameLength)
                result.append(output)
            }
            if status == .endOfStream || output.frameLength == 0 || emittedFrames >= expectedOutputFrames { ended = true }
        }
        return result
    }
}
