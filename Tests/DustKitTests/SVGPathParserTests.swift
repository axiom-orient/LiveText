#if os(iOS)
import CoreGraphics
import XCTest

@testable import DustKit

final class SVGPathParserTests: XCTestCase {
  func testAbsoluteAndRelativeCommands() throws {
    let path = try DustSVGPathParser.parse("M10 10 h20 v20 h-20 z")
    XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 10, y: 10, width: 20, height: 20))
  }

  func testCubicQuadraticAndShorthandCommands() throws {
    let path = try DustSVGPathParser.parse(
      "M0 20 C10 0 20 0 30 20 S50 40 60 20 Q70 0 80 20 T100 20"
    )
    XCTAssertFalse(path.isEmpty)
    XCTAssertEqual(path.currentPoint, CGPoint(x: 100, y: 20))
  }

  func testEllipticalArcEndsAtRequestedPoint() throws {
    let path = try DustSVGPathParser.parse("M10 50 A40 20 30 0 1 90 50")
    XCTAssertEqual(path.currentPoint.x, 90, accuracy: 0.001)
    XCTAssertEqual(path.currentPoint.y, 50, accuracy: 0.001)
  }

  func testMalformedOperandCountFails() {
    XCTAssertThrowsError(try DustSVGPathParser.parse("M10"))
  }
}
#endif
