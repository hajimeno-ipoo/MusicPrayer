import XCTest
@testable import MusicPrayer

final class AppleMusicLyricCacheTests: XCTestCase {
    func testCachedAvailabilityKeepsUnknownUnpublishedAndNativeOutcomesDistinctAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let songs = ["unknown", "unpublished", "native"].map {
            AppleMusicSong(id: $0, title: "", artist: "", album: "", duration: 60)
        }
        let cache = AppleMusicAnalysisCache(directory: directory)
        try await cache.retainSongs(Set(songs.map(\.id)))
        for song in songs {
            let issued = await cache.ticket(for: song.id)
            let ticket = try XCTUnwrap(issued)
            var timing = AppleMusicLyricTiming(songID: song.id, duration: 60,
                sourceText: song.id == "native" ? "公式文字時刻のある歌詞" : "", timeline: nil, errorMessage: nil)
            if song.id == "unpublished" { timing.hasLyrics = false }
            if song.id == "native" {
                timing.hasLyrics = true
                timing.usesOfficialWordTimings = true
            }
            let saved = try await cache.saveLyricTiming(timing, ticket: ticket)
            XCTAssertTrue(saved)
        }
        let reopened = AppleMusicAnalysisCache(directory: directory)
        try await reopened.retainSongs(Set(songs.map(\.id)))
        let unknown = await reopened.loadLyricTiming(for: songs[0])
        let unpublished = await reopened.loadLyricTiming(for: songs[1])
        let native = await reopened.loadLyricTiming(for: songs[2])
        XCTAssertNil(unknown?.hasLyrics)
        XCTAssertNil(unknown?.usesOfficialWordTimings)
        XCTAssertEqual(unknown?.completion, .missingLyrics)
        XCTAssertEqual(unpublished?.hasLyrics, false)
        XCTAssertEqual(unpublished?.completion, .noLyrics)
        XCTAssertEqual(native?.hasLyrics, true)
        XCTAssertEqual(native?.usesOfficialWordTimings, true)
        XCTAssertEqual(native?.completion, .complete)
    }

    func testOldUnsupportedLanguageFailureIsNotReusedWhileMusicAnalysisSurvives() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = AppleMusicSong(id: "mixed-language-song", title: "", artist: "", album: "", duration: 60)
        let cache = AppleMusicAnalysisCache(directory: directory)
        try await cache.retainSongs([song.id])
        let issued = await cache.ticket(for: song.id)
        let ticket = try XCTUnwrap(issued)
        let analysis = MusicAnalysis(fingerprint: "appleMusic:" + song.id, duration: 60,
                                     beats: [1, 1.5], bpm: 120)
        var failure = AppleMusicLyricTiming(songID: song.id, duration: 60, sourceText: "愛とLove",
            timeline: nil, errorMessage: LyricRecognitionError.unsupportedLanguage("tr").localizedDescription)
        failure.version = AppleMusicLyricTiming.currentVersion - 1
        let musicSaved = try await cache.save(analysis, id: song.id, ticket: ticket)
        let timingSaved = try await cache.saveLyricTiming(failure, ticket: ticket)
        XCTAssertTrue(musicSaved)
        XCTAssertTrue(timingSaved)

        let reopened = AppleMusicAnalysisCache(directory: directory)
        try await reopened.retainSongs([song.id])
        let loadedTiming = await reopened.loadLyricTiming(for: song)
        let loadedMusic = await reopened.load(id: song.id, duration: song.duration)
        XCTAssertNil(loadedTiming)
        XCTAssertEqual(loadedMusic?.fingerprint, analysis.fingerprint)
        XCTAssertEqual(loadedMusic?.duration, analysis.duration)
        XCTAssertEqual(loadedMusic?.beats, analysis.beats)
        XCTAssertEqual(loadedMusic?.bpm, analysis.bpm)
    }

    func testTimingSurvivesRestartWithMusicAndIsRemovedWithItsSong() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = AppleMusicSong(id: "timed-song", title: "", artist: "", album: "", duration: 60)
        let cache = AppleMusicAnalysisCache(directory: directory)
        try await cache.retainSongs([song.id])
        let issued = await cache.ticket(for: song.id)
        let ticket = try XCTUnwrap(issued)
        let analysis = MusicAnalysis(fingerprint: "appleMusic:" + song.id, duration: 60, beats: [1, 1.5], bpm: 120)
        let timing = AppleMusicLyricTiming(songID: song.id, duration: 60, sourceText: "歌詞",
                                          timeline: nil, errorMessage: "認識できませんでした")
        let musicSaved = try await cache.save(analysis, id: song.id, ticket: ticket)
        let timingSaved = try await cache.saveLyricTiming(timing, ticket: ticket)
        XCTAssertTrue(musicSaved)
        XCTAssertTrue(timingSaved)

        let reopened = AppleMusicAnalysisCache(directory: directory)
        try await reopened.retainSongs([song.id])
        let loadedMusic = await reopened.load(id: song.id, duration: 60)
        let loadedTiming = await reopened.loadLyricTiming(for: song)
        XCTAssertEqual(loadedMusic?.beats, [1, 1.5])
        XCTAssertEqual(loadedTiming?.sourceText, "歌詞")
        XCTAssertEqual(loadedTiming?.errorMessage, timing.errorMessage)
        XCTAssertEqual(loadedTiming?.completion, .failedLyrics)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        try await reopened.retainSongs([])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testDeletedRegistrationRejectsLateTimingAfterReaddition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMusicAnalysisCache(directory: directory)
        let song = AppleMusicSong(id: "same-id", title: "", artist: "", album: "", duration: 60)
        try await cache.retainSongs([song.id])
        let issued = await cache.ticket(for: song.id)
        let ticket = try XCTUnwrap(issued)
        try await cache.retainSongs([])
        try await cache.retainSongs([song.id])
        let timing = AppleMusicLyricTiming(songID: song.id, duration: 60, sourceText: "歌詞",
                                          timeline: nil, errorMessage: nil)
        let accepted = try await cache.saveLyricTiming(timing, ticket: ticket)
        let loaded = await cache.loadLyricTiming(for: song)
        XCTAssertFalse(accepted)
        XCTAssertNil(loaded)
    }
}
