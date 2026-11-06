import Foundation
import LiveTextSVG
import XCTest

final class SVGDecodedInvariantTests: XCTestCase {
  private func rejects<T: Codable>(_ value: T, key: String, value invalid: Any) throws {
    let bytes = try JSONEncoder().encode(value)
    XCTAssertNoThrow(try JSONDecoder().decode(T.self, from: bytes))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    object[key] = invalid
    XCTAssertThrowsError(
      try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object)))
  }

  func testColorDecodeEnforcesComponentBounds() throws {
    for component in ["red", "green", "blue", "alpha"] {
      try rejects(LiveTextSVGColor.black, key: component, value: 1.1)
    }
  }

  func testStrokeDecodeEnforcesWidthAndMiterLimit() throws {
    try rejects(LiveTextSVGStrokeStyle.default, key: "width", value: 0)
    try rejects(LiveTextSVGStrokeStyle.default, key: "miterLimit", value: 0.5)
  }

  func testSizeDecodeEnforcesPositiveViewport() throws {
    try rejects(LiveTextSVGSize(width: 1, height: 1), key: "width", value: 0)
    try rejects(LiveTextSVGSize(width: 1, height: 1), key: "height", value: -1)
  }

  func testArtworkPathDecodeEnforcesItsConstructionContract() throws {
    let line = LiveTextSVGCommand.line(to: try LiveTextSVGPoint(x: 2, y: 2))
    let path = try LiveTextSVGArtworkPath(
      commands: [.move(to: LiveTextSVGPoint(x: 1, y: 1)), line],
      paint: .fill(color: .black, rule: .nonZero))
    try rejects(path, key: "commands", value: [])
    let lineOnly = try JSONSerialization.jsonObject(with: JSONEncoder().encode([line]))
    try rejects(path, key: "commands", value: lineOnly)

    let document = try LiveTextSVGArtworkDocument(
      size: LiveTextSVGSize(width: 10, height: 10),
      coordinateBounds: LiveTextSVGRect(minX: 0, minY: 0, maxX: 10, maxY: 10),
      paths: [path])
    var invalidPath = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(path)) as? [String: Any])
    invalidPath["commands"] = []
    try rejects(document, key: "paths", value: [invalidPath])
  }
}
