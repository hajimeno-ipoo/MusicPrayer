import Foundation

actor LyricStore {
    private let directory: URL
    private var latestURLRequest: [String: UInt64] = [:]
    private var latestFingerprintRequest: [String: UInt64] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                               in: .userDomainMask)[0]
            .appendingPathComponent("com.hazimeno.MusicPrayer/Lyrics", isDirectory: true)
    }

    func fingerprint(url: URL) throws -> String {
        try MusicAnalyzer.fingerprint(url)
    }

    /// A failed write still owns its accepted text unless a newer audio request won.
    func isCurrentRequest(_ request: UInt64, url: URL, fingerprint: String) -> Bool {
        request >= (latestURLRequest[url.standardizedFileURL.absoluteString] ?? 0) &&
        request >= (latestFingerprintRequest[fingerprint] ?? 0)
    }

    func load(fingerprint: String) throws -> SavedLyrics? {
        let file = try fileURL(fingerprint: fingerprint)
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch {
            if isMissingFile(error) { return nil }
            throw error
        }
        let envelope: SavedEnvelope
        do { envelope = try JSONDecoder().decode(SavedEnvelope.self, from: data) }
        catch { throw LyricStoreError.inconsistentData }
        guard envelope.audioFingerprint == fingerprint else { throw LyricStoreError.inconsistentData }

        let actualTextHash = LyricHash.text(envelope.sourceText)
        var timeline = envelope.timeline
        if envelope.schemaVersion != LyricVersions.schema || envelope.sourceTextHash != actualTextHash ||
            !timelineIsConsistent(timeline, fingerprint: fingerprint,
                                  sourceText: envelope.sourceText, sourceTextHash: actualTextHash) {
            // A stale or damaged result must not erase the independently saved source text.
            timeline = nil
        }
        return SavedLyrics(schemaVersion: LyricVersions.schema, audioFingerprint: fingerprint,
                           sourceText: envelope.sourceText, sourceTextHash: actualTextHash,
                           timeline: timeline)
    }

    @discardableResult
    func saveText(url: URL, text: String, request: UInt64) throws -> String {
        try acceptURL(url, request: request)
        let fingerprint = try MusicAnalyzer.fingerprint(url)
        try acceptFingerprint(fingerprint, request: request)
        let saved = SavedLyrics(schemaVersion: LyricVersions.schema, audioFingerprint: fingerprint,
                                sourceText: text, sourceTextHash: LyricHash.text(text), timeline: nil)
        try write(saved)
        return fingerprint
    }

    func saveTimeline(_ timeline: LyricTimeline, request: UInt64) throws {
        let fingerprint = timeline.analysisFingerprint
        try acceptFingerprint(fingerprint, request: request)
        guard var saved = try load(fingerprint: fingerprint),
              saved.sourceText == timeline.sourceText, saved.sourceTextHash == timeline.sourceTextHash,
              timelineIsConsistent(timeline, fingerprint: fingerprint,
                                   sourceText: saved.sourceText, sourceTextHash: saved.sourceTextHash) else {
            throw LyricStoreError.inconsistentData
        }
        saved.timeline = timeline
        try write(saved)
    }

    @discardableResult
    func clear(url: URL, request: UInt64) throws -> String {
        try acceptURL(url, request: request)
        let fingerprint = try MusicAnalyzer.fingerprint(url)
        try acceptFingerprint(fingerprint, request: request)
        let file = try fileURL(fingerprint: fingerprint)
        do { try FileManager.default.removeItem(at: file) }
        catch {
            if !isMissingFile(error) { throw error }
        }
        return fingerprint
    }

    private func acceptURL(_ url: URL, request: UInt64) throws {
        let key = url.standardizedFileURL.absoluteString
        if let latest = latestURLRequest[key], request < latest { throw LyricStoreError.staleRequest }
        latestURLRequest[key] = request
    }

    private func acceptFingerprint(_ fingerprint: String, request: UInt64) throws {
        _ = try fileURL(fingerprint: fingerprint)
        if let latest = latestFingerprintRequest[fingerprint], request < latest {
            throw LyricStoreError.staleRequest
        }
        latestFingerprintRequest[fingerprint] = request
    }

    private func fileURL(fingerprint: String) throws -> URL {
        guard isFingerprint(fingerprint) else { throw LyricStoreError.invalidFingerprint }
        return directory.appendingPathComponent("\(fingerprint).json")
    }

    private func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain &&
            (error.code == CocoaError.Code.fileNoSuchFile.rawValue ||
             error.code == CocoaError.Code.fileReadNoSuchFile.rawValue)
    }

    private func write(_ saved: SavedLyrics) throws {
        let file = try fileURL(fingerprint: saved.audioFingerprint)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(saved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    private func timelineIsConsistent(_ optional: LyricTimeline?, fingerprint: String,
                                      sourceText: String, sourceTextHash: String) -> Bool {
        guard let timeline = optional else { return true }
        guard timeline.version == LyricVersions.alignment,
              timeline.mode == .speechRecognition,
              timeline.analysisVersion == MusicAnalyzer.cacheVersion,
              timeline.analysisFingerprint == fingerprint,
              isFingerprint(timeline.analysisDigest),
              timeline.sourceText == sourceText, timeline.sourceTextHash == sourceTextHash,
              timeline.confidence.isFinite, (0...1).contains(timeline.confidence) else { return false }
        let sourceLines = LyricParser.parse(sourceText)
        guard !sourceLines.isEmpty, timeline.lines.count == sourceLines.count,
              LyricMusicContext.isConsistent(timeline.frames, lines: timeline.lines) else { return false }
        var previousEnd = 0.0
        for (line, source) in zip(timeline.lines, sourceLines) {
            guard line.ordinal == source.ordinal, line.text == source.text,
                  line.textWeight == source.textWeight,
                  line.id == LyricHash.lineID(audioFingerprint: fingerprint, version: timeline.version,
                                             sourceTextHash: sourceTextHash, ordinal: source.ordinal),
                  line.start.isFinite, line.end.isFinite, line.start >= previousEnd,
                  line.end > line.start, line.end - line.start >= 0.30 - 1e-9,
                  line.hasValidCharacterTimings,
                  line.confidence.isFinite, (0...1).contains(line.confidence) else { return false }
            previousEnd = line.end
        }
        return true
    }
}

private struct SavedEnvelope: Decodable {
    var schemaVersion: Int
    var audioFingerprint: String
    var sourceText: String
    var sourceTextHash: String
    var timeline: LyricTimeline?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, audioFingerprint, sourceText, sourceTextHash, timeline
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        audioFingerprint = try values.decode(String.self, forKey: .audioFingerprint)
        sourceText = try values.decode(String.self, forKey: .sourceText)
        sourceTextHash = try values.decode(String.self, forKey: .sourceTextHash)
        timeline = try? values.decodeIfPresent(LyricTimeline.self, forKey: .timeline)
    }
}
