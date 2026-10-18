import Foundation
import Observation

/// One queue on the existing Apple Music connection. Foreground playback always takes priority.
@MainActor @Observable
final class AppleMusicPreanalysis {
    enum Phase { case preparing, capturing, analyzing, restoring }
    private(set) var songID: String?
    var phase = Phase.preparing
    var position: Double = 0
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored var operation: (@MainActor (AppleMusicSong) async throws -> Void)?
    @ObservationIgnored private var songs: [AppleMusicSong] = []
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var allowed = false
    @ObservationIgnored private var task: Task<Void, Never>?
    var isWorking: Bool { task != nil }

    func status(for song: AppleMusicSong) -> String {
        if songID == song.id {
            switch phase {
            case .preparing: return "解析の準備中"
            case .capturing: return "解析中"
            case .analyzing, .restoring: return "解析を仕上げています"
            }
        }
        if errors[song.id] != nil { return "事前解析に失敗しました" }
        return attempted.contains(song.id) ? "解析済み" : "解析待ち"
    }

    func progress(for song: AppleMusicSong) -> Double? {
        guard songID == song.id, phase == .capturing, song.duration > 0 else { return nil }
        return min(1, max(0, position / song.duration))
    }

    func setSongs(_ songs: [AppleMusicSong]) {
        var seen: Set<String> = []
        self.songs = songs.filter { seen.insert($0.id).inserted }
        attempted.formIntersection(seen)
        errors = errors.filter { seen.contains($0.key) }
        if let songID, !seen.contains(songID) { task?.cancel() }
        schedule()
    }

    func setAllowed(_ value: Bool) {
        allowed = value
        if !value { task?.cancel() }
        else { schedule() }
    }

    func yieldToPlayback() async {
        setAllowed(false)
        await task?.value
    }

    private func schedule() {
        guard allowed, task == nil, let operation,
              songs.contains(where: { !attempted.contains($0.id) }) else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.songID = nil; self.position = 0; self.task = nil
                self.schedule()
            }
            while self.allowed, !Task.isCancelled,
                  let song = self.songs.first(where: { !self.attempted.contains($0.id) }) {
                self.songID = song.id; self.position = 0; self.phase = .preparing
                do {
                    try await operation(song)
                    try Task.checkCancellation()
                    self.attempted.insert(song.id)
                    self.errors[song.id] = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self.attempted.insert(song.id)
                    self.errors[song.id] = error.localizedDescription
                }
            }
        }
    }
}
