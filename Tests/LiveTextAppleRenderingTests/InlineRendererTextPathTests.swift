import CoreGraphics
import CoreText
import LiveTextCore
import LiveTextAppleRendering
import LiveTextEffects
import LiveTextCanvas
import LiveTextLayout
import LiveTextSwiftUI
import SwiftUI
import XCTest

@testable import LiveTextCanvas
@testable import LiveTextSwiftUI

private struct TextGlyphSpec: Sendable {
  let start: Int
  let end: Int
  let positionX: Double
  let positionY: Double
  let glyphID: UInt16?

  init(
    start: Int,
    end: Int,
    positionX: Double,
    positionY: Double = 0,
    glyphID: UInt16? = nil
  ) {
    self.start = start
    self.end = end
    self.positionX = positionX
    self.positionY = positionY
    self.glyphID = glyphID
  }
}

private struct FixedTextShaper: InlineTextShaping {
  let runs: [[TextGlyphSpec]]

  func shape(
    text: String, style: InlineTextStyle, sourceRange: InlineSourceRange
  ) throws -> InlineShapedText {
    let baseline = try CoreTextInlineShaper().shape(
      text: text, style: style, sourceRange: sourceRange)
    guard let baselineRun = baseline.runs.first, let fallbackGlyphID = baselineRun.glyphs.first?.glyphID
    else {
      throw InlineLayoutError.unsupportedShaping("test fixture has no baseline glyph")
    }

    let shapedRuns = try runs.map { specs in
      guard !specs.isEmpty else {
        throw InlineLayoutError.unsupportedShaping("test fixture has an empty run")
      }
      let runStart = sourceRange.startUTF16 + specs.map(\.start).min()!
      let runEnd = sourceRange.startUTF16 + specs.map(\.end).max()!
      let runRange = try InlineSourceRange(startUTF16: runStart, endUTF16: runEnd)
      let glyphs = try specs.map { spec in
        let glyphRange = try InlineSourceRange(
          startUTF16: sourceRange.startUTF16 + spec.start,
          endUTF16: sourceRange.startUTF16 + spec.end
        )
        return try InlineGlyph(
          glyphID: spec.glyphID ?? fallbackGlyphID,
          positionX: spec.positionX,
          positionY: spec.positionY,
          sourceUTF16Index: glyphRange.startUTF16,
          sourceRange: glyphRange
        )
      }
      return try InlineShapedRun(
        glyphs: glyphs,
        font: baselineRun.font,
        sourceRange: runRange,
        advance: baselineRun.advance,
        ascent: baselineRun.ascent,
        descent: baselineRun.descent
      )
    }
    return try InlineShapedText(
      graphemeRanges: baseline.graphemeRanges,
      graphemeAdvances: baseline.graphemeAdvances,
      runs: shapedRuns,
      metrics: baseline.metrics
    )
  }
}

private struct EmptyAssetProvider: InlineAssetGeometryProvider {
  func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
    throw InlineAssetResolutionError.missingAsset(assetID, version: version)
  }
}

@MainActor
final class InlineRendererTextPathTests: XCTestCase {
  private func style() throws -> InlineTextStyle {
    try InlineTextStyle(font: FontDescriptor(postScriptName: "Helvetica", pointSize: 14))
  }

  private func prepared(
    text: String,
    shaper: any InlineTextShaping = CoreTextInlineShaper()
  ) throws -> PreparedInlineDocument {
    let atom = try InlineAtom.text(InlineTextAtom(id: "text", text: text, style: style()))
    return try InlinePreparation(shaper: shaper)
      .prepare(document: InlineDocument(atoms: [atom]))
  }

  func testSwiftUICanvasFacadesShareOneAppleRenderContentOwner() throws {
    let prepared = try prepared(text: "shared core")
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 160)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let core = try InlineAppleRenderContent(
      plan: plan, assets: EmptyAssetProvider())
    let swiftContent = InlineSwiftUIRenderContent(core: core)
    let canvasContent = InlineCanvasRenderContent(core: core)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
    let swift = InlineSwiftUIRenderer(content: swiftContent, viewport: viewport)
    let canvas = InlineCanvasRenderer(content: canvasContent, viewport: viewport)

    XCTAssertEqual(swift.contentIdentityForTesting, canvas.contentIdentityForTesting)
  }

  func testTwoPointSemanticUnitHasExactZeroMidAndCompleteGeometryAcrossStaticAdapters() throws {
    let sourceRange = try InlineSourceRange(startUTF16: 0, endUTF16: 1)
    let unitID = try InlineRevealUnitID(rawValue: "semantic-unit")
    let strokePoints = [CGPoint(x: 0, y: 10), CGPoint(x: 20, y: 10)]
    var strokePath = Path()
    strokePath.move(to: strokePoints[0])
    strokePath.addLine(to: strokePoints[1])
    let fullPath = strokePath
    let fullWidth: CGFloat = 2
    let entry = try InlineTextPaintEntry(
      semanticStrokePath: strokePath,
      sourceRange: sourceRange,
      writingUnitID: unitID,
      strokeWidth: Double(fullWidth),
      strokePoints: strokePoints,
      localPaintBounds: fullPath.strokedPath(
        StrokeStyle(lineWidth: fullWidth, lineCap: .round, lineJoin: .round)
      ).boundingRect
    )
    let activation = try InlineRenderRevealTextActivation(
      atomID: "semantic",
      units: [
        try InlineRenderRevealTextUnit(
          id: unitID,
          kind: .semanticStroke,
          sourceRange: sourceRange,
          startTime: 0,
          duration: 1
        )
      ]
    )

    let zeroSwift = InlineSwiftUIRenderer.semanticMaskPathForTesting(
      [entry], activation: activation, time: 0)
    let zeroCanvas = InlineCanvasRenderer.semanticMaskPathForTesting(
      [entry], activation: activation, time: 0)
    let partialSwift = InlineSwiftUIRenderer.semanticMaskPathForTesting(
      [entry], activation: activation, time: 0.5)
    let partialCanvas = InlineCanvasRenderer.semanticMaskPathForTesting(
      [entry], activation: activation, time: 0.5)
    let completeSwift = InlineSwiftUIRenderer.semanticMaskPathForTesting(
      [entry], activation: activation, time: 1)
    let completeCanvas = InlineCanvasRenderer.semanticMaskPathForTesting(
      [entry], activation: activation, time: 1)
    var expectedMidPath = Path()
    expectedMidPath.move(to: strokePoints[0])
    expectedMidPath.addLine(to: CGPoint(x: 10, y: 10))
    let expectedMidBounds = expectedMidPath.strokedPath(
      StrokeStyle(lineWidth: fullWidth, lineCap: .round, lineJoin: .round)
    ).boundingRect
    let expectedCompleteBounds = fullPath.strokedPath(
      StrokeStyle(lineWidth: fullWidth, lineCap: .round, lineJoin: .round)
    ).boundingRect

    XCTAssertTrue(zeroSwift.isEmpty)
    XCTAssertTrue(zeroCanvas.isEmpty)
    XCTAssertEqual(partialSwift.boundingRect, expectedMidBounds)
    XCTAssertEqual(partialSwift.boundingRect, partialCanvas.boundingRect)
    XCTAssertEqual(completeSwift.boundingRect, expectedCompleteBounds)
    XCTAssertEqual(completeSwift.boundingRect, completeCanvas.boundingRect)
    XCTAssertLessThan(partialCanvas.boundingRect.maxX, completeCanvas.boundingRect.maxX)
  }

  func testOnePointSemanticUnitGrowsMonotonicallyAcrossStaticAdapters() throws {
    let sourceRange = try InlineSourceRange(startUTF16: 0, endUTF16: 1)
    let unitID = try InlineRevealUnitID(rawValue: "semantic-dab")
    let point = CGPoint(x: 12, y: 8)
    let fullWidth: CGFloat = 10
    let fullPath = Path(ellipseIn: CGRect(
      x: point.x - fullWidth * 0.5,
      y: point.y - fullWidth * 0.5,
      width: fullWidth,
      height: fullWidth))
    let entry = try InlineTextPaintEntry(
      semanticStrokePath: fullPath,
      sourceRange: sourceRange,
      writingUnitID: unitID,
      strokeWidth: Double(fullWidth),
      strokePoints: [point],
      localPaintBounds: fullPath.boundingRect)
    let activation = try InlineRenderRevealTextActivation(
      atomID: "semantic-dab",
      units: [
        try InlineRenderRevealTextUnit(
          id: unitID,
          kind: .semanticStroke,
          sourceRange: sourceRange,
          startTime: 0,
          duration: 1)
      ])

    let zeroSwift = InlineSwiftUIRenderer.semanticMaskPathForTesting(
      [entry], activation: activation, time: 0)
    let zeroCanvas = InlineCanvasRenderer.semanticMaskPathForTesting(
      [entry], activation: activation, time: 0)
    let midSwift = InlineSwiftUIRenderer.semanticMaskPathForTesting(
      [entry], activation: activation, time: 0.25)
    let midCanvas = InlineCanvasRenderer.semanticMaskPathForTesting(
      [entry], activation: activation, time: 0.25)
    let almostCompleteSwift = InlineSwiftUIRenderer.semanticMaskPathForTesting(
      [entry], activation: activation, time: 0.999)
    let completeSwift = InlineSwiftUIRenderer.semanticMaskPathForTesting(
      [entry], activation: activation, time: 1)
    let completeCanvas = InlineCanvasRenderer.semanticMaskPathForTesting(
      [entry], activation: activation, time: 1)

    XCTAssertTrue(zeroSwift.isEmpty)
    XCTAssertTrue(zeroCanvas.isEmpty)
    XCTAssertGreaterThan(midSwift.boundingRect.width, 0)
    XCTAssertLessThan(midSwift.boundingRect.width, completeSwift.boundingRect.width)
    XCTAssertLessThan(
      almostCompleteSwift.boundingRect.width, completeSwift.boundingRect.width)
    XCTAssertEqual(midSwift.boundingRect, midCanvas.boundingRect)
    XCTAssertEqual(completeSwift.boundingRect, completeCanvas.boundingRect)
    XCTAssertEqual(completeSwift.boundingRect, CGRect(
      x: point.x - fullWidth * 0.5,
      y: point.y - fullWidth * 0.5,
      width: fullWidth,
      height: fullWidth
    ))
  }

  func testSemanticBrushRecipeUsesCoverageScaleSeedAndUnitProgress() throws {
    let sourceRange = try InlineSourceRange(startUTF16: 0, endUTF16: 1)
    let unitID = try InlineRevealUnitID(rawValue: "brush-unit")
    let points = [
      CGPoint(x: 2, y: 8), CGPoint(x: 12, y: 10), CGPoint(x: 24, y: 7),
    ]
    var path = Path()
    path.move(to: points[0])
    for point in points.dropFirst() { path.addLine(to: point) }
    let entry = try InlineTextPaintEntry(
      semanticStrokePath: path,
      sourceRange: sourceRange,
      writingUnitID: unitID,
      strokeWidth: 4,
      strokePoints: points,
      localPaintBounds: path.strokedPath(
        StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
      ).boundingRect
    )
    let activation = try InlineRenderRevealTextActivation(
      atomID: "brush-atom",
      units: [try InlineRenderRevealTextUnit(
        id: unitID,
        kind: .semanticStroke,
        sourceRange: sourceRange,
        startTime: 0,
        duration: 1
      )]
    )
    let lowCoverage = try WritingBrushConfiguration(
      seed: 7, coverage: 0.25, streakScale: 1)
    let highCoverage = try WritingBrushConfiguration(
      seed: 7, coverage: 0.9, streakScale: 1)
    let wideStreaks = try WritingBrushConfiguration(
      seed: 7, coverage: 0.25, streakScale: 6)
    let differentSeed = try WritingBrushConfiguration(
      seed: 8, coverage: 0.25, streakScale: 1)

    let zero = InlineAppleSemanticStrokePainter.makeBrushRecipe(
      entry, configuration: lowCoverage, activation: activation, time: 0)
    let middle = try XCTUnwrap(InlineAppleSemanticStrokePainter.makeBrushRecipe(
      entry, configuration: lowCoverage, activation: activation, time: 0.5))
    let complete = try XCTUnwrap(InlineAppleSemanticStrokePainter.makeBrushRecipe(
      entry, configuration: lowCoverage, activation: activation, time: 1))
    XCTAssertNil(zero)
    XCTAssertEqual(middle.progress, 0.5, accuracy: 0.0001)
    XCTAssertEqual(complete.progress, 1, accuracy: 0.0001)
    XCTAssertLessThan(middle.centerline.count, complete.centerline.count)
    XCTAssertFalse(middle.streaks.isEmpty)

    let coverageRecipe = try XCTUnwrap(InlineAppleSemanticStrokePainter.makeBrushRecipe(
      entry, configuration: highCoverage, activation: activation, time: 1))
    XCTAssertGreaterThan(coverageRecipe.pigmentOpacity, complete.pigmentOpacity)
    XCTAssertEqual(complete, try XCTUnwrap(InlineAppleSemanticStrokePainter.makeBrushRecipe(
      entry, configuration: lowCoverage, activation: activation, time: 1)))

    let wideRecipe = try XCTUnwrap(InlineAppleSemanticStrokePainter.makeBrushRecipe(
      entry, configuration: wideStreaks, activation: activation, time: 1))
    XCTAssertGreaterThan(wideRecipe.streaks.count, complete.streaks.count)
    XCTAssertNotEqual(wideRecipe.streaks[0].width, complete.streaks[0].width)
    XCTAssertNotEqual(wideRecipe.streaks, complete.streaks)

    let seedRecipe = try XCTUnwrap(InlineAppleSemanticStrokePainter.makeBrushRecipe(
      entry, configuration: differentSeed, activation: activation, time: 1))
    XCTAssertNotEqual(seedRecipe.phase, complete.phase)
    XCTAssertNotEqual(seedRecipe.streaks, complete.streaks)
  }

  func testSemanticBrushDabUsesPartialUnitProgressAndCoverageVisibility() throws {
    let sourceRange = try InlineSourceRange(startUTF16: 0, endUTF16: 1)
    let unitID = try InlineRevealUnitID(rawValue: "brush-dab")
    let point = CGPoint(x: 8, y: 8)
    let path = Path(ellipseIn: CGRect(x: 6, y: 6, width: 4, height: 4))
    let entry = try InlineTextPaintEntry(
      semanticStrokePath: path,
      sourceRange: sourceRange,
      writingUnitID: unitID,
      strokeWidth: 10,
      strokePoints: [point],
      localPaintBounds: path.boundingRect
    )
    let activation = try InlineRenderRevealTextActivation(
      atomID: "dab-atom",
      units: [try InlineRenderRevealTextUnit(
        id: unitID, kind: .semanticStroke, sourceRange: sourceRange,
        startTime: 0, duration: 1)]
    )
    let visible = try WritingBrushConfiguration(seed: 1, coverage: 0.8, streakScale: 2)
    let invisible = try WritingBrushConfiguration(seed: 1, coverage: 0, streakScale: 2)
    let middle = try XCTUnwrap(InlineAppleSemanticStrokePainter.makeBrushRecipe(
      entry, configuration: visible, activation: activation, time: 0.25))
    let complete = try XCTUnwrap(InlineAppleSemanticStrokePainter.makeBrushRecipe(
      entry, configuration: visible, activation: activation, time: 1))
    let noPigment = try XCTUnwrap(InlineAppleSemanticStrokePainter.makeBrushRecipe(
      entry, configuration: invisible, activation: activation, time: 1))
    XCTAssertTrue(middle.isDab)
    XCTAssertLessThan(middle.dabRadius, complete.dabRadius)
    XCTAssertGreaterThan(complete.pigmentOpacity, noPigment.pigmentOpacity)
    XCTAssertEqual(noPigment.pigmentOpacity, 0, accuracy: 0.0001)
  }

  private func manualLayout(
    prepared: PreparedInlineDocument,
    ranges: [InlineSourceRange],
    origins: [Double]? = nil,
    cellWidth: Double = 100
  ) throws -> InlineLayoutResult {
    guard case .text(let text) = prepared.atoms[0] else {
      throw InlineLayoutError.invalidRenderPlan
    }
    let originValues = origins ?? Array(repeating: 0, count: ranges.count)
    guard originValues.count == ranges.count else {
      throw InlineLayoutError.invalidRenderPlan
    }
    let baseline = text.metrics.ascent + text.metrics.baselineOffset
    let height = text.metrics.ascent + text.metrics.descent
    let positioned = try ranges.enumerated().map { index, range in
      try PositionedInlineAtom(
        atomID: text.atom.id,
        kind: .text,
        lineIndex: 0,
        originX: originValues[index],
        baselineY: baseline,
        width: cellWidth,
        height: height,
        metrics: text.metrics,
        sourceRange: range
      )
    }
    let line = try InlineLayoutLine(
      index: 0,
      baselineY: baseline,
      ascent: text.metrics.ascent,
      descent: text.metrics.descent,
      leading: 0,
      width: cellWidth,
      start: .zero,
      end: InlineCursor(atomIndex: 1, graphemeIndex: 0),
      atoms: positioned
    )
    return InlineLayoutResult(
      lines: [line],
      width: 100,
      height: height,
      preparationRevision: prepared.revision,
      continuation: nil
    )
  }

  private func bounds(_ path: Path) -> CGRect {
    path.cgPath.boundingBox
  }

  private func viewport(for layout: InlineLayoutResult) throws -> InlineRenderViewport {
    try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
  }

  private func swiftUIRenderer<Provider: InlineAssetGeometryProvider>(
    prepared: PreparedInlineDocument,
    layout: InlineLayoutResult,
    assets: Provider,
    registry: InlineAssetRegistry = .empty,
    schedule: InlineRenderRevealSchedule? = nil,
    phase: InlineRenderRevealPhase = .complete
  ) throws -> InlineSwiftUIRenderer {
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let content = try InlineSwiftUIRenderContent(
      plan: plan, assets: assets, registry: registry, schedule: schedule)
    return InlineSwiftUIRenderer(
      content: content, phase: phase, viewport: try viewport(for: layout))
  }

  private func canvasRenderer<Provider: InlineAssetGeometryProvider>(
    prepared: PreparedInlineDocument,
    layout: InlineLayoutResult,
    assets: Provider,
    registry: InlineAssetRegistry = .empty,
    schedule: InlineRenderRevealSchedule? = nil,
    phase: InlineRenderRevealPhase = .complete
  ) throws -> InlineCanvasRenderer {
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let content = try InlineCanvasRenderContent(
      plan: plan, assets: assets, registry: registry, schedule: schedule)
    return InlineCanvasRenderer(
      content: content, phase: phase, viewport: try viewport(for: layout))
  }

  private func assertPathParity(
    swiftUI: InlineSwiftUIRenderer,
    canvas: InlineCanvasRenderer,
    positioned: PositionedInlineAtom,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    guard let swiftPaths = swiftUI.renderedTextPathsForTesting[positioned],
      let canvasPaths = canvas.renderedTextPathsForTesting[positioned]
    else {
      return XCTFail("both renderers must retain the positioned text fragment", file: file, line: line)
    }
    XCTAssertEqual(swiftPaths.count, canvasPaths.count, file: file, line: line)
    for (swiftPath, canvasPath) in zip(swiftPaths, canvasPaths) {
      let swiftBounds = bounds(swiftPath)
      let canvasBounds = bounds(canvasPath)
      XCTAssertEqual(swiftBounds.minX, canvasBounds.minX, accuracy: 0.0001, file: file, line: line)
      XCTAssertEqual(swiftBounds.minY, canvasBounds.minY, accuracy: 0.0001, file: file, line: line)
      XCTAssertEqual(swiftBounds.width, canvasBounds.width, accuracy: 0.0001, file: file, line: line)
      XCTAssertEqual(swiftBounds.height, canvasBounds.height, accuracy: 0.0001, file: file, line: line)
    }
  }

  func testRenderersSkipNonRenderingWhitespaceGlyphs() throws {
    let id = try InlineAssetID(rawValue: "star")
    let metrics = try InlineMetrics(advance: 34, ascent: 30, descent: 4)
    let path = try InlineSVGBridge.parsePath(
      "M17 1 L21 12 L33 13 L24 21 L27 33 L17 26 L7 33 L10 21 L1 13 L13 12 Z")
    let svg = try InlineSVGAsset(
      id: id,
      metrics: metrics,
      coordinateBounds: path.bounds,
      coveragePath: path,
      coveragePaint: .fill(.nonZero),
      trajectoryPath: path,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1),
      accessibilityLabel: "A five point star")
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 19))
    let text = try InlineTextAtom(
      id: "intro", text: "LiveText renders shaped text beside real vector assets. 你好世界",
      style: style)
    let vector = try InlineVectorAtom(id: "star-atom", asset: svg)
    let document = try InlineDocument(atoms: [.text(text), .vector(vector)])
    let prepared = try InlinePreparation().prepare(document: document)
    let layout = try InlineLayoutEngine(oversizedVectorPolicy: .scaleToFit(minimumScale: 0.5))
      .layout(prepared: prepared, width: 340)
    let registry = try InlineAssetRegistry(records: [try InlineAssetRecord(asset: svg)])
    struct Provider: InlineAssetGeometryProvider {
      let asset: InlineSVGAsset
      func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
        guard asset.id == assetID, asset.version == version else {
          throw InlineAssetResolutionError.missingAsset(assetID, version: version)
        }
        return asset
      }
    }
    let provider = Provider(asset: svg)
    XCTAssertNoThrow(
      try swiftUIRenderer(
        prepared: prepared, layout: layout, assets: provider, registry: registry))
    XCTAssertNoThrow(
      try canvasRenderer(
        prepared: prepared, layout: layout, assets: provider, registry: registry))
  }

  func testLongAtomAcrossLinesProducesTextPathsForBothRenderers() throws {
    let prepared = try prepared(text: String(repeating: "alpha beta gamma ", count: 80))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 90)
    let positions = layout.lines.flatMap(\.atoms).filter { $0.kind == .text }
    XCTAssertGreaterThan(positions.count, 1)

    let swiftUI = try swiftUIRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    let canvas = try canvasRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    XCTAssertEqual(swiftUI.renderedTextPathsForTesting.keys, canvas.renderedTextPathsForTesting.keys)
    XCTAssertEqual(
      swiftUI.renderedTextPathsForTesting.values.reduce(0) { $0 + $1.count },
      canvas.renderedTextPathsForTesting.values.reduce(0) { $0 + $1.count }
    )
    for positioned in positions {
      try assertPathParity(swiftUI: swiftUI, canvas: canvas, positioned: positioned)
    }
  }

  func testWhitespaceGlyphsRemainNonRendering() throws {
    let prepared = try prepared(text: "a b")
    let layout = try manualLayout(
      prepared: prepared,
      ranges: [try InlineSourceRange(startUTF16: 0, endUTF16: 3)]
    )
    let positioned = try XCTUnwrap(layout.lines[0].atoms.first)
    let swiftUI = try swiftUIRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    let canvas = try canvasRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    XCTAssertEqual(swiftUI.renderedTextPathsForTesting[positioned]?.count, 2)
    XCTAssertEqual(canvas.renderedTextPathsForTesting[positioned]?.count, 2)
    try assertPathParity(swiftUI: swiftUI, canvas: canvas, positioned: positioned)
  }

  func testGlyphSpanningAdjacentFragmentsIsAssignedToBothRenderers() throws {
    let shaper = FixedTextShaper(runs: [[TextGlyphSpec(start: 0, end: 2, positionX: 12)]])
    let prepared = try prepared(text: "ab", shaper: shaper)
    let layout = try manualLayout(
      prepared: prepared,
      ranges: [
        try InlineSourceRange(startUTF16: 0, endUTF16: 1),
        try InlineSourceRange(startUTF16: 1, endUTF16: 2),
      ],
      origins: [0, 30]
    )
    let swiftUI = try swiftUIRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    let canvas = try canvasRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    for positioned in layout.lines[0].atoms {
      XCTAssertEqual(swiftUI.renderedTextPathsForTesting[positioned]?.count, 1)
      XCTAssertEqual(canvas.renderedTextPathsForTesting[positioned]?.count, 1)
      try assertPathParity(swiftUI: swiftUI, canvas: canvas, positioned: positioned)
    }
  }

  func testRevealHidesPathsWithoutChangingFragmentOriginAndRetainsEmptyFragments() throws {
    let prepared = try prepared(text: "ab")
    let fullRange = try InlineSourceRange(startUTF16: 0, endUTF16: 2)
    let layout = try manualLayout(prepared: prepared, ranges: [fullRange])
    let positioned = try XCTUnwrap(layout.lines[0].atoms.first)
    let plan = try InlineRevealPlanBuilder().graphemePlan(prepared: prepared)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let schedule = try InlineRenderRevealSchedule(
      plan: renderPlan, assets: InlineAssetStore(), textPlan: plan)

    let hiddenSwiftUI = try swiftUIRenderer(
      prepared: prepared,
      layout: layout,
      assets: EmptyAssetProvider(),
      schedule: schedule,
      phase: .zero
    )
    let hiddenCanvas = try canvasRenderer(
      prepared: prepared,
      layout: layout,
      assets: EmptyAssetProvider(),
      schedule: schedule,
      phase: .zero
    )
    XCTAssertNotNil(hiddenSwiftUI.visibleTextPathsForTesting[positioned])
    XCTAssertNotNil(hiddenCanvas.visibleTextPathsForTesting[positioned])
    XCTAssertEqual(hiddenSwiftUI.visibleTextPathsForTesting[positioned]?.count, 0)
    XCTAssertEqual(hiddenCanvas.visibleTextPathsForTesting[positioned]?.count, 0)

    let midPhase = try InlineRenderRevealPhase(rawValue: 0.5)
    let midSwiftUI = try swiftUIRenderer(
      prepared: prepared,
      layout: layout,
      assets: EmptyAssetProvider(),
      schedule: schedule,
      phase: midPhase
    )
    let midCanvas = try canvasRenderer(
      prepared: prepared,
      layout: layout,
      assets: EmptyAssetProvider(),
      schedule: schedule,
      phase: midPhase
    )
    let midSwiftPaths = try XCTUnwrap(midSwiftUI.visibleTextPathsForTesting[positioned])
    let midCanvasPaths = try XCTUnwrap(midCanvas.visibleTextPathsForTesting[positioned])
    XCTAssertEqual(midSwiftPaths.count, 1)
    XCTAssertEqual(midCanvasPaths.count, 1)
    XCTAssertEqual(bounds(midSwiftPaths[0]), bounds(midCanvasPaths[0]))

    let completeSwiftUI = try swiftUIRenderer(
      prepared: prepared,
      layout: layout,
      assets: EmptyAssetProvider(),
      schedule: schedule,
      phase: .complete
    )
    let completeCanvas = try canvasRenderer(
      prepared: prepared,
      layout: layout,
      assets: EmptyAssetProvider(),
      schedule: schedule,
      phase: .complete
    )
    XCTAssertEqual(completeSwiftUI.visibleTextPathsForTesting[positioned]?.count, 2)
    XCTAssertEqual(completeCanvas.visibleTextPathsForTesting[positioned]?.count, 2)

    let secondPlan = try InlineRevealPlan(units: [try XCTUnwrap(plan.units.last)])
    let secondSchedule = try InlineRenderRevealSchedule(
      plan: renderPlan, assets: InlineAssetStore(), textPlan: secondPlan)
    let fullSwiftUI = try swiftUIRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    let visibleSwiftUI = try swiftUIRenderer(
      prepared: prepared,
      layout: layout,
      assets: EmptyAssetProvider(),
      schedule: secondSchedule
    )
    let fullCanvas = try canvasRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    let visibleCanvas = try canvasRenderer(
      prepared: prepared,
      layout: layout,
      assets: EmptyAssetProvider(),
      schedule: secondSchedule
    )
    let allSwiftPaths = try XCTUnwrap(fullSwiftUI.renderedTextPathsForTesting[positioned])
    let visibleSwiftPaths = try XCTUnwrap(visibleSwiftUI.visibleTextPathsForTesting[positioned])
    let allCanvasPaths = try XCTUnwrap(fullCanvas.renderedTextPathsForTesting[positioned])
    let visibleCanvasPaths = try XCTUnwrap(visibleCanvas.visibleTextPathsForTesting[positioned])
    XCTAssertEqual(allSwiftPaths.count, 2)
    XCTAssertEqual(visibleSwiftPaths.count, 1)
    XCTAssertEqual(allCanvasPaths.count, 2)
    XCTAssertEqual(visibleCanvasPaths.count, 1)
    XCTAssertEqual(bounds(visibleSwiftPaths[0]), bounds(allSwiftPaths[1]))
    XCTAssertEqual(bounds(visibleCanvasPaths[0]), bounds(allCanvasPaths[1]))
    try assertPathParity(swiftUI: visibleSwiftUI, canvas: visibleCanvas, positioned: positioned)
  }

  func testExplicitEmptyTextPlanIsRejectedByBothRendererOwners() throws {
    let prepared = try prepared(text: "ab")
    let fullRange = try InlineSourceRange(startUTF16: 0, endUTF16: 2)
    let layout = try manualLayout(prepared: prepared, ranges: [fullRange])
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let emptyTextPlan = try InlineRevealPlan(units: [])
    XCTAssertThrowsError(
      try InlineRenderRevealSchedule(
        plan: renderPlan, assets: InlineAssetStore(), textPlan: emptyTextPlan)
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidRenderPlan)
    }
  }

  func testNilScheduleLeavesTextVisibleAtZeroInsteadOfAnimatingByPhaseAlone() throws {
    let prepared = try prepared(text: "ab")
    let fullRange = try InlineSourceRange(startUTF16: 0, endUTF16: 2)
    let layout = try manualLayout(prepared: prepared, ranges: [fullRange])
    let positioned = try XCTUnwrap(layout.lines[0].atoms.first)

    // A nil schedule is intentionally a completed/no-activation schedule. A
    // scalar phase update cannot reveal text unless its source units were
    // compiled into `textPlan` first.
    let swiftUI = try swiftUIRenderer(
      prepared: prepared,
      layout: layout,
      assets: EmptyAssetProvider(),
      phase: .zero
    )
    let canvas = try canvasRenderer(
      prepared: prepared,
      layout: layout,
      assets: EmptyAssetProvider(),
      phase: .zero
    )
    XCTAssertEqual(swiftUI.visibleTextPathsForTesting[positioned]?.count, 2)
    XCTAssertEqual(canvas.visibleTextPathsForTesting[positioned]?.count, 2)
  }

  func testShuffledGlyphOrderUsesFinalMinimumOriginAndPreservesRunOrder() throws {
    let shaper = FixedTextShaper(runs: [[
      TextGlyphSpec(start: 2, end: 3, positionX: 20),
      TextGlyphSpec(start: 0, end: 1, positionX: 0),
      TextGlyphSpec(start: 1, end: 2, positionX: 10),
    ]])
    let prepared = try prepared(text: "abc", shaper: shaper)
    let layout = try manualLayout(
      prepared: prepared,
      ranges: [try InlineSourceRange(startUTF16: 0, endUTF16: 3)]
    )
    let positioned = try XCTUnwrap(layout.lines[0].atoms.first)
    let swiftUI = try swiftUIRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    let canvas = try canvasRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    let swiftPaths = try XCTUnwrap(swiftUI.renderedTextPathsForTesting[positioned])
    let canvasPaths = try XCTUnwrap(canvas.renderedTextPathsForTesting[positioned])
    XCTAssertEqual(swiftPaths.count, 3)
    XCTAssertEqual(canvasPaths.count, 3)
    XCTAssertEqual(bounds(swiftPaths[0]).minX - bounds(swiftPaths[1]).minX, 20, accuracy: 0.0001)
    XCTAssertEqual(bounds(swiftPaths[2]).minX - bounds(swiftPaths[1]).minX, 10, accuracy: 0.0001)
    XCTAssertEqual(bounds(canvasPaths[0]).minX - bounds(canvasPaths[1]).minX, 20, accuracy: 0.0001)
    XCTAssertEqual(bounds(canvasPaths[2]).minX - bounds(canvasPaths[1]).minX, 10, accuracy: 0.0001)
    try assertPathParity(swiftUI: swiftUI, canvas: canvas, positioned: positioned)
  }

  func testBidiGlyphOrderKeepsSwiftUIAndCanvasPathsInParity() throws {
    let prepared = try prepared(text: "abc אבג")
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 90)
    let positions = layout.lines.flatMap(\.atoms).filter { $0.kind == .text }
    XCTAssertFalse(positions.isEmpty)
    let swiftUI = try swiftUIRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    let canvas = try canvasRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    for positioned in positions {
      try assertPathParity(swiftUI: swiftUI, canvas: canvas, positioned: positioned)
    }
  }

  func testForgedOverlappingFragmentsAreRejected() throws {
    let prepared = try prepared(text: "abc")
    let layout = try manualLayout(
      prepared: prepared,
      ranges: [
        try InlineSourceRange(startUTF16: 0, endUTF16: 2),
        try InlineSourceRange(startUTF16: 1, endUTF16: 3),
      ]
    )
    XCTAssertThrowsError(
      try swiftUIRenderer(
        prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidRenderPlan)
    }
    XCTAssertThrowsError(
      try canvasRenderer(
        prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidRenderPlan)
    }
  }

  func testMissingVisibleGlyphPathRemainsTypedShapingFailure() throws {
    let shaper = FixedTextShaper(
      runs: [[TextGlyphSpec(start: 0, end: 1, positionX: 0, glyphID: UInt16.max)]])
    let prepared = try prepared(text: "a", shaper: shaper)
    let layout = try manualLayout(
      prepared: prepared,
      ranges: [try InlineSourceRange(startUTF16: 0, endUTF16: 1)]
    )

    XCTAssertThrowsError(
      try swiftUIRenderer(
        prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    ) { error in
      guard case .unsupportedShaping = error as? InlineLayoutError else {
        return XCTFail("missing Core Text glyph path must remain a typed shaping failure")
      }
    }
    XCTAssertThrowsError(
      try canvasRenderer(
        prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    ) { error in
      guard case .unsupportedShaping = error as? InlineLayoutError else {
        return XCTFail("missing Core Text glyph path must remain a typed shaping failure")
      }
    }
  }

  func testSwiftUIPerAtomCanvasExpandsToTextPaintOverhang() throws {
    let shaper = FixedTextShaper(
      runs: [[TextGlyphSpec(start: 0, end: 1, positionX: 0)]])
    let prepared = try prepared(text: "a", shaper: shaper)
    let layout = try manualLayout(
      prepared: prepared,
      ranges: [try InlineSourceRange(startUTF16: 0, endUTF16: 1)],
      cellWidth: 1
    )
    let positioned = try XCTUnwrap(layout.lines[0].atoms.first)
    let swiftUI = try swiftUIRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    let canvas = try canvasRenderer(
      prepared: prepared, layout: layout, assets: EmptyAssetProvider())
    let entries = try XCTUnwrap(swiftUI.renderedTextPaintEntriesForTesting[positioned])
    let expected = entries.reduce(
      CGRect(x: 0, y: 0, width: positioned.width, height: positioned.height)
    ) { partial, entry in
      partial.union(entry.localPaintBounds)
    }
    XCTAssertGreaterThan(expected.maxX, CGFloat(positioned.width))
    XCTAssertEqual(swiftUI.textCanvasBoundsForTesting(positioned), expected)
    XCTAssertEqual(canvas.textCanvasBoundsForTesting(positioned), expected)
    XCTAssertGreaterThan(expected.width, CGFloat(positioned.width))
  }
}
