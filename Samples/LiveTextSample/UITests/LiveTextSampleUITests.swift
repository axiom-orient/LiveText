import XCTest

@MainActor
final class LiveTextSampleUITests: XCTestCase {
  private let sampleCards = [
    "Writing + materials",
    "Renderer parity",
    "Expressive motion",
    "Responsive reflow",
    "Mixed inline flow",
    "SVG composition",
    "Append stream",
    "Standalone chalk",
    "Dust terminal effect",
  ]

  func testEverySampleRouteIsReachable() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.navigationBars["LiveText"].waitForExistence(timeout: 15))

    for title in sampleCards {
      let card = app.buttons[title]
      XCTAssertTrue(card.waitForExistence(timeout: 5), "Missing sample card: \(title)")
      card.tap()

      XCTAssertTrue(
        app.navigationBars[title].waitForExistence(timeout: 5),
        "Route did not open: \(title)"
      )
      let backButton = app.navigationBars.buttons.element(boundBy: 0)
      XCTAssertTrue(backButton.exists, "Missing back button: \(title)")
      backButton.tap()
      XCTAssertTrue(app.navigationBars["LiveText"].waitForExistence(timeout: 5))
    }
  }

  func testWritingRouteExposesPlaybackControls() {
    let app = XCUIApplication()
    app.launch()

    let card = app.buttons["Writing + materials"]
    XCTAssertTrue(card.waitForExistence(timeout: 15))
    card.tap()

    XCTAssertTrue(app.buttons["Replay"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.switches["Auto-repeat"].exists)
    XCTAssertTrue(app.buttons["Pause"].exists || app.buttons["Play"].exists)
  }
}
