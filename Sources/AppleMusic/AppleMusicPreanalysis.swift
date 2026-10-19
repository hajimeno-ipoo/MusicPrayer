import Foundation
import Observation

/// Each song owns an independent worker. Two workers may capture and analyze at once.
@MainActor @Observable
final class AppleMusicPreanalysis {
    enum Phase { case preparing, capturing, analyzing, restoring }

    private struct Job {
        let ticket: UUID
        let registration: UUID
        let task: Task<Void, Never>
        var phase = Phase.preparing
        var position: Double = 0
    }

    @TaskLocal private static var currentTicket: UUID?
    @ObservationIgnored var operation: (@MainActor (AppleMusicSong) async throws -> Void)?
    @ObservationIgnored private var songs: [AppleMusicSong] = []
    @ObservationIgnored private var registrations: [String: UUID] = [:]
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var allowed = false
    @ObservationIgnored private var stopWaiters = 0
    private var jobs: [String: Job] = [:]
    private(set) var errors: [String: String] = [:]

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
        return attempted.contains(song.id) ? "解析済み" : "解析待ち"
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
        errors = errors.filter { seen.contains($0.key) }
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
                let result: Result<Void, Error> = await Self.$currentTicket.withValue(ticket) {
                    do {
                        try await operation(song)
                        try Task.checkCancellation()
                        return .success(())
                    } catch { return .failure(error) }
                }
                self?.finish(songID: song.id, ticket: ticket, result: result)
            }
            jobs[song.id] = Job(ticket: ticket, registration: registration, task: task)
        }
    }

    private func finish(songID: String, ticket: UUID, result: Result<Void, Error>) {
        guard let job = jobs[songID], job.ticket == ticket else { return }
        jobs[songID] = nil
        if registrations[songID] == job.registration, !job.task.isCancelled {
            attempted.insert(songID)
            switch result {
            case .success: errors[songID] = nil
            case .failure(let error): errors[songID] = error.localizedDescription
            }
        }
        schedule()
    }
}
