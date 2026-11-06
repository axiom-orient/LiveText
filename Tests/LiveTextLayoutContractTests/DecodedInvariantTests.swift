import Foundation
import LiveTextCore
import LiveTextLayout
import XCTest

/// Real Codable boundary tests: valid production values are encoded, one field
/// is corrupted, then the public decoder must enforce the constructor contract.
final class DecodedInvariantTests: XCTestCase {
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
      file: file, line: line
    )
  }

  private var range: InlineSourceRange {
    get throws {
      try InlineSourceRange(startUTF16: 0, endUTF16: 1)
    }
  }

  func testDigestRejectsMalformedHexBeforeBytesCanBeAccessed() throws {
    let digest = InlineAssetDigest(data: Data("verified bytes".utf8))
    for hex in ["a", "", String(repeating: "g", count: 64), String(repeating: "0", count: 63)] {
      try reject(digest) { $0["hex"] = hex }
    }
  }

  func testDigestDecodeUsesCanonicalLowercaseAndPreservesWireShape() throws {
    let hex = String(repeating: "a1", count: 32)
    let input = Data("{\"hex\":\"\(hex.uppercased())\"}".utf8)
    let digest = try JSONDecoder().decode(InlineAssetDigest.self, from: input)
    XCTAssertEqual(digest.hex, hex)
    XCTAssertEqual(digest.bytes, Array(repeating: 0xa1, count: 32))
    XCTAssertEqual(
      String(decoding: try JSONEncoder().encode(digest), as: UTF8.self),
      "{\"hex\":\"\(hex)\"}")
  }

  func testImageAccessibilityDecodeRejectsBlankLabelWithoutChangingWireShape() throws {
    let accessibility = try InlineImageAccessibility(label: "Diagram")
    let encoded = try JSONEncoder().encode(accessibility)
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
      ["label": ["_0": "Diagram"]] as NSDictionary)
    XCTAssertEqual(
      try JSONDecoder().decode(InlineImageAccessibility.self, from: encoded), accessibility)

    let invalid = Data(#"{"label":{"_0":"   "}}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(InlineImageAccessibility.self, from: invalid))
  }

  func testImageReferenceAndCacheKeyRejectNegativeVersion() throws {
    let id = try InlineAssetID(rawValue: "asset")
    try reject(InlineImageReference(assetID: id, data: Data())) { $0["version"] = -1 }
    try reject(InlineAssetCache.Key(id: id, version: 1)) { $0["version"] = -1 }
  }

  func testRegistryRejectsDuplicateAssetIDsOnDecode() throws {
    let record = try InlineAssetRecord(
      id: InlineAssetID(rawValue: "asset"), version: 1,
      metrics: InlineMetrics(advance: 1, ascent: 1, descent: 0))
    try reject(InlineAssetRegistry(records: [record])) {
      let records = $0["records"] as! [Any]
      $0["records"] = records + records
    }
  }

  func testCustomTextUnitRejectsEmptyIdentifierAndRange() throws {
    let unit = try InlineCustomTextUnit(id: "word", sourceRange: range)
    try reject(unit) { $0["id"] = "" }
    try reject(unit) { $0["sourceRange"] = ["startUTF16": 0, "endUTF16": 0] }
  }

  func testRevealUnitRejectsInvalidTimingAndAtomID() throws {
    let unit = try InlineRevealUnit(
      id: InlineRevealUnitID(rawValue: "unit"), kind: .grapheme,
      atomID: "text", sourceRange: range, startTime: 0, duration: 1)
    try reject(unit) { $0["startTime"] = -1 }
    try reject(unit) { $0["duration"] = 0 }
    try reject(unit) { $0["atomID"] = "" }
  }

  func testWritingPointRejectsOutOfRangeCoordinatesAndWidth() throws {
    let point = try InlineNormalizedWritingPoint(x: 0.5, y: 0.5)
    try reject(point) { $0["x"] = -0.1 }
    try reject(point) { $0["y"] = 1.1 }
    try reject(point) { $0["width"] = 0 }
  }

  func testWritingStrokeRejectsEmptyPoints() throws {
    let stroke = try InlineWritingStroke(points: [InlineNormalizedWritingPoint(x: 0, y: 0)])
    try reject(stroke) { $0["points"] = [] }
  }

  func testWritingGlyphRejectsInvalidCharacterAndAdvance() throws {
    let glyph = try InlineWritingGlyph(character: "a", advance: 1, strokes: [])
    try reject(glyph) { $0["character"] = "ab" }
    try reject(glyph) { $0["advance"] = -1 }
  }

  func testPreparedWritingUnitRejectsEmptyRange() throws {
    let unit = try InlinePreparedWritingUnit(
      id: InlineRevealUnitID(rawValue: "unit"), sourceRange: range, kind: .nativeAtomic)
    try reject(unit) { $0["sourceRange"] = ["startUTF16": 1, "endUTF16": 1] }
  }

  func testPositionedAtomRejectsInvalidGeometry() throws {
    let atom = try PositionedInlineAtom(
      atomID: "text", kind: .text, lineIndex: 0, originX: 0, baselineY: 1,
      width: 1, height: 1, metrics: InlineMetrics(advance: 1, ascent: 1, descent: 0))
    try reject(atom) { $0["lineIndex"] = -1 }
    try reject(atom) { $0["width"] = -1 }
    try reject(atom) { $0["scale"] = 0 }
  }

  func testLayoutLineRejectsInvalidGeometry() throws {
    let cursor = InlineCursor(atomIndex: 0, graphemeIndex: 0)
    let line = try InlineLayoutLine(
      index: 0, baselineY: 1, ascent: 1, descent: 0,
      leading: 0, width: 0, start: cursor, end: cursor, atoms: [])
    try reject(line) { $0["index"] = -1 }
    try reject(line) { $0["ascent"] = -1 }
  }

  func testPathBoundsRejectsReversedExtent() throws {
    let bounds = try InlinePathBounds(minX: 0, minY: 0, maxX: 1, maxY: 1)
    try reject(bounds) { $0["maxX"] = -1 }
    try reject(bounds) { $0["maxY"] = -1 }
  }

  func testHitPointRejectsNonFiniteDecodedValue() throws {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    XCTAssertThrowsError(
      try decoder.decode(InlineHitPoint.self, from: Data("{\"x\":\"inf\",\"y\":0}".utf8)))
  }
  func testHitValuesRejectInvalidStandaloneDecodedIdentity() throws {
    let textJSON: [String: Any] = [
      "atomID": "text", "unitKind": "word",
      "sourceRange": ["startUTF16": 0, "endUTF16": 1], "lineIndex": 0,
      "rect": ["minX": 0.0, "minY": 0.0, "width": 1.0, "height": 1.0],
    ]
    let text = try JSONDecoder().decode(
      InlineTextUnitHit.self, from: JSONSerialization.data(withJSONObject: textJSON))
    try reject(text) { $0["atomID"] = "" }
    try reject(text) { $0["customID"] = "unexpected" }

    let asset = try InlineAssetID(rawValue: "asset")
    let vectorJSON: [String: Any] = [
      "atomID": "vector", "assetID": asset.rawValue, "assetVersion": 1,
      "lineIndex": 0,
      "rect": ["minX": 0.0, "minY": 0.0, "width": 1.0, "height": 1.0],
    ]
    let vector = try JSONDecoder().decode(
      InlineVectorHit.self, from: JSONSerialization.data(withJSONObject: vectorJSON))
    try reject(vector) { $0["assetVersion"] = -1 }
  }

  func testStandaloneHitIndexesRejectEmptyPreparationRevision() throws {
    let profile: [String: Any] = [
      "unitKind": "word", "cjk": "eachGrapheme", "punctuation": "exclude",
      "includeWhitespace": false, "includeVectors": true, "includeImages": true,
    ]
    let object: [String: Any] = [
      "targets": [], "profile": profile, "preparationRevision": "revision",
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    let index = try JSONDecoder().decode(InlineHitTestIndex.self, from: data)
    let chunk = try JSONDecoder().decode(InlineHitTestChunk.self, from: data)
    try reject(index) { $0["preparationRevision"] = "" }
    try reject(chunk) { $0["preparationRevision"] = "" }
  }

}
