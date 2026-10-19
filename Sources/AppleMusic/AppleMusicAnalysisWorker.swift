import AppKit
import Darwin
import Foundation
import WebKit

/// A transient copy for an internal analysis process. Authentication never goes to a file or log.
struct AppleMusicWorkerSession: Codable, Sendable {
    struct Cookie: Codable, Sendable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
        var secure: Bool
        var httpOnly: Bool

        init(_ cookie: HTTPCookie) {
            name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
            expires = cookie.expiresDate; secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly
        }

        var httpCookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path
            ]
            if let expires { properties[.expires] = expires }
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE" }
            return HTTPCookie(properties: properties)
        }
    }

    var localStorage: Data
    var cookies: [Cookie]

    @MainActor
    static func capture(from store: WKWebsiteDataStore) async throws -> Self {
        let storage = try await store.fetchData(of: [WKWebsiteDataTypeLocalStorage])
        let cookies = await store.httpCookieStore.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "apple.com" || domain.hasSuffix(".apple.com")
        }
        return Self(localStorage: storage, cookies: cookies.map(Cookie.init))
    }

    @MainActor
    func restore(into store: WKWebsiteDataStore) async throws {
        try await store.restoreData(localStorage)
        for value in cookies {
            guard let cookie = value.httpCookie else { throw AppleMusicWorkerError.invalidSession }
            await store.httpCookieStore.setCookie(cookie)
        }
    }
}

/// Each process owns one WebKit audio process, one muted capture, and one analysis.
@MainActor
enum AppleMusicAnalysisWorker {
    static let argument = "--apple-music-analysis-worker"
    private static let cacheArgument = "--analysis-directory"

    static func run(
        song: AppleMusicSong,
        session: AppleMusicWorkerSession,
        onProgress: @escaping @MainActor (AppleMusicPreanalysis.Phase, Double) -> Void,
        onReady: @escaping @MainActor (Int32) -> Void
    ) async throws -> MusicAnalysis {
        guard let executable = Bundle.main.executableURL else { throw AppleMusicWorkerError.unavailable }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MusicPrayerAnalysis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = Pipe(), output = Pipe(), process = Process()
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw AppleMusicWorkerError.unavailable
        }
        process.executableURL = executable
        process.arguments = [argument, cacheArgument, directory.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let lifetime = WorkerProcessLifetime(process: process, input: input.fileHandleForWriting)
        let request = try JSONEncoder().encode(WorkerRequest(song: song, session: session))

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try lifetime.launch()
            // Closing the unused ends makes EOF mean that this worker has actually ended.
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            let writer = Task.detached(priority: .utility) {
                defer { try? input.fileHandleForWriting.close() }
                try input.fileHandleForWriting.write(contentsOf: request)
            }
            var result: MusicAnalysis?
            var failure: Error?
            var ready = false
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    try Task.checkCancellation()
                    guard let data = line.data(using: .utf8), let event = try? JSONDecoder().decode(WorkerEvent.self, from: data) else {
                        throw AppleMusicWorkerError.invalidResponse
                    }
                    switch event.kind {
                    case .progress:
                        guard let phase = event.phase.flatMap(Self.phase), let position = event.position, position.isFinite else {
                            throw AppleMusicWorkerError.invalidResponse
                        }
                        onProgress(phase, max(0, position))
                    case .ready:
                        guard let pid = event.processID, pid > 0 else { throw AppleMusicWorkerError.invalidResponse }
                        if !ready { ready = true; onReady(pid) }
                    case .result:
                        result = event.analysis
                    case .error:
                        failure = AppleMusicWorkerError.analysis(event.message ?? "Apple Musicの事前解析に失敗しました。")
                    }
                }
            } catch {
                failure = error
                lifetime.cancel()
            }
            if case .failure(let error) = await writer.result, failure == nil { failure = error }
            lifetime.closeInput()
            await lifetime.waitForExit()
            try? output.fileHandleForReading.close()
            try Task.checkCancellation()
            if let failure { throw failure }
            guard process.terminationStatus == 0, let result,
                  result.fingerprint == "appleMusic:" + song.id,
                  result.duration.isFinite, abs(result.duration - song.duration) < 1 else {
                throw AppleMusicWorkerError.invalidResponse
            }
            return result
        } onCancel: {
            lifetime.cancel()
        }
    }

    /// Called instead of SwiftUI's App.main() for the internal process mode.
    static func runMain() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            var status: Int32 = 1
            do {
                let data = try FileHandle.standardInput.readToEnd() ?? Data()
                let request = try JSONDecoder().decode(WorkerRequest.self, from: data)
                guard let index = CommandLine.arguments.firstIndex(of: cacheArgument),
                      CommandLine.arguments.indices.contains(index + 1) else {
                    throw AppleMusicWorkerError.invalidRequest
                }
                let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
                try await execute(request, directory: directory)
                status = 0
            } catch {
                // Keep WebKit errors, URLs, cookie values, and storage data out of IPC diagnostics.
                let message: String
                if let error = error as? AppleMusicWorkerError { message = error.localizedDescription }
                else { message = "Apple Musicの事前解析に失敗しました。" }
                try? emit(WorkerEvent(kind: .error, message: message))
            }
            try? FileHandle.standardOutput.close()
            exit(status)
        }
        application.run()
    }

    private static func execute(_ request: WorkerRequest, directory: URL) async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        try await request.session.restore(into: dataStore)
        let store = AppleMusicStore(analysisDirectory: directory, websiteDataStore: dataStore, usesAnalysisWorkers: false)
        let webView = store.webViewForDisplay()
        // WebKit gets a live window without a visible surface, activation, or a Dock item.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = webView
        window.orderBack(nil)
        defer { store.stop(); window.orderOut(nil); window.contentView = nil }

        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while !store.playback.isReady || !store.playback.isAuthorized {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw AppleMusicWorkerError.connection }
            store.pollPlayback()
            try await Task.sleep(for: .milliseconds(50))
        }
        let reporter = Task { @MainActor in
            var lastPhase: String?, lastPosition: Double?
            while !Task.isCancelled {
                let phase = String(describing: store.workerPhase), position = store.workerPosition
                if phase != lastPhase || position != lastPosition {
                    try? emit(WorkerEvent(kind: .progress, phase: phase, position: position))
                    lastPhase = phase; lastPosition = position
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { reporter.cancel() }
        let analysis = try await store.analyzeInWorker(request.song) { pid in
            try? emit(WorkerEvent(kind: .ready, processID: pid))
        }
        try emit(WorkerEvent(kind: .result, analysis: analysis))
    }

    private static func phase(_ value: String) -> AppleMusicPreanalysis.Phase? {
        switch value {
        case "preparing": return .preparing
        case "capturing": return .capturing
        case "analyzing": return .analyzing
        case "restoring": return .restoring
        default: return nil
        }
    }

    private static func emit(_ event: WorkerEvent) throws {
        var data = try JSONEncoder().encode(event)
        data.append(0x0a)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}

private struct WorkerRequest: Codable {
    var song: AppleMusicSong
    var session: AppleMusicWorkerSession
}

private struct WorkerEvent: Codable {
    enum Kind: String, Codable { case progress, ready, result, error }
    var kind: Kind
    var processID: Int32? = nil
    var phase: String? = nil
    var position: Double? = nil
    var analysis: MusicAnalysis? = nil
    var message: String? = nil
}

private enum AppleMusicWorkerError: LocalizedError {
    case unavailable, invalidRequest, invalidSession, invalidResponse, connection, analysis(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Apple Musicの解析処理を起動できませんでした。"
        case .invalidRequest: return "Apple Musicの解析要求を読み込めませんでした。"
        case .invalidSession: return "Apple Musicの接続状態を引き継げませんでした。"
        case .invalidResponse: return "Apple Musicの解析結果を受け取れませんでした。"
        case .connection: return "Apple Musicの接続を準備できませんでした。公式画面のサインイン状態を確認してください。"
        case .analysis(let message): return message
        }
    }
}

/// Launch and cancellation may race; the lock makes cancellation win even before Process.run().
private final class WorkerProcessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let input: FileHandle
    private var cancelled = false
    private var launched = false

    init(process: Process, input: FileHandle) { self.process = process; self.input = input }

    func launch() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        launched = true
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if launched, process.isRunning { process.terminate() }
        try? input.close()
    }

    func closeInput() { try? input.close() }

    func waitForExit() async {
        await Task.detached(priority: .utility) { [process] in process.waitUntilExit() }.value
    }
}
