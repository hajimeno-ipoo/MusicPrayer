import XCTest
@testable import MusicPrayer

final class AppleMusicLyricCacheTests: XCTestCase {
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
