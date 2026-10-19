import AVFoundation
import CryptoKit
import Foundation
import MusicUnderstanding
import Observation
import OSLog

/// Derived results only. No streamed audio is retained on disk.
actor AppleMusicAnalysisCache {
    private let directory: URL
    private var retainedIDs: Set<String> = []
    private var tickets: [String: UUID] = [:]
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hazimeno.MusicPrayer/AppleMusicAnalysis", isDirectory: true)
    }
    private func filename(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }
    private func url(_ id: String) -> URL { directory.appendingPathComponent(filename(id)) }

    /// The queue owns these files. Invalidating a ticket also rejects a late save after removal/re-addition.
    func retainSongs(_ ids: Set<String>) throws {
        for id in retainedIDs.subtracting(ids) { tickets[id] = nil }
        retainedIDs = ids
        let keep = Set(ids.flatMap { [filename($0), lyricURL($0).lastPathComponent] })
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" && !keep.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }
    func ticket(for id: String) -> UUID? {
        guard retainedIDs.contains(id) else { return nil }
        if let ticket = tickets[id] { return ticket }
        let ticket = UUID(); tickets[id] = ticket; return ticket
    }
    func load(id: String, duration: Double) -> MusicAnalysis? {
        guard retainedIDs.contains(id), let data = try? Data(contentsOf: url(id)),
              let value = try? JSONDecoder().decode(MusicAnalysis.self, from: data),
              value.version == MusicAnalyzer.cacheVersion, value.fingerprint == "appleMusic:" + id,
              value.duration.isFinite, abs(value.duration - duration) < 1 else { return nil }
        return value
    }
    private func lyricURL(_ id: String) -> URL {
        directory.appendingPathComponent(String(filename(id).dropLast(5)) + ".lyrics.json")
    }

    func loadLyricTiming(for song: AppleMusicSong) -> AppleMusicLyricTiming? {
        guard retainedIDs.contains(song.id), let data = try? Data(contentsOf: lyricURL(song.id)),
              let value = try? JSONDecoder().decode(AppleMusicLyricTiming.self, from: data),
              value.isCurrent(for: song) else { return nil }
        return value
    }

    func invalidateLyricTiming(for song: AppleMusicSong) throws {
        guard retainedIDs.contains(song.id), FileManager.default.fileExists(atPath: lyricURL(song.id).path) else { return }
        try FileManager.default.removeItem(at: lyricURL(song.id))
    }

    @discardableResult
    func saveLyricTiming(_ value: AppleMusicLyricTiming, ticket: UUID) throws -> Bool {
        guard retainedIDs.contains(value.songID), tickets[value.songID] == ticket else { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: lyricURL(value.songID), options: .atomic)
        return true
    }
    @discardableResult
    func save(_ value: MusicAnalysis, id: String, ticket: UUID) throws -> Bool {
        guard retainedIDs.contains(id), tickets[id] == ticket else { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url(id), options: .atomic)
        return true
    }
}

/// A bounded handoff from the private audio callback queue to MusicUnderstanding.
/// The callback's borrowed buffers are copied before returning to CoreAudio.
final class AppleMusicAnalysisInput: @unchecked Sendable {
    let stream: AsyncStream<AVReadOnlyAudioPCMBuffer>
    private let continuation: AsyncStream<AVReadOnlyAudioPCMBuffer>.Continuation?
    private let lock = NSLock()
    private var position: Double?
    private var gain: Float = 1
    private var origin: Double?
    private var seconds: Double = 0
    private var valid = true
    private var finished = false
    init() {
        let pair = AsyncStream<AVReadOnlyAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingOldest(64))
        stream = pair.stream; continuation = pair.continuation
    }
    /// Prepared PCM is pulled by the same analyzer without filling the realtime handoff queue.
    init(prepared buffer: AVAudioPCMBuffer, origin: Double) {
        let cursor = PreparedAudioCursor(buffer)
        stream = AsyncStream(unfolding: { cursor.next() })
        continuation = nil
        self.origin = origin
        seconds = Double(buffer.frameLength) / buffer.format.sampleRate
    }

    func update(position: Double?, volume: Float) {
        lock.lock(); defer { lock.unlock() }
        self.position = position
        gain = volume > 0 ? 1 / volume : 1
    }
    func append(_ list: UnsafePointer<AudioBufferList>, sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, let position else { return }
        guard let buffer = Self.copy(list, sampleRate: sampleRate, gain: gain) else { valid = false; return }
        if origin == nil { origin = position }
        seconds += Double(buffer.frameLength) / sampleRate
        if case .dropped? = continuation?.yield(AVReadOnlyAudioPCMBuffer(copying: buffer)) {
            valid = false
        }
    }
    static func copy(_ list: UnsafePointer<AudioBufferList>, sampleRate: Double, gain: Float) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0, sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else { return nil }
        let frames = buffers.map { Int($0.mDataByteSize) / (MemoryLayout<Float>.size * max(1, Int($0.mNumberChannels))) }.min() ?? 0
        guard frames > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData else { return nil }
        output.frameLength = AVAudioFrameCount(frames)
        var outputChannel = 0
        for buffer in buffers {
            guard let source = buffer.mData?.assumingMemoryBound(to: Float.self) else { return nil }
            let count = Int(buffer.mNumberChannels)
            for channel in 0..<count {
                for frame in 0..<frames { destination[outputChannel][frame] = source[frame * count + channel] * gain }
                outputChannel += 1
            }
        }
        return output
    }
    func snapshot() -> (origin: Double, seconds: Double, valid: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (origin ?? 0, seconds, valid && origin != nil)
    }
    func finish() {
        lock.lock(); finished = true; position = nil; lock.unlock()
        continuation?.finish()
    }
}

private final class PreparedAudioCursor: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var offset = 0
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next() -> AVReadOnlyAudioPCMBuffer? {
        guard !Task.isCancelled, offset < Int(buffer.frameLength) else { return nil }
        let count = min(4096, Int(buffer.frameLength) - offset)
        guard let chunk = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        chunk.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(chunk.floatChannelData![channel], buffer.floatChannelData![channel] + offset, count * 4)
        }
        offset += count
        return AVReadOnlyAudioPCMBuffer(copying: chunk)
    }
}

@MainActor @Observable
final class AppleMusicAnalysis {
    private(set) var analysis: MusicAnalysis?
    private(set) var revision = 0
    private(set) var analyzing = false
    private(set) var error: String?
    private(set) var songID: String?
    @ObservationIgnored private let cache: AppleMusicAnalysisCache
    @ObservationIgnored private var input: AppleMusicAnalysisInput?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var song: AppleMusicSong?
    @ObservationIgnored private var completed = false
    @ObservationIgnored private var finishing = false
    @ObservationIgnored private var retainedIDs: Set<String> = []
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var queueRegistered = false
    @ObservationIgnored private var queueGeneration = UUID()
    @ObservationIgnored private var finishingTasks: [String: (generation: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var liveMomentary: TimeValue?
    @ObservationIgnored private var liveShortTerm: TimeValue?
    @ObservationIgnored private let managesQueueCache: Bool
    init(cache: AppleMusicAnalysisCache = AppleMusicAnalysisCache(), managesQueueCache: Bool = true) {
        self.cache = cache; self.managesQueueCache = managesQueueCache
    }
    var queueRegistration: Task<Void, Never>? { queueTask }

    func setQueueSongs(_ songs: [AppleMusicSong], after registration: Task<Void, Never>? = nil) {
        let ids = Set(songs.map(\.id))
        guard !queueRegistered || ids != retainedIDs else { return }
        queueRegistered = true; retainedIDs = ids
        for (id, work) in finishingTasks where !ids.contains(id) { work.task.cancel() }
        if let songID, !ids.contains(songID) {
            interrupt()
            analysis = nil; revision += 1; completed = false; self.songID = nil; song = nil
        }
        let previous = queueTask
        let token = UUID(); queueGeneration = token
        let managesQueueCache = self.managesQueueCache
        queueTask = Task { [weak self, cache] in
            defer { if self?.queueGeneration == token { self?.queueTask = nil } }
            await previous?.value
            await registration?.value
            guard managesQueueCache else { return }
            do { try await cache.retainSongs(ids) }
            catch {
                self?.error = "一覧から外した曲の解析結果を整理できませんでした：" + error.localizedDescription
            }
        }
    }

    var needsStorageBeforeTermination: Bool { queueTask != nil || !finishingTasks.isEmpty }

    func finishStorageBeforeTermination() async {
        while needsStorageBeforeTermination {
            await queueTask?.value
            let pending = finishingTasks.values.map(\.task)
            for task in pending { await task.value }
        }
    }

    func stopUnfinishedAnalysis() {
        // Completed results and a natural-end finalization remain available after Stop.
        if input != nil { interrupt() }
    }

    func select(_ song: AppleMusicSong, force: Bool = false) {
        guard retainedIDs.contains(song.id) else { return }
        if !force, songID == song.id, (completed || finishing),
           abs((self.song?.duration ?? 0) - song.duration) < 1 { return }
        cancel()
        self.song = song; songID = song.id
        analysis = nil; revision += 1; analyzing = false; error = nil; completed = false
        liveMomentary = nil; liveShortTerm = nil
        let token = generation
        if force { return }
        let queueUpdate = queueTask
        let pending = finishingTasks[song.id]?.task
        loadTask = Task { [weak self, cache] in
            await queueUpdate?.value
            await pending?.value
            let cached = await cache.load(id: song.id, duration: song.duration)
            guard let self, self.generation == token else { return }
            self.loadTask = nil
            guard let cached, self.input == nil else { return }
            self.analysis = cached; self.completed = true; self.revision += 1
        }
    }

    /// Reuse the same cache/load ordering before deciding whether a silent pass is needed.
    func loadSavedAnalysis(for song: AppleMusicSong) async -> Bool {
        select(song)
        await loadTask?.value
        return songID == song.id && completed
    }

    func refreshSavedAnalysis(for song: AppleMusicSong) {
        guard songID == song.id else { return }
        select(song, force: true)
        select(song)
    }

    /// Pauses preserve the provider; seeks start a new contiguous excerpt.
    func update(position: Double, isPlaying: Bool, volume: Float) -> AppleMusicAnalysisInput? {
        guard let song, !completed, !finishing else { return nil }
        if volume <= 0 {
            if input != nil { interrupt() }
            return nil
        }
        if input == nil, task == nil, loadTask == nil, isPlaying {
            start(song)
        }
        // A playing state can precede the first advancing media clock. Exclude that preparation silence.
        input?.update(position: isPlaying && position > 0 ? position : nil, volume: volume)
        return input
    }

    func interrupt() {
        cancel()
        analyzing = false
        liveMomentary = nil; liveShortTerm = nil
    }

    func finish() {
        guard input != nil else { return }
        finishing = true
        input?.finish(); input = nil
        if let task, let songID { finishingTasks[songID] = (generation, task) }
        task = nil
    }

    func liveLevels(at time: Double) -> (momentary: Float?, shortTerm: Float?) {
        func fresh(_ value: TimeValue?) -> Float? {
            guard let value, time >= value.time, time - value.time < 0.5 else { return nil }
            return value.value
        }
        return (fresh(liveMomentary), fresh(liveShortTerm))
    }

    private func cancel() {
        generation = UUID(); finishing = false
        loadTask?.cancel(); loadTask = nil
        input?.finish(); input = nil
        task?.cancel(); task = nil
    }

    func analyzePreparedAudio(_ buffer: AVAudioPCMBuffer, origin: Double) async {
        guard let song, !completed else { return }
        start(song, input: AppleMusicAnalysisInput(prepared: buffer, origin: origin))
        finish()
        await finishStorageBeforeTermination()
    }

    private func start(_ song: AppleMusicSong, input: AppleMusicAnalysisInput = AppleMusicAnalysisInput()) {
        loadTask?.cancel(); loadTask = nil
        self.input = input; analyzing = true; error = nil
        analysis = nil; liveMomentary = nil; liveShortTerm = nil; revision += 1
        let token = generation
        let queueUpdate = queueTask
        task = Task { [weak self, cache] in
            defer {
                if self?.finishingTasks[song.id]?.generation == token { self?.finishingTasks[song.id] = nil }
            }
            await queueUpdate?.value
            guard let ticket = await cache.ticket(for: song.id), !Task.isCancelled else { input.finish(); return }
            let session = MusicUnderstandingSession(audioProvider: input.stream)
            let levels = Task { @MainActor [weak self] in
                do {
                    for try await result in session.loudnessResults {
                        guard let self, self.generation == token else { return }
                        self.publish(result, origin: input.snapshot().origin, duration: song.duration, id: song.id)
                    }
                } catch { /* The analyze task owns error reporting. */ }
            }
            defer { levels.cancel() }
            do {
                let result = try await withTaskCancellationHandler {
                    try await session.analyze(for: [.key, .rhythm, .structure, .pace, .instrumentActivity, .loudness])
                } onCancel: { Task { await session.cancel() } }
                try Task.checkCancellation()
                let coverage = input.snapshot()
                guard coverage.valid else { throw AnalysisInputError.missingAudio }
                var value = MusicAnalyzer.convert(result, duration: song.duration, fingerprint: "appleMusic:" + song.id)
                value.shiftTimes(by: coverage.origin)
                // Preserve every successful contiguous excerpt, including a tap that starts late.
                // Ranges retain their actual start; no observations are invented before that point.
                do {
                    guard try await cache.save(value, id: song.id, ticket: ticket) else { return }
                } catch {
                    Logger(subsystem: "com.hazimeno.MusicPrayer", category: "AnalysisCache").error("Apple Music analysis cache: \(error.localizedDescription, privacy: .public)")
                    if self?.songID == song.id { self?.error = "解析結果を保存できませんでした：" + error.localizedDescription }
                }
                guard let self, self.retainedIDs.contains(song.id), self.songID == song.id,
                      abs((self.song?.duration ?? 0) - song.duration) < 1 else { return }
                if self.generation != token { self.cancel() }
                self.analysis = value; self.completed = true; self.analyzing = false; self.revision += 1
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                input.finish(); self.input = nil
                self.error = error.localizedDescription; self.analyzing = false
            }
        }
    }

    private func publish(_ result: LoudnessResult, origin: Double, duration: Double, id: String) {
        let momentary = MusicAnalyzer.values(result.momentary).map { TimeValue(time: $0.time + origin, value: $0.value) }
        let shortTerm = MusicAnalyzer.values(result.shortTerm).map { TimeValue(time: $0.time + origin, value: $0.value) }
        if analysis == nil { analysis = MusicAnalysis(fingerprint: "appleMusic:" + id, duration: duration) }
        // Streaming results contain the latest measurements, not the complete history.
        if let last = momentary.last { liveMomentary = last }
        if let last = shortTerm.last { liveShortTerm = last }
        let lastMomentary = analysis?.momentary.last?.time ?? -1
        let lastShortTerm = analysis?.shortTerm.last?.time ?? -1
        analysis?.momentary.append(contentsOf: momentary.filter { $0.time > lastMomentary })
        analysis?.shortTerm.append(contentsOf: shortTerm.filter { $0.time > lastShortTerm })
        analysis?.integrated = result.integrated.value.isFinite ? result.integrated.value : nil
        revision += 1
    }
}

private enum AnalysisInputError: LocalizedError {
    case missingAudio
    var errorDescription: String? { "解析中に音声入力が欠落したため、結果を保存できませんでした。" }
}

extension MusicAnalysis {
    mutating func shiftTimes(by offset: Double) {
        func spans(_ spans: [TimeSpan]) -> [TimeSpan] { spans.map { TimeSpan(start: $0.start + offset, duration: $0.duration) } }
        func values(_ values: [TimeValue]) -> [TimeValue] { values.map { TimeValue(time: $0.time + offset, value: $0.value) } }
        beats = beats.map { $0 + offset }; bars = bars.map { $0 + offset }
        sections = spans(sections); segments = spans(segments); phrases = spans(phrases)
        pace = pace.map { PaceSpan(range: TimeSpan(start: $0.range.start + offset, duration: $0.range.duration), value: $0.value) }
        keys = keys.map { KeySpan(range: TimeSpan(start: $0.range.start + offset, duration: $0.range.duration), label: $0.label, hue: $0.hue, minor: $0.minor) }
        vocal = values(vocal); drums = values(drums); bass = values(bass); other = values(other)
        instrumentRanges = InstrumentRanges(vocal: spans(instrumentRanges.vocal), drums: spans(instrumentRanges.drums), bass: spans(instrumentRanges.bass), other: spans(instrumentRanges.other))
        momentary = values(momentary); shortTerm = values(shortTerm)
        if let measured = peak { peak = TimeValue(time: measured.time + offset, value: measured.value) }
    }
}
