import AppKit
import AVFoundation
import Observation
import OSLog
import WebKit

@MainActor @Observable
final class AppleMusicStore: NSObject {
    var errorMessage: String?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var playback = AppleMusicPlayback()
    private(set) var workerPhase = AppleMusicPreanalysis.Phase.preparing
    private(set) var workerPosition: Double = 0
    var audioCaptureError: String?
    let musicAnalysis: AppleMusicAnalysis
    let preanalysis = AppleMusicPreanalysis()
    @ObservationIgnored private let analysisCache: AppleMusicAnalysisCache
    @ObservationIgnored private let silentAnalysis: AppleMusicAnalysis
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private let isOfficialBrowser: Bool
    @ObservationIgnored private let websiteDataStore: WKWebsiteDataStore
    @ObservationIgnored private var workerAudioPIDs: [UUID: Int32] = [:]
    @ObservationIgnored private let workerStartup = AppleMusicWorkerStartupGate()
    init(analysisDirectory: URL? = nil, websiteDataStore: WKWebsiteDataStore? = nil, usesAnalysisWorkers: Bool = true, isOfficialBrowser: Bool = false) {
        self.isOfficialBrowser = isOfficialBrowser
        self.websiteDataStore = websiteDataStore ?? .default()
        let cache = AppleMusicAnalysisCache(directory: analysisDirectory)
        analysisCache = cache
        musicAnalysis = AppleMusicAnalysis(cache: cache)
        silentAnalysis = AppleMusicAnalysis(cache: cache, managesQueueCache: false)
        super.init()
        // Capture the host baseline before either native or browsing WebView creates its shared GPU.
        audioCapture.prepareForWebView()
        guard usesAnalysisWorkers else { return }
        preanalysis.operation = { [weak self] song in
            guard let self else { throw CancellationError() }
            await self.musicAnalysis.queueRegistration?.value
            let savedAnalysis = await cache.load(id: song.id, duration: song.duration)
            if savedAnalysis != nil, let savedTiming = await cache.loadLyricTiming(for: song) {
                let needsUntimedVerification = savedTiming.hasLyrics == true &&
                    savedTiming.hasOfficialUntimedLyrics == nil &&
                    savedTiming.usesOfficialWordTimings != true &&
                    savedTiming.derivedLines == nil
                if savedTiming.completion != .missingLyrics && !needsUntimedVerification {
                    guard let ticket = await cache.ticket(for: song.id) else { throw CancellationError() }
                    let prepared = try await self.preparingReadings(for: savedTiming, song: song)
                    try Task.checkCancellation()
                    if prepared.readings != savedTiming.readings {
                        guard try await cache.saveLyricTiming(prepared, ticket: ticket) else { throw CancellationError() }
                    }
                    await self.refreshLyricTiming(for: song)
                    return prepared.completion
                }
                // Verify old unknown outcomes and generated timelines against
                // the official lyric document without replaying saved music.
                guard let ticket = await cache.ticket(for: song.id) else { throw CancellationError() }
                do {
                    let source = try await self.fetchLyrics(for: song)
                    if source == nil || source?.lines.isEmpty == true ||
                        (source?.lines.allSatisfy(\.hasValidCharacterTimings) == true) {
                        let verified = AppleMusicLyricTiming(songID: song.id, duration: song.duration,
                            sourceText: source?.text ?? "", hasLyrics: source != nil,
                            usesOfficialWordTimings: source?.lines.isEmpty == false,
                            hasOfficialUntimedLyrics: source?.lines.isEmpty == true)
                        let prepared = try await self.preparingReadings(for: verified, song: song, source: source)
                        guard try await cache.saveLyricTiming(prepared, ticket: ticket) else { throw CancellationError() }
                        await self.refreshLyricTiming(for: song)
                        return verified.completion
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    var failed = savedTiming
                    failed.errorMessage = error.localizedDescription
                    guard try await cache.saveLyricTiming(failed, ticket: ticket) else { throw CancellationError() }
                    await self.refreshLyricTiming(for: song)
                    return failed.completion
                }
            }
            guard let ticket = await cache.ticket(for: song.id) else { throw CancellationError() }
            let session = try await AppleMusicWorkerSession.capture(from: self.websiteDataStore)
            let permit = try await self.workerStartup.acquire()
            defer {
                self.workerStartup.release(permit)
                self.workerAudioPIDs[permit] = nil
                self.audioCapture.setExcludedProcesses(Set(self.workerAudioPIDs.values))
            }
            if self.webView != nil { _ = try await self.audioCapture.identifyProcess() }
            try Task.checkCancellation()
            let result = try await AppleMusicAnalysisWorker.run(song: song, session: session, existingAnalysis: savedAnalysis,
                onProgress: { [weak self] phase, position in
                    self?.preanalysis.update(songID: song.id, phase: phase, position: position)
                }, onReady: { [weak self] pid in
                    guard let self else { return }
                    self.workerAudioPIDs[permit] = pid
                    self.audioCapture.setExcludedProcesses(Set(self.workerAudioPIDs.values))
                    self.workerStartup.release(permit)
                })
            try Task.checkCancellation()
            let prepared = try await self.preparingReadings(for: result.lyricTiming, song: song)
            try Task.checkCancellation()
            guard try await cache.save(result.analysis, id: song.id, ticket: ticket),
                  try await cache.saveLyricTiming(prepared, ticket: ticket) else { throw CancellationError() }
            let rows = prepared.derivedLines ?? prepared.timeline?.lines ?? []
            Logger(subsystem: "com.hazimeno.MusicPrayer", category: "AppleMusicLyrics").notice("Saved song=\(song.id, privacy: .public) rows=\(rows.count) timed=\(rows.filter(\.hasValidCharacterTimings).count)")
            self.musicAnalysis.refreshSavedAnalysis(for: song)
            await self.refreshLyricTiming(for: song)
            return prepared.completion
        }
    }
    private(set) var artworkData: Data?
    @ObservationIgnored private let audioCapture = AppleMusicAudioCapture()
    @ObservationIgnored private var audioCaptureFailed = false
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    var searchText = ""
    private(set) var searchResults: [AppleMusicSong] = []
    private(set) var isSearching = false
    private(set) var hasSearched = false
    private(set) var searchError: String?
    private(set) var startingSongID: String?
    @ObservationIgnored private var searchGeneration: UInt64 = 0
    @ObservationIgnored private var selectedSong: AppleMusicSong?
    private(set) var lyrics: AppleMusicLyrics?
    private(set) var lyricTimingMessage: String?
    private var lyricTimingFailure: String?
    var lyricRetryTitle: String { sourceLyrics == nil ? "歌詞を再取得" : "解析をやり直す" }
    var lyricTimingError: String? {
        guard let selectedSong else { return nil }
        guard let sourceLyrics else { return lyricTimingFailure }
        guard !sourceLyrics.lines.isEmpty else { return nil }
        guard
              lyrics == nil || sourceLyrics.lines.isEmpty || !sourceLyrics.lines.allSatisfy(\.hasValidCharacterTimings),
              lyrics == nil || lyrics?.lines == sourceLyrics.lines else { return nil }
        return lyricTimingFailure ?? preanalysis.errors[selectedSong.id].map { "歌詞の時刻を解析できませんでした：" + $0 }
    }
    var lyricTimingStatus: String? {
        guard selectedSong != nil, lyricTimingError == nil else { return nil }
        guard let sourceLyrics else { return lyricTimingMessage }
        guard !sourceLyrics.lines.isEmpty else { return nil }
        guard
              lyrics == nil || sourceLyrics.lines.isEmpty || !sourceLyrics.lines.allSatisfy(\.hasValidCharacterTimings),
              lyrics == nil || lyrics?.lines == sourceLyrics.lines else { return nil }
        return lyricTimingMessage
    }
    @ObservationIgnored private var sourceLyrics: AppleMusicLyrics?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsGeneration: UInt64 = 0

    func setQueueSongs(_ songs: [AppleMusicSong]) {
        musicAnalysis.setQueueSongs(songs)
        silentAnalysis.setQueueSongs(songs, after: musicAnalysis.queueRegistration)
        preanalysis.setSongs(songs)
    }

    func startPreanalysisIfReady(connectionReady: Bool = false) {
        guard !stopping, connectionReady || (webView != nil && playback.isReady) else { return }
        preanalysis.setAllowed(true)
    }

    var needsStorageBeforeTermination: Bool {
        preanalysis.isWorking || musicAnalysis.needsStorageBeforeTermination || silentAnalysis.needsStorageBeforeTermination
    }

    func finishStorageBeforeTermination() async {
        stopping = true
        await preanalysis.yieldToPlayback()
        await silentAnalysis.finishStorageBeforeTermination()
        await musicAnalysis.finishStorageBeforeTermination()
    }

    func audioFeatures(isPlaying: Bool) -> AudioFeatures {
        let input = musicAnalysis.update(position: playback.time, isPlaying: isPlaying && !playbackSuspended, volume: desiredVolume)
        audioCapture.setAnalysisInput(input)
        guard isPlaying, !playbackSuspended else {
            audioCapture.stop()
            return AudioFeatures()
        }
        if !audioCaptureFailed {
            audioCapture.update { [weak self] error in
                guard let self, !self.playbackSuspended, self.playback.isPlaying else { return }
                self.audioCaptureFailed = true
                self.audioCaptureError = "ビジュアライザー用の音を取得できませんでした。\(error.localizedDescription)"
            }
        }
        return audioCapture.features()
    }

    func stopPlayback() {
        if playback.ended { finishAnalysis() }
        else { musicAnalysis.stopUnfinishedAnalysis(); audioCapture.setAnalysisInput(nil) }
        audioCapture.stop()
        let pendingSong = songTask
        guard pendingSong != nil else { command("stop"); return }
        bridgeGeneration &+= 1
        let generation = bridgeGeneration
        Task { [weak self] in
            _ = await pendingSong?.value
            guard let self, self.bridgeGeneration == generation else { return }
            self.command("stop")
        }
    }

    func finishAnalysis() {
        audioCapture.setAnalysisInput(nil)
        musicAnalysis.finish()
    }

    private func loadArtwork(for song: AppleMusicSong) {
        artworkTask?.cancel()
        artworkData = nil
        guard let value = song.artworkURL, let url = URL(string: value) else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled, let self, self.selectedSong?.id == song.id else { return }
            self.artworkData = data
        }
    }

    private func loadLyrics(for song: AppleMusicSong) {
        lyricsGeneration &+= 1
        let generation = lyricsGeneration
        lyricsTask?.cancel()
        lyrics = nil
        sourceLyrics = nil
        lyricTimingMessage = "歌詞を取得しています"
        lyricTimingFailure = nil
        lyricsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.lyricsGeneration {
                    self.lyricsTask = nil
                }
            }
            do {
                let fetched = try await self.fetchLyrics(for: song)
                guard !Task.isCancelled, generation == self.lyricsGeneration,
                      self.selectedSong?.id == song.id else { return }
                self.sourceLyrics = fetched
                self.lyrics = fetched
                self.lyricTimingMessage = fetched == nil ? "この曲の歌詞はApple Musicで配信されていません。" : nil
                Logger(subsystem: "com.hazimeno.MusicPrayer", category: "AppleMusicLyrics").notice("Loaded song=\(song.id, privacy: .public) lines=\(fetched?.lines.count ?? 0) timed=\(fetched?.lines.filter(\.hasValidCharacterTimings).count ?? 0)")
                // These responses need no audio recognition. Persist the verified
                // outcome even when this fetch follows a failed lyric request.
                if fetched == nil || fetched?.lines.isEmpty == true ||
                    (fetched?.lines.allSatisfy(\.hasValidCharacterTimings) == true) {
                    await self.musicAnalysis.queueRegistration?.value
                    if await self.analysisCache.load(id: song.id, duration: song.duration) != nil,
                       let ticket = await self.analysisCache.ticket(for: song.id) {
                        guard !Task.isCancelled, generation == self.lyricsGeneration,
                              self.selectedSong?.id == song.id else { return }
                        var verified = AppleMusicLyricTiming(songID: song.id, duration: song.duration,
                            sourceText: fetched?.text ?? "", hasLyrics: fetched != nil,
                            usesOfficialWordTimings: fetched?.lines.isEmpty == false,
                            hasOfficialUntimedLyrics: fetched?.lines.isEmpty == true)
                        let existing = await self.analysisCache.loadLyricTiming(for: song)
                        if existing?.sourceText == verified.sourceText {
                            verified.readings = existing?.readings
                        }
                        guard try await self.analysisCache.saveLyricTiming(verified, ticket: ticket) else { return }
                        guard !Task.isCancelled, generation == self.lyricsGeneration,
                              self.selectedSong?.id == song.id else { return }
                        if !self.preanalysis.isAnalyzing(songID: song.id) {
                            self.preanalysis.retry(songID: song.id)
                        }
                    }
                }
                await self.refreshLyricTiming(for: song)
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, generation == self.lyricsGeneration,
                      self.selectedSong?.id == song.id else { return }
                self.lyricTimingMessage = nil
                self.lyricTimingFailure = "歌詞を取得できませんでした：" + error.localizedDescription
                Logger(subsystem: "com.hazimeno.MusicPrayer", category: "AppleMusicLyrics").error("Fetch failed song=\(song.id, privacy: .public) domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            }
        }
    }

    private func fetchLyrics(for song: AppleMusicSong) async throws -> AppleMusicLyrics? {
        guard let response = try await evaluateValue("lyrics", value: song.id) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return try AppleMusicLyricsParser.parseResponse(response, songID: song.id)
    }

    /// Called only by preanalysis, before the timing cache is saved and completed.
    private func preparingReadings(for timing: AppleMusicLyricTiming, song: AppleMusicSong,
                                  source: AppleMusicLyrics? = nil) async throws -> AppleMusicLyricTiming {
        guard !timing.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return timing }
        var result = timing
        var lines = timing.derivedLines ?? timing.timeline?.lines
        let source = source ?? (sourceLyrics?.songID == song.id ? sourceLyrics : nil)
        if let readings = timing.readings, readings.isCurrent(sourceText: timing.sourceText),
           readings.readings(for: timing.sourceText) != nil,
           (lines ?? []).allSatisfy({ readings.readings(for: $0.text) != nil }),
           source == nil || (source?.text == timing.sourceText &&
               source!.lines.allSatisfy({ readings.readings(for: $0.text) != nil })) { return timing }
        if lines == nil {
            let fetched: AppleMusicLyrics?
            if let source { fetched = source }
            else { fetched = try await fetchLyrics(for: song) }
            guard let fetched, fetched.text == timing.sourceText else {
                throw LyricAlignmentError.inconsistentSavedData
            }
            lines = fetched.lines
        }
        result.readings = try await LyricReadingResolver.shared.prepare(sourceText: timing.sourceText,
            lines: [timing.sourceText] + (lines ?? []).map(\.text), existing: timing.readings)
        try Task.checkCancellation()
        return result
    }

    private func refreshLyricTiming(for song: AppleMusicSong) async {
        let generation = lyricsGeneration
        let timing = await analysisCache.loadLyricTiming(for: song)
        let analysis = await analysisCache.load(id: song.id, duration: song.duration)
        guard generation == lyricsGeneration, selectedSong?.id == song.id,
              let source = sourceLyrics, source.songID == song.id else { return }
        if source.lines.isEmpty {
            lyrics = timing?.applyingReadings(to: source) ?? source
            lyricTimingMessage = nil
            lyricTimingFailure = nil
            return
        }
        let recognized = timing.flatMap { timing in
            analysis.flatMap { timing.applying(to: source, song: song, analysis: $0) }
        }
        let display = recognized ?? source
        let prepared = timing?.applyingReadings(to: display)
        lyrics = prepared ?? display
        if prepared == nil, !preanalysis.isAnalyzing(songID: song.id) {
            preanalysis.retry(songID: song.id)
        }
        if lyrics != nil, recognized != nil || (!source.lines.isEmpty && source.lines.allSatisfy(\.hasValidCharacterTimings)) {
            lyricTimingMessage = nil
            lyricTimingFailure = nil
        } else if let timing, timing.sourceText == source.text, let error = timing.errorMessage {
            lyricTimingMessage = nil
            lyricTimingFailure = "歌詞の同期を生成できませんでした：" + error
        } else {
            lyricTimingMessage = lyrics == nil ? "歌詞の読みを準備しています" : "音声から歌詞の時刻を解析しています"
            lyricTimingFailure = nil
            if let timing, timing.sourceText != source.text ||
                (recognized == nil && !source.lines.allSatisfy(\.hasValidCharacterTimings) && lyrics != nil) {
                do {
                    try await analysisCache.invalidateLyricTiming(for: song)
                    guard generation == lyricsGeneration, selectedSong?.id == song.id else { return }
                    preanalysis.retry(songID: song.id)
                } catch {
                    guard generation == lyricsGeneration, selectedSong?.id == song.id else { return }
                    lyricTimingMessage = nil
                    lyricTimingFailure = "歌詞の時刻を更新できませんでした。"
                }
            } else if !preanalysis.isAnalyzing(songID: song.id) {
                preanalysis.retry(songID: song.id)
            }
        }
    }

    /// Retry only lyric timing; keep the existing music analysis available.
    func retryLyricTiming() {
        guard !stopping, let song = selectedSong else { return }
        guard sourceLyrics?.lines.isEmpty != true else { return }
        let source = sourceLyrics
        lyricsGeneration &+= 1
        let generation = lyricsGeneration
        lyricsTask?.cancel()
        lyrics = source
        lyricTimingMessage = source == nil ? "歌詞を取得しています" : "音声から歌詞の時刻を解析しています"
        lyricTimingFailure = nil
        lyricsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == self.lyricsGeneration { self.lyricsTask = nil } }
            do {
                try await self.analysisCache.invalidateLyricTiming(for: song)
                guard !Task.isCancelled, generation == self.lyricsGeneration,
                      self.selectedSong?.id == song.id else { return }
                if source == nil {
                    self.lyricsTask = nil
                    self.loadLyrics(for: song)
                } else {
                    self.preanalysis.retry(songID: song.id)
                }
            } catch {
                guard !Task.isCancelled, generation == self.lyricsGeneration,
                      self.selectedSong?.id == song.id else { return }
                self.lyricTimingMessage = nil
                self.lyricTimingFailure = "歌詞の時刻を更新できませんでした。"
            }
        }
    }

    private func withCatalogMetadata(_ snapshot: AppleMusicPlayback) -> AppleMusicPlayback {
        guard let song = selectedSong, snapshot.id == song.id else { return snapshot }
        var snapshot = snapshot
        snapshot.title = song.title
        snapshot.artist = song.artist
        snapshot.artworkURL = song.artworkURL
        return snapshot
    }

    func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration &+= 1
        let generation = searchGeneration
        searchResults = []
        searchError = nil
        hasSearched = false
        guard !query.isEmpty else { isSearching = false; return }
        isSearching = true
        do {
            guard let result = try await evaluateValue("search", value: query), !(result is NSNull) else {
                throw URLError(.cannotParseResponse)
            }
            let songs = try JSONDecoder().decode(AppleMusicSearchResult.self,
                from: JSONSerialization.data(withJSONObject: result)).songs
            guard generation == searchGeneration else { return }
            searchResults = songs
            hasSearched = true
        } catch {
            guard generation == searchGeneration else { return }
            searchError = "曲を検索できませんでした。接続状態を確認し、もう一度検索してください。"
        }
        if generation == searchGeneration { isSearching = false }
    }

    func cancelSearch() {
        searchGeneration &+= 1
        isSearching = false
    }

    func currentBrowserSong() async throws -> AppleMusicSong? {
        guard let result = try await evaluateValue("currentSong"), !(result is NSNull) else {
            throw URLError(.resourceUnavailable)
        }
        return try JSONDecoder().decode(AppleMusicSearchResult.self,
            from: JSONSerialization.data(withJSONObject: result)).songs.first
    }

    func analyzeInWorker(_ song: AppleMusicSong, existingAnalysis: MusicAnalysis? = nil,
                         onReady: @MainActor (Int32) -> Void) async throws -> AppleMusicWorkerResult {
        setQueueSongs([song])
        await silentAnalysis.finishStorageBeforeTermination()
        silentAnalysis.select(song, force: true)
        var lyrics: AppleMusicLyrics?
        var lyricError: String?
        do { lyrics = try await fetchLyrics(for: song) }
        catch is CancellationError { throw CancellationError() }
        catch { lyricError = error.localizedDescription }
        try Task.checkCancellation()
        var result: AppleMusicWorkerResult
        if let existingAnalysis, lyrics == nil || lyrics?.lines.isEmpty == true ||
            (lyrics?.lines.allSatisfy(\.hasValidCharacterTimings) == true) {
            result = AppleMusicWorkerResult(analysis: existingAnalysis,
                lyricTiming: AppleMusicLyricTiming(songID: song.id, duration: song.duration,
                    sourceText: lyrics?.text ?? "", timeline: nil, errorMessage: lyricError,
                    hasLyrics: lyricError == nil ? (lyrics != nil) : nil,
                    usesOfficialWordTimings: lyrics?.lines.isEmpty == false,
                    hasOfficialUntimedLyrics: lyrics?.lines.isEmpty == true))
        } else {
            result = try await analyzeSilently(song, lyrics: lyrics, existingAnalysis: existingAnalysis, onReady: onReady)
        }
        if let lyricError {
            result.lyricTiming.errorMessage = lyricError
            result.lyricTiming.hasLyrics = nil
        }
        // The worker owns the fetched document; the parent may be playing a local file with no WebView.
        result.lyricTiming = try await preparingReadings(for: result.lyricTiming, song: song, source: lyrics)
        return result
    }

    func playSong(_ song: AppleMusicSong, autoplay: Bool = true) async -> Bool {
        guard !playbackSuspended, startingSongID == nil else { return false }
        startingSongID = song.id
        bridgeGeneration &+= 1
        let generation = bridgeGeneration
        let previousCommand = commandTask
        let task = Task { @MainActor [weak self] () -> Bool in
            defer { self?.startingSongID = nil; self?.songTask = nil }
            await previousCommand?.value
            guard let self, !self.playbackSuspended, generation == self.bridgeGeneration else { return false }
            self.commandTask = nil
            do {
                let value = try await self.evaluateValue(autoplay ? "playSong" : "prepareSong", value: song.id)
                guard !self.playbackSuspended, generation == self.bridgeGeneration else { return false }
                self.selectedSong = song
                self.playback = self.withCatalogMetadata(try AppleMusicBridge.decode(value))
                guard self.playback.available || self.playback.isPlaying || !autoplay else { throw URLError(.cannotParseResponse) }
                self.searchError = nil
                self.errorMessage = nil
                self.musicAnalysis.select(song)
                self.audioCapture.reset()
                self.loadArtwork(for: song)
                self.loadLyrics(for: song)
                Logger(subsystem: "com.hazimeno.MusicPrayer", category: "AppleMusicLyrics").notice("Selected song=\(song.id, privacy: .public) ready=\(self.playback.isReady) authorized=\(self.playback.isAuthorized)")
                return true
            } catch {
                guard generation == self.bridgeGeneration else { return false }
                self.searchError = "曲の再生を開始できませんでした。もう一度再生してください。"
                return false
            }
        }
        songTask = task
        return await task.value
    }

    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var backNavigationObservation: NSKeyValueObservation?
    @ObservationIgnored private var popupWindows: [ObjectIdentifier: NSWindow] = [:]
    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    @ObservationIgnored private var mediaGeneration: UInt64 = 0
    @ObservationIgnored private var playbackSuspended = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var songTask: Task<Bool, Never>?
    @ObservationIgnored private var lastPoll = Date.distantPast
    @ObservationIgnored private var bridgeGeneration: UInt64 = 0
    @ObservationIgnored private var desiredVolume: Float = 0.75

    func setVolume(_ value: Float) {
        desiredVolume = value
        audioCapture.setPlaybackVolume(value)
        command("volume", value: Double(value))
    }

    func pollPlayback() {
        guard webView != nil, pollTask == nil, commandTask == nil, startingSongID == nil,
              Date().timeIntervalSince(lastPoll) >= (playback.isPlaying ? 1.0 / 30.0 : 0.5) else { return }
        lastPoll = Date()
        let generation = bridgeGeneration
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pollTask = nil }
            do {
                let snapshot = try await self.evaluate(self.isOfficialBrowser ? "browserSnapshot" : "snapshot")
                if generation == self.bridgeGeneration { self.playback = self.withCatalogMetadata(snapshot) }
            } catch {
                // Navigation can invalidate a poll. The next poll reads the new page.
                if generation == self.bridgeGeneration { self.playback = AppleMusicPlayback() }
            }
        }
    }

    func command(_ name: String, value: Double = 0) {
        if name == "seek" { musicAnalysis.interrupt(); audioCapture.setAnalysisInput(nil) }
        guard webView != nil, !playbackSuspended, startingSongID == nil else { return }
        if name == "toggle", !playback.isPlaying {
            audioCaptureFailed = false
            audioCaptureError = nil
        }
        bridgeGeneration &+= 1
        let generation = bridgeGeneration
        let previous = commandTask
        commandTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            guard !self.playbackSuspended else { return }
            do {
                let snapshot = try await self.evaluate(name, value: value)
                if generation == self.bridgeGeneration {
                    self.playback = self.withCatalogMetadata(snapshot)
                    self.errorMessage = nil
                }
            } catch {
                if generation == self.bridgeGeneration {
                    self.errorMessage = "Apple Musicの再生操作に失敗しました。もう一度再生してください。"
                }
            }
            if generation == self.bridgeGeneration { self.commandTask = nil }
        }
    }

    private func analyzeSilently(_ song: AppleMusicSong, lyrics: AppleMusicLyrics?, existingAnalysis: MusicAnalysis?,
                                 onReady: @MainActor (Int32) -> Void) async throws -> AppleMusicWorkerResult {
        let pendingPoll = pollTask, pendingCommand = commandTask, pendingSong = songTask
        await pendingPoll?.value
        try Task.checkCancellation()
        await pendingCommand?.value
        try Task.checkCancellation()
        _ = await pendingSong?.value
        try Task.checkCancellation()
        let restoreSong = selectedSong
        let restorePosition = playback.ended ? 0 : playback.time
        var failure: Error?
        var result: AppleMusicWorkerResult?
        let recording = AppleMusicPCMRecording(volume: 0.12)
        do {
            // Warm the existing media process at volume zero. Raise gain only after the muted tap is ready.
            try await audioCapture.setMuted(true)
            _ = try await evaluate("volume", value: 0)
            _ = try await evaluateValue("playSong", value: song.id)
            var ready = false
            for _ in 0..<100 {
                try Task.checkCancellation()
                if try await audioCapture.prepareMutedCapture() { ready = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard ready else { throw SilentAnalysisError.noAudioProcess }
            guard let processID = await audioCapture.capturedProcessID() else { throw SilentAnalysisError.noAudioProcess }
            onReady(processID)
            _ = try await evaluate("pause")
            _ = try await evaluate("seek", value: 0)
            audioCapture.reset()
            audioCapture.setPlaybackVolume(0.12)
            audioCapture.setRecording(recording)
            _ = try await evaluate("analysisRate", value: 2)
            try Task.checkCancellation()
            _ = try await evaluate("volume", value: 0.12)
            _ = try await evaluate("toggle")
            _ = try await evaluate("analysisRate", value: 2)
            workerPhase = .capturing
            let began = Date()
            while true {
                try Task.checkCancellation()
                let state = try await evaluate("snapshot", value: 0.12)
                guard state.id == song.id else { throw SilentAnalysisError.noAudio }
                if state.ended {
                    audioCapture.setRecording(nil)
                    workerPosition = song.duration
                    workerPhase = .analyzing
                    let captured = try recording.takeAudio(endingAt: song.duration)
                    let expansion = Task.detached(priority: .utility) {
                        try AppleMusicTimeExpansion.expand(captured.buffer)
                    }
                    let restored = try await withTaskCancellationHandler {
                        try await expansion.value
                    } onCancel: { expansion.cancel() }
                    try Task.checkCancellation()
                    if existingAnalysis == nil {
                        await silentAnalysis.analyzePreparedAudio(restored, origin: captured.origin)
                    }
                    try Task.checkCancellation()
                    if let error = silentAnalysis.error { throw SilentAnalysisError.analysis(error) }
                    guard let analysis = existingAnalysis ?? silentAnalysis.analysis else { throw SilentAnalysisError.noAudio }
                    let timing = try await recognizeLyrics(lyrics, song: song, analysis: analysis,
                                                           buffer: restored, origin: captured.origin)
                    result = AppleMusicWorkerResult(analysis: analysis, lyricTiming: timing)
                    musicAnalysis.refreshSavedAnalysis(for: song)
                    break
                }
                guard Date().timeIntervalSince(began) < song.duration + 30 else { throw SilentAnalysisError.didNotFinish }
                guard state.playbackRate == 2, state.preservesPitch == true else { throw SilentAnalysisError.playbackRateChanged }
                workerPosition = state.time
                recording.update(position: state.isPlaying ? state.time : nil)
                if let error = silentAnalysis.error { throw SilentAnalysisError.analysis(error) }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch { failure = error }
        workerPhase = .restoring
        audioCapture.setRecording(nil)
        audioCapture.setAnalysisInput(nil)
        silentAnalysis.stopUnfinishedAnalysis()
        // Cleanup also runs after cancellation. Never release output suppression while internal audio is playing.
        if let webView { await webView.pauseAllMediaPlayback() }
        _ = try? await evaluate("analysisRate", value: 1)
        if !stopping {
            do {
                _ = try await evaluate("volume", value: 0)
                let changedSelection = selectedSong?.id != restoreSong?.id
                if let target = changedSelection ? selectedSong : restoreSong {
                    _ = try await evaluateValue("prepareSong", value: target.id)
                    _ = try await evaluate("toggle")
                    _ = try await evaluate("pause")
                    _ = try await evaluate("seek", value: changedSelection ? 0 : restorePosition)
                } else { _ = try await evaluate("stop") }
            } catch {
                // Force the normal play button to prepare its own selected song after a failed restore.
                playback.available = false
            }
            if let webView { await webView.pauseAllMediaPlayback() }
            _ = try? await evaluate("volume", value: Double(desiredVolume))
        }
        audioCapture.setPlaybackVolume(desiredVolume)
        do { try await audioCapture.setMuted(false) }
        catch { if failure == nil { failure = error } }
        if stopping { audioCapture.stop() }
        if let failure { throw failure }
        guard let result else { throw SilentAnalysisError.noAudio }
        return result
    }

    private func recognizeLyrics(_ lyrics: AppleMusicLyrics?, song: AppleMusicSong, analysis: MusicAnalysis,
                                 buffer: AVAudioPCMBuffer, origin: Double) async throws -> AppleMusicLyricTiming {
        try await AppleMusicLyricTiming.generate(lyrics: lyrics, song: song, analysis: analysis,
                                                  audioBuffer: buffer, startTime: origin)
    }

    private func evaluate(_ command: String, value: Double = 0) async throws -> AppleMusicPlayback {
        try AppleMusicBridge.decode(await evaluateValue(command, value: value))
    }

    private func evaluateValue(_ command: String, value: Any = 0) async throws -> Any? {
        guard let webView, webView.url?.scheme == "https", webView.url?.host == "music.apple.com" else {
            return nil
        }
        return try await webView.callAsyncJavaScript(AppleMusicBridge.invocation,
            arguments: ["command": command, "value": value], in: nil, contentWorld: .page)
    }

    var isInitialized: Bool { webView != nil }

    func webViewForDisplay() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Playback is controlled by the native queue and buttons, including track-end advances.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        if isOfficialBrowser { AppleMusicAppearance.configure(webView) }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView
        if isOfficialBrowser {
            backNavigationObservation = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, let view = self.webView else { return }
                    self.canGoBack = view.canGoBack
                }
            }
        }
        isLoading = true
        webView.load(URLRequest(url: URL(string: "https://music.apple.com/jp/")!))
        return webView
    }

    func reload() {
        guard let webView else { return }
        errorMessage = nil
        webView.reload()
    }

    func goBack() {
        guard let webView, webView.canGoBack else { return }
        errorMessage = nil
        webView.goBack()
    }

    func suspendPlayback() async {
        await updatePlaybackSuspension(true)
    }

    func allowPlayback() async {
        await updatePlaybackSuspension(false)
    }

    func stop() {
        stopping = true
        backNavigationObservation = nil
        preanalysis.setAllowed(false)
        audioCapture.setRecording(nil)
        musicAnalysis.interrupt()
        audioCapture.setAnalysisInput(nil)
        audioCapture.stop()
        artworkTask?.cancel(); artworkTask = nil
        guard webView != nil else { return }
        lyricsGeneration &+= 1
        lyricsTask?.cancel(); lyricsTask = nil
        lyrics = nil
        sourceLyrics = nil
        lyricTimingMessage = nil
        mediaGeneration &+= 1
        playbackSuspended = true
        bridgeGeneration &+= 1
        playback = AppleMusicPlayback()
        commandTask = nil
        mediaTask?.cancel()
        mediaTask = nil
        for view in existingWebViews {
            view.pauseAllMediaPlayback(completionHandler: nil)
            view.stopLoading()
        }
        for window in Array(popupWindows.values) { window.close() }
        isLoading = false
    }

    private var existingWebViews: [WKWebView] {
        let popups = popupWindows.values.compactMap { $0.contentView as? WKWebView }
        return webView.map { [$0] + popups } ?? []
    }

    private func updatePlaybackSuspension(_ suspended: Bool) async {
        guard webView != nil else { return }
        mediaGeneration &+= 1
        let generation = mediaGeneration
        playbackSuspended = suspended
        if suspended { musicAnalysis.interrupt(); audioCapture.setAnalysisInput(nil); audioCapture.stop() }
        else { audioCaptureFailed = false; audioCaptureError = nil }
        bridgeGeneration &+= 1
        if suspended { playback.isPlaying = false }
        let pendingCommand = commandTask
        let pendingSong = songTask
        let previousTask = mediaTask
        // 切り替え処理を順番に適用し、古い完了通知が最新の再生意図を上書きしないようにする。
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            await pendingCommand?.value
            _ = await pendingSong?.value
            guard let self, generation == self.mediaGeneration else { return }
            self.commandTask = nil
            for view in self.existingWebViews {
                guard generation == self.mediaGeneration else { return }
                // Pause the old audio without imposing a persistent WebKit playback ban.
                if suspended { await view.pauseAllMediaPlayback() }
            }
        }
        mediaTask = task
        await task.value
        if generation == mediaGeneration { mediaTask = nil }
    }

    private func updateNavigationState(_ view: WKWebView) {
        guard view === webView else { return }
        isLoading = view.isLoading
        canGoBack = view.canGoBack
    }

    private func navigationFailed(_ view: WKWebView, error: Error) {
        guard view === webView else { return }
        updateNavigationState(view)
        let error = error as NSError
        guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
        errorMessage = "Apple Musicのページを開けませんでした。\(error.localizedDescription)"
        isLoading = false
    }
}

extension AppleMusicStore: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        errorMessage = nil
        isLoading = true
        canGoBack = webView.canGoBack
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateNavigationState(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavigationState(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        isLoading = false
        errorMessage = "Apple Musicのページの処理が終了しました。再読み込みしてください。"
    }
}

extension AppleMusicStore: WKUIDelegate, NSWindowDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // WebKit が用意した設定と window.opener の関係を保ち、公式のログイン画面を表示する。
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        let size = NSSize(width: max(420, windowFeatures.width?.doubleValue ?? 600),
                          height: max(500, windowFeatures.height?.doubleValue ?? 720))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Apple Music"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = popup
        popupWindows[ObjectIdentifier(popup)] = window
        if playbackSuspended {
            popup.pauseAllMediaPlayback(completionHandler: nil)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popupWindows[ObjectIdentifier(webView)]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let popup = window.contentView as? WKWebView else { return }
        popup.stopLoading()
        popup.uiDelegate = nil
        popupWindows.removeValue(forKey: ObjectIdentifier(popup))
    }
}

enum SilentAnalysisError: LocalizedError {
    case noAudioProcess, noAudio, didNotFinish, playbackRateChanged, analysis(String)
    var errorDescription: String? {
        switch self {
        case .noAudioProcess: return "事前解析の音声入力を準備できませんでした。"
        case .noAudio: return "事前解析用の音声を取得できませんでした。"
        case .didNotFinish: return "事前解析中に曲の再生が停止しました。"
        case .playbackRateChanged: return "事前解析の2倍速再生を維持できませんでした。"
        case .analysis(let message): return message
        }
    }
}
