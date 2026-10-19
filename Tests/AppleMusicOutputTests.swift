import XCTest
@testable import MusicPrayer

final class AppleMusicOutputTests: XCTestCase {
    @MainActor
    func testAppleMusicCanSelectCurrentSystemOutputAndFollowDefaultWithoutChangingLocalSelection() throws {
        let queue = try? Data(contentsOf: QueuePersistence.file)
        defer { if let queue { try? queue.write(to: QueuePersistence.file) } else { try? FileManager.default.removeItem(at: QueuePersistence.file) } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PlayerStore(lyricDirectory: directory, appleMusicAnalysisDirectory: directory)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let systemID = try XCTUnwrap(AudioOutputs.defaultDevice())
        store.refreshDevices()
        XCTAssertTrue(store.devices.contains { $0.id == systemID })
        store.isAppleMusicActive = true
        XCTAssertEqual(store.selectedOutputID, 0)

        // Re-select the current device: exercise the real HAL setter without switching speakers.
        store.chooseOutput(systemID)
        XCTAssertNil(store.playbackError)
        XCTAssertEqual(store.selectedOutputID, systemID)
        XCTAssertEqual(store.outputDeviceName, AudioOutputs.name(of: systemID))
        XCTAssertEqual(AudioOutputs.defaultDevice(), systemID)
        XCTAssertEqual(store.outputID, 0, "Apple Musicの選択でローカルエンジンの出力設定を書き換えない")

        store.chooseOutput(0)
        XCTAssertNil(store.playbackError)
        XCTAssertEqual(store.selectedOutputID, 0)
        XCTAssertEqual(AudioOutputs.defaultDevice(), systemID)
        store.isAppleMusicActive = false
        XCTAssertEqual(store.selectedOutputID, store.outputID)
    }

    @MainActor
    func testUnavailableOutputDoesNotCommitSelection() {
        let queue = try? Data(contentsOf: QueuePersistence.file)
        defer { if let queue { try? queue.write(to: QueuePersistence.file) } else { try? FileManager.default.removeItem(at: QueuePersistence.file) } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PlayerStore(lyricDirectory: directory, appleMusicAnalysisDirectory: directory)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let original = AudioOutputs.defaultDevice()
        store.isAppleMusicActive = true
        store.chooseOutput(UInt32.max)
        XCTAssertNotNil(store.playbackError)
        XCTAssertEqual(store.selectedOutputID, 0)
        XCTAssertEqual(AudioOutputs.defaultDevice(), original)
    }
}
