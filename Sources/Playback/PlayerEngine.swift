import AppKit
import AVFoundation
import AudioToolbox
import Foundation

@MainActor
final class PlayerEngine {
    private struct Boundary {
        let url: URL
        let duration: Double
        let startSample: AVAudioFramePosition
        let offset: Double
    }
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let decodeQueue = DispatchQueue(label: "MusicPrayer.audio.decode", qos: .userInitiated)
    private var analyzer = AudioFeatureAnalyzer(sampleRate: 48_000)
    private var producer: AudioFileStream?
    private var prepared: AudioFileStream?
    private var preparedURL: URL?
    private var currentURL: URL?
    private var boundaries: [Boundary] = []
    private var currentBoundary = Boundary(url: URL(fileURLWithPath: "/"), duration: 0, startSample: 0, offset: 0)
    private var scheduledSample: AVAudioFramePosition = 0
    private var queuedBuffers = 0
    private var filling = false
    private var generation = 0
    private var lastPosition: Double = 0
    private var desiredPlayback = false
    private var endDelivered = false
    private var selectedDevice: AudioDeviceID?
    private var observers: [NSObjectProtocol] = []
    private var resumeAfterSleep = false
    private var changingConfiguration = false
    private var setupError: Error?

    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    var volume: Float {
        get { player.volume }
        set { player.volume = min(max(newValue, 0), 1) }
    }
    var onTrackTransition: ((URL) -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((Error) -> Void)?

    var currentTime: Double {
        updateClock()
        deliverEndIfNeeded()
        return lastPosition
    }

    init() {
        engine.attach(player)
        do {
            try engine.connectNode(player, to: engine.mainMixerNode, format: format)
            try installTap()
        } catch { setupError = error }
        let config = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.configurationChanged() }
        }
        observers.append(config)
        let sleep = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resumeAfterSleep = self.isPlaying
                self.pause()
            }
        }
        let wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.resumeAfterSleep else { return }
                self.resumeAfterSleep = false
                do { try self.restore(position: self.lastPosition, resume: true) } catch { self.onError?(error) }
            }
        }
        observers += [sleep, wake]
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        player.stop(); engine.stop()
    }

    func load(url: URL) throws {
        if let setupError { throw setupError }
        let source = try AudioFileStream(url: url, format: format)
        let initial = try source.read(maxChunks: 6)
        guard !initial.isEmpty else { throw PlaybackError.emptyFile }
        invalidate()
        producer = source; prepared = nil; preparedURL = nil
        currentURL = url; duration = source.duration; lastPosition = 0
        currentBoundary = Boundary(url: url, duration: source.duration, startSample: 0, offset: 0)
        enqueue(initial)
    }

    /// Remove the loaded track and every scheduled successor, including stale completion work.
    func unload() {
        invalidate()
        producer = nil; prepared = nil; preparedURL = nil; currentURL = nil
        duration = 0; lastPosition = 0
        currentBoundary = Boundary(url: URL(fileURLWithPath: "/"), duration: 0, startSample: 0, offset: 0)
        engine.stop()
    }

    func play() throws {
        guard currentURL != nil else { return }
        if endDelivered || lastPosition >= duration {
            try seek(to: 0)
        }
        if !engine.isRunning { try engine.start() }
        desiredPlayback = true
        try player.playAudio()
        isPlaying = true
        requestFill()
    }

    func pause() {
        updateClock()
        desiredPlayback = false; isPlaying = false
        player.pause()
    }

    func stop() {
        pause()
        guard currentURL != nil else { return }
        do { try restore(position: 0, resume: false) } catch { onError?(error) }
    }

    func seek(to seconds: Double) throws {
        guard seconds.isFinite else { throw PlaybackError.invalidPosition }
        updateClock()
        let resume = isPlaying
        try restore(position: min(max(seconds, 0), duration), resume: resume)
    }

    func prepareNext(url: URL?) throws {
        updateClock()
        if url == preparedURL { return }
        let candidate = try url.map { try AudioFileStream(url: $0, format: format) }
        // Already-scheduled successor cannot be withdrawn individually; rebuild the current
        // stream at its audible position when the playlist changes before a boundary.
        if !boundaries.isEmpty {
            let position = lastPosition
            let resume = isPlaying
            prepared = nil; preparedURL = nil
            try restore(position: position, resume: resume, preserveNext: false)
        }
        preparedURL = url
        prepared = candidate
        requestFill()
    }

    func features() -> AudioFeatures {
        let now = mach_absolute_time()
        let latency = AVAudioTime.hostTime(forSeconds: player.outputPresentationLatency)
        return analyzer.snapshot(atOrBefore: now >= latency ? now - latency : 0)
    }

    func setOutputDevice(_ id: UInt32?) throws {
        updateClock()
        let position = lastPosition
        let resume = isPlaying
        let previousDevice = selectedDevice
        guard var device = id ?? AudioOutputs.defaultDevice() else { throw PlaybackError.outputDevice(kAudio_ParamError) }
        changingConfiguration = true
        defer { changingConfiguration = false }
        player.pause(); engine.stop()
        let status = engine.outputNode.withAudioUnit { unit in
            guard let unit else { return kAudio_ParamError }
            return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        if status != noErr {
            if var previousDevice {
                engine.outputNode.withAudioUnit { unit in
                    if let unit {
                        _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &previousDevice, UInt32(MemoryLayout<AudioDeviceID>.size))
                    }
                }
            }
            try? restore(position: position, resume: resume)
            throw PlaybackError.outputDevice(status)
        }
        selectedDevice = id
        try restore(position: position, resume: resume)
    }

    private func installTap() throws {
        let sink = analyzer
        // Observe the source before the player's output gain, so muting does not
        // remove the signal that drives the visualizer.
        try player.installAudioTap(onBus: 0, bufferSize: 512, format: format) { buffer, time in
            sink.process(buffer, at: time)
        }
    }

    private func invalidate() {
        generation += 1
        analyzer.reset()
        desiredPlayback = false; isPlaying = false
        player.stop()
        queuedBuffers = 0; scheduledSample = 0; boundaries = []
        filling = false; endDelivered = false
    }

    private func restore(position: Double, resume: Bool, preserveNext: Bool = true) throws {
        guard let currentURL else { return }
        let next = preserveNext ? preparedURL : nil
        let source = try AudioFileStream(url: currentURL, offset: position, format: format)
        let initial = try source.read(maxChunks: 6)
        invalidate()
        producer = source; duration = source.duration; lastPosition = source.offset
        currentBoundary = Boundary(url: currentURL, duration: duration, startSample: 0, offset: source.offset)
        preparedURL = next
        prepared = try next.map { try AudioFileStream(url: $0, format: format) }
        enqueue(initial)
        requestFill()
        if resume, source.offset < duration { try play() }
    }

    private func enqueue(_ buffers: [AVAudioPCMBuffer]) {
        let token = generation
        for buffer in buffers {
            queuedBuffers += 1
            scheduledSample += AVAudioFramePosition(buffer.frameLength)
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.queuedBuffers = max(0, self.queuedBuffers - 1)
                    self.updateClock()
                    self.requestFill()
                    self.deliverEndIfNeeded()
                }
            }
        }
    }

    private func requestFill() {
        guard !filling, queuedBuffers < 6, let source = producer else { return }
        if source.ended {
            guard let next = prepared else { deliverEndIfNeeded(); return }
            prepared = nil
            producer = next
            boundaries.append(Boundary(url: next.url, duration: next.duration, startSample: scheduledSample, offset: 0))
            requestFill()
            return
        }
        filling = true
        let count = 6 - queuedBuffers
        let token = generation
        decodeQueue.async { [weak self] in
            let result = Result { try source.read(maxChunks: count) }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.filling = false
                switch result {
                case .success(let buffers):
                    self.enqueue(buffers)
                    if source.ended { self.requestFill() }
                    self.deliverEndIfNeeded()
                case .failure(let error):
                    self.onError?(error)
                    self.pause()
                }
            }
        }
    }

    private func updateClock() {
        guard isPlaying, let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render), time.isSampleTimeValid else { return }
        // Map the rendered player clock onto the audio reaching the selected device.
        let now = mach_absolute_time()
        let elapsed = render.isHostTimeValid && now >= render.hostTime ? AVAudioTime.seconds(forHostTime: now - render.hostTime) : 0
        let latency = player.outputPresentationLatency
        let sample = max(0, time.sampleTime + AVAudioFramePosition((elapsed - latency) * format.sampleRate))
        while let boundary = boundaries.first, sample >= boundary.startSample {
            boundaries.removeFirst()
            currentBoundary = boundary; currentURL = boundary.url
            duration = boundary.duration; preparedURL = nil
            lastPosition = min(duration, max(0, boundary.offset + Double(sample - boundary.startSample) / format.sampleRate))
            let token = generation
            onTrackTransition?(boundary.url)
            if token != generation { return }
        }
        lastPosition = min(duration, max(0, currentBoundary.offset + Double(sample - currentBoundary.startSample) / format.sampleRate))
    }

    private func deliverEndIfNeeded() {
        guard queuedBuffers == 0, !filling, producer?.ended == true, prepared == nil, boundaries.isEmpty, desiredPlayback, !endDelivered else { return }
        endDelivered = true
        lastPosition = duration
        desiredPlayback = false; isPlaying = false
        player.pause()
        onEnd?()
    }

    private func configurationChanged() {
        guard !changingConfiguration, currentURL != nil else { return }
        let resume = desiredPlayback
        do { try restore(position: lastPosition, resume: resume) } catch { isPlaying = false; desiredPlayback = false; onError?(error) }
    }
}
