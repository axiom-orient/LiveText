import LiveTextCore
import LiveTextLayout
import XCTest

final class InlineAssetStreamingTests: XCTestCase {
  func testSVGBridgePreservesMultipleSubpathsAndRejectsUnsupportedCommands() throws {
    let path = try InlineSVGBridge.parsePath("M0 0 L1 0 M2 2 l1 0")
    XCTAssertEqual(
      path.commands.compactMap { command in
        if case .move = command { return true }
        return nil
      }.count, 2)

    let arc = try InlineSVGBridge.parsePath("M0 0 A1 1 0 0 0 2 2")
    XCTAssertTrue(
      arc.commands.contains { command in
        if case .cubic = command { return true }
        return false
      })

    XCTAssertThrowsError(try InlineSVGBridge.parsePath("M0 0 R1 1")) { error in
      guard case .invalidSVGPath = error as? InlineLayoutError else {
        return XCTFail("expected unsupported SVG command rejection")
      }
    }

    let repeated = try InlineSVGBridge.parsePath("M1e1 -2e0 2 3 L4 5 Z")
    XCTAssertEqual(repeated.commands.count, 4)
    XCTAssertEqual(repeated.bounds.minX, 2, accuracy: 0.0001)
    XCTAssertEqual(repeated.bounds.maxX, 10, accuracy: 0.0001)
    XCTAssertEqual(repeated.bounds.minY, -2, accuracy: 0.0001)
    XCTAssertEqual(repeated.bounds.maxY, 5, accuracy: 0.0001)
    let curve = try InlineSVGBridge.parsePath("M0 0 Q10 10 20 0")
    XCTAssertEqual(curve.bounds.maxY, 5, accuracy: 0.0001)
    let smooth = try InlineSVGBridge.parsePath(
      "M0 0 C1 2 2 2 3 0 S5 -2 6 0 Q7 2 8 0 T10 0")
    XCTAssertEqual(
      smooth.commands.filter { command in
        if case .cubic = command { return true }
        return false
      }.count, 2)
    XCTAssertEqual(
      smooth.commands.filter { command in
        if case .quadratic = command { return true }
        return false
      }.count, 2)
    let adjacent = try InlineSVGBridge.parsePath("M0 0L1 0zM2 2l1 0")
    XCTAssertEqual(
      adjacent.commands.compactMap { command in
        if case .move = command { return true }
        return nil
      }.count, 2)
    XCTAssertThrowsError(try InlineSVGBridge.parsePath("M0 0 L1 1 2"))
    XCTAssertThrowsError(try InlineSVGBridge.parsePath("M0 0"))
    XCTAssertThrowsError(try InlineSVGBridge.parsePath("M0 0 L1 0 Z L2 0"))
    XCTAssertThrowsError(try InlineSVGBridge.parsePath("M0 0 M1 1 L2 2"))
    XCTAssertThrowsError(try InlineSVGBridge.parsePath("M1000001 0 L1 0"))
  }

  func testAssetCacheReportsDeterministicEvictionAndBoundedCapacity() throws {
    let path = try InlineSVGBridge.parsePath("M0 0 L1 0")
    let metrics = try InlineMetrics(advance: 1, ascent: 1, descent: 0)
    let first = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "first"), metrics: metrics,
      coordinateBounds: path.bounds, coveragePath: path,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let second = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "second"), metrics: metrics,
      coordinateBounds: path.bounds, coveragePath: path,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let cache = try InlineAssetCache(maximumEntries: 2)
    XCTAssertNil(try cache.insert(first))
    XCTAssertNil(try cache.value(for: second.id, version: second.version))
    XCTAssertEqual(cache.missCount, 1)
    XCTAssertNil(try cache.insert(second))
    _ = try cache.value(for: first.id, version: first.version)
    let third = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "third"), metrics: metrics,
      coordinateBounds: path.bounds, coveragePath: path,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let evicted = try cache.insert(third)
    XCTAssertEqual(evicted?.id, second.id)
    XCTAssertEqual(cache.evictionCount, 1)
    XCTAssertEqual(cache.maximumEntries, 2)
    XCTAssertEqual(try cache.value(for: third.id, version: third.version), third)
    let newer = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "third"), version: 2, metrics: metrics,
      coordinateBounds: path.bounds, coveragePath: path,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    XCTAssertEqual(try cache.insert(newer)?.id, first.id)
    XCTAssertEqual(cache.count, 2)
    XCTAssertEqual(try cache.insert(newer)?.id, nil)
    XCTAssertEqual(cache.replacementCount, 1)
    XCTAssertEqual(try cache.remove(id: newer.id, version: newer.version)?.id, newer.id)
    XCTAssertEqual(cache.removalCount, 1)
    XCTAssertGreaterThan(cache.hitCount, 0)
    XCTAssertEqual(try InlineAssetCache(maximumEntries: 99_999).maximumEntries, 4_096)
  }

  func testPathRevealUsesValidatedSemanticCommandOrder() throws {
    let path = try InlineSVGBridge.parsePath("M0 0 L1 0 Q1 1 2 1 M3 3 L4 3")
    let asset = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "stroke"),
      metrics: try InlineMetrics(advance: 4, ascent: 3, descent: 1),
      coordinateBounds: path.bounds, coveragePath: path,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let plan = try InlinePathRevealPlanBuilder(secondsPerUnit: 0.1).plan(asset: asset)
    XCTAssertNoThrow(try plan.validate(for: asset))
    XCTAssertEqual(plan.units.map(\.commandIndex), [1, 2, 4])
    let staleAsset = try InlineSVGAsset(
      id: asset.id, version: asset.version + 1, metrics: asset.metrics,
      coordinateBounds: asset.coordinateBounds, coveragePath: asset.coveragePath,
      coveragePaint: asset.coveragePaint, trajectoryPath: asset.trajectoryPath,
      trajectoryStyle: asset.trajectoryStyle)
    XCTAssertThrowsError(try plan.validate(for: staleAsset))

    XCTAssertThrowsError(
      try InlinePathRevealPlanBuilder(maximumUnits: 1).plan(asset: asset)
    ) { error in
      guard case .resourceLimitExceeded = error as? InlineLayoutError else {
        return XCTFail("expected path reveal unit limit")
      }
    }
    let first = try InlinePathRevealUnit(
      assetID: asset.id, assetVersion: asset.version, commandIndex: 3, duration: 0.1)
    let second = try InlinePathRevealUnit(
      assetID: asset.id, assetVersion: asset.version, commandIndex: 2, duration: 0.1)
    XCTAssertThrowsError(try InlinePathRevealPlan(units: [first, second]))
    let beyond = try InlinePathRevealUnit(
      assetID: asset.id, assetVersion: asset.version, commandIndex: 99, duration: 0.1)
    let invalid = try InlinePathRevealPlan(units: [first, beyond])
    XCTAssertThrowsError(try invalid.validate(for: asset))
    let omitted = try InlinePathRevealPlan(units: [
      try InlinePathRevealUnit(
        assetID: asset.id, assetVersion: asset.version, commandIndex: 1, duration: 0.1)
    ])
    XCTAssertThrowsError(try omitted.validate(for: asset))

    XCTAssertThrowsError(
      try InlinePathRevealPlanBuilder().plan(asset: asset) {
        throw InlineLayoutError.cancelled
      }
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .cancelled)
    }
    XCTAssertThrowsError(try InlineSVGBridge.parsePath("M0 0Z"))

    let geometryRecord = try InlineAssetRecord(asset: asset)
    let geometryRegistry = try InlineAssetRegistry(records: [geometryRecord])
    XCTAssertNoThrow(
      try geometryRegistry.validate(
        document: InlineDocument(atoms: [
          try InlineAtom.vector(InlineVectorAtom(id: "stroke-vector", asset: asset))
        ])))
    let roundTrip = try JSONDecoder().decode(
      InlineAssetRegistry.self, from: JSONEncoder().encode(geometryRegistry))
    XCTAssertEqual(roundTrip.records.first?.geometry, asset)

    let zeroSegmentPath = try InlineSVGBridge.parsePath("M0 0 L0 0 L1 0")
    let zeroSegmentMetrics = try InlineMetrics(advance: 1, ascent: 1, descent: 0)
    let zeroSegmentAsset = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "zero-segment"),
      metrics: zeroSegmentMetrics,
      coordinateBounds: zeroSegmentPath.bounds,
      coveragePath: zeroSegmentPath,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: zeroSegmentPath,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let zeroSegmentPlan = try InlinePathRevealPlanBuilder().plan(asset: zeroSegmentAsset)
    XCTAssertEqual(zeroSegmentPlan.units.map { $0.commandIndex }, [2])
    XCTAssertNoThrow(try zeroSegmentPlan.validate(for: zeroSegmentAsset))

    let vector = try InlineAtom.vector(
      InlineVectorAtom(id: "stroke-vector", asset: asset))
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [vector]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 20)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let schedule = try InlineRenderRevealSchedule(
      plan: renderPlan,
      assets: InlineAssetStore(values: [InlineAssetKey(id: asset.id, version: asset.version): asset]),
      vectorPlans: ["stroke-vector": plan])
    let zeroFrame = schedule.sample(at: .zero)
    XCTAssertEqual(zeroFrame.completedVectorCommandCount(atomID: "stroke-vector"), 0)
    let partialTime = plan.units[0].duration + plan.units[1].duration / 2
    let partialPhase = try InlineRenderRevealPhase(rawValue: partialTime / plan.duration)
    let partialFrame = schedule.sample(at: partialPhase)
    XCTAssertEqual(
      partialFrame.completedVectorCommandCount(atomID: "stroke-vector"), 1)
    XCTAssertEqual(
      partialFrame.vectorProgress(atomID: "stroke-vector", commandIndex: 2),
      0.5,
      accuracy: 0.0001
    )
    let completeFrame = schedule.sample(at: .complete)
    XCTAssertEqual(
      completeFrame.completedVectorCommandCount(atomID: "stroke-vector"), plan.units.count)
  }

  func testRenderRevealScheduleMapsProgressToSourceRanges() throws {
    let firstRange = try InlineSourceRange(startUTF16: 0, endUTF16: 1)
    let secondRange = try InlineSourceRange(startUTF16: 1, endUTF16: 2)
    let firstID = try InlineRevealUnitID(rawValue: "first")
    let secondID = try InlineRevealUnitID(rawValue: "second")
    let revealPlan = try InlineRevealPlan(units: [
      try InlineRevealUnit(
        id: firstID, kind: .grapheme, atomID: "text", sourceRange: firstRange,
        startTime: 0, duration: 1),
      try InlineRevealUnit(
        id: secondID, kind: .grapheme, atomID: "text", sourceRange: secondRange,
        startTime: 1, duration: 1),
    ])
    let text = try InlineAtom.text(
      InlineTextAtom(
        id: "text",
        text: "ab",
        style: try InlineTextStyle(
          font: LiveTextCore.FontDescriptor(postScriptName: "Helvetica", pointSize: 12)
        )
      ))
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [text]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 20)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let schedule = try InlineRenderRevealSchedule(
      plan: renderPlan, assets: InlineAssetStore(), textPlan: revealPlan)
    let hidden = schedule.sample(at: .zero)
    XCTAssertFalse(hidden.textIsVisible(atomID: "text", sourceRange: firstRange))
    XCTAssertFalse(hidden.textIsVisible(atomID: "other", sourceRange: firstRange))

    let visible = schedule.sample(at: try InlineRenderRevealPhase(rawValue: 0.5))
    XCTAssertTrue(visible.textIsVisible(atomID: "text", sourceRange: firstRange))
    XCTAssertFalse(visible.textIsVisible(atomID: "text", sourceRange: secondRange))

    let unknownID = try InlineRevealUnitID(rawValue: "unknown")
    let invalidPlan = try InlineRevealPlan(units: [
      try InlineRevealUnit(
        id: unknownID, kind: .grapheme, atomID: "other", sourceRange: firstRange,
        startTime: 0, duration: 1)
    ])
    XCTAssertThrowsError(
      try InlineRenderRevealSchedule(
        plan: renderPlan, assets: InlineAssetStore(), textPlan: invalidPlan)
    )
  }

  func testStreamingPublishesCompleteImmutableTail() async throws {
    let vector = try InlineAtom.vector(
      InlineVectorAtom(
        id: "vector",
        assetID: try InlineAssetID(rawValue: "vector"),
        metrics: try InlineMetrics(advance: 2, ascent: 1, descent: 0)
      ))
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [vector]), cancellation: {})
    var results: [InlineLayoutResult] = []
    for try await result in try InlineLayoutEngine().stream(
      prepared: prepared, width: 10, maximumLinesPerYield: 1)
    {
      results.append(result)
    }
    XCTAssertEqual(results.count, 1)
    XCTAssertNil(results[0].continuation)
    XCTAssertNoThrow(try results[0].validate(for: prepared))
  }

  func testStreamingEmptyDocumentCompletesWithOneValidEmptyResult() async throws {
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: []), cancellation: {})
    var results: [InlineLayoutResult] = []
    for try await result in try InlineLayoutEngine().stream(
      prepared: prepared, width: 10, maximumLinesPerYield: 1)
    {
      results.append(result)
    }
    XCTAssertEqual(results.count, 1)
    XCTAssertTrue(results[0].lines.isEmpty)
    XCTAssertNil(results[0].continuation)
  }

  func testStreamingResultRejectsFabricatedContinuation() throws {
    let text = try InlineAtom.text(
      InlineTextAtom(
        id: "text",
        text: String(repeating: "abcdef ", count: 5),
        style: try InlineTextStyle(
          font: LiveTextCore.FontDescriptor(postScriptName: "Helvetica", pointSize: 12)
        )
      ))
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [text]))
    let result = try InlineLayoutEngine().layout(prepared: prepared, width: 2, maximumLines: 1)
    guard let valid = result.continuation else {
      return XCTFail("expected continuation")
    }
    let invalid = InlineLayoutContinuation(
      cursor: InlineCursor(atomIndex: 99, graphemeIndex: 0),
      preparationRevision: valid.preparationRevision,
      width: valid.width,
      leading: valid.leading,
      oversizedVectorPolicy: valid.oversizedVectorPolicy
    )
    let fabricated = InlineLayoutResult(
      lines: result.lines,
      width: result.width,
      height: result.height,
      preparationRevision: result.preparationRevision,
      continuation: invalid
    )
    XCTAssertThrowsError(try InlineStreamingResult(prepared: prepared, layout: fabricated))

    let invalidPolicy = InlineLayoutContinuation(
      cursor: valid.cursor,
      preparationRevision: valid.preparationRevision,
      width: valid.width,
      leading: valid.leading,
      oversizedVectorPolicy: .scaleToFit(minimumScale: 2)
    )
    let policyFabrication = InlineLayoutResult(
      lines: result.lines,
      width: result.width,
      height: result.height,
      preparationRevision: result.preparationRevision,
      continuation: invalidPolicy
    )
    XCTAssertThrowsError(try InlineStreamingResult(prepared: prepared, layout: policyFabrication))
  }

  func testLayoutStreamPropagatesInvalidWidthAndYieldLimit() async throws {
    let metrics = try InlineMetrics(advance: 2, ascent: 1, descent: 0)
    let vector = try InlineAtom.vector(
      InlineVectorAtom(
        id: "vector",
        assetID: try InlineAssetID(rawValue: "vector"),
        metrics: metrics
      ))
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [vector]))
    let engine = try InlineLayoutEngine()

    do {
      for try await _ in engine.stream(prepared: prepared, width: -1) {}
      XCTFail("expected invalid width")
    } catch let error as InlineLayoutError {
      XCTAssertEqual(error, .invalidWidth(-1))
    }

    do {
      for try await _ in engine.stream(prepared: prepared, width: 10, maximumLinesPerYield: 0) {}
      XCTFail("expected invalid yield limit")
    } catch let error as InlineLayoutError {
      XCTAssertEqual(error, .invalidMetric(name: "maximumLinesPerYield", value: 0))
    }
  }

  #if canImport(CoreText)
    func testPreparedGeometryCarriesShapedRunsForRendererAdapters() throws {
      let atom = try InlineAtom.text(
        InlineTextAtom(
          id: "ligature",
          text: "fi",
          style: InlineTextStyle(
            font: FontDescriptor(postScriptName: "Helvetica", pointSize: 14)
          )
        ))
      let prepared = try InlinePreparation().prepare(
        document: InlineDocument(atoms: [atom]))
      let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 100)
      let geometry = try layout.preparedGeometry(for: prepared)
      guard case .text(let positioned, let preparedText) = geometry[0] else {
        return XCTFail("expected prepared text geometry")
      }
      XCTAssertEqual(positioned.sourceRange, preparedText.sourceRange)
      XCTAssertFalse(preparedText.shaped.runs.isEmpty)
      XCTAssertEqual(preparedText.shaped.metrics, positioned.metrics)
    }
  #endif
}
