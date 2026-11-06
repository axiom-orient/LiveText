import ChalkLineEffects
import Foundation
import XCTest

final class WritingDecodedInvariantTests: XCTestCase {
  private func reject<T: Codable>(
    _ value: T, _ mutation: (inout [String: Any]) -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let data = try JSONEncoder().encode(value)
    XCTAssertNoThrow(try JSONDecoder().decode(T.self, from: data), file: file, line: line)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    mutation(&object)
    XCTAssertThrowsError(
      try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object)),
      file: file, line: line)
  }

  func testResourceLimitsMustBePositive() throws {
    try reject(WritingResourceLimits.default) { $0["maximumGlyphs"] = 0 }
  }

  func testWritingPointAndStrokeRejectInvalidDecodedGeometry() throws {
    let point = try WritingPoint(x: 0, y: 0)
    try reject(point) { $0["width"] = 0 }
    let stroke = try WritingStroke(id: "stroke", points: [point])
    try reject(stroke) { $0["id"] = "" }
    try reject(stroke) { $0["points"] = [] }
  }

  func testGlyphRejectsDuplicateStrokesAndInvalidIndex() throws {
    let stroke = try WritingStroke(id: "stroke", points: [WritingPoint(x: 0, y: 0)])
    let glyph = try StrokeGlyph(index: 0, cluster: "a", advance: 1, strokes: [stroke])
    try reject(glyph) { $0["index"] = -1 }
    try reject(glyph) { $0["advance"] = -1 }
    try reject(glyph) {
      let values = $0["strokes"] as! [Any]
      $0["strokes"] = values + values
    }
  }

  func testTimingAndLayoutOptionsEnforceConstructorContract() throws {
    try reject(WritingTimingOptions.default) { $0["pointsPerSecond"] = 0 }
    try reject(WritingTimingOptions.default) { $0["interStrokeDelay"] = -1 }
    try reject(WritingLayoutOptions.default) { $0["glyphHeight"] = 0 }
    try reject(WritingLayoutOptions.default) { $0["maximumLineWidth"] = 1 }
  }

  func testCoordinateRejectsNonFiniteDecodedValue() throws {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    XCTAssertThrowsError(
      try decoder.decode(
        WritingCoordinate.self,
        from: Data("{\"x\":\"inf\",\"y\":0}".utf8)))
  }
}
