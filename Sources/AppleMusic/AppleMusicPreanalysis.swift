import Foundation
import Observation
import OSLog

/// Each song owns an independent worker. Two workers may capture and analyze at once.
@MainActor @Observable
final class AppleMusicPreanalysis {
    enum Phase { case preparing, capturing, analyzing, restoring }
    enum Completion: Sendable, Equatable {
        case complete
        case noLyrics
        case partialLyrics(recognized: Int, total: Int)
        case failedLyrics
        case missingLyrics
        case unmatchedLyrics
    }

    private struct Job {
        let ticket: UUID
        let registration: UUID
        let task: Task<Void, Never>
        var phase = Phase.preparing
        var position: Double = 0
    }

    @TaskLocal private static var currentTicket: UUID?
    @ObservationIgnored var operation: (@MainActor (AppleMusicSong) async throws -> Completion)?
    @ObservationIgnored private var songs: [AppleMusicSong] = []
    @ObservationIgnored private var registrations: [String: UUID] = [:]
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var pendingRetries: Set<String> = []
    @ObservationIgnored private var allowed = false
    @ObservationIgnored private var stopWaiters = 0
    private var jobs: [String: Job] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var completions: [String: Completion] = [:]

    var isWorking: Bool { !jobs.isEmpty }

    func isAnalyzing(songID: String) -> Bool { currentJob(for: songID) != nil }

    func status(for song: AppleMusicSong) -> String {
        if let job = currentJob(for: song.id) {
            switch job.phase {
            case .preparing: return "解析の準備中"
            case .capturing: return "解析中"
            case .analyzing, .restoring: return "解析を仕上げています"
            }
        }
        if errors[song.id] != nil { return "事前解析に失敗しました" }
        if completions[song.id] == .noLyrics { return "解析済み・歌詞なし" }
        return completions[song.id] != nil ? "解析済み" : "解析待ち"
    }

    func progress(for song: AppleMusicSong) -> Double? {
        guard let job = currentJob(for: song.id), job.phase == .capturing,
              song.duration.isFinite, song.duration > 0 else { return nil }
        return min(1, max(0, job.position / song.duration))
    }

    /// Call from the operation task, or a child task inheriting its ticket.
    func update(songID: String, phase: Phase, position: Double) {
        guard position.isFinite, let ticket = Self.currentTicket,
              var job = currentJob(for: songID), job.ticket == ticket,
              !job.task.isCancelled else { return }
        job.phase = phase
        job.position = max(0, position)
        jobs[songID] = job
    }

    func setSongs(_ songs: [AppleMusicSong]) {
        var seen: Set<String> = []
        self.songs = songs.filter { seen.insert($0.id).inserted }
        registrations = registrations.filter { seen.contains($0.key) }
        for id in seen where registrations[id] == nil { registrations[id] = UUID() }
        attempted.formIntersection(seen)
        pendingRetries.formIntersection(seen)
        errors = errors.filter { seen.contains($0.key) }
        completions = completions.filter { seen.contains($0.key) }
        for (id, job) in jobs where registrations[id] != job.registration {
            job.task.cancel()
        }
        schedule()
    }

    func setAllowed(_ value: Bool) {
        allowed = value && stopWaiters == 0
        if allowed { schedule() }
        else { jobs.values.forEach { $0.task.cancel() } }
    }

    func retry(songID: String) {
        guard registrations[songID] != nil else { return }
        completions[songID] = nil
        if currentJob(for: songID) != nil {
            pendingRetries.insert(songID)
            return
        }
        attempted.remove(songID)
        errors[songID] = nil
        schedule()
    }

    /// Shutdown waits for every worker's output suppression and process cleanup.
    func yieldToPlayback() async {
        stopWaiters += 1
        setAllowed(false)
        let pending = jobs.values.map(\.task)
        for task in pending { await task.value }
        stopWaiters -= 1
    }

    private func currentJob(for id: String) -> Job? {
        guard let job = jobs[id], registrations[id] == job.registration else { return nil }
        return job
    }

    private func schedule() {
        guard allowed, stopWaiters == 0, let operation else { return }
        for song in songs where jobs.count < 2 && !attempted.contains(song.id) && jobs[song.id] == nil {
            guard let registration = registrations[song.id] else { continue }
            let ticket = UUID()
            let task = Task { @MainActor [weak self] in
                let result: Result<Completion, Error> = await Self.$currentTicket.withValue(ticket) {
                    do {
                        let completion = try await operation(song)
                        try Task.checkCancellation()
                        return .success(completion)
                    } catch { return .failure(error) }
                }
                self?.finish(songID: song.id, ticket: ticket, result: result)
            }
            jobs[song.id] = Job(ticket: ticket, registration: registration, task: task)
        }
    }

    private func finish(songID: String, ticket: UUID, result: Result<Completion, Error>) {
        guard let job = jobs[songID], job.ticket == ticket else { return }
        jobs[songID] = nil
        if registrations[songID] == job.registration {
            if pendingRetries.remove(songID) != nil {
                attempted.remove(songID)
                errors[songID] = nil
                completions[songID] = nil
            } else if !job.task.isCancelled {
                attempted.insert(songID)
                switch result {
                case .success(let completion):
                    errors[songID] = nil
                    completions[songID] = completion
                case .failure(let error):
                    completions[songID] = nil
                    errors[songID] = error.localizedDescription
                    Logger(subsystem: "com.hazimeno.MusicPrayer", category: "AppleMusicPreanalysis")
                        .error("song=\(songID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        schedule()
    }
}
