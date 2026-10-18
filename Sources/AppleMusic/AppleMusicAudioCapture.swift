import AVFoundation
import CoreAudio

/// Observes the WebKit audio process created by this connection. The tap only
/// reads audio; WebKit continues to own playback, volume and the output device.
final class AppleMusicAudioCapture {
    private let workQueue = DispatchQueue(label: "MusicPrayer.appleMusicAudio")
    private let stateLock = NSLock()
    private let audioQueue = DispatchQueue(label: "MusicPrayer.appleMusicPCM")
    private var analysisInput: AppleMusicAnalysisInput?
    private var recording: AppleMusicPCMRecording?
    private var updatePending = false
    private var wantsCapture = false
    private var existingPIDs: Set<pid_t>?
    private var target: AudioProcess?
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var analyzer: AudioFeatureAnalyzer?
    private var lastProcessCheck = Date.distantPast
    private var playbackVolume: Float = 1
    // Owned by workQueue, like the tap and aggregate device.
    private var muted = false

    deinit { stopOnQueue() }

    func prepareForWebView() {
        // Record before constructing WKWebView, including WebKit processes used
        // by other apps. Never tap every process with the shared WebKit bundle ID.
        existingPIDs = try? Set(AudioProcess.all().map(\.pid))
    }

    /// Changes only this connection's output route; the captured PCM remains available.
    func setMuted(_ muted: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workQueue.async { [self] in
                do {
                    try setMutedOnQueue(muted)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// The caller keeps WebKit's volume at zero until a muted tap is ready.
    func prepareMutedCapture() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            stateLock.lock(); wantsCapture = true; stateLock.unlock()
            workQueue.async { [self] in
                stateLock.lock(); let requested = wantsCapture; stateLock.unlock()
                guard requested else { continuation.resume(returning: false); return }
                do {
                    try setMutedOnQueue(true)
                    try updateOnQueue()
                    if tap != 0 { try verifyMuteOnQueue() }
                    continuation.resume(returning: tap != 0)
                } catch {
                    stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func setMutedOnQueue(_ muted: Bool) throws {
        self.muted = muted
        guard tap != 0 else { return }
        let description = try tapDescriptionOnQueue()
        let behavior: CATapMuteBehavior = muted ? .muted : .unmuted
        guard description.muteBehavior != behavior else { return }
        description.muteBehavior = behavior
        var reference: Unmanaged<CATapDescription>? = .passUnretained(description)
        var address = property(kAudioTapPropertyDescription)
        try check(AudioObjectSetPropertyData(tap, &address, 0, nil,
                                             UInt32(MemoryLayout.size(ofValue: reference)), &reference), "音声出力の切り替え")
        try verifyMuteOnQueue()
    }

    private func tapDescriptionOnQueue() throws -> CATapDescription {
        let reference: Unmanaged<CATapDescription>? = try readValue(tap, kAudioTapPropertyDescription, initial: nil)
        guard let description = reference?.takeRetainedValue() else {
            throw CaptureError.message("音声出力の設定を確認できませんでした。")
        }
        return description
    }

    private func verifyMuteOnQueue() throws {
        guard try tapDescriptionOnQueue().muteBehavior == (muted ? .muted : .unmuted) else {
            throw CaptureError.message("音声出力の切り替えを確認できませんでした。")
        }
    }

    /// HAL setup can wait for the audio service or permission. Never block the UI clock.
    func update(onError: @escaping (Error) -> Void) {
        stateLock.lock()
        wantsCapture = true
        guard !updatePending else { stateLock.unlock(); return }
        updatePending = true
        stateLock.unlock()
        workQueue.async { [self] in
            defer { stateLock.lock(); updatePending = false; stateLock.unlock() }
            stateLock.lock(); let requested = wantsCapture; stateLock.unlock()
            guard requested else { return }
            do { try updateOnQueue() }
            catch {
                stopOnQueue()
                DispatchQueue.main.async { onError(error) }
            }
        }
    }

    private func updateOnQueue() throws {
        guard Date().timeIntervalSince(lastProcessCheck) >= 0.5 else { return }
        lastProcessCheck = Date()
        guard let existingPIDs else { throw CaptureError.message("音声プロセスの一覧を取得できませんでした。") }
        let processes = try AudioProcess.all()
        if let target, processes.contains(target) {
            if tap != 0 { return }
        } else {
            stopOnQueue()
            target = nil
        }
        if target == nil {
            let candidates = processes.filter {
                $0.bundleID == "com.apple.WebKit.GPU" && !existingPIDs.contains($0.pid) && $0.isRunningOutput
            }
            guard candidates.count <= 1 else {
                throw CaptureError.message("Apple Musicの音声プロセスを特定できませんでした。")
            }
            // The audio process appears only once WebKit starts outputting sound.
            guard let process = candidates.first else { return }
            target = process
        }
        try start(process: target!.id)
    }

    func features() -> AudioFeatures {
        stateLock.lock()
        let analyzer = wantsCapture ? self.analyzer : nil
        stateLock.unlock()
        guard let analyzer else { return AudioFeatures() }
        let now = mach_absolute_time()
        let features = analyzer.snapshot(atOrBefore: now)
        guard features.hostTime <= now,
              AVAudioTime.seconds(forHostTime: now - features.hostTime) < 0.5 else { return AudioFeatures() }
        return features
    }

    func setAnalysisInput(_ input: AppleMusicAnalysisInput?) {
        stateLock.lock(); analysisInput = input; stateLock.unlock()
    }

    func setRecording(_ recording: AppleMusicPCMRecording?) {
        stateLock.lock(); self.recording = recording; stateLock.unlock()
    }

    func reset() {
        stateLock.lock(); let analyzer = self.analyzer; stateLock.unlock()
        analyzer?.reset()
    }

    func setPlaybackVolume(_ volume: Float) {
        stateLock.lock(); defer { stateLock.unlock() }
        playbackVolume = volume
        // Restore the signal scale before WebKit's output gain, matching local analysis.
        analyzer?.setInputGain(volume > 0 ? 1 / volume : 1)
    }

    func stop() {
        stateLock.lock()
        let requested = wantsCapture
        wantsCapture = false
        stateLock.unlock()
        if requested { workQueue.async { [self] in stopOnQueue() } }
    }

    private func stopOnQueue() {
        if tap != 0 { lastProcessCheck = .distantPast }
        if device != 0, let ioProc {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
        }
        ioProc = nil
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        stateLock.lock(); analyzer = nil; stateLock.unlock()
    }

    private func start(process: AudioObjectID) throws {
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: [process])
            description.name = "MusicPrayer Apple Music"
            description.isPrivate = true
            description.isProcessRestoreEnabled = false
            description.muteBehavior = muted ? .muted : .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "音声タップの作成")
            let uid = try readString(tap, kAudioTapPropertyUID)
            let format: AudioStreamBasicDescription = try readValue(tap, kAudioTapPropertyFormat,
                                                                   initial: AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mSampleRate > 0 else {
                throw CaptureError.message("取得した音声形式を解析できませんでした。")
            }
            let sink = AudioFeatureAnalyzer(sampleRate: format.mSampleRate)
            stateLock.lock()
            sink.setInputGain(playbackVolume > 0 ? 1 / playbackVolume : 1)
            analyzer = sink
            stateLock.unlock()
            let configuration: [String: Any] = [
                kAudioAggregateDeviceUIDKey: "MusicPrayer-\(UUID().uuidString)",
                kAudioAggregateDeviceNameKey: "MusicPrayer Apple Music input",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid,
                                                   kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &device), "音声入力の作成")
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, audioQueue) { [weak self] _, input, time, _, _ in
                let stamp = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : mach_absolute_time()
                sink.process(input, at: AVAudioTime(hostTime: stamp))
                guard let self else { return }
                self.stateLock.lock()
                let analysisInput = self.analysisInput, recording = self.recording
                self.stateLock.unlock()
                analysisInput?.append(input, sampleRate: format.mSampleRate)
                recording?.append(input, sampleRate: format.mSampleRate)
            }, "音声解析の接続")
            try check(AudioDeviceStart(device, ioProc), "音声解析の開始")
        } catch {
            stopOnQueue()
            throw error
        }
    }
}

private struct AudioProcess: Equatable {
    var id: AudioObjectID
    var pid: pid_t
    var bundleID: String
    var isRunningOutput: Bool

    static func all() throws -> [AudioProcess] {
        var address = property(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), "音声プロセスの取得")
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty else { return [] }
        try ids.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!), "音声プロセスの取得")
        }
        return ids.compactMap { id in
            guard let pid = try? readValue(id, kAudioProcessPropertyPID, initial: pid_t(0)),
                  let bundle = try? readString(id, kAudioProcessPropertyBundleID),
                  let running = try? readValue(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) else { return nil }
            return AudioProcess(id: id, pid: pid, bundleID: bundle, isRunningOutput: running != 0)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.pid == rhs.pid && lhs.bundleID == rhs.bundleID
    }
}

private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

private func readValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
    var address = property(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try withUnsafeMutableBytes(of: &value) { bytes in
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!), "音声情報の取得")
    }
    return value
}

private func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var address = property(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "音声情報の取得")
    return value?.takeRetainedValue() as String? ?? ""
}

private func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw CaptureError.message("\(operation)に失敗しました（\(status)）。") }
}

private enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
