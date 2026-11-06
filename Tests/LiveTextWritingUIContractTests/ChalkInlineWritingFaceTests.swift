import ChalkLineEffects
import LiveTextLayout
import XCTest

final class ChalkInlineWritingFaceTests: XCTestCase {
  func testBuiltinFaceAdaptsLatinAndHangulWithoutMovingCatalogOwnership() throws {
    let face = try ChalkInlineWritingFace()
    let latin = try XCTUnwrap(face.glyph(for: "A"))
    let hangul = try XCTUnwrap(face.glyph(for: "한"))

    XCTAssertEqual(latin.character, "A")
    XCTAssertGreaterThanOrEqual(latin.strokes.count, 1)
    XCTAssertGreaterThanOrEqual(hangul.strokes.count, 1)
    XCTAssertTrue(
      latin.strokes.flatMap(\.points).allSatisfy { point in
        (0...1).contains(point.x) && (0...1).contains(point.y) && point.width > 0
      }
    )
  }

  func testEverySupportedASCIIGlyphAdaptsIntoTheInlineUnitCell() throws {
    let face = try ChalkInlineWritingFace()
    var supportedGlyphCount = 0

    for scalarValue in 0x21...0x7E {
      let character = Character(UnicodeScalar(scalarValue)!)
      guard let glyph = try face.glyph(for: character) else { continue }
      supportedGlyphCount += 1
      XCTAssertFalse(glyph.strokes.isEmpty, String(character))
      for point in glyph.strokes.flatMap(\.points) {
        XCTAssertTrue((0...1).contains(point.x), "\(character) x=\(point.x)")
        XCTAssertTrue((0...1).contains(point.y), "\(character) y=\(point.y)")
        XCTAssertGreaterThan(point.width, 0, String(character))
      }
    }

    XCTAssertGreaterThanOrEqual(supportedGlyphCount, 70)
  }
}
