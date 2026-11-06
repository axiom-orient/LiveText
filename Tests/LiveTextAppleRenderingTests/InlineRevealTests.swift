import Foundation
import LiveTextCore
import LiveTextLayout
import LiveTextSwiftUI
import XCTest

final class InlineRevealTests: XCTestCase {
  func testGraphemePlanUsesPreparedSourceRanges() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let atom = try InlineAtom.text(InlineTextAtom(id: "text", text: "A😀", style: style))
    let document = try InlineDocument(atoms: [atom])
    let shaper = FixedShaperForReveal()
    let prepared = try InlinePreparation(shaper: shaper).prepare(document: document)
    let plan = try InlineRevealPlanBuilder(secondsPerUnit: 0.1)
      .graphemePlan(prepared: prepared)

    XCTAssertEqual(plan.units.count, 2)
    XCTAssertEqual(plan.units[1].sourceRange, try InlineSourceRange(startUTF16: 1, endUTF16: 3))
  }

  func testRevealPlansKeepMultiGraphemeGlyphClustersAtomic() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let atom = try InlineAtom.text(InlineTextAtom(id: "ligature", text: "fi", style: style))
    let prepared = try InlinePreparation(shaper: ClusterShaperForReveal()).prepare(
      document: InlineDocument(atoms: [atom]))
    let builder = try InlineRevealPlanBuilder(secondsPerUnit: 0.1)

    let graphemes = try builder.graphemePlan(prepared: prepared)
    let glyphs = try builder.shapedGlyphPlan(prepared: prepared)

    XCTAssertEqual(graphemes.units.count, 1)
    XCTAssertEqual(glyphs.units.count, 1)
    XCTAssertEqual(glyphs.units[0].sourceRange, try InlineSourceRange(startUTF16: 0, endUTF16: 2))
    XCTAssertEqual(glyphs.duration, 0.1, accuracy: 0.0001)
  }

  func testShapedGlyphPlanOmitsClustersWithoutGlyphs() throws {
    let prepared = try preparedDocument(
      text: "abc",
      glyphRuns: [[GlyphInterval(start: 0, end: 1)]]
    )
    let plan = try InlineRevealPlanBuilder().shapedGlyphPlan(prepared: prepared)

    XCTAssertEqual(plan.units.map(\.sourceRange), [try InlineSourceRange(startUTF16: 0, endUTF16: 1)])
  }

  func testShapedGlyphPlanKeepsLigatureAcrossGraphemeRangesAtomic() throws {
    let prepared = try preparedDocument(
      text: "fi",
      glyphRuns: [[GlyphInterval(start: 0, end: 2)]]
    )
    let plan = try InlineRevealPlanBuilder(secondsPerUnit: 0.1)
      .shapedGlyphPlan(prepared: prepared)

    XCTAssertEqual(plan.units.count, 1)
    XCTAssertEqual(
      plan.units[0].sourceRange,
      try InlineSourceRange(startUTF16: 0, endUTF16: 2)
    )
  }

  func testShapedGlyphPlanReturnsNoUnitsWhenThereAreNoGlyphs() throws {
    let prepared = try preparedDocument(text: "abc", glyphRuns: [])
    let plan = try InlineRevealPlanBuilder().shapedGlyphPlan(prepared: prepared)

    XCTAssertTrue(plan.units.isEmpty)
    XCTAssertEqual(plan.duration, 0)
  }

  func testShapedGlyphPlanPreservesOneToOneClusters() throws {
    let prepared = try preparedDocument(
      text: "abc",
      glyphRuns: [[
        GlyphInterval(start: 0, end: 1),
        GlyphInterval(start: 1, end: 2),
        GlyphInterval(start: 2, end: 3),
      ]]
    )
    let plan = try InlineRevealPlanBuilder(secondsPerUnit: 0.1)
      .shapedGlyphPlan(prepared: prepared)

    XCTAssertEqual(
      plan.units.map(\.sourceRange),
      [
        try InlineSourceRange(startUTF16: 0, endUTF16: 1),
        try InlineSourceRange(startUTF16: 1, endUTF16: 2),
        try InlineSourceRange(startUTF16: 2, endUTF16: 3),
      ]
    )
    XCTAssertEqual(plan.units.map(\.startTime), [0, 0.1, 0.2])
  }

  func testShapedGlyphPlanRejectsBoundaryTouchAsOverlap() throws {
    let prepared = try preparedDocument(
      text: "abc",
      glyphRuns: [[GlyphInterval(start: 1, end: 2)]]
    )
    let plan = try InlineRevealPlanBuilder().shapedGlyphPlan(prepared: prepared)

    XCTAssertEqual(plan.units.map(\.sourceRange), [try InlineSourceRange(startUTF16: 1, endUTF16: 2)])
  }

  func testShapedGlyphPlanIgnoresRunAndGlyphOrder() throws {
    let ordered = try preparedDocument(
      text: "abc",
      glyphRuns: [
        [GlyphInterval(start: 0, end: 1)],
        [GlyphInterval(start: 1, end: 2)],
        [GlyphInterval(start: 2, end: 3)],
      ]
    )
    let shuffled = try preparedDocument(
      text: "abc",
      glyphRuns: [
        [
          GlyphInterval(start: 2, end: 3),
          GlyphInterval(start: 0, end: 1),
        ],
        [GlyphInterval(start: 1, end: 2)],
      ]
    )

    let builder = try InlineRevealPlanBuilder(secondsPerUnit: 0.1)
    XCTAssertEqual(
      try builder.shapedGlyphPlan(prepared: shuffled),
      try builder.shapedGlyphPlan(prepared: ordered)
    )
  }

  func testShapedGlyphPlanMatchesNaiveOverlapOracleForDeterministicIntervals() throws {
    let textLength = 96
    var random = DeterministicRevealRandom(seed: 0x4C_54_52_50)
    var intervals: [GlyphInterval] = []
    intervals.reserveCapacity(160)
    for index in 0..<160 {
      let start = random.nextInt(upperBound: textLength - 1)
      let length = 1 + random.nextInt(upperBound: min(4, textLength - start))
      intervals.append(GlyphInterval(start: start, end: start + length))
      if index.isMultiple(of: 11) {
        intervals.append(GlyphInterval(start: start, end: start + 1))
      }
    }
    intervals = shuffled(intervals, using: &random)

    let prepared = try preparedDocument(text: String(repeating: "a", count: textLength), glyphRuns: [
      Array(intervals.prefix(53)),
      Array(intervals.dropFirst(53).prefix(47)),
      Array(intervals.dropFirst(100)),
    ])
    let builder = try InlineRevealPlanBuilder(secondsPerUnit: 0.125)
    let actual = try builder.shapedGlyphPlan(prepared: prepared)
    let preparedText: PreparedInlineText
    guard case .text(let text) = prepared.atoms[0] else {
      return XCTFail("expected text fixture")
    }
    preparedText = text

    let clusters = try expectedClusterRanges(for: preparedText)
    var expectedUnits: [InlineRevealUnit] = []
    var time = 0.0
    for (index, cluster) in clusters.enumerated() {
      guard intervals.contains(where: { glyph in
        glyph.start < cluster.endUTF16 && cluster.startUTF16 < glyph.end
      }) else { continue }
      expectedUnits.append(
        try InlineRevealUnit(
          id: InlineRevealUnitID(rawValue: "random-shaped-cluster-\(index)"),
          kind: .shapedGlyph,
          atomID: "random",
          sourceRange: cluster,
          startTime: time,
          duration: 0.125
        ))
      time += 0.125
    }

    XCTAssertEqual(actual, try InlineRevealPlan(units: expectedUnits))
  }

  func testAssetRegistryRejectsMissingVersionAndMetrics() throws {
    let assetID = try InlineAssetID(rawValue: "icon")
    let atom = try InlineAtom.vector(
      InlineVectorAtom(
        id: "icon-atom",
        assetID: assetID,
        assetVersion: 2,
        metrics: try InlineMetrics(advance: 8, ascent: 5, descent: 2)
      ))
    let document = try InlineDocument(atoms: [atom])
    let registry = try InlineAssetRegistry(records: [
      try InlineAssetRecord(
        id: assetID,
        version: 1,
        metrics: try InlineMetrics(advance: 8, ascent: 5, descent: 2)
      )
    ])
    XCTAssertThrowsError(try registry.validate(document: document))
  }

  func testRenderRevealPhaseIsValidatedScalarAndCodable() throws {
    let phase = try InlineRenderRevealPhase(rawValue: 0.25)
    let data = try JSONEncoder().encode(phase)
    XCTAssertEqual(try JSONDecoder().decode(InlineRenderRevealPhase.self, from: data), phase)
    XCTAssertEqual(InlineRenderRevealPhase.complete.rawValue, 1)
    XCTAssertThrowsError(try InlineRenderRevealPhase(rawValue: -0.01))
    XCTAssertThrowsError(try InlineRenderRevealPhase(rawValue: .infinity))
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlineRenderRevealPhase.self,
        from: Data("1.1".utf8)
      )
    )
  }

  func testRenderPlanOwnsValidatedPreparationGeometryAndHitIndex() throws {
    let fixture = try renderRevealFixture()
    let plan = fixture.wideRenderPlan

    XCTAssertEqual(plan.prepared.revision, fixture.prepared.revision)
    XCTAssertEqual(plan.layout.preparationRevision, fixture.prepared.revision)
    XCTAssertEqual(plan.geometry.count, plan.layout.lines.reduce(0) { $0 + $1.atoms.count })
    XCTAssertEqual(plan.hitIndex.preparationRevision, fixture.prepared.revision)

    let data = try JSONEncoder().encode(plan)
    XCTAssertEqual(try JSONDecoder().decode(InlineRenderPlan.self, from: data), plan)
  }

  func testRenderRevealScheduleUsesStableAtomIDsAcrossReflow() throws {
    let fixture = try renderRevealFixture()
    let first = try InlineRenderRevealSchedule(
      plan: fixture.narrowRenderPlan,
      assets: fixture.assetStore,
      textPlan: fixture.textPlan,
      vectorPlans: ["vector": fixture.pathPlan]
    )
    let second = try InlineRenderRevealSchedule(
      plan: fixture.wideRenderPlan,
      assets: fixture.assetStore,
      textPlan: fixture.textPlan,
      vectorPlans: ["vector": fixture.pathPlan]
    )

    XCTAssertEqual(first.preparationRevision, second.preparationRevision)
    XCTAssertEqual(first.textActivations, second.textActivations)
    XCTAssertEqual(first.vectorActivations, second.vectorActivations)
    XCTAssertEqual(first.duration, second.duration)
    XCTAssertEqual(first.textActivation(for: "text")?.atomID, "text")
    XCTAssertEqual(first.vectorActivation(for: "vector")?.assetID, fixture.assetID)
  }

  func testRenderRevealScheduleKeepsLogicalOrderForBidiCJKAndCombiningText() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let text = try InlineAtom.text(
      InlineTextAtom(id: "bidi", text: "אבג 界 e\u{301}", style: style)
    )
    let prepared = try InlinePreparation(shaper: FixedShaperForReveal()).prepare(
      document: InlineDocument(atoms: [text])
    )
    let engine = try InlineLayoutEngine()
    let narrow = try InlineRenderPlan(
      prepared: prepared,
      layout: try engine.layout(prepared: prepared, width: 2)
    )
    let wide = try InlineRenderPlan(
      prepared: prepared,
      layout: try engine.layout(prepared: prepared, width: 100)
    )
    let builder = try InlineRevealPlanBuilder(secondsPerUnit: 0.05)
    let revealPlan = try builder.graphemePlan(prepared: prepared)
    let narrowSchedule = try InlineRenderRevealSchedule(
      plan: narrow, assets: InlineAssetStore(), textPlan: revealPlan)
    let wideSchedule = try InlineRenderRevealSchedule(
      plan: wide, assets: InlineAssetStore(), textPlan: revealPlan)
    let narrowUnits = try XCTUnwrap(narrowSchedule.textActivation(for: "bidi")?.units)

    XCTAssertEqual(narrowSchedule, wideSchedule)
    XCTAssertEqual(narrowUnits.count, prepared.totalGraphemes)
    XCTAssertEqual(
      narrowUnits.map(\.sourceRange),
      narrowUnits.map(\.sourceRange).sorted { $0.startUTF16 < $1.startUTF16 }
    )
    XCTAssertTrue(narrowUnits.contains { $0.sourceRange.lengthUTF16 == 2 })
  }

  func testRenderRevealScheduleSamplesTextAndVectorMetadataWithoutPaths() throws {
    let fixture = try renderRevealFixture()
    let schedule = try InlineRenderRevealSchedule(
      plan: fixture.wideRenderPlan,
      assets: fixture.assetStore,
      textPlan: fixture.textPlan,
      vectorPlans: ["vector": fixture.pathPlan]
    )
    let phase = try InlineRenderRevealPhase(0.5)
    let sample = schedule.sample(at: phase)
    let firstTextRange = try XCTUnwrap(fixture.textPlan.units.first?.sourceRange)

    XCTAssertEqual(sample.phase, phase)
    XCTAssertEqual(sample.duration, schedule.duration)
    XCTAssertGreaterThan(sample.textProgress(atomID: "text", sourceRange: firstTextRange), 0)
    XCTAssertEqual(sample.textProgress(atomID: "missing", sourceRange: firstTextRange), 0)
    XCTAssertGreaterThanOrEqual(sample.vectorProgress(atomID: "vector", commandIndex: 1), 0)
    XCTAssertEqual(sample.vectorProgress(atomID: "missing", commandIndex: 1), 0)
    // The text atom precedes the vector in the prepared document. At global
    // phase .5 the text activation is still in flight, so the vector has not
    // started; all atom kinds share one sequential document timeline.
    XCTAssertEqual(sample.completedVectorCommandCount(atomID: "vector"), 0)

    let complete = schedule.sample(at: .complete)
    XCTAssertTrue(complete.isComplete)
    XCTAssertEqual(
      complete.completedVectorCommandCount(atomID: "vector"),
      fixture.pathPlan.units.count
    )
    let beforeSampling = schedule
    for _ in 0..<120 {
      _ = schedule.sample(at: phase).textIsVisible(
        atomID: "text", sourceRange: firstTextRange)
      _ = schedule.sample(at: phase).vectorProgress(atomID: "vector", commandIndex: 1)
    }
    XCTAssertEqual(schedule, beforeSampling)
  }

  func testRenderRevealVectorActivationsAreSequentialInPreparedSourceOrder() throws {
    let metrics = try InlineMetrics(advance: 1, ascent: 1, descent: 1)
    let firstAssetID = try InlineAssetID(rawValue: "z-first-asset")
    let secondAssetID = try InlineAssetID(rawValue: "a-second-asset")
    let firstAsset = try InlineSVGAsset(
      id: firstAssetID,
      metrics: metrics,
      coordinateBounds: try InlineSVGBridge.parsePath("M0 0 L1 0").bounds,
      coveragePath: try InlineSVGBridge.parsePath("M0 0 L1 0"),
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: try InlineSVGBridge.parsePath("M0 0 L1 0"),
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let secondAsset = try InlineSVGAsset(
      id: secondAssetID,
      metrics: metrics,
      coordinateBounds: try InlineSVGBridge.parsePath("M0 0 L2 0").bounds,
      coveragePath: try InlineSVGBridge.parsePath("M0 0 L2 0"),
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: try InlineSVGBridge.parsePath("M0 0 L2 0"),
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let first = try InlineAtom.vector(
      InlineVectorAtom(
        id: "z-first-vector",
        assetID: firstAssetID,
        metrics: metrics
      ))
    let second = try InlineAtom.vector(
      InlineVectorAtom(
        id: "a-second-vector",
        assetID: secondAssetID,
        metrics: metrics
      ))
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [first, second]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 10)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let builder = try InlinePathRevealPlanBuilder(secondsPerUnit: 1)
    let firstPlan = try builder.plan(asset: firstAsset)
    let secondPlan = try builder.plan(asset: secondAsset)

    // Deliberately reverse dictionary order: prepared atom order is the
    // deterministic tie-breaker, not hash/dictionary ordering.
    let schedule = try InlineRenderRevealSchedule(
      plan: renderPlan,
      assets: InlineAssetStore(values: [
        InlineAssetKey(id: firstAsset.id, version: firstAsset.version): firstAsset,
        InlineAssetKey(id: secondAsset.id, version: secondAsset.version): secondAsset
      ]),
      vectorPlans: [
        "a-second-vector": secondPlan,
        "z-first-vector": firstPlan,
      ]
    )
    XCTAssertEqual(
      schedule.vectorActivations.map(\.atomID),
      ["z-first-vector", "a-second-vector"]
    )
    let firstActivation = try XCTUnwrap(schedule.vectorActivation(for: "z-first-vector"))
    let secondActivation = try XCTUnwrap(schedule.vectorActivation(for: "a-second-vector"))
    let firstStart = try XCTUnwrap(firstActivation.units.first?.startTime)
    let secondStart = try XCTUnwrap(secondActivation.units.first?.startTime)
    XCTAssertEqual(firstStart, 0, accuracy: 0.0001)
    XCTAssertEqual(
      secondStart,
      firstActivation.duration,
      accuracy: 0.0001
    )
    XCTAssertEqual(schedule.duration, secondActivation.duration, accuracy: 0.0001)

    var previousProgress: [String: Double] = [:]
    for step in 0...200 {
      let phase = try InlineRenderRevealPhase(rawValue: Double(step) / 200)
      let frame = schedule.sample(at: phase)
      var activeCommandCount = 0
      for activation in schedule.vectorActivations {
        for unit in activation.units {
          let progress = frame.vectorProgress(
            atomID: activation.atomID, commandIndex: unit.commandIndex)
          let key = "\(activation.atomID):\(unit.commandIndex)"
          XCTAssertGreaterThanOrEqual(
            progress + 0.0000001,
            previousProgress[key] ?? 0,
            "vector progress regressed for \(key)"
          )
          previousProgress[key] = progress
          if progress > 0 && progress < 1 { activeCommandCount += 1 }
        }
      }
      XCTAssertLessThanOrEqual(
        activeCommandCount,
        1,
        "more than one vector command was partial at phase \(phase.rawValue)"
      )
    }
  }

  func testRenderRevealScheduleKeepsTextPublicOrderAndUsesIDLookup() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let textBefore = try InlineAtom.text(
      InlineTextAtom(id: "z-text", text: "z", style: style))
    let textAfter = try InlineAtom.text(
      InlineTextAtom(id: "a-text", text: "a", style: style))
    let metrics = try InlineMetrics(advance: 2, ascent: 1, descent: 1)
    let assetID = try InlineAssetID(rawValue: "ordered-vector-asset")
    let path = try InlineSVGBridge.parsePath("M0 0 L2 0")
    let asset = try InlineSVGAsset(
      id: assetID,
      metrics: metrics,
      coordinateBounds: path.bounds,
      coveragePath: path,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let vector = try InlineAtom.vector(
      InlineVectorAtom(id: "vector", assetID: assetID, metrics: metrics))
    let imageReference = try InlineImageReference(
      assetID: try InlineAssetID(rawValue: "ordered-image"),
      data: Data([1, 2, 3])
    )
    let image = try InlineAtom.image(
      InlineImageAtom(
        id: "image",
        reference: imageReference,
        metrics: metrics,
        accessibility: .label("ordered image")
      ))
    let prepared = try InlinePreparation(shaper: FixedShaperForReveal()).prepare(
      document: InlineDocument(atoms: [textBefore, vector, image, textAfter]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 100)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let builder = try InlineRevealPlanBuilder(secondsPerUnit: 1)
    let textPlan = try builder.graphemePlan(prepared: prepared)
    let pathPlan = try InlinePathRevealPlanBuilder(secondsPerUnit: 1).plan(asset: asset)
    let schedule = try InlineRenderRevealSchedule(
      plan: renderPlan,
      assets: InlineAssetStore(values: [
        InlineAssetKey(id: asset.id, version: asset.version): asset
      ]),
      textPlan: textPlan,
      vectorPlans: ["vector": pathPlan]
    )

    XCTAssertEqual(schedule.textActivations.map(\.atomID), ["z-text", "a-text"])
    XCTAssertEqual(schedule.vectorActivations.map(\.atomID), ["vector"])
    XCTAssertEqual(schedule.imageActivations.map(\.atomID), ["image"])
    let z = try XCTUnwrap(schedule.textActivation(for: "z-text"))
    let a = try XCTUnwrap(schedule.textActivation(for: "a-text"))
    let vectorActivation = try XCTUnwrap(schedule.vectorActivation(for: "vector"))
    let imageActivation = try XCTUnwrap(schedule.imageActivation(for: "image"))
    let zStart = try XCTUnwrap(z.units.first?.startTime)
    let vectorStart = try XCTUnwrap(vectorActivation.units.first?.startTime)
    let imageEnd = imageActivation.startTime + imageActivation.duration
    let aStart = try XCTUnwrap(a.units.first?.startTime)
    let aLast = try XCTUnwrap(a.units.last)
    let aEnd = aLast.startTime + aLast.duration
    XCTAssertEqual(zStart, 0, accuracy: 0.0001)
    XCTAssertEqual(vectorStart, z.duration, accuracy: 0.0001)
    XCTAssertEqual(imageActivation.startTime, vectorActivation.units.last!.startTime
      + vectorActivation.units.last!.duration, accuracy: 0.0001)
    XCTAssertEqual(aStart, imageEnd, accuracy: 0.0001)
    XCTAssertEqual(schedule.duration, aEnd, accuracy: 0.0001)
  }

  func testRenderRevealScheduleRejectsUnknownVectorAndCancellationAtomically() throws {
    let fixture = try renderRevealFixture()
    var unknownResult: InlineRenderRevealSchedule?
    XCTAssertThrowsError(
      try {
        unknownResult = try InlineRenderRevealSchedule(
          plan: fixture.wideRenderPlan,
          assets: fixture.assetStore,
          textPlan: fixture.textPlan,
          vectorPlans: ["missing": fixture.pathPlan]
        )
      }()
    )
    XCTAssertNil(unknownResult)

    var cancelledResult: InlineRenderRevealSchedule?
    XCTAssertThrowsError(
      try {
        cancelledResult = try InlineRenderRevealSchedule(
          plan: fixture.wideRenderPlan,
          assets: fixture.assetStore,
          textPlan: fixture.textPlan,
          vectorPlans: ["vector": fixture.pathPlan],
          cancellation: { throw InlineLayoutError.cancelled }
        )
      }()
    )
    XCTAssertNil(cancelledResult)
  }

  func testRenderRevealVectorActivationRejectsOverlappingCompletionTimes() throws {
    let assetID = try InlineAssetID(rawValue: "vector-asset")
    let first = try InlineRenderRevealVectorUnit(
      commandIndex: 0,
      startTime: 0,
      duration: 2
    )
    let overlapping = try InlineRenderRevealVectorUnit(
      commandIndex: 1,
      startTime: 1,
      duration: 0.1
    )

    XCTAssertThrowsError(
      try InlineRenderRevealVectorActivation(
        atomID: "vector",
        assetID: assetID,
        assetVersion: 0,
        units: [first, overlapping]
      )
    )
  }

  func testDerivedRevealScheduleAndActivationsAreNotCodable() throws {
    let fixture = try renderRevealFixture()
    let schedule = try InlineRenderRevealSchedule(
      plan: fixture.wideRenderPlan,
      assets: fixture.assetStore,
      textPlan: fixture.textPlan,
      vectorPlans: ["vector": fixture.pathPlan]
    )

    XCTAssertFalse(InlineRenderRevealSchedule.self is any Encodable.Type)
    XCTAssertFalse(InlineRenderRevealSchedule.self is any Decodable.Type)
    XCTAssertFalse(InlineRenderRevealTextActivation.self is any Encodable.Type)
    XCTAssertFalse(InlineRenderRevealTextActivation.self is any Decodable.Type)
    XCTAssertFalse(InlineRenderRevealVectorActivation.self is any Encodable.Type)
    XCTAssertFalse(InlineRenderRevealVectorActivation.self is any Decodable.Type)
    XCTAssertEqual(schedule.textActivations.count, 1)
    XCTAssertEqual(schedule.vectorActivations.count, 1)
  }
}

private struct RenderRevealFixture {
  let prepared: PreparedInlineDocument
  let textPlan: InlineRevealPlan
  let pathPlan: InlinePathRevealPlan
  let assetID: InlineAssetID
  let narrowRenderPlan: InlineRenderPlan
  let wideRenderPlan: InlineRenderPlan
  let asset: InlineSVGAsset

  var assetStore: InlineAssetStore {
    InlineAssetStore(values: [InlineAssetKey(id: asset.id, version: asset.version): asset])
  }
}

private func renderRevealFixture() throws -> RenderRevealFixture {
  let style = try InlineTextStyle(
    font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
  let text = try InlineAtom.text(
    InlineTextAtom(id: "text", text: "A😀 e\u{301}界", style: style)
  )
  let assetID = try InlineAssetID(rawValue: "vector-asset")
  let metrics = try InlineMetrics(advance: 4, ascent: 3, descent: 1)
  let vector = try InlineAtom.vector(
    InlineVectorAtom(id: "vector", assetID: assetID, metrics: metrics)
  )
  let document = try InlineDocument(atoms: [text, vector])
  let prepared = try InlinePreparation(shaper: FixedShaperForReveal()).prepare(document: document)
  let engine = try InlineLayoutEngine()
  let narrowLayout = try engine.layout(prepared: prepared, width: 5)
  let wideLayout = try engine.layout(prepared: prepared, width: 100)
  let narrowRenderPlan = try InlineRenderPlan(prepared: prepared, layout: narrowLayout)
  let wideRenderPlan = try InlineRenderPlan(prepared: prepared, layout: wideLayout)
  let textPlan = try InlineRevealPlanBuilder(secondsPerUnit: 0.1)
    .graphemePlan(prepared: prepared)
  let path = try InlinePathData(commands: [
    .move(try InlinePathPoint(x: 0, y: 0)),
    .line(try InlinePathPoint(x: 3, y: 0)),
    .cubic(
      control1: try InlinePathPoint(x: 4, y: 0),
      control2: try InlinePathPoint(x: 4, y: 3),
      to: try InlinePathPoint(x: 3, y: 3)
    ),
  ])
  let asset = try InlineSVGAsset(
    id: assetID,
    metrics: metrics,
    coordinateBounds: path.bounds,
    coveragePath: path,
    coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
    trajectoryPath: path,
    trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
  )
  let pathPlan = try InlinePathRevealPlanBuilder(secondsPerUnit: 0.1).plan(asset: asset)
  return RenderRevealFixture(
    prepared: prepared,
    textPlan: textPlan,
    pathPlan: pathPlan,
    assetID: assetID,
    narrowRenderPlan: narrowRenderPlan,
    wideRenderPlan: wideRenderPlan,
    asset: asset
  )
}

private struct GlyphInterval: Sendable {
  let start: Int
  let end: Int
}

private struct FixtureRevealShaper: InlineTextShaping {
  let glyphRuns: [[GlyphInterval]]

  func shape(
    text: String,
    style: InlineTextStyle,
    sourceRange: InlineSourceRange
  ) throws -> InlineShapedText {
    var graphemeRanges: [InlineSourceRange] = []
    graphemeRanges.reserveCapacity(text.count)
    var offset = sourceRange.startUTF16
    for grapheme in text {
      let length = String(grapheme).utf16.count
      graphemeRanges.append(
        try InlineSourceRange(startUTF16: offset, endUTF16: offset + length)
      )
      offset += length
    }

    let runs = try glyphRuns.compactMap { intervals -> InlineShapedRun? in
      guard !intervals.isEmpty else { return nil }
      let glyphs = try intervals.enumerated().map { glyphIndex, interval in
        let range = try InlineSourceRange(
          startUTF16: sourceRange.startUTF16 + interval.start,
          endUTF16: sourceRange.startUTF16 + interval.end
        )
        return try InlineGlyph(
          glyphID: UInt16(glyphIndex),
          positionX: Double(glyphIndex),
          positionY: 0,
          sourceUTF16Index: range.startUTF16,
          sourceRange: range
        )
      }
      return try InlineShapedRun(
        glyphs: glyphs,
        font: style.font,
        sourceRange: sourceRange,
        advance: Double(text.count),
        ascent: 10,
        descent: 2
      )
    }
    return try InlineShapedText(
      graphemeRanges: graphemeRanges,
      graphemeAdvances: Array(repeating: 1, count: graphemeRanges.count),
      runs: runs,
      metrics: try InlineMetrics(
        advance: Double(graphemeRanges.count),
        ascent: 10,
        descent: 2
      )
    )
  }
}

private struct DeterministicRevealRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func nextInt(upperBound: Int) -> Int {
    precondition(upperBound > 0)
    state = state &* 2_862_933_555_777_941_757 &+ 3_039_700_493
    return Int(state % UInt64(upperBound))
  }
}

private func shuffled(
  _ values: [GlyphInterval],
  using random: inout DeterministicRevealRandom
) -> [GlyphInterval] {
  var result = values
  guard result.count > 1 else { return result }
  for index in stride(from: result.count - 1, through: 1, by: -1) {
    let swapIndex = random.nextInt(upperBound: index + 1)
    result.swapAt(index, swapIndex)
  }
  return result
}

private func preparedDocument(
  text: String,
  glyphRuns: [[GlyphInterval]]
) throws -> PreparedInlineDocument {
  let style = try InlineTextStyle(
    font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
  let atom = try InlineAtom.text(InlineTextAtom(id: "random", text: text, style: style))
  return try InlinePreparation(shaper: FixtureRevealShaper(glyphRuns: glyphRuns)).prepare(
    document: InlineDocument(atoms: [atom])
  )
}

private func expectedClusterRanges(for text: PreparedInlineText) throws -> [InlineSourceRange] {
  guard !text.graphemes.isEmpty else { return [] }
  var result: [InlineSourceRange] = []
  var clusterStart = 0
  for index in text.graphemes.indices {
    let isLast = index == text.graphemes.index(before: text.graphemes.endIndex)
    guard isLast || text.shaped.graphemeCanBreakAfter[index] else { continue }
    result.append(
      try InlineSourceRange(
        startUTF16: text.shaped.graphemeRanges[clusterStart].startUTF16,
        endUTF16: text.shaped.graphemeRanges[index].endUTF16
      )
    )
    clusterStart = index + 1
  }
  return result
}

private struct FixedShaperForReveal: InlineTextShaping {
  func shape(text: String, style: InlineTextStyle, sourceRange: InlineSourceRange) throws
    -> InlineShapedText
  {
    var ranges: [InlineSourceRange] = []
    var offset = sourceRange.startUTF16
    for grapheme in text {
      let length = String(grapheme).utf16.count
      ranges.append(try InlineSourceRange(startUTF16: offset, endUTF16: offset + length))
      offset += length
    }
    return try InlineShapedText(
      graphemeRanges: ranges,
      graphemeAdvances: Array(repeating: 1, count: ranges.count),
      runs: [],
      metrics: try InlineMetrics(advance: Double(ranges.count), ascent: 10, descent: 2)
    )
  }
}

private struct ClusterShaperForReveal: InlineTextShaping {
  func shape(text: String, style: InlineTextStyle, sourceRange: InlineSourceRange) throws
    -> InlineShapedText
  {
    guard text == "fi" else { throw InlineLayoutError.unsupportedShaping("fixture") }
    let cluster = try InlineSourceRange(startUTF16: 0, endUTF16: 2)
    let glyphs = try [
      InlineGlyph(
        glyphID: 1,
        positionX: 0,
        positionY: 0,
        sourceUTF16Index: 0,
        sourceRange: cluster
      ),
      InlineGlyph(
        glyphID: 2,
        positionX: 1,
        positionY: 0,
        sourceUTF16Index: 0,
        sourceRange: cluster
      ),
    ]
    let run = try InlineShapedRun(
      glyphs: glyphs,
      font: style.font,
      sourceRange: cluster,
      advance: 2,
      ascent: 10,
      descent: 2
    )
    return try InlineShapedText(
      graphemeRanges: [
        try InlineSourceRange(startUTF16: 0, endUTF16: 1),
        try InlineSourceRange(startUTF16: 1, endUTF16: 2),
      ],
      graphemeAdvances: [1, 1],
      runs: [run],
      metrics: try InlineMetrics(advance: 2, ascent: 10, descent: 2)
    )
  }
}
