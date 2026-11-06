import XCTest

@testable import LiveTextEffects

final class WritingStrokeGeometryTests: XCTestCase {
  func testOpenStrokeNarrowsAtTerminalWhileClosedStrokeKeepsBodyWidth() {
    let samples = (0...20).map { WritingStrokeSample(x: Double($0) * 10, y: 0) }
    let material = WritingMaterial.brush(.default)
    let open = WritingStrokeGeometryPlan.geometry(
      samples: samples,
      isClosed: false,
      material: material,
      destinationHeight: 24,
      seedSalt: 17
    )
    let closed = WritingStrokeGeometryPlan.geometry(
      samples: samples,
      isClosed: true,
      material: material,
      destinationHeight: 24,
      seedSalt: 17
    )

    let openTail = maximumVerticalExtent(open.body, nearX: 200)
    let closedTail = maximumVerticalExtent(closed.body, nearX: 200)
    XCTAssertGreaterThan(openTail, 0)
    XCTAssertLessThan(openTail, closedTail * 0.60)
  }

  func testGeometryIsDeterministicForSameSeedAndInput() {
    let samples = [
      WritingStrokeSample(x: 0, y: 0),
      WritingStrokeSample(x: 23, y: 7),
      WritingStrokeSample(x: 51, y: 4),
      WritingStrokeSample(x: 80, y: 16),
    ]
    let material = WritingMaterial.ink(.default)
    let first = WritingStrokeGeometryPlan.geometry(
      samples: samples,
      isClosed: false,
      material: material,
      destinationHeight: 32,
      seedSalt: 123
    )
    let second = WritingStrokeGeometryPlan.geometry(
      samples: samples,
      isClosed: false,
      material: material,
      destinationHeight: 32,
      seedSalt: 123
    )
    XCTAssertEqual(first, second)
  }

  func testRevealPrefixKeepsEarlierGeometryStable() {
    let prefix = (0...4).map { WritingStrokeSample(x: Double($0) * 10, y: 0) }
    let extended = (0...20).map { WritingStrokeSample(x: Double($0) * 10, y: 0) }
    let material = WritingMaterial.brush(.default)
    let prefixGeometry = WritingStrokeGeometryPlan.geometry(
      samples: prefix,
      isClosed: false,
      material: material,
      destinationHeight: 24,
      seedSalt: 99
    )
    let extendedGeometry = WritingStrokeGeometryPlan.geometry(
      samples: extended,
      isClosed: false,
      material: material,
      destinationHeight: 24,
      seedSalt: 99
    )
    let prefixPoint = prefixGeometry.body.first { abs($0.x - 10) < 0.01 }
    let extendedPoint = extendedGeometry.body.first { abs($0.x - 10) < 0.01 }
    XCTAssertNotNil(prefixPoint)
    XCTAssertNotNil(extendedPoint)
    XCTAssertEqual(prefixPoint?.x, extendedPoint?.x)
    XCTAssertEqual(prefixPoint?.y, extendedPoint?.y)
  }

  func testSourceArclengthControlsTaperAcrossRevealFragments() {
    let samples = [
      WritingStrokeSample(x: 0, y: 0),
      WritingStrokeSample(x: 40, y: 0),
      WritingStrokeSample(x: 50, y: 0),
    ]
    let material = WritingMaterial.brush(.default)
    let physical = WritingStrokeGeometryPlan.geometry(
      samples: samples,
      isClosed: false,
      material: material,
      destinationHeight: 24,
      seedSalt: 73
    )
    let sourceArclength = WritingStrokeGeometryPlan.geometry(
      samples: samples,
      isClosed: false,
      material: material,
      destinationHeight: 24,
      seedSalt: 73,
      sourceDistances: [0, 40, 80],
      visibleLength: 80
    )
    let physicalBoundary = maximumVerticalExtent(physical.body, nearX: 40)
    let sourceBoundary = maximumVerticalExtent(sourceArclength.body, nearX: 40)
    XCTAssertGreaterThan(physicalBoundary, 0)
    XCTAssertGreaterThan(sourceBoundary, physicalBoundary * 1.05)
  }

  func testInvalidAndExtremeFiniteInputReturnsExplicitEmptyGeometry() {
    let invalid = WritingStrokeGeometryPlan.geometry(
      samples: [
        WritingStrokeSample(x: 0, y: 0),
        WritingStrokeSample(x: .nan, y: 1),
      ],
      isClosed: false,
      material: .pen(.default),
      destinationHeight: 20,
      seedSalt: 1
    )
    let extreme = WritingStrokeGeometryPlan.geometry(
      samples: [
        WritingStrokeSample(x: -Double.greatestFiniteMagnitude, y: 0),
        WritingStrokeSample(x: Double.greatestFiniteMagnitude, y: 0),
      ],
      isClosed: false,
      material: .pen(.default),
      destinationHeight: 20,
      seedSalt: 1
    )
    let invalidSourceDistances = WritingStrokeGeometryPlan.geometry(
      samples: [
        WritingStrokeSample(x: 0, y: 0),
        WritingStrokeSample(x: 10, y: 0),
      ],
      isClosed: false,
      material: .pen(.default),
      destinationHeight: 20,
      seedSalt: 1,
      sourceDistances: [4, 2],
      visibleLength: 2
    )
    XCTAssertTrue(invalid.body.isEmpty)
    XCTAssertTrue(extreme.body.isEmpty)
    XCTAssertTrue(invalidSourceDistances.body.isEmpty)
    XCTAssertTrue(invalid.maximumHalfWidth.isFinite)
    XCTAssertTrue(extreme.maximumHalfWidth.isFinite)
  }

  func testGreatestFiniteSourceDistanceDoesNotTrapOrCreateNonfiniteGeometry() {
    let geometry = WritingStrokeGeometryPlan.geometry(
      samples: [
        WritingStrokeSample(x: 0, y: 0),
        WritingStrokeSample(x: 1, y: 0),
      ],
      isClosed: false,
      material: .pen(.default),
      destinationHeight: 20,
      seedSalt: 2,
      sourceDistances: [0, .greatestFiniteMagnitude],
      visibleLength: .greatestFiniteMagnitude
    )
    XCTAssertTrue(
      geometry.body.isEmpty
        || geometry.body.allSatisfy {
          $0.x.isFinite && $0.y.isFinite
        })
    XCTAssertTrue(geometry.maximumHalfWidth.isFinite)
  }

  func testShortStrokeDoesNotDuplicateInteriorEndpoint() {
    let geometry = WritingStrokeGeometryPlan.geometry(
      samples: [
        WritingStrokeSample(x: 0, y: 0),
        WritingStrokeSample(x: 1, y: 0),
      ],
      isClosed: false,
      material: .pen(.default),
      destinationHeight: 20,
      seedSalt: 3
    )
    XCTAssertEqual(Set(geometry.body).count, geometry.body.count)
  }

  func testMaximumPossibleHalfWidthCoversEveryValidMaterialFamily() {
    let samples = (0...24).map {
      WritingStrokeSample(x: Double($0) * 7, y: sin(Double($0) * 0.31) * 9)
    }
    let bound = WritingStrokeGeometryPlan.maximumPossibleHalfWidth(
      destinationHeight: 36)
    for material in [
      WritingMaterial.chalk(.rough),
      WritingMaterial.brush(try! WritingBrushConfiguration(coverage: 1, streakScale: 64)),
      WritingMaterial.pen(try! WritingPenConfiguration(coverage: 1, dotScale: 64)),
      WritingMaterial.ink(
        try! WritingInkConfiguration(
          coverage: 1, bleed: 1, pooling: 1)),
    ] {
      let geometry = WritingStrokeGeometryPlan.geometry(
        samples: samples,
        isClosed: false,
        material: material,
        destinationHeight: 36,
        seedSalt: 4)
      XCTAssertLessThanOrEqual(geometry.maximumHalfWidth, bound + 1e-9)
    }
  }

  func testZeroHeightUsesTheSameMinimumFaceAsMaterialGeometry() {
    let bound = WritingStrokeGeometryPlan.maximumPossibleHalfWidth(
      destinationHeight: 0)
    XCTAssertGreaterThan(bound, 0)

    let materials: [WritingMaterial] = [
      .chalk(.rough),
      .brush(try! WritingBrushConfiguration(coverage: 1, streakScale: 64)),
      .pen(try! WritingPenConfiguration(coverage: 1, dotScale: 64)),
      .ink(try! WritingInkConfiguration(coverage: 1, bleed: 1, pooling: 1)),
    ]
    for material in materials {
      let localBound = WritingStrokeGeometryPlan.conservativeMaximumHalfWidth(
        for: material,
        destinationHeight: 0)
      XCTAssertGreaterThan(localBound, 0)
      XCTAssertLessThanOrEqual(localBound, bound + 1e-9)
    }
  }

  func testSampleAndMaterialDetailBudgetsAreBounded() {
    let samples = (0..<20_000).map {
      WritingStrokeSample(x: Double($0) * 0.5, y: sin(Double($0) * 0.04))
    }
    let geometry = WritingStrokeGeometryPlan.geometry(
      samples: samples,
      isClosed: false,
      material: .ink(.default),
      destinationHeight: 28,
      seedSalt: 4
    )
    XCTAssertLessThanOrEqual(
      geometry.body.count,
      WritingStrokeGeometryPlan.maximumSamples * 2 + 32
    )
    XCTAssertLessThanOrEqual(
      geometry.bristles.count,
      WritingStrokeGeometryPlan.maximumBristles
    )
    XCTAssertLessThanOrEqual(
      geometry.splatters.count,
      WritingStrokeGeometryPlan.maximumSplatters
    )
    XCTAssertTrue(
      geometry.body.contains { abs($0.x - samples.last!.x) < 1.0 },
      "bounded geometry must retain the terminal sample"
    )
  }

  func testResamplingRetainsTerminalWhenInputAlreadyAtSampleLimit() {
    let samples =
      [WritingStrokeSample(x: 0, y: 0)]
      + [WritingStrokeSample(x: 1_000, y: 0)]
      + (1..<(WritingStrokeGeometryPlan.maximumSamples - 1)).map {
        WritingStrokeSample(x: 1_000 + Double($0), y: 0)
      }
    let geometry = WritingStrokeGeometryPlan.geometry(
      samples: samples,
      isClosed: false,
      material: .pen(.default),
      destinationHeight: 20,
      seedSalt: 5
    )
    XCTAssertLessThanOrEqual(
      geometry.body.count,
      WritingStrokeGeometryPlan.maximumSamples * 2 + 32
    )
    XCTAssertTrue(
      geometry.body.contains {
        abs($0.x - samples.last!.x) < 1.0
      },
      "resampling must preserve the final source endpoint"
    )
  }

  func testMaximumHalfWidthContainsEveryGeneratedDetail() {
    let samples = (0...30).map {
      WritingStrokeSample(x: Double($0) * 8, y: sin(Double($0) * 0.42) * 12)
    }
    let materials: [WritingMaterial] = [
      .chalk(.default), .brush(.default), .pen(.default), .ink(.default),
      .chalk(.rough),
      .brush(try! WritingBrushConfiguration(coverage: 1, streakScale: 64)),
      .pen(try! WritingPenConfiguration(coverage: 1, dotScale: 64)),
      .ink(try! WritingInkConfiguration(coverage: 1, bleed: 1, pooling: 1)),
    ]
    for material in materials {
      let geometry = WritingStrokeGeometryPlan.geometry(
        samples: samples,
        isClosed: false,
        material: material,
        destinationHeight: 36,
        seedSalt: 88
      )
      for point in geometry.body {
        XCTAssertLessThanOrEqual(
          nearestSegmentDistance(point, samples), geometry.maximumHalfWidth + 1e-9,
          "body/overlay exceeded bound for \(material.kind)"
        )
      }
      for bristle in geometry.bristles {
        for run in bristle.runs {
          for point in run {
            XCTAssertLessThanOrEqual(
              nearestSegmentDistance(point, samples) + bristle.width * 0.5,
              geometry.maximumHalfWidth + 1e-9,
              "bristle exceeded bound for \(material.kind)"
            )
          }
        }
      }
      for splat in geometry.splatters {
        let point = WritingPlanPoint(x: splat.x, y: splat.y)
        XCTAssertLessThanOrEqual(
          nearestSegmentDistance(point, samples) + splat.radius,
          geometry.maximumHalfWidth + 1e-9,
          "splatter exceeded bound for \(material.kind)"
        )
      }
    }
  }

  private func maximumVerticalExtent(
    _ points: [WritingPlanPoint], nearX x: Double
  ) -> Double {
    points
      .filter { abs($0.x - x) < 1.0 }
      .map { abs($0.y) }
      .max() ?? 0
  }

  private func nearestSegmentDistance(
    _ point: WritingPlanPoint, _ samples: [WritingStrokeSample]
  ) -> Double {
    guard samples.count > 1 else {
      guard let first = samples.first else { return .infinity }
      return hypot(point.x - first.x, point.y - first.y)
    }
    return zip(samples, samples.dropFirst()).map { start, end in
      let dx = end.x - start.x
      let dy = end.y - start.y
      let lengthSquared = dx * dx + dy * dy
      guard lengthSquared > 0, lengthSquared.isFinite else {
        return hypot(point.x - start.x, point.y - start.y)
      }
      let projection =
        ((point.x - start.x) * dx + (point.y - start.y) * dy)
        / lengthSquared
      let t = min(1, max(0, projection))
      return hypot(
        point.x - (start.x + dx * t),
        point.y - (start.y + dy * t)
      )
    }.min() ?? .infinity
  }
}
