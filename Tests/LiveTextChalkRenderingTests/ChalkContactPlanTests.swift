import Foundation
import LiveTextEffects
import XCTest
@testable import LiveTextChalkRendering
@testable import ChalkLineEffects

final class ChalkContactPlanTests: XCTestCase {
  private func line(id: String = "stroke", width: Double = 6, length: Double = 180) -> ChalkRenderStrokeGeometry {
    ChalkRenderStrokeGeometry(id: id, points: [
      ChalkRenderStrokePoint(x: 0, y: 32, width: width),
      ChalkRenderStrokePoint(x: length, y: 32, width: width),
    ])
  }

  private func prepare(
    _ strokes: [ChalkRenderStrokeGeometry],
    configuration: WritingChalkConfiguration = .default
  ) throws -> ChalkPreparedContactPlan {
    try ChalkPreparedContactPlan.prepare(strokes: strokes, material: .liveText(configuration))
  }

  func testRepeatPreparationIsDeterministic() throws {
    let a = try prepare([line()])
    let b = try prepare([line()])
    XCTAssertEqual(a.strokes, b.strokes)
    XCTAssertEqual(a.support, b.support)
  }

  func testReorderingUnrelatedStrokesPreservesIdentityOwnedDeposits() throws {
    let a = line(id: "a"), b = line(id: "b", width: 9)
    let first = try prepare([a, b])
    let reordered = try prepare([b, a])
    XCTAssertEqual(first.strokes[0], reordered.strokes[1])
    XCTAssertEqual(first.strokes[1], reordered.strokes[0])
  }

  func testDustDoesNotConsumePigmentRandomness() throws {
    let off = try prepare([line()], configuration: WritingChalkConfiguration(edgeRoughness: 0))
    let on = try prepare([line()], configuration: WritingChalkConfiguration(edgeRoughness: 1))
    XCTAssertEqual(off.strokes[0].dabs, on.strokes[0].dabs)
    XCTAssertTrue(off.strokes[0].dust.isEmpty)
    XCTAssertFalse(on.strokes[0].dust.isEmpty)
  }

  func testVisibilityHasExactEmptyAndFullEndpoints() throws {
    let stroke = try prepare([line()]).strokes[0]
    XCTAssertTrue(stroke.dabs(for: .prefix(0)).isEmpty)
    XCTAssertTrue(stroke.dabs(for: .suffix(1)).isEmpty)
    XCTAssertTrue(stroke.dust(for: .prefix(0)).isEmpty)
    XCTAssertTrue(stroke.dust(for: .suffix(1)).isEmpty)
    XCTAssertEqual(Array(stroke.dabs(for: .prefix(1))), stroke.dabs)
    XCTAssertEqual(Array(stroke.dabs(for: .suffix(0))), stroke.dabs)
    XCTAssertTrue(stroke.dabs(for: .prefix(.nan)).isEmpty)
    XCTAssertTrue(stroke.dabs(for: .suffix(.infinity)).isEmpty)
    XCTAssertEqual(stroke.dabs.first?.arcFraction, 0)
    XCTAssertEqual(stroke.dabs.last?.arcFraction, 1)
  }

  func testPartialVisibilitySelectsAnImmutableArcSlice() throws {
    let stroke = try prepare([line()]).strokes[0]
    let early = Array(stroke.dabs(for: .prefix(0.25)))
    let later = Array(stroke.dabs(for: .prefix(0.75)))
    XCTAssertFalse(early.isEmpty)
    XCTAssertLessThan(early.count, later.count)
    XCTAssertEqual(early, Array(later.prefix(early.count)))
    XCTAssertTrue(stroke.dust(for: .prefix(0.25)).allSatisfy { $0.arcFraction <= 0.25 })
    XCTAssertTrue(stroke.dabs(for: .suffix(0.75)).allSatisfy { $0.arcFraction >= 0.75 })
  }

  func testCoincidentPointsAreOneDotWithLatestPressure() throws {
    let points = [2.0, 4.0, 6.0].map { ChalkRenderStrokePoint(x: 20, y: 30, width: $0) }
    let repeated = try prepare([ChalkRenderStrokeGeometry(id: "dot", points: points)]).strokes[0]
    let single = try prepare([ChalkRenderStrokeGeometry(id: "dot", points: [points[2]])]).strokes[0]
    XCTAssertEqual(repeated, single)
    XCTAssertEqual(single.dabs.count, 1)
    XCTAssertEqual(single.dabs(for: .prefix(0.01)).count, 1)
    XCTAssertEqual(single.dabs(for: .suffix(0.99)).count, 1)
    XCTAssertTrue(single.dabs(for: .prefix(0)).isEmpty)
    XCTAssertTrue(single.dabs(for: .suffix(1)).isEmpty)
  }

  func testNonFiniteInputAndOverflowAreTypedErrors() {
    let inputs = [
      [ChalkRenderStrokePoint(x: .nan, y: 0, width: 1)],
      [ChalkRenderStrokePoint(x: 0, y: 0, width: .infinity)],
      [ChalkRenderStrokePoint(x: 0, y: 0, width: 0)],
      [ChalkRenderStrokePoint(x: -1e308, y: 0, width: 1),
       ChalkRenderStrokePoint(x: 1e308, y: 0, width: 1)],
    ]
    for points in inputs {
      XCTAssertThrowsError(try prepare([ChalkRenderStrokeGeometry(id: "invalid", points: points)])) {
        XCTAssertEqual($0 as? ChalkRenderError, .invalidStroke("invalid"))
      }
    }
  }

  func testHugeFiniteTravelFailsBeforeUnsafeIntegerConversionOrPartialPublication() {
    XCTAssertThrowsError(try prepare([line(width: 1, length: 1e200)])) {
      XCTAssertEqual($0 as? ChalkRenderError, .resourceLimitExceeded(
        resource: "chalk contact dabs", actual: 8_193, limit: 8_192))
    }
  }

  func testEmptyAndUnsupportedContactInputAreRejected() throws {
    XCTAssertThrowsError(try prepare([ChalkRenderStrokeGeometry(id: "", points: [])]))
    for style in [WritingChalkStyle.powderFill, .diagonalHatch, .crossHatch, .smudged] {
      let configuration = try WritingChalkConfiguration(style: style)
      XCTAssertThrowsError(try prepare([line()], configuration: configuration))
    }
  }

  func testUniformPhysicalScalingDoesNotApplyPowerToPointUnits() throws {
    let small = try prepare([line(width: 8, length: 200)]).strokes[0]
    let large = try prepare([line(width: 16, length: 400)]).strokes[0]
    XCTAssertEqual(small.dabs.count, large.dabs.count)
    for (a, b) in zip(small.dabs, large.dabs) {
      XCTAssertEqual(b.width, a.width * 2, accuracy: 1e-9)
      XCTAssertEqual(b.height, a.height * 2, accuracy: 1e-9)
      XCTAssertEqual(b.opacity, a.opacity, accuracy: 1e-12)
    }
  }

  func testSubstrateFamiliesChangeMaterialNotStrokeGeometry() throws {
    let plans = try WritingChalkTextureStyle.allCases.map {
      try prepare([line()], configuration: WritingChalkConfiguration(textureStyle: $0))
    }
    XCTAssertEqual(Set(plans.map(\.support.substrateImageScale)).count,
                   WritingChalkTextureStyle.allCases.count)
    for plan in plans {
      XCTAssertEqual(plan.strokes, plans[0].strokes)
      XCTAssertGreaterThan(plan.support.substrateLoss, 0)
    }
  }

  func testBoardToothIsAppliedPerContactOrAfterCompositionButNotBoth() throws {
    let fine = try prepare([line()], configuration: WritingChalkConfiguration(style: .fineLine))
    let dry = try prepare([line()], configuration: WritingChalkConfiguration(style: .dryBrush))
    XCTAssertGreaterThan(fine.support.postCompositeToothLoss, 0)
    XCTAssertTrue(fine.strokes[0].dabs.allSatisfy { $0.toothLoss == 0 })
    XCTAssertEqual(dry.support.postCompositeToothLoss, 0)
    XCTAssertTrue(dry.strokes[0].dabs.contains { $0.toothLoss > 0 })
  }

  func testPressureAndCornerSamplesRemainFiniteAndBounded() throws {
    let geometry = ChalkRenderStrokeGeometry(id: "corner", points: [
      ChalkRenderStrokePoint(x: 10, y: 10, width: 1),
      ChalkRenderStrokePoint(x: 100, y: 10, width: 12),
      ChalkRenderStrokePoint(x: 100, y: 100, width: 3),
    ])
    let stroke = try prepare([geometry]).strokes[0]
    XCTAssertGreaterThan(stroke.dabs.count, 2)
    XCTAssertLessThanOrEqual(stroke.dabs.count, ChalkPreparedContactPlan.maximumDabsPerStroke)
    XCTAssertEqual(stroke.dabs.map(\.arcFraction), stroke.dabs.map(\.arcFraction).sorted())
    for dab in stroke.dabs {
      XCTAssertTrue([dab.centerX, dab.centerY, dab.width, dab.height, dab.opacity].allSatisfy(\.isFinite))
      XCTAssertGreaterThan(dab.width, 0)
      XCTAssertGreaterThan(dab.height, 0)
      XCTAssertTrue((0...1).contains(dab.opacity))
    }
  }

  @MainActor
  func testBothPublicViewEntriesRejectInvalidProgressWithoutTrapping() async throws {
    let prepared = try ChalkWritingPreparation(text: "A")
    for progress in [Double.nan, .infinity, -0.01, 1.01] {
      let direct = ChalkWritingText("A", progress: progress)
      let reused = ChalkWritingText(preparation: prepared, progress: progress)
      XCTAssertTrue(direct.isShowingPreparationFailure)
      XCTAssertTrue(reused.isShowingPreparationFailure)
    }
    XCTAssertFalse(ChalkWritingText(preparation: prepared, progress: 1).isShowingPreparationFailure)
  }

  @MainActor
  func testValidatedSemanticPreparationCanFailMaterialBudgetWithoutTrapping() async throws {
    struct EncodedPreparation: Encodable {
      let scene: StrokeWritingScene
      let timeline: WritingTimeline
    }
    // Exercise the real public Codable preparation boundary, not a mock plan.
    let stroke = try WritingStroke(id: "long-stroke", points: [
      WritingPoint(x: 0, y: 500, width: 1),
      WritingPoint(x: 10_000, y: 500, width: 1),
    ])
    let glyph = try StrokeGlyph(index: 0, cluster: "X", advance: 10_000, strokes: [stroke])
    let scene = try StrokeWritingScene(
      text: "X", size: WritingSize(width: 10_000, height: 1_000), glyphs: [glyph],
      source: .custom(description: "material budget regression"), catalogVersion: "test")
    let timeline = try WritingTimeline(duration: 1, strokes: [
      WritingStrokeTiming(layerIndex: 0, glyphIndex: 0, strokeIndex: 0,
        strokeID: stroke.id, startTime: 0, endTime: 1)
    ])
    let data = try JSONEncoder().encode(EncodedPreparation(scene: scene, timeline: timeline))
    let prepared = try JSONDecoder().decode(ChalkWritingPreparation.self, from: data)
    XCTAssertEqual(prepared.scene, scene)
    XCTAssertTrue(ChalkWritingText(preparation: prepared, progress: 1).isShowingPreparationFailure)
  }

}
