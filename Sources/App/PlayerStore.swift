import AppKit
import AVFoundation
import Observation

@MainActor @Observable
final class PlayerStore {
    var tracks: [Track] = []
    var currentIndex = 0
    var position: Double = 0
    var duration: Double = 0
    var isPlaying = false
    var visualizerStyle = VisualizerStyle.ribbons
    var volume: Float = 0.75 { didSet { engine.volume = isMuted ? 0 : volume } }
    var isMuted = false { didSet { engine.volume = isMuted ? 0 : volume } }
    var shuffle = false { didSet { planNext() } }
    var repeatSetting = RepeatSetting.off { didSet { planNext() } }
    var analysis: MusicAnalysis?
    var moment = MusicalMoment()
    var analyzing = false
    var analysisError: String?
    var playbackError: String?
    var devices: [OutputDevice] = []
    var outputID: UInt32 = 0
    var defaultOutputName: String?
    var outputDeviceName: String {
        if outputID == 0 { return defaultOutputName ?? "Macの既定の出力先" }
        return devices.first { $0.id == outputID }?.name ?? "選択した出力先（未接続）"
    }
    var outputName: String { outputID == 0 ? "Macの既定：\(outputDeviceName)" : outputDeviceName }
    var previewTime: Double?
    @ObservationIgnored let visualSource = VisualFrameSource()
    @ObservationIgnored let engine = PlayerEngine()
    @ObservationIgnored private let analyzer = MusicAnalyzer()
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var composer = VisualComposer()
    @ObservationIgnored private var plannedIndex: Int?
    @ObservationIgnored private var visualTransition: TrackVisualTransition?
    @ObservationIgnored private var previousTick = Date()
    @ObservationIgnored private var uiTick = Date.distantPast
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var openedURLs: [URL] = []
    @ObservationIgnored private var nowPlaying: NowPlayingController?
    @ObservationIgnored private var warmTask: Task<Void, Never>?
    @ObservationIgnored private var scenes: [SectionScene] = []
    @ObservationIgnored private var loadedURL: URL?
    var currentTrack: Track? { tracks.indices.contains(currentIndex) ? tracks[currentIndex] : nil }

    init() {
        engine.onTrackTransition = { [weak self] url in self?.didTransition(to: url) }
        engine.onEnd = { [weak self] in self?.isPlaying = false; self?.persist() }
        engine.onError = { [weak self] error in self?.playbackError = error.localizedDescription }
        engine.volume = volume
        refreshDevices()
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func restore() async {
        nowPlaying = NowPlayingController(store: self)
        guard let session = QueuePersistence.restore() else { return }
        await add(urls: session.urls, selectFirst: false)
        volume = session.volume
        if !tracks.isEmpty {
            select(min(max(0, session.current), tracks.count - 1), autoplay: false)
            seek(session.time)
        }
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "曲を追加"
        panel.begin { [weak self] result in
            guard result == .OK else { return }
            Task { @MainActor in await self?.add(urls: panel.urls) }
        }
    }

    func add(urls: [URL], selectFirst: Bool = true) async {
        let wasEmpty = tracks.isEmpty
        for url in urls where !tracks.contains(where: { $0.url == url }) {
            if url.startAccessingSecurityScopedResource() { openedURLs.append(url) }
            tracks.append(Track(url: url))
        }
        if wasEmpty, selectFirst, !tracks.isEmpty { select(0, autoplay: false) }
        let ids = tracks.map { ($0.id, $0.url) }
        for (id, url) in ids {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            do {
                let metadata = try await asset.load(.commonMetadata)
                let seconds = try await asset.load(.duration).seconds
                var title: String?, artist: String?, album: String?, artwork: Data?
                for item in metadata {
                    switch item.commonKey {
                    case .commonKeyTitle: title = try? await item.load(.stringValue)
                    case .commonKeyArtist: artist = try? await item.load(.stringValue)
                    case .commonKeyAlbumName: album = try? await item.load(.stringValue)
                    case .commonKeyArtwork: artwork = try? await item.load(.dataValue)
                    default: break
                    }
                }
                if let i = tracks.firstIndex(where: { $0.id == id }) {
                    if let title, !title.isEmpty { tracks[i].title = title }
                    tracks[i].artist = artist ?? ""
                    tracks[i].album = album ?? ""
                    tracks[i].artwork = artwork
                    tracks[i].duration = seconds.isFinite ? seconds : 0
                }
            } catch { /* A missing file stays visible; playback supplies its actual error. */ }
        }
        planNext(); persist(); warmAnalyses()
    }

    func select(_ index: Int, autoplay: Bool = true) {
        guard tracks.indices.contains(index) else { return }
        let outgoing = loadedURL == nil ? nil : visualSource.snapshot()
        let wasPlaying = engine.isPlaying
        do {
            try engine.load(url: tracks[index].url)
            loadedURL = tracks[index].url
            currentIndex = index; position = 0; duration = engine.duration
            playbackError = nil; previewTime = nil
            visualTransition = TrackVisualTransition(outgoing: outgoing, started: ProcessInfo.processInfo.systemUptime, wasPlaying: wasPlaying)
            analyzeCurrent()
            planNext()
            if autoplay { try engine.play() }
            isPlaying = engine.isPlaying
            persist()
        } catch { playbackError = error.localizedDescription; isPlaying = engine.isPlaying }
    }

    func togglePlayback() {
        guard currentTrack != nil else { openFiles(); return }
        guard loadedURL == currentTrack?.url else { select(currentIndex); return }
        do {
            if engine.isPlaying { engine.pause() }
            else { try engine.play() }
            isPlaying = engine.isPlaying
            persist()
        } catch { playbackError = error.localizedDescription }
    }
    func toggleMute() { isMuted.toggle() }
    func stop() { visualTransition = nil; engine.stop(); isPlaying = false; position = 0; persist() }
    func seek(_ time: Double) {
        do { try engine.seek(to: min(max(0, time), duration)); position = engine.currentTime; previewTime = nil; visualTransition = nil; planNext(); persist() }
        catch { playbackError = error.localizedDescription }
    }
    func next() { if let plannedIndex { select(plannedIndex) } }
    func previous() {
        if position > 3 { seek(0) }
        else if currentIndex > 0 { select(currentIndex - 1) }
    }
    func remove(_ id: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let removingCurrent = index == currentIndex
        let playing = isPlaying
        tracks.remove(at: index)
        if removingCurrent {
            engine.unload(); loadedURL = nil
            visualTransition = nil
            analysisTask?.cancel(); analysis = nil; scenes = []; analyzing = false; analysisError = nil
            duration = 0; position = 0; isPlaying = false; moment = MusicalMoment(); previewTime = nil
            currentIndex = min(index, max(0, tracks.count - 1))
        }
        if tracks.isEmpty { currentIndex = 0; plannedIndex = nil }
        else if removingCurrent { select(currentIndex, autoplay: playing) }
        else { if index < currentIndex { currentIndex -= 1 }; planNext() }
        persist()
    }
    func chooseOutput(_ id: UInt32) {
        do { try engine.setOutputDevice(id == 0 ? nil : id); outputID = id; refreshDevices(); playbackError = nil }
        catch { playbackError = error.localizedDescription }
    }
    func refreshDevices() {
        devices = AudioOutputs.devices()
        defaultOutputName = AudioOutputs.defaultDevice().flatMap { AudioOutputs.name(of: $0) }
    }
    func retryAnalysis() { analyzeCurrent(force: true) }

    private func analyzeCurrent(force: Bool = false) {
        analysisTask?.cancel(); analysis = nil; scenes = []; analysisError = nil; moment = MusicalMoment()
        guard let track = currentTrack else { analyzing = false; return }
        analyzing = true
        analysisTask = Task { [weak self, analyzer] in
            do {
                let result = try await analyzer.analyze(url: track.url, force: force)
                guard !Task.isCancelled, let self, self.currentTrack?.id == track.id else { return }
                self.analysis = result; self.scenes = SectionScenes.make(result); self.analyzing = false
            } catch {
                guard !Task.isCancelled, let self, self.currentTrack?.id == track.id else { return }
                self.analysisError = error.localizedDescription; self.analyzing = false
            }
        }
    }
    private func planNext() {
        plannedIndex = nil
        guard tracks.indices.contains(currentIndex), loadedURL != nil else { try? engine.prepareNext(url: nil); return }
        if repeatSetting == .one { plannedIndex = currentIndex }
        else if shuffle { plannedIndex = tracks.indices.filter { $0 != currentIndex }.randomElement() ?? (repeatSetting == .all ? currentIndex : nil) }
        else if currentIndex + 1 < tracks.count { plannedIndex = currentIndex + 1 }
        else if repeatSetting == .all { plannedIndex = 0 }
        do { try engine.prepareNext(url: plannedIndex.map { tracks[$0].url }) }
        catch { playbackError = error.localizedDescription }
    }
    private func warmAnalyses() {
        warmTask?.cancel()
        let urls = tracks.map(\.url).filter { $0 != currentTrack?.url }
        warmTask = Task { [weak self, analyzer] in
            for url in urls {
                guard !Task.isCancelled else { return }
                do {
                    _ = try await analyzer.analyze(url: url)
                    guard !Task.isCancelled, let self else { return }
                    guard self.tracks.contains(where: { $0.url == url }) else { continue }
                } catch { if Task.isCancelled { return } }
            }
        }
    }
    private func didTransition(to url: URL) {
        if let plannedIndex, tracks.indices.contains(plannedIndex), tracks[plannedIndex].url == url { currentIndex = plannedIndex }
        else if let i = tracks.firstIndex(where: { $0.url == url }) { currentIndex = i }
        loadedURL = url; duration = engine.duration; position = engine.currentTime
        // The previous track already faded over its final 0.4 seconds; keep audio gapless.
        visualTransition = TrackVisualTransition(outgoing: nil, started: ProcessInfo.processInfo.systemUptime, wasPlaying: true)
        analyzeCurrent(); planNext(); persist()
    }
    private func tick() {
        let now = Date()
        let dt = Float(min(0.1, now.timeIntervalSince(previousTick))); previousTick = now
        let time = engine.currentTime
        let sampled = TimelineSampler.sample(analysis, at: previewTime ?? time)
        var audio = engine.features()
        if !engine.isPlaying { audio = AudioFeatures() }
        let uptime = ProcessInfo.processInfo.systemUptime
        let presence = plannedIndex == nil ? 1 : TrackVisualTransition.envelope(max(0, engine.duration - time) / TrackVisualTransition.halfDuration)
        let sceneIndex = (sampled.section ?? 0) - 1
        let scene = scenes.indices.contains(sceneIndex) ? scenes[sceneIndex] : nil
        var frame = composer.compose(time: previewTime ?? time, audio: audio, moment: sampled, scene: scene, analyzed: analysis != nil, presence: presence, dt: dt)
        frame.trackID = currentTrack?.id
        if previewTime != nil { visualTransition = nil }
        if let transition = visualTransition {
            frame = transition.frame(incoming: frame, at: uptime)
            if transition.isFinished(at: uptime) { visualTransition = nil }
        }
        visualSource.publish(frame)
        if now.timeIntervalSince(uiTick) >= 0.1 {
            position = time
            if moment != sampled { moment = sampled }
            isPlaying = engine.isPlaying; duration = engine.duration
            nowPlaying?.update()
            uiTick = now
        }
        if now.timeIntervalSince(lastSave) > 5 { persist(); lastSave = now }
    }
    func persist() {
        do { try QueuePersistence.save(tracks: tracks, current: currentIndex, time: engine.currentTime, volume: volume) }
        catch { playbackError = "再生位置を保存できませんでした：\(error.localizedDescription)" }
    }
    func shutdown() { persist(); analysisTask?.cancel(); warmTask?.cancel(); timer?.invalidate(); engine.stop(); openedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
}
