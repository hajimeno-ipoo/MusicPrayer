import XCTest
@testable import MusicPrayer

final class PlayerContentDisplayTests: XCTestCase {
    func testRequestedPressOrderRepeatsAfterInitialCombinedDisplay() {
        var display = PlayerContentDisplay.initial
        XCTAssertTrue(display.showsArtwork)
        XCTAssertTrue(display.showsLyrics)
        let expected = [(true, false), (true, true), (false, false),
                        (true, false), (true, true), (false, false)]
        for (artwork, lyrics) in expected {
            display = display.next
            XCTAssertEqual(display.showsArtwork, artwork)
            XCTAssertEqual(display.showsLyrics, lyrics)
            XCTAssertFalse(display.title.isEmpty)
        }
    }
}
