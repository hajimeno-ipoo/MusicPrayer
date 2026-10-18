import Foundation
import XCTest
@testable import MusicPrayer

final class QueuePersistenceTests: XCTestCase {
    func testMixedQueueRoundTripPreservesOrderSelectionAndCatalogMetadata() throws {
        try withTemporaryDirectory { directory in
            let local = directory.appendingPathComponent("local.wav")
            try Data([0]).write(to: local)
            let song = AppleMusicSong(id: "123456", title: "曲名", artist: "歌手", album: "アルバム",
                                      artworkURL: "https://example.com/cover.jpg", duration: 209)
            let queueFile = directory.appendingPathComponent("session/queue.json")
            try QueuePersistence.save(tracks: [Track(url: local), Track(appleMusicSong: song), Track(url: local)],
                                      current: 1, time: 31, volume: 0.4, to: queueFile)

            let session = try XCTUnwrap(QueuePersistence.restore(from: queueFile))
            XCTAssertEqual(session.tracks.map(\.isAppleMusic), [false, true, false])
            XCTAssertEqual(session.tracks[1].appleMusicSong, song)
            XCTAssertEqual(session.tracks[1].url.absoluteString, "https://music.apple.com/jp/song/123456")
            XCTAssertEqual(session.tracks[1].title, song.title)
            XCTAssertEqual(session.tracks[1].duration, song.duration)
            XCTAssertEqual(session.urls.map { $0.resolvingSymlinksInPath() }, [local, local].map { $0.resolvingSymlinksInPath() })
            XCTAssertEqual(session.current, 1)
            XCTAssertEqual(session.time, 31)
            XCTAssertEqual(session.volume, 0.4)
        }
    }

    func testLegacyBookmarkQueueRestoresExistingLocalSelection() throws {
        try withTemporaryDirectory { directory in
            let first = directory.appendingPathComponent("first.wav")
            let second = directory.appendingPathComponent("second.wav")
            try Data([0]).write(to: first)
            try Data([0]).write(to: second)
            let oldTracks = try [first, second].map { url in
                ["bookmark": try url.bookmarkData().base64EncodedString(), "path": url.path]
            }
            let queueFile = directory.appendingPathComponent("queue.json")
            try JSONSerialization.data(withJSONObject: ["tracks": oldTracks, "current": 1, "time": 12.5, "volume": 0.6]).write(to: queueFile)

            let session = try XCTUnwrap(QueuePersistence.restore(from: queueFile))
            XCTAssertEqual(session.tracks.map(\.isAppleMusic), [false, false])
            XCTAssertEqual(session.urls.map { $0.resolvingSymlinksInPath() }, [first, second].map { $0.resolvingSymlinksInPath() })
            XCTAssertEqual(session.current, 1)
            XCTAssertEqual(session.time, 12.5)
        }
    }

    func testInvalidLegacyBookmarkKeepsMissingLocalFileByPath() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("missing.wav")
            let queueFile = directory.appendingPathComponent("queue.json")
            try JSONSerialization.data(withJSONObject: [
                "tracks": [["bookmark": Data([1, 2, 3]).base64EncodedString(), "path": missing.path]],
                "current": 0, "time": 5, "volume": 0.5
            ]).write(to: queueFile)

            let session = try XCTUnwrap(QueuePersistence.restore(from: queueFile))
            XCTAssertEqual(session.tracks.count, 1)
            XCTAssertEqual(session.urls, [missing])
            XCTAssertEqual(session.current, 0)
        }
    }

    func testUnreadableEntryDoesNotShiftSelectionToDifferentFollowingSong() throws {
        try withTemporaryDirectory { directory in
            let song = AppleMusicSong(id: "123", title: "選択曲", artist: "歌手", album: "", artworkURL: nil, duration: 100)
            let queueFile = directory.appendingPathComponent("queue.json")
            let encodedSong = try JSONSerialization.jsonObject(with: JSONEncoder().encode(song))
            try JSONSerialization.data(withJSONObject: [
                "tracks": [[:], ["appleMusicSong": encodedSong]], "current": 1, "time": 0, "volume": 1
            ]).write(to: queueFile)

            let session = try XCTUnwrap(QueuePersistence.restore(from: queueFile))
            XCTAssertEqual(session.tracks.count, 1)
            XCTAssertEqual(session.tracks[0].appleMusicSong, song)
            XCTAssertEqual(session.current, 0)
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MusicPrayerQueueTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
