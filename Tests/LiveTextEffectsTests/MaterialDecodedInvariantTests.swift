import Foundation
import LiveTextEffects
import XCTest

final class MaterialDecodedInvariantTests: XCTestCase {
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

  func testMaterialRectangleDecodeEnforcesGeometry() throws {
    try reject(WritingMaterialRect(width: 1, height: 1)) { $0["width"] = -1 }
    try reject(ColoredPencilRect(width: 1, height: 1)) { $0["height"] = -1 }
  }

  func testPencilPointDecodeRejectsZeroWidth() throws {
    try reject(ColoredPencilPoint(x: 0, y: 0)) { $0["width"] = 0 }
  }

  func testMaterialTargetDecodeRejectsEmptyIdentity() throws {
    try reject(
      WritingMaterialTarget(
        targetID: "text", documentOriginX: 0,
        documentOriginY: 0, destination: WritingMaterialRect(width: 1, height: 1))
    ) {
      $0["targetID"] = ""
    }
  }
  func testWidthProfileDecodeRejectsNoncanonicalKnotsAndOrder() throws {
    let profile = WritingWidthProfile(knots: [
      .init(position: 0.2, scale: 1),
      .init(position: 0.8, scale: 0.7),
    ])
    try reject(profile) { object in
      var knots = object["knots"] as! [[String: Any]]
      knots[0]["scale"] = 0
      object["knots"] = knots
    }
    try reject(profile) { object in
      var knots = object["knots"] as! [[String: Any]]
      knots.swapAt(0, 1)
      object["knots"] = knots
    }
  }

  func testDerivedChalkSurfaceDecodeRejectsTamperedState() throws {
    let plan = WritingChalkSurfacePlan(configuration: .default)
    try reject(plan) { $0["baseOpacity"] = 0.25 }
    try reject(plan.edgeDustRecipe) { $0["radius"] = -1 }
  }

  func testMaterialTextureDecodeEnforcesShapeAndBounds() throws {
    let plan = WritingMaterialTexturePlan(material: .brush(.default), dimension: 8)
    try reject(plan) { $0["dimension"] = 9 }
    try reject(plan) { $0["pointSize"] = 1 }
    try reject(plan) { $0["kind"] = "chalk" }
  }

  func testMaterialPlanDecodeEnforcesIdentityBudgetAndOpacity() throws {
    let destination = try WritingMaterialRect(width: 10, height: 10)
    let plan = WritingMaterialPlan(
      material: .brush(.default), targetID: "target",
      documentOriginX: 0, documentOriginY: 0, destination: destination, markCount: 1)
    try reject(plan) { $0["targetID"] = "" }
    try reject(plan) { $0["baseOpacity"] = 2 }
    try reject(plan) { object in
      let mark = (object["marks"] as! [Any]).first!
      object["marks"] = Array(repeating: mark, count: WritingMaterialPlan.maximumMarksPerTarget + 1)
    }
  }

  func testColoredPencilDecodedPlansRejectInconsistentDerivedState() throws {
    let first = try ColoredPencilPoint(x: 0, y: 0)
    let second = try ColoredPencilPoint(x: 20, y: 5)
    let path = try ColoredPencilPathPlan(points: [first, second])
    try reject(path) { $0["sampleCount"] = path.sampleCount + 1 }
    let stroke = try XCTUnwrap(path.strokes.first)
    try reject(stroke) { object in
      var cumulative = object["cumulativeLengths"] as! [Double]
      cumulative[cumulative.count - 1] += 1
      object["cumulativeLengths"] = cumulative
    }
    if let span = stroke.commandSpans.first {
      try reject(span) { $0["endDistance"] = 0 }
    }

    let fill = ColoredPencilFillPlan(
      destination: try ColoredPencilRect(width: 20, height: 20))
    if !fill.hatches.isEmpty {
      try reject(fill) { object in
        var hatches = object["hatches"] as! [[String: Any]]
        hatches[0]["opacity"] = 2
        object["hatches"] = hatches
      }
    }
  }

}
