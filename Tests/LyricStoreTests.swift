import Darwin
import Foundation
import XCTest
@testable import MusicPrayer

final class LyricStoreTests: XCTestCase {
    func testBodyPersistsWithoutAnalysisAndValidTimelineRoundTrips() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LyricStore(directory: fixture.lyrics)
        let source = "  君の声\r\n\r\n遠い夜の向こうから  "
        let fingerprint = try await store.saveText(url: fixture.audio, text: source, request: 1)
        XCTAssertEqual(fingerprint, LyricHash.digest(fixture.audioBytes))
        let restoredBody = try await store.load(fingerprint: fingerprint)
        XCTAssertEqual(restoredBody?.sourceText, source)
        XCTAssertEqual(restoredBody?.sourceTextHash, LyricHash.text(source))
        XCTAssertEqual(restoredBody?.audioFingerprint, fingerprint)
        XCTAssertEqual(restoredBody?.schemaVersion, LyricVersions.schema)
        XCTAssertNil(restoredBody?.timeline)

        let timeline = makeTimeline(fingerprint: fingerprint, source: source)
        try await store.saveTimeline(timeline, request: 1)
        let restoredTimeline = try await store.load(fingerprint: fingerprint)
        XCTAssertEqual(restoredTimeline?.timeline, timeline)

        _ = try await store.saveText(url: fixture.audio, text: "新しい本文", request: 2)
        let editedBody = try await store.load(fingerprint: fingerprint)
        XCTAssertEqual(editedBody?.sourceText, "新しい本文")
        XCTAssertNil(editedBody?.timeline)
    }

    func testDeletePreventsOldBodyAndOldTimelineFromReappearing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LyricStore(directory: fixture.lyrics)
        let fingerprint = try await store.saveText(url: fixture.audio, text: "古い本文", request: 1)
        let oldTimeline = makeTimeline(fingerprint: fingerprint, source: "古い本文")
        _ = try await store.clear(url: fixture.audio, request: 2)
        do {
            _ = try await store.saveText(url: fixture.audio, text: "古い本文", request: 1)
            XCTFail("削除より古い本文要求を受理してはいけません")
        } catch { XCTAssertEqual(error as? LyricStoreError, .staleRequest) }
        do {
            try await store.saveTimeline(oldTimeline, request: 1)
            XCTFail("削除より古い生成結果を受理してはいけません")
        } catch { XCTAssertEqual(error as? LyricStoreError, .staleRequest) }
        let saved = try await store.load(fingerprint: fingerprint)
        XCTAssertNil(saved)
    }

    func testSameAudioAtDifferentURLsUsesTheNewestRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("same-bytes.bin")
        try fixture.audioBytes.write(to: alias)
        let store = LyricStore(directory: fixture.lyrics)
        let fingerprint = try await store.saveText(url: alias, text: "新しい本文", request: 12)
        do {
            _ = try await store.saveText(url: fixture.audio, text: "古い本文", request: 11)
            XCTFail("同じfingerprintへ古いURL側の要求を書いてはいけません")
        } catch { XCTAssertEqual(error as? LyricStoreError, .staleRequest) }
        do {
            _ = try await store.clear(url: fixture.audio, request: 10)
            XCTFail("同じfingerprintへ古い削除要求を適用してはいけません")
        } catch { XCTAssertEqual(error as? LyricStoreError, .staleRequest) }
        let saved = try await store.load(fingerprint: fingerprint)
        XCTAssertEqual(saved?.sourceText, "新しい本文")
        _ = try await store.clear(url: fixture.audio, request: 13)
        let cleared = try await store.load(fingerprint: fingerprint)
        XCTAssertNil(cleared)
    }

    func testNewerRequestWhoseHashFailsStillInvalidatesOldURLRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LyricStore(directory: fixture.lyrics)
        try FileManager.default.removeItem(at: fixture.audio)
        let standardizedAlias = fixture.root.appendingPathComponent(".").appendingPathComponent("audio.bin")
        do {
            _ = try await store.clear(url: standardizedAlias, request: 2)
            XCTFail("音源を読めない削除要求は失敗すること")
        } catch { XCTAssertNotEqual(error as? LyricStoreError, .staleRequest) }
        try fixture.audioBytes.write(to: fixture.audio)
        do {
            _ = try await store.saveText(url: fixture.audio, text: "古い本文", request: 1)
            XCTFail("hash取得失敗後にも古い本文を保存してはいけません")
        } catch { XCTAssertEqual(error as? LyricStoreError, .staleRequest) }
        _ = try await store.clear(url: fixture.audio, request: 2)
    }

    func testBrokenJSONIsReportedWhileDamagedTimelineKeepsReadableBody() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LyricStore(directory: fixture.lyrics)
        let fingerprint = try await store.saveText(url: fixture.audio, text: "本文を保持", request: 1)
        let file = fixture.file(fingerprint)
        let intact = try Data(contentsOf: file)
        try Data("{ broken".utf8).write(to: file, options: .atomic)
        do {
            _ = try await store.load(fingerprint: fingerprint)
            XCTFail("壊れたJSONを歌詞なしとして隠してはいけません")
        } catch { XCTAssertEqual(error as? LyricStoreError, .inconsistentData) }
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: intact) as? [String: Any])
        envelope["timeline"] = ["unreadable": true]
        try JSONSerialization.data(withJSONObject: envelope).write(to: file, options: .atomic)
        let recovered = try await store.load(fingerprint: fingerprint)
        XCTAssertEqual(recovered?.sourceText, "本文を保持")
        XCTAssertNil(recovered?.timeline)

        envelope.removeValue(forKey: "sourceText")
        try JSONSerialization.data(withJSONObject: envelope).write(to: file, options: .atomic)
        do {
            _ = try await store.load(fingerprint: fingerprint)
            XCTFail("本文が復元できない場合はエラーとして伝えること")
        } catch { XCTAssertEqual(error as? LyricStoreError, .inconsistentData) }

        envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: intact) as? [String: Any])
        envelope["audioFingerprint"] = String(repeating: "a", count: 64)
        try JSONSerialization.data(withJSONObject: envelope).write(to: file, options: .atomic)
        do {
            _ = try await store.load(fingerprint: fingerprint)
            XCTFail("保存先名と違う音源の本文を復元してはいけません")
        } catch { XCTAssertEqual(error as? LyricStoreError, .inconsistentData) }
    }

    func testStaleSavedKeysDiscardOnlyTimeline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LyricStore(directory: fixture.lyrics)
        let fingerprint = try await store.saveText(url: fixture.audio, text: "君の声", request: 1)
        try await store.saveTimeline(makeTimeline(fingerprint: fingerprint, source: "君の声"), request: 1)
        let file = fixture.file(fingerprint)
        let intact = try Data(contentsOf: file)
        let mutations: [(String, Any)] = [("version", 0), ("version", 1), ("version", 2), ("version", 3), ("version", 4), ("analysisVersion", 0),
                                         ("mode", "vocalAndPhrases"),
                                         ("analysisFingerprint", String(repeating: "a", count: 64)),
                                         ("sourceTextHash", String(repeating: "b", count: 64)),
                                         ("analysisDigest", "invalid")]
        for (key, value) in mutations {
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: intact) as? [String: Any])
            var timeline = try XCTUnwrap(envelope["timeline"] as? [String: Any])
            timeline[key] = value
            envelope["timeline"] = timeline
            try JSONSerialization.data(withJSONObject: envelope).write(to: file, options: .atomic)
            let recovered = try await store.load(fingerprint: fingerprint)
            XCTAssertEqual(recovered?.sourceText, "君の声", key)
            XCTAssertNil(recovered?.timeline, key)
        }
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: intact) as? [String: Any])
        envelope["schemaVersion"] = 0
        envelope["sourceTextHash"] = "outdated"
        try JSONSerialization.data(withJSONObject: envelope).write(to: file, options: .atomic)
        let recovered = try await store.load(fingerprint: fingerprint)
        XCTAssertEqual(recovered?.sourceText, "君の声")
        XCTAssertEqual(recovered?.sourceTextHash, LyricHash.text("君の声"))
        XCTAssertNil(recovered?.timeline)
    }

    func testWriteFailureCanRetrySameConfirmedRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("blocking file".utf8).write(to: fixture.lyrics)
        let store = LyricStore(directory: fixture.lyrics)
        do {
            _ = try await store.saveText(url: fixture.audio, text: "確定本文", request: 3)
            XCTFail("保存先がファイルの場合は保存失敗を返すこと")
        } catch { XCTAssertNotEqual(error as? LyricStoreError, .staleRequest) }
        try FileManager.default.removeItem(at: fixture.lyrics)
        let fingerprint = try await store.saveText(url: fixture.audio, text: "確定本文", request: 3)
        let saved = try await store.load(fingerprint: fingerprint)
        XCTAssertEqual(saved?.sourceText, "確定本文")
    }

    func testDeleteFailureRemainsRetryableAndBlocksOldSave() async throws {
        guard geteuid() != 0 else { throw XCTSkip("管理者特権ではディレクトリの削除権限を検証できません") }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LyricStore(directory: fixture.lyrics)
        let fingerprint = try await store.saveText(url: fixture.audio, text: "保存済み本文", request: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.lyrics.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.lyrics.path) }
        do {
            _ = try await store.clear(url: fixture.audio, request: 2)
            XCTFail("削除権限がない場合は失敗を返すこと")
        } catch { XCTAssertNotEqual(error as? LyricStoreError, .staleRequest) }
        let remaining = try await store.load(fingerprint: fingerprint)
        XCTAssertEqual(remaining?.sourceText, "保存済み本文")
        do {
            _ = try await store.saveText(url: fixture.audio, text: "古い本文", request: 1)
            XCTFail("削除失敗後にも古い本文で上書きしてはいけません")
        } catch { XCTAssertEqual(error as? LyricStoreError, .staleRequest) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.lyrics.path)
        _ = try await store.clear(url: fixture.audio, request: 2)
        let cleared = try await store.load(fingerprint: fingerprint)
        XCTAssertNil(cleared)
    }

    func testChangedAudioBytesCreateDifferentDestinationAndUnsafeKeyIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LyricStore(directory: fixture.lyrics)
        let first = try await store.saveText(url: fixture.audio, text: "旧音源", request: 1)
        try Data("replaced audio".utf8).write(to: fixture.audio)
        let second = try await store.fingerprint(url: fixture.audio)
        XCTAssertNotEqual(first, second)
        let beforeSave = try await store.load(fingerprint: second)
        XCTAssertNil(beforeSave)
        _ = try await store.saveText(url: fixture.audio, text: "新音源", request: 2)
        let replaced = try await store.load(fingerprint: second)
        XCTAssertEqual(replaced?.sourceText, "新音源")
        do {
            _ = try await store.load(fingerprint: "../outside")
            XCTFail("fingerprint以外を保存先名に使ってはいけません")
        } catch { XCTAssertEqual(error as? LyricStoreError, .invalidFingerprint) }
    }

    private func makeTimeline(fingerprint: String, source: String) -> LyricTimeline {
        let hash = LyricHash.text(source)
        let lines = LyricParser.parse(source).map { line in
            TimedLyricLine(id: LyricHash.lineID(audioFingerprint: fingerprint, version: LyricVersions.alignment,
                                              sourceTextHash: hash, ordinal: line.ordinal),
                           ordinal: line.ordinal, text: line.text,
                           start: Double(line.ordinal) * 2 + 1, end: Double(line.ordinal) * 2 + 2,
                           textWeight: line.textWeight, confidence: 0.5,
                           characterTimings: line.text.map { _ in
                               LyricCharacterTiming(start: Double(line.ordinal) * 2 + 1,
                                                    end: Double(line.ordinal) * 2 + 2)
                           })
        }
        return LyricTimeline(version: LyricVersions.alignment, analysisVersion: MusicAnalyzer.cacheVersion,
                             analysisFingerprint: fingerprint, analysisDigest: String(repeating: "d", count: 64),
                             sourceText: source, sourceTextHash: hash, mode: .speechRecognition,
                             lines: lines, confidence: 0.5,
                             frames: [LyricStructureFrame(start: 0, end: Double(lines.count) * 2 + 1,
                                 section: 0, segment: 0, lineOrdinals: lines.map(\.ordinal),
                                 support: LyricFrameSupport())])
    }
}

private struct Fixture {
    let root: URL
    let lyrics: URL
    let audio: URL
    let audioBytes = Data((0..<140_000).map { UInt8($0 % 251) })

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MusicPrayerLyrics-\(UUID().uuidString)",
                                                                           isDirectory: true)
        lyrics = root.appendingPathComponent("Lyrics", isDirectory: true)
        audio = root.appendingPathComponent("audio.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try audioBytes.write(to: audio)
    }

    func file(_ fingerprint: String) -> URL { lyrics.appendingPathComponent("\(fingerprint).json") }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
