import CoreGraphics
import LiveTextCore
import LiveTextLayout
import LiveTextAppleRendering
import SwiftUI
import XCTest

@testable import LiveTextCanvas
@testable import LiveTextSwiftUI

private enum PathProjectionError: Error {
  case transformFailed
}

private enum PathElementProjection: Equatable {
  case move(CGPoint)
  case line(CGPoint)
  case quadratic(CGPoint, CGPoint)
  case cubic(CGPoint, CGPoint, CGPoint)
  case close
}

private func projectPath(_ path: Path, translatedBy offset: CGPoint) throws
  -> [PathElementProjection]
{
  var transform = CGAffineTransform(translationX: offset.x, y: offset.y)
  guard let transformed = path.cgPath.copy(using: &transform) else {
    throw PathProjectionError.transformFailed
  }
  var result: [PathElementProjection] = []
  transformed.applyWithBlock { element in
    let points = element.pointee.points
    switch element.pointee.type {
    case .moveToPoint: result.append(.move(points[0]))
    case .addLineToPoint: result.append(.line(points[0]))
    case .addQuadCurveToPoint: result.append(.quadratic(points[0], points[1]))
    case .addCurveToPoint: result.append(.cubic(points[0], points[1], points[2]))
    case .closeSubpath: result.append(.close)
    @unknown default: break
    }
  }
  return result
}

private func assertPathsEquivalent(
  _ lhs: [PathElementProjection],
  _ rhs: [PathElementProjection],
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
  for (left, right) in zip(lhs, rhs) {
    switch (left, right) {
    case (.move(let a), .move(let b)), (.line(let a), .line(let b)):
      XCTAssertEqual(a.x, b.x, accuracy: 0.0001, file: file, line: line)
      XCTAssertEqual(a.y, b.y, accuracy: 0.0001, file: file, line: line)
    case (.quadratic(let ac, let ae), .quadratic(let bc, let be)):
      XCTAssertEqual(ac.x, bc.x, accuracy: 0.0001, file: file, line: line)
      XCTAssertEqual(ac.y, bc.y, accuracy: 0.0001, file: file, line: line)
      XCTAssertEqual(ae.x, be.x, accuracy: 0.0001, file: file, line: line)
      XCTAssertEqual(ae.y, be.y, accuracy: 0.0001, file: file, line: line)
    case (.cubic(let ac1, let ac2, let ae), .cubic(let bc1, let bc2, let be)):
      for (a, b) in [(ac1, bc1), (ac2, bc2), (ae, be)] {
        XCTAssertEqual(a.x, b.x, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.0001, file: file, line: line)
      }
    case (.close, .close): break
    default:
      XCTFail("path element topology differs", file: file, line: line)
    }
  }
}

@MainActor
final class InlineRendererContractTests: XCTestCase {
  private struct MultiRunShaper: InlineTextShaping {
    func shape(
      text: String, style: InlineTextStyle, sourceRange: InlineSourceRange
    ) throws -> InlineShapedText {
      let graphemes = Array(text)
      var ranges: [InlineSourceRange] = []
      var offset = sourceRange.startUTF16
      for grapheme in graphemes {
        let length = String(grapheme).utf16.count
        ranges.append(try InlineSourceRange(startUTF16: offset, endUTF16: offset + length))
        offset += length
      }
      let runs = try ranges.enumerated().map { index, range in
        try InlineShapedRun(
          glyphs: [
            try InlineGlyph(
              glyphID: UInt16(index + 1),
              positionX: Double(index),
              positionY: 0,
              sourceUTF16Index: range.startUTF16,
              sourceRange: range
            )
          ],
          font: style.font,
          sourceRange: range,
          advance: 1,
          ascent: style.font.pointSize,
          descent: 2
        )
      }
      return try InlineShapedText(
        graphemeRanges: ranges,
        graphemeAdvances: Array(repeating: 1, count: ranges.count),
        runs: runs,
        metrics: try InlineMetrics(
          advance: Double(ranges.count),
          ascent: style.font.pointSize,
          descent: 2,
          baselineOffset: style.baselineOffset
        )
      )
    }
  }

  private struct FailingGeometryProvider: InlineAssetGeometryProvider {
    let assetID: InlineAssetID

    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      throw InlineAssetResolutionError.metricsMismatch(self.assetID)
    }
  }

  private struct FailingCanvasGeometryProvider: InlineAssetGeometryProvider {
    let assetID: InlineAssetID

    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      throw InlineAssetResolutionError.metricsMismatch(self.assetID)
    }
  }

  private struct ValidGeometryProvider: InlineAssetGeometryProvider {
    let asset: InlineSVGAsset

    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      asset
    }
  }

  private struct MapGeometryProvider: InlineAssetGeometryProvider {
    let assets: [InlineAssetID: InlineSVGAsset]

    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      guard let asset = assets[assetID], asset.version == version else {
        throw InlineAssetResolutionError.missingGeometry(assetID, version: version)
      }
      return asset
    }
  }

  private final class CountingGeometryProvider: InlineAssetGeometryProvider, @unchecked Sendable {
    let asset: InlineSVGAsset
    var callCount = 0

    init(asset: InlineSVGAsset) {
      self.asset = asset
    }

    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      callCount += 1
      return asset
    }
  }

  private struct UnusedShaper: InlineTextShaping {
    func shape(
      text: String, style: InlineTextStyle, sourceRange: InlineSourceRange
    ) throws -> InlineShapedText {
      throw InlineLayoutError.unsupportedShaping("unused shaper")
    }
  }

  private func style() throws -> InlineTextStyle {
    try InlineTextStyle(font: FontDescriptor(postScriptName: "Helvetica", pointSize: 10))
  }

  private func viewport(for layout: InlineLayoutResult) throws -> InlineRenderViewport {
    try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
  }

  private func plan(
    prepared: PreparedInlineDocument, layout: InlineLayoutResult
  ) throws -> InlineRenderPlan {
    try InlineRenderPlan(prepared: prepared, layout: layout)
  }

  private func swiftUIContent<Provider: InlineAssetGeometryProvider>(
    prepared: PreparedInlineDocument,
    layout: InlineLayoutResult,
    assets: Provider,
    registry: InlineAssetRegistry = .empty,
    schedule: InlineRenderRevealSchedule? = nil
  ) throws -> InlineSwiftUIRenderContent {
    try InlineSwiftUIRenderContent(
      plan: plan(prepared: prepared, layout: layout),
      assets: assets,
      registry: registry,
      schedule: schedule
    )
  }

  private func canvasContent<Provider: InlineAssetGeometryProvider>(
    prepared: PreparedInlineDocument,
    layout: InlineLayoutResult,
    assets: Provider,
    registry: InlineAssetRegistry = .empty,
    schedule: InlineRenderRevealSchedule? = nil
  ) throws -> InlineCanvasRenderContent {
    try InlineCanvasRenderContent(
      plan: plan(prepared: prepared, layout: layout),
      assets: assets,
      registry: registry,
      schedule: schedule
    )
  }

  private func swiftUIRenderer<Provider: InlineAssetGeometryProvider>(
    prepared: PreparedInlineDocument,
    layout: InlineLayoutResult,
    assets: Provider,
    registry: InlineAssetRegistry = .empty,
    schedule: InlineRenderRevealSchedule? = nil,
    phase: InlineRenderRevealPhase = .complete
  ) throws -> InlineSwiftUIRenderer {
    InlineSwiftUIRenderer(
      content: try swiftUIContent(
        prepared: prepared, layout: layout, assets: assets, registry: registry, schedule: schedule),
      phase: phase,
      viewport: try viewport(for: layout)
    )
  }

  private func canvasRenderer<Provider: InlineAssetGeometryProvider>(
    prepared: PreparedInlineDocument,
    layout: InlineLayoutResult,
    assets: Provider,
    registry: InlineAssetRegistry = .empty,
    schedule: InlineRenderRevealSchedule? = nil,
    phase: InlineRenderRevealPhase = .complete
  ) throws -> InlineCanvasRenderer {
    InlineCanvasRenderer(
      content: try canvasContent(
        prepared: prepared, layout: layout, assets: assets, registry: registry, schedule: schedule),
      phase: phase,
      viewport: try viewport(for: layout)
    )
  }

  func testHitTestingKeepsAtomLocalMultiRunPositions() throws {
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "text", text: "a b", style: style()))
    let prepared = try InlinePreparation(shaper: MultiRunShaper())
      .prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 3)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)

    guard case .textUnit(let hit) = index.hitTest(try InlineHitPoint(x: 2.5, y: 5)) else {
      return XCTFail("expected the second word hit")
    }
    XCTAssertEqual(hit.rect.minX, 2, accuracy: 0.0001)
    XCTAssertEqual(hit.rect.width, 1, accuracy: 0.0001)
  }

  func testSwiftUIRendererInvokesGeometryProviderDuringInitialization() throws {
    let assetID = try InlineAssetID(rawValue: "asset")
    let metrics = try InlineMetrics(advance: 4, ascent: 8, descent: 2)
    let atom = try InlineAtom.vector(
      InlineVectorAtom(id: "vector", assetID: assetID, metrics: metrics))
    let document = try InlineDocument(atoms: [atom])
    let prepared = try InlinePreparation(shaper: UnusedShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 20)

    XCTAssertThrowsError(
      try swiftUIContent(
        prepared: prepared,
        layout: layout,
        assets: FailingGeometryProvider(assetID: assetID)
      )
    ) { error in
      XCTAssertEqual(error as? InlineAssetResolutionError, .metricsMismatch(assetID))
    }
  }

  func testCanvasRendererInvokesGeometryProviderDuringInitialization() throws {
    let assetID = try InlineAssetID(rawValue: "canvas-asset")
    let metrics = try InlineMetrics(advance: 4, ascent: 8, descent: 2)
    let atom = try InlineAtom.vector(
      InlineVectorAtom(id: "canvas-vector", assetID: assetID, metrics: metrics))
    let document = try InlineDocument(atoms: [atom])
    let prepared = try InlinePreparation(shaper: UnusedShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 20)

    XCTAssertThrowsError(
      try canvasContent(
        prepared: prepared,
        layout: layout,
        assets: FailingCanvasGeometryProvider(assetID: assetID)
      )
    ) { error in
      XCTAssertEqual(error as? InlineAssetResolutionError, .metricsMismatch(assetID))
    }
  }

  func testSwiftUIRendererAcceptsProviderGeometryWithoutRegistryRecord() throws {
    let assetID = try InlineAssetID(rawValue: "provider-only")
    let metrics = try InlineMetrics(advance: 4, ascent: 8, descent: 2)
    let path = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 1, y: 1)),
    ])
    let asset = try InlineSVGAsset(
      id: assetID, metrics: metrics, coordinateBounds: path.bounds,
      coveragePath: path, coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let atom = try InlineAtom.vector(
      InlineVectorAtom(id: "provider-vector", assetID: assetID, metrics: metrics))
    let document = try InlineDocument(atoms: [atom])
    let prepared = try InlinePreparation(shaper: UnusedShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 20)

    XCTAssertNoThrow(
      try swiftUIContent(
        prepared: prepared,
        layout: layout,
        assets: ValidGeometryProvider(asset: asset)
      )
    )
  }

  func testSharedResolverResolvesEachAssetKeyOnce() throws {
    let assetID = try InlineAssetID(rawValue: "shared")
    let metrics = try InlineMetrics(advance: 4, ascent: 8, descent: 2)
    let path = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 1, y: 1)),
    ])
    let asset = try InlineSVGAsset(
      id: assetID, metrics: metrics, coordinateBounds: path.bounds,
      coveragePath: path, coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let first = try InlineAtom.vector(
      InlineVectorAtom(id: "first", assetID: assetID, metrics: metrics))
    let second = try InlineAtom.vector(
      InlineVectorAtom(id: "second", assetID: assetID, metrics: metrics))
    let provider = CountingGeometryProvider(asset: asset)

    let resolved = try resolveInlineAssets(
      document: try InlineDocument(atoms: [first, second]),
      registry: .empty,
      provider: provider
    )

    XCTAssertEqual(provider.callCount, 1)
    XCTAssertNotNil(resolved[InlineAssetKey(id: assetID, version: asset.version)])
  }

  func testSharedResolverUsesValidatedAssetCacheAcrossCalls() throws {
    let assetID = try InlineAssetID(rawValue: "cached")
    let metrics = try InlineMetrics(advance: 4, ascent: 8, descent: 2)
    let path = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 1, y: 1)),
    ])
    let asset = try InlineSVGAsset(
      id: assetID, metrics: metrics, coordinateBounds: path.bounds,
      coveragePath: path, coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let atom = try InlineAtom.vector(
      InlineVectorAtom(id: "cached-vector", assetID: assetID, metrics: metrics))
    let document = try InlineDocument(atoms: [atom])
    let provider = CountingGeometryProvider(asset: asset)
    let cache = try InlineAssetCache(maximumEntries: 2)

    _ = try resolveInlineAssets(
      document: document, registry: .empty, provider: provider, cache: cache)
    _ = try resolveInlineAssets(
      document: document, registry: .empty, provider: provider, cache: cache)

    XCTAssertEqual(provider.callCount, 1)
    XCTAssertEqual(cache.missCount, 1)
    XCTAssertEqual(cache.hitCount, 1)
    XCTAssertEqual(cache.count, 1)
  }

  func testStaticRendererCachePublicationIsAtomicForSwiftUIAndCanvas() throws {
    let metrics = try InlineMetrics(advance: 2, ascent: 2, descent: 1)
    let targetID = try InlineAssetID(rawValue: "atomic-target")
    let sentinelID = try InlineAssetID(rawValue: "atomic-sentinel")
    let path = try InlineSVGBridge.parsePath("M0 0 L1 0")
    let targetAsset = try InlineSVGAsset(
      id: targetID, metrics: metrics, coordinateBounds: path.bounds,
      coveragePath: path, coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let sentinel = try InlineSVGAsset(
      id: sentinelID, metrics: metrics, coordinateBounds: path.bounds,
      coveragePath: path, coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let targetAtom = try InlineAtom.vector(
      InlineVectorAtom(id: "atomic-vector", assetID: targetID, metrics: metrics))
    let targetPrepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [targetAtom]))
    let engine = try InlineLayoutEngine()
    let targetLayout = try engine.layout(prepared: targetPrepared, width: 20)
    let targetPlan = try InlineRenderPlan(prepared: targetPrepared, layout: targetLayout)
    // Asset resolution succeeds first, then composition validation fails because
    // the declared mask target is not a document atom. Cache publication must
    // therefore remain behind the complete static-render candidate boundary.
    let invalidComposition = try InlineSVGCompositionPlan(
      preparationRevision: targetPrepared.revision,
      instances: [
        try InlineSVGCompositionInstance(
          instanceID: "atomic-invalid-mask",
          assetID: targetID,
          assetVersion: targetAsset.version,
          role: .mask,
          targetID: "missing-target",
          operation: .reveal,
          declarationOrder: 0
        )
      ]
    )
    let provider = MapGeometryProvider(assets: [targetID: targetAsset])

    func stats(_ cache: InlineAssetCache) -> [Int] {
      [
        cache.count,
        cache.hitCount,
        cache.missCount,
        cache.evictionCount,
        cache.replacementCount,
        cache.removalCount,
      ]
    }

    let swiftCache = try InlineAssetCache(maximumEntries: 1)
    _ = try swiftCache.insert(sentinel)
    let swiftBefore = stats(swiftCache)
    XCTAssertThrowsError(
      try InlineSwiftUIRenderContent(
        plan: targetPlan,
        assets: provider,
        assetCache: swiftCache,
        composition: invalidComposition
      )
    )
    XCTAssertEqual(stats(swiftCache), swiftBefore)
    XCTAssertNotNil(try swiftCache.peek(id: sentinelID, version: sentinel.version))
    XCTAssertNil(try swiftCache.peek(id: targetID, version: targetAsset.version))
    XCTAssertNoThrow(
      try InlineSwiftUIRenderContent(
        plan: targetPlan,
        assets: provider,
        assetCache: swiftCache
      )
    )
    XCTAssertEqual(swiftCache.count, 1)
    XCTAssertEqual(swiftCache.hitCount, 0)
    XCTAssertEqual(swiftCache.missCount, 1)
    XCTAssertEqual(swiftCache.evictionCount, 1)
    XCTAssertEqual(swiftCache.replacementCount, 0)
    XCTAssertNotNil(try swiftCache.peek(id: targetID, version: targetAsset.version))
    XCTAssertNil(try swiftCache.peek(id: sentinelID, version: sentinel.version))

    let canvasCache = try InlineAssetCache(maximumEntries: 1)
    _ = try canvasCache.insert(sentinel)
    let canvasBefore = stats(canvasCache)
    XCTAssertThrowsError(
      try InlineCanvasRenderContent(
        plan: targetPlan,
        assets: provider,
        assetCache: canvasCache,
        composition: invalidComposition
      )
    )
    XCTAssertEqual(stats(canvasCache), canvasBefore)
    XCTAssertNotNil(try canvasCache.peek(id: sentinelID, version: sentinel.version))
    XCTAssertNil(try canvasCache.peek(id: targetID, version: targetAsset.version))
    XCTAssertNoThrow(
      try InlineCanvasRenderContent(
        plan: targetPlan,
        assets: provider,
        assetCache: canvasCache
      )
    )
    XCTAssertEqual(canvasCache.count, 1)
    XCTAssertEqual(canvasCache.hitCount, 0)
    XCTAssertEqual(canvasCache.missCount, 1)
    XCTAssertEqual(canvasCache.evictionCount, 1)
    XCTAssertEqual(canvasCache.replacementCount, 0)
    XCTAssertNotNil(try canvasCache.peek(id: targetID, version: targetAsset.version))
    XCTAssertNil(try canvasCache.peek(id: sentinelID, version: sentinel.version))
  }

  func testAccessibilityLabelIndexesPreservePrecedenceAndVersionParity() throws {
    let assetID = try InlineAssetID(rawValue: "labelled")
    let metrics = try InlineMetrics(advance: 4, ascent: 8, descent: 2)
    let path = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 1, y: 1)),
    ])
    let providerAsset = try InlineSVGAsset(
      id: assetID, metrics: metrics, coordinateBounds: path.bounds,
      coveragePath: path, coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1),
      accessibilityLabel: "provider")
    let vector = try InlineVectorAtom(id: "vector", assetID: assetID, metrics: metrics)
    let document = try InlineDocument(atoms: [.vector(vector)])
    let prepared = try InlinePreparation(shaper: UnusedShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 20)
    let provider = ValidGeometryProvider(asset: providerAsset)
    let registry = try InlineAssetRegistry(records: [
      try InlineAssetRecord(
        id: assetID, version: 1, metrics: metrics,
        accessibilityLabel: "registry")
    ])
    let swiftUI = try swiftUIRenderer(
      prepared: prepared, layout: layout, assets: provider, registry: registry)
    let canvas = try canvasRenderer(
      prepared: prepared, layout: layout, assets: provider, registry: registry)
    let explicit = try InlineVectorAtom(
      id: "explicit", assetID: assetID, metrics: metrics, accessibilityLabel: "explicit")
    let unknownID = try InlineAssetID(rawValue: "unindexed")
    let unknown = try InlineVectorAtom(id: "fallback", assetID: unknownID, metrics: metrics)

    XCTAssertEqual(
      swiftUI.resolvedAccessibilityLabel(vector: explicit, fallback: "fallback"), "explicit")
    XCTAssertEqual(
      canvas.resolvedAccessibilityLabel(vector: explicit, fallback: "fallback"), "explicit")
    XCTAssertEqual(
      swiftUI.resolvedAccessibilityLabel(vector: vector, fallback: "fallback"), "registry")
    XCTAssertEqual(
      canvas.resolvedAccessibilityLabel(vector: vector, fallback: "fallback"), "registry")
    XCTAssertEqual(
      swiftUI.resolvedAccessibilityLabel(vector: unknown, fallback: "fallback"), "fallback")
    XCTAssertEqual(
      canvas.resolvedAccessibilityLabel(vector: unknown, fallback: "fallback"), "fallback")

    let providerOnlySwiftUI = try swiftUIRenderer(
      prepared: prepared, layout: layout, assets: provider)
    let providerOnlyCanvas = try canvasRenderer(
      prepared: prepared, layout: layout, assets: provider)
    XCTAssertEqual(
      providerOnlySwiftUI.resolvedAccessibilityLabel(vector: vector, fallback: "fallback"),
      "provider")
    XCTAssertEqual(
      providerOnlyCanvas.resolvedAccessibilityLabel(vector: vector, fallback: "fallback"),
      "provider")

    let wrongVersionRegistry = try InlineAssetRegistry(records: [
      try InlineAssetRecord(
        id: assetID, version: 2, metrics: metrics, accessibilityLabel: "wrong-version")
    ])
    let noLabelAsset = try InlineSVGAsset(
      id: assetID, metrics: metrics, coordinateBounds: path.bounds,
      coveragePath: path, coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let wrongVersionProvider = ValidGeometryProvider(asset: noLabelAsset)
    let wrongVersionSwiftUI = try swiftUIRenderer(
      prepared: prepared, layout: layout, assets: wrongVersionProvider,
      registry: wrongVersionRegistry)
    let wrongVersionCanvas = try canvasRenderer(
      prepared: prepared, layout: layout, assets: wrongVersionProvider,
      registry: wrongVersionRegistry)
    XCTAssertEqual(
      wrongVersionSwiftUI.resolvedAccessibilityLabel(vector: vector, fallback: "fallback"),
      "fallback")
    XCTAssertEqual(
      wrongVersionCanvas.resolvedAccessibilityLabel(vector: vector, fallback: "fallback"),
      "fallback")

    let representation = InlineAccessibilityRepresentation(
      prepared: prepared,
      registry: registry,
      resolvedAssetLabels: [InlineAssetKey(id: assetID, version: 1): "resolved"]
    )
    XCTAssertEqual(
      representation.resolvedAccessibilityLabel(vector: explicit, fallback: vector.id),
      "explicit")
    XCTAssertEqual(
      representation.resolvedAccessibilityLabel(vector: vector, fallback: vector.id), "registry")

    let resolvedRepresentation = InlineAccessibilityRepresentation(
      prepared: prepared,
      resolvedAssetLabels: [InlineAssetKey(id: assetID, version: 1): "resolved"]
    )
    XCTAssertEqual(
      resolvedRepresentation.resolvedAccessibilityLabel(vector: vector, fallback: vector.id),
      "resolved")
    let mismatchedRepresentation = InlineAccessibilityRepresentation(
      prepared: prepared, registry: wrongVersionRegistry)
    XCTAssertEqual(
      mismatchedRepresentation.resolvedAccessibilityLabel(vector: vector, fallback: vector.id),
      vector.id)
  }

  func testRenderersCompileRevealScheduleBeforeDrawing() throws {
    let assetID = try InlineAssetID(rawValue: "revealed")
    let metrics = try InlineMetrics(advance: 4, ascent: 8, descent: 2)
    let path = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 1, y: 1)),
    ])
    let asset = try InlineSVGAsset(
      id: assetID, metrics: metrics, coordinateBounds: path.bounds,
      coveragePath: path, coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let atom = try InlineAtom.vector(
      InlineVectorAtom(id: "revealed-vector", assetID: assetID, metrics: metrics))
    let prepared = try InlinePreparation(shaper: UnusedShaper()).prepare(
      document: try InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 20)
    let plan = try InlinePathRevealPlanBuilder().plan(asset: asset)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let schedule = try InlineRenderRevealSchedule(
      plan: renderPlan,
      assets: InlineAssetStore(values: [
        InlineAssetKey(id: asset.id, version: asset.version): asset
      ]),
      vectorPlans: ["revealed-vector": plan])

    XCTAssertNoThrow(
      try swiftUIRenderer(
        prepared: prepared,
        layout: layout,
        assets: ValidGeometryProvider(asset: asset),
        schedule: schedule,
        phase: .zero
      )
    )
    XCTAssertNoThrow(
      try canvasRenderer(
        prepared: prepared,
        layout: layout,
        assets: ValidGeometryProvider(asset: asset),
        schedule: schedule,
        phase: .zero
      )
    )
  }

  func testSharedVectorFrameUsesCoordinateBoundsForSplitCoverageAndTrajectory() throws {
    let assetID = try InlineAssetID(rawValue: "split-frame")
    let metrics = try InlineMetrics(advance: 10, ascent: 5, descent: 0)
    let coverage = try InlineSVGBridge.parsePath(
      "M0 0 L10 0 L10 10 L0 10 Z")
    let trajectory = try InlineSVGBridge.parsePath("M5 2 L5 8")
    let asset = try InlineSVGAsset(
      id: assetID,
      metrics: metrics,
      coordinateBounds: try InlineSVGBridge.parsePath("M0 0 L10 0 L10 10 L0 10 Z").bounds,
      coveragePath: coverage,
      coveragePaint: .fill(.evenOdd),
      trajectoryPath: trajectory,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 2)
    )
    let atom = try InlineAtom.vector(
      InlineVectorAtom(id: "split-vector", assetID: assetID, metrics: metrics))
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 100)
    let positioned = try XCTUnwrap(layout.lines.flatMap(\.atoms).first)
    XCTAssertEqual(positioned.width, 10, accuracy: 0.0001)
    XCTAssertEqual(positioned.height, 5, accuracy: 0.0001)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let pathPlan = try InlinePathRevealPlanBuilder(secondsPerUnit: 1).plan(asset: asset)
    let store = InlineAssetStore(values: [
      InlineAssetKey(id: asset.id, version: asset.version): asset
    ])
    let schedule = try InlineRenderRevealSchedule(
      plan: renderPlan,
      assets: store,
      vectorPlans: ["split-vector": pathPlan]
    )
    let content = try InlineAppleRenderContent(
      plan: renderPlan,
      assets: ValidGeometryProvider(asset: asset),
      schedule: schedule
    )

    let zero = content.vectorRenderFrame(
      for: positioned, frame: schedule.sample(at: .zero))
    XCTAssertTrue(zero.trajectory.isEmpty)
    XCTAssertEqual(zero.coverage.cgPath.boundingBox.minX, 2.5, accuracy: 0.0001)
    XCTAssertEqual(zero.coverage.cgPath.boundingBox.minY, 0, accuracy: 0.0001)
    XCTAssertEqual(zero.coverage.cgPath.boundingBox.width, 5, accuracy: 0.0001)
    XCTAssertEqual(zero.coverage.cgPath.boundingBox.height, 5, accuracy: 0.0001)
    XCTAssertEqual(zero.trajectoryStyle.width, 1, accuracy: 0.0001)
    guard case .fill(.evenOdd) = zero.coveragePaint else {
      return XCTFail("split frame must preserve the even-odd coverage paint")
    }

    let partialPhase = try InlineRenderRevealPhase(rawValue: 0.5)
    let partial = content.vectorRenderFrame(
      for: positioned, frame: schedule.sample(at: partialPhase))
    XCTAssertFalse(partial.isComplete)
    XCTAssertFalse(partial.trajectory.isEmpty)
    XCTAssertEqual(partial.coverage.cgPath.boundingBox, zero.coverage.cgPath.boundingBox)
    XCTAssertEqual(partial.trajectory.cgPath.boundingBox.minX, 5, accuracy: 0.0001)
    XCTAssertEqual(partial.trajectory.cgPath.boundingBox.minY, 1, accuracy: 0.0001)
    XCTAssertLessThan(partial.trajectory.cgPath.boundingBox.height, 3.1)

    let complete = content.vectorRenderFrame(
      for: positioned, frame: schedule.sample(at: .complete))
    XCTAssertTrue(complete.isComplete)
    XCTAssertEqual(complete.coverage.cgPath.boundingBox, zero.coverage.cgPath.boundingBox)
    XCTAssertEqual(complete.trajectory.cgPath.boundingBox.minX, 5, accuracy: 0.0001)
    XCTAssertEqual(complete.trajectory.cgPath.boundingBox.minY, 1, accuracy: 0.0001)
    XCTAssertEqual(complete.trajectory.cgPath.boundingBox.width, 0, accuracy: 0.0001)
    XCTAssertEqual(complete.trajectory.cgPath.boundingBox.height, 3, accuracy: 0.0001)
    XCTAssertEqual(complete.trajectoryStyle.width, 1, accuracy: 0.0001)
  }

  func testSwiftUIAndCanvasShareCanonicalGeometryAndHitTesting() throws {
    let text = try InlineAtom.text(
      InlineTextAtom(
        id: "text",
        text: "ffi 你好",
        style: try InlineTextStyle(
          font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
          baselineOffset: 2
        )
      ))
    let assetID = try InlineAssetID(rawValue: "parity-asset")
    let metrics = try InlineMetrics(advance: 6, ascent: 8, descent: 2, baselineOffset: -1)
    let path = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 2, y: 1)),
      .quadratic(
        control: try InlinePathPoint(x: 3, y: 4), to: try InlinePathPoint(x: 4, y: 0)),
      .close,
    ])
    let asset = try InlineSVGAsset(
      id: assetID, metrics: metrics, coordinateBounds: path.bounds,
      coveragePath: path, coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let vector = try InlineAtom.vector(
      InlineVectorAtom(id: "vector", assetID: assetID, metrics: metrics))
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [text, vector]))
    let layout = try InlineLayoutEngine(oversizedVectorPolicy: .scaleToFit(minimumScale: 0.5))
      .layout(prepared: prepared, width: 12)
    let provider = ValidGeometryProvider(asset: asset)
    let pathPlan = try InlinePathRevealPlanBuilder().plan(asset: asset)
    let textPlan = try InlineRevealPlanBuilder().shapedGlyphPlan(prepared: prepared)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let schedule = try InlineRenderRevealSchedule(
      plan: renderPlan,
      assets: InlineAssetStore(values: [
        InlineAssetKey(id: asset.id, version: asset.version): asset
      ]),
      textPlan: textPlan,
      vectorPlans: ["vector": pathPlan]
    )
    let swiftUI = try swiftUIRenderer(
      prepared: prepared,
      layout: layout,
      assets: provider,
      schedule: schedule,
      phase: try InlineRenderRevealPhase(rawValue: 0.5)
    )
    let canvas = try canvasRenderer(
      prepared: prepared,
      layout: layout,
      assets: provider,
      schedule: schedule,
      phase: try InlineRenderRevealPhase(rawValue: 0.5)
    )

    XCTAssertEqual(swiftUI.canonicalGeometryForTesting, canvas.canonicalGeometryForTesting)
    XCTAssertEqual(
      swiftUI.renderedAssetPathsForTesting.keys, canvas.renderedAssetPathsForTesting.keys)
    for positioned in swiftUI.renderedAssetPathsForTesting.keys {
      guard let swiftPath = swiftUI.renderedAssetPathsForTesting[positioned],
        let canvasPath = canvas.renderedAssetPathsForTesting[positioned]
      else {
        return XCTFail("both renderers must prebuild the revealed vector path")
      }
      assertPathsEquivalent(
        try projectPath(swiftPath, translatedBy: .zero),
        try projectPath(canvasPath, translatedBy: .zero)
      )
    }
    XCTAssertEqual(
      swiftUI.renderedTextPathsForTesting.keys, canvas.renderedTextPathsForTesting.keys)
    for positioned in swiftUI.renderedTextPathsForTesting.keys {
      guard let swiftPaths = swiftUI.renderedTextPathsForTesting[positioned],
        let canvasPaths = canvas.renderedTextPathsForTesting[positioned]
      else {
        return XCTFail("both renderers must prebuild the revealed text paths")
      }
      XCTAssertEqual(swiftPaths.count, canvasPaths.count)
      for (swiftPath, canvasPath) in zip(swiftPaths, canvasPaths) {
        assertPathsEquivalent(
          try projectPath(swiftPath, translatedBy: .zero),
          try projectPath(canvasPath, translatedBy: .zero)
        )
      }
    }
    let canonicalIndex = try InlineHitTestIndex.build(prepared: prepared, layout: layout)
    for positioned in layout.lines.flatMap(\.atoms) {
      let point = try InlineHitPoint(
        x: positioned.originX + positioned.width / 2,
        y: positioned.baselineY - positioned.metrics.baselineOffset
          - positioned.metrics.ascent + positioned.height / 2
      )
      XCTAssertEqual(swiftUI.hitTest(point), canonicalIndex.hitTest(point))
      XCTAssertEqual(canvas.hitTest(point), canonicalIndex.hitTest(point))
    }
    let outside = try InlineHitPoint(x: 0, y: layout.height + 10)
    XCTAssertEqual(swiftUI.hitTest(outside), .none)
    XCTAssertEqual(canvas.hitTest(outside), .none)
  }

  func testCanvasConvertsLocalVectorBoundsToViewportExactlyOnce() throws {
    let assetID = try InlineAssetID(rawValue: "origin-once")
    let metrics = try InlineMetrics(advance: 4, ascent: 8, descent: 2)
    let path = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 4, y: 2)),
    ])
    let asset = try InlineSVGAsset(
      id: assetID, metrics: metrics, coordinateBounds: path.bounds,
      coveragePath: path, coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let atom = try InlineAtom.vector(
      InlineVectorAtom(id: "positioned-vector", assetID: assetID, metrics: metrics))
    let prepared = try InlinePreparation(shaper: UnusedShaper()).prepare(
      document: try InlineDocument(atoms: [atom]))

    // Use a non-zero atom origin so a second origin application is observable.
    let positioned = try PositionedInlineAtom(
      atomID: "positioned-vector",
      kind: .vector,
      lineIndex: 0,
      originX: 7.25,
      baselineY: 14,
      width: 4,
      height: 10,
      metrics: metrics
    )
    let line = try InlineLayoutLine(
      index: 0,
      baselineY: 14,
      ascent: 8,
      descent: 2,
      leading: 0,
      width: 11.25,
      start: .zero,
      end: InlineCursor(atomIndex: 1),
      atoms: [positioned]
    )
    let layout = InlineLayoutResult(
      lines: [line],
      width: 11.25,
      height: 16,
      preparationRevision: prepared.revision,
      continuation: nil
    )
    let viewport = try InlineRenderViewport(x: 3.5, y: 2.25, width: 12, height: 16)
    let renderer = InlineCanvasRenderer(
      content: try canvasContent(
        prepared: prepared,
        layout: layout,
        assets: ValidGeometryProvider(asset: asset)
      ),
      viewport: viewport
    )

    let viewportOrigin = inlineCanvasViewportOrigin(for: positioned, viewport: viewport)
    XCTAssertEqual(viewportOrigin.x, 3.75, accuracy: 0.0001)
    XCTAssertEqual(viewportOrigin.y, 3.75, accuracy: 0.0001)

    guard let localPath = renderer.renderedAssetPathsForTesting[positioned] else {
      return XCTFail("the validated vector must have a local paint path")
    }
    let localBounds = localPath.cgPath.boundingBox
    XCTAssertEqual(localBounds.minX, 0, accuracy: 0.0001)
    XCTAssertEqual(localBounds.minY, 4, accuracy: 0.0001)
    XCTAssertEqual(localBounds.width, 4, accuracy: 0.0001)
    XCTAssertEqual(localBounds.height, 2, accuracy: 0.0001)

    // The local path is translated once to document space, then cropped once.
    let documentOriginY = positioned.baselineY - positioned.metrics.baselineOffset
      - positioned.metrics.ascent
    let documentBounds = localBounds.offsetBy(
      dx: CGFloat(positioned.originX), dy: CGFloat(documentOriginY))
    XCTAssertEqual(documentBounds.minX, 7.25, accuracy: 0.0001)
    XCTAssertEqual(documentBounds.minY, 10, accuracy: 0.0001)
    XCTAssertEqual(documentBounds.width, 4, accuracy: 0.0001)
    XCTAssertEqual(documentBounds.height, 2, accuracy: 0.0001)
    let viewportBounds = documentBounds.offsetBy(
      dx: CGFloat(-viewport.x), dy: CGFloat(-viewport.y))
    XCTAssertEqual(viewportBounds.minX, 3.75, accuracy: 0.0001)
    XCTAssertEqual(viewportBounds.minY, 7.75, accuracy: 0.0001)
    XCTAssertEqual(viewportBounds.width, 4, accuracy: 0.0001)
    XCTAssertEqual(viewportBounds.height, 2, accuracy: 0.0001)

    let viewportPoint = try InlineHitPoint(x: 4.5, y: 4.75)
    guard let layoutPoint = viewport.layoutPoint(fromLocal: viewportPoint) else {
      return XCTFail("an interior viewport point must convert to layout space")
    }
    XCTAssertEqual(layoutPoint.x, 8, accuracy: 0.0001)
    XCTAssertEqual(layoutPoint.y, 7, accuracy: 0.0001)
    guard case .vector(let hit) = renderer.hitTest(atViewportPoint: viewportPoint) else {
      return XCTFail("the converted interior point must hit the vector atom")
    }
    XCTAssertEqual(hit.atomID, positioned.atomID)
    XCTAssertEqual(hit.rect.minX, positioned.originX, accuracy: 0.0001)
    XCTAssertEqual(hit.rect.minY, documentOriginY, accuracy: 0.0001)
    XCTAssertEqual(hit.rect.width, positioned.width, accuracy: 0.0001)
    XCTAssertEqual(hit.rect.height, positioned.height, accuracy: 0.0001)

    let snapshot = try renderer.rasterSnapshot(scale: 2)
    XCTAssertEqual(snapshot.size.width, viewport.width, accuracy: 0.0001)
    XCTAssertEqual(snapshot.size.height, viewport.height, accuracy: 0.0001)
    XCTAssertEqual(snapshot.scale, 2, accuracy: 0.0001)
    XCTAssertEqual(snapshot.image.width, Int((viewport.width * 2).rounded(.up)))
    XCTAssertEqual(snapshot.image.height, Int((viewport.height * 2).rounded(.up)))
    XCTAssertThrowsError(try renderer.rasterSnapshot(scale: .nan))

    let swiftRenderer = InlineSwiftUIRenderer(
      content: try swiftUIContent(
        prepared: prepared,
        layout: layout,
        assets: ValidGeometryProvider(asset: asset)
      ),
      viewport: viewport
    )
    let swiftSnapshot = try swiftRenderer.rasterSnapshot(scale: 2)
    XCTAssertEqual(swiftSnapshot.size.width, viewport.width, accuracy: 0.0001)
    XCTAssertEqual(swiftSnapshot.size.height, viewport.height, accuracy: 0.0001)
    XCTAssertEqual(swiftSnapshot.scale, 2, accuracy: 0.0001)
    XCTAssertEqual(swiftSnapshot.image.width, snapshot.image.width)
    XCTAssertEqual(swiftSnapshot.image.height, snapshot.image.height)
    XCTAssertThrowsError(try swiftRenderer.rasterSnapshot(scale: .nan))

    let tinyLimits = try InlineAppleRasterSnapshotLimits(
      maximumDimension: 2, maximumPixels: 4)
    XCTAssertThrowsError(
      try InlineApplePresentationSnapshotter.snapshot(
        content: Color.clear,
        size: CGSize(width: 3, height: 1),
        limits: tinyLimits
      )
    ) { error in
      guard case .resourceLimitExceeded = error as? InlineAppleRasterSnapshotError else {
        return XCTFail("expected pre-allocation resource limit error, got \(error)")
      }
    }
    XCTAssertThrowsError(
      try InlineAppleRasterSnapshotLimits(
        maximumDimension: InlineAppleRasterSnapshotLimits.maximumDimensionCeiling + 1
      )
    )
  }

  func testStaticHorizontalAndVerticalVectorPaintBoundsRemainViewportVisible() throws {
    let horizontalPath = try InlineSVGBridge.parsePath("M0 0 L10 0")
    let verticalPath = try InlineSVGBridge.parsePath("M0 0 L0 10")
    let metricsByKind: [(id: String, asset: InlineSVGAsset)] = [
      (
        "horizontal",
        try InlineSVGAsset(
          id: try InlineAssetID(rawValue: "horizontal-viewport"),
          metrics: try InlineMetrics(advance: 10, ascent: 2, descent: 1),
          coordinateBounds: horizontalPath.bounds,
          coveragePath: horizontalPath,
          coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
          trajectoryPath: horizontalPath,
          trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
        )
      ),
      (
        "vertical",
        try InlineSVGAsset(
          id: try InlineAssetID(rawValue: "vertical-viewport"),
          metrics: try InlineMetrics(advance: 2, ascent: 10, descent: 1),
          coordinateBounds: verticalPath.bounds,
          coveragePath: verticalPath,
          coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
          trajectoryPath: verticalPath,
          trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
        )
      ),
    ]

    for (kind, asset) in metricsByKind {
      let atom = try InlineAtom.vector(
        InlineVectorAtom(id: "\(kind)-vector", assetID: asset.id, metrics: asset.metrics))
      let prepared = try InlinePreparation().prepare(
        document: InlineDocument(atoms: [atom]))
      let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 20)
      let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
      let provider = MapGeometryProvider(assets: [asset.id: asset])
      let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: provider)
      let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: provider)
      let swift = InlineSwiftUIRenderer(
        content: swiftContent,
        viewport: try InlineRenderViewport(
          x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height)))
      let canvas = InlineCanvasRenderer(
        content: canvasContent,
        viewport: try InlineRenderViewport(
          x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height)))
      let positioned = try XCTUnwrap(layout.lines.flatMap(\.atoms).first)
      let whole = try InlineRenderViewport(
        x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
      let crop = try InlineRenderViewport(
        x: positioned.originX + max(0.1, positioned.width * 0.5 - 0.25),
        y: 0,
        width: min(0.5, max(0.5, positioned.width)),
        height: whole.height
      )
      let croppedSwift = InlineSwiftUIRenderer(
        content: swiftContent,
        viewport: crop)
      let croppedCanvas = InlineCanvasRenderer(
        content: canvasContent,
        viewport: crop)

      XCTAssertTrue(swift.visibleAtomIDsForTesting(in: whole).contains(positioned.atomID))
      XCTAssertTrue(canvas.visibleAtomIDsForTesting(in: whole).contains(positioned.atomID))
      XCTAssertTrue(croppedSwift.visibleAtomIDsForTesting(in: crop).contains(positioned.atomID))
      XCTAssertTrue(croppedCanvas.visibleAtomIDsForTesting(in: crop).contains(positioned.atomID))
    }
  }
}
