import Foundation
import LiveTextEffects
import XCTest

final class ColoredPencilSamplingTests: XCTestCase {
  func testDecodedFiniteExtremesCanBeSampledWithoutOverflow() throws {
    let plan = try ColoredPencilPathPlan(points: [
      ColoredPencilPoint(x: 0, y: 0), ColoredPencilPoint(x: 20, y: 0),
    ])
    let stroke = try XCTUnwrap(plan.strokes.first)
    var encoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(stroke)) as? [String: Any])
    var points = try XCTUnwrap(encoded["points"] as? [[String: Any]])
    points[0]["x"] = -Double.greatestFiniteMagnitude
    points[0]["y"] = -Double.greatestFiniteMagnitude
    points[1]["x"] = Double.greatestFiniteMagnitude
    points[1]["y"] = Double.greatestFiniteMagnitude
    encoded["points"] = points
    let restored = try JSONDecoder().decode(
      ColoredPencilStrokePlan.self, from: JSONSerialization.data(withJSONObject: encoded))
    let sampled = restored.points(upToDistance: restored.cumulativeLengths[1] / 2)
    let midpoint = try XCTUnwrap(sampled.last)
    XCTAssertEqual(midpoint.x, 0)
    XCTAssertEqual(midpoint.y, 0)
    XCTAssertTrue(midpoint.width.isFinite)
    XCTAssertEqual(restored.points(upToDistance: 0).first, restored.points.first)
    XCTAssertEqual(restored.points(upToDistance: restored.length), restored.points)
  }

  func testDecodedWidthEndpointsAndSubnormalConstantsArePreserved() throws {
    let plan = try ColoredPencilPathPlan(points: [
      ColoredPencilPoint(x: 0, y: 0), ColoredPencilPoint(x: 20, y: 0),
    ])
    let stroke = try XCTUnwrap(plan.strokes.first)
    var encoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(stroke)) as? [String: Any])
    var points = try XCTUnwrap(encoded["points"] as? [[String: Any]])
    points[0]["width"] = Double.greatestFiniteMagnitude
    points[1]["width"] = Double.leastNonzeroMagnitude
    encoded["points"] = points
    var restored = try JSONDecoder().decode(
      ColoredPencilStrokePlan.self, from: JSONSerialization.data(withJSONObject: encoded))
    XCTAssertEqual(restored.points(upToDistance: restored.cumulativeLengths[1]).last?.width,
      Double.leastNonzeroMagnitude)
    points[0]["width"] = Double.leastNonzeroMagnitude
    encoded["points"] = points
    restored = try JSONDecoder().decode(
      ColoredPencilStrokePlan.self, from: JSONSerialization.data(withJSONObject: encoded))
    XCTAssertEqual(restored.points(upToDistance: restored.cumulativeLengths[1] / 2).last?.width,
      Double.leastNonzeroMagnitude)
  }
}
