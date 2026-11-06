import Foundation
import LiveTextLayout
import XCTest

final class InlinePathDataTests: XCTestCase {
  func testBoundsPreserveCurveExtremaAcrossCommandsOnlyRoundTrip() throws {
    let path = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: -2, y: -1)),
      .quadratic(
        control: try InlinePathPoint(x: 8, y: 9),
        to: try InlinePathPoint(x: 18, y: -1)
      ),
      .cubic(
        control1: try InlinePathPoint(x: 18, y: 9),
        control2: try InlinePathPoint(x: 28, y: 9),
        to: try InlinePathPoint(x: 28, y: -1)
      ),
      .close,
    ])
    let expected = try InlinePathBounds(minX: -2, minY: -1, maxX: 28, maxY: 6.5)
    XCTAssertEqual(path.bounds, expected)

    let encoded = try JSONEncoder().encode(path)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(["commands"]))

    let decoded = try JSONDecoder().decode(InlinePathData.self, from: encoded)
    XCTAssertEqual(decoded, path)
    XCTAssertEqual(decoded.commands, path.commands)
    XCTAssertEqual(decoded.bounds, expected)
    XCTAssertTrue(Set([path, decoded]).count == 1)
  }

  func testMaximumCommandPathBoundsRemainStableAcrossRepeatedAccessAndPreparation() throws {
    var commands: [InlinePathCommand] = [
      .move(try InlinePathPoint(x: 0, y: 0))
    ]
    commands.reserveCapacity(InlinePathData.defaultMaximumCommands)
    for index in 1..<InlinePathData.defaultMaximumCommands {
      commands.append(
        .line(try InlinePathPoint(x: Double(index), y: index.isMultiple(of: 2) ? 1 : -1)))
    }

    let path = try InlinePathData(commands: commands)
    XCTAssertEqual(path.commands.count, InlinePathData.defaultMaximumCommands)
    let expected = try InlinePathBounds(
      minX: 0, minY: -1, maxX: Double(InlinePathData.defaultMaximumCommands - 1), maxY: 1)

    var observed: [InlinePathBounds] = []
    observed.reserveCapacity(256)
    for _ in 0..<256 { observed.append(path.bounds) }
    XCTAssertTrue(observed.allSatisfy { $0 == expected })

    let asset = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "maximum-command-path"),
      metrics: try InlineMetrics(advance: 1, ascent: 1, descent: 0),
      coordinateBounds: path.bounds,
      coveragePath: path,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let revealPlan = try InlinePathRevealPlanBuilder(
      secondsPerUnit: 0.001, maximumUnits: InlinePathData.defaultMaximumCommands
    ).plan(asset: asset)
    XCTAssertEqual(revealPlan.units.count, InlinePathData.defaultMaximumCommands - 1)
  }

  func testPathValidationRetainsEmptyAndInvalidBoundaries() throws {
    let point = try InlinePathPoint(x: 0, y: 0)
    XCTAssertThrowsError(try InlinePathData(commands: [])) { error in
      XCTAssertEqual(error as? InlineLayoutError, .emptySVGPath)
    }
    XCTAssertThrowsError(try InlinePathData(commands: [.line(point)])) { error in
      guard case .invalidSVGPath = error as? InlineLayoutError else {
        return XCTFail("expected a move-first validation error")
      }
    }
    XCTAssertThrowsError(try InlinePathData(commands: [.move(point)])) { error in
      XCTAssertEqual(error as? InlineLayoutError, .emptySVGPath)
    }
    XCTAssertThrowsError(try InlinePathData(commands: [.move(point), .line(point)])) { error in
      XCTAssertEqual(error as? InlineLayoutError, .emptySVGPath)
    }
  }

  func testSVGAssetKeepsCoverageAndTrajectoryIndependentAndRejectsIncompletePath() throws {
    let coverage = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 10, y: 0)),
      .line(try InlinePathPoint(x: 10, y: 10)),
      .line(try InlinePathPoint(x: 0, y: 10)),
      .close,
    ])
    let trajectory = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 2, y: 5)),
      .line(try InlinePathPoint(x: 8, y: 5)),
    ])
    let coordinateBounds = try InlinePathBounds(minX: 0, minY: 0, maxX: 10, maxY: 10)
    let asset = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "split-geometry"),
      metrics: try InlineMetrics(advance: 10, ascent: 10, descent: 0),
      coordinateBounds: coordinateBounds,
      coveragePath: coverage,
      coveragePaint: .fill(.evenOdd),
      trajectoryPath: trajectory,
      trajectoryStyle: try InlineSVGStrokeStyle(
        width: 2, cap: .round, join: .round, miterLimit: 3)
    )
    let roundTrip = try JSONDecoder().decode(
      InlineSVGAsset.self,
      from: JSONEncoder().encode(asset)
    )
    XCTAssertEqual(roundTrip, asset)
    XCTAssertNotEqual(asset.coveragePath.bounds, asset.trajectoryPath.bounds)
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlineSVGAsset.self,
        from: Data("{\"id\":\"split-geometry\",\"version\":1,\"metrics\":{}}".utf8)
      )
    )
  }

  func testPathRevealPlanUsesTrajectoryCommandsOnly() throws {
    let coverage = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 10, y: 0)),
      .line(try InlinePathPoint(x: 10, y: 10)),
      .line(try InlinePathPoint(x: 0, y: 10)),
      .close,
    ])
    let trajectory = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 2, y: 5)),
      .line(try InlinePathPoint(x: 8, y: 5)),
    ])
    let asset = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "trajectory-only"),
      metrics: try InlineMetrics(advance: 10, ascent: 10, descent: 0),
      coordinateBounds: try InlinePathBounds(minX: 0, minY: 0, maxX: 10, maxY: 10),
      coveragePath: coverage,
      coveragePaint: .fill(.nonZero),
      trajectoryPath: trajectory,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let plan = try InlinePathRevealPlanBuilder(secondsPerUnit: 0.1).plan(asset: asset)
    XCTAssertEqual(plan.units.map(\.commandIndex), [1])
    XCTAssertNoThrow(try plan.validate(for: asset))
  }
}
