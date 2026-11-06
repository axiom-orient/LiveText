import Foundation
import LiveTextCore
import LiveTextLayout
import XCTest

@testable import LiveTextCanvas
@testable import LiveTextSwiftUI

private struct RendererPerformanceProvider: InlineAssetGeometryProvider {
  let asset: InlineSVGAsset

  func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
    guard asset.id == assetID, asset.version == version else {
      throw InlineAssetResolutionError.missingAsset(assetID, version: version)
    }
    return asset
  }
}

private struct EmptyRendererPerformanceProvider: InlineAssetGeometryProvider {
  func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
    throw InlineAssetResolutionError.missingAsset(assetID, version: version)
  }
}

private struct RendererTextWorkload {
  let prepared: PreparedInlineDocument
  let layout: InlineLayoutResult
  let fragmentCount: Int
  let glyphCount: Int
}

@MainActor
final class InlinePerformanceHarnessTests: XCTestCase {
  private func rendererTextWorkload(fragmentCount: Int) throws -> RendererTextWorkload {
    let glyphCount = 1_024
    guard fragmentCount > 0, glyphCount.isMultiple(of: fragmentCount) else {
      throw InlineLayoutError.invalidRenderPlan
    }
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 14))
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "text", text: String(repeating: "a", count: glyphCount), style: style))
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [atom]))
    guard case .text(let text) = prepared.atoms[0] else {
      throw InlineLayoutError.invalidRenderPlan
    }
    let fragmentLength = glyphCount / fragmentCount
    let baseline = text.metrics.ascent + text.metrics.baselineOffset
    let positioned = try (0..<fragmentCount).map { index in
      try PositionedInlineAtom(
        atomID: text.atom.id,
        kind: .text,
        lineIndex: 0,
        originX: Double(index * fragmentLength),
        baselineY: baseline,
        width: Double(fragmentLength),
        height: text.metrics.ascent + text.metrics.descent,
        metrics: text.metrics,
        sourceRange: try InlineSourceRange(
          startUTF16: index * fragmentLength,
          endUTF16: (index + 1) * fragmentLength
        )
      )
    }
    let line = try InlineLayoutLine(
      index: 0,
      baselineY: baseline,
      ascent: text.metrics.ascent,
      descent: text.metrics.descent,
      leading: 0,
      width: Double(glyphCount),
      start: .zero,
      end: InlineCursor(atomIndex: 1, graphemeIndex: 0),
      atoms: positioned
    )
    let layout = InlineLayoutResult(
      lines: [line],
      width: Double(glyphCount),
      height: text.metrics.ascent + text.metrics.descent,
      preparationRevision: prepared.revision,
      continuation: nil
    )
    return RendererTextWorkload(
      prepared: prepared,
      layout: layout,
      fragmentCount: fragmentCount,
      glyphCount: glyphCount
    )
  }

  private func durationInSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds)
      + Double(components.attoseconds) / 1_000_000_000_000_000_000
  }

  private func swiftUIInitializationDuration(
    for workload: RendererTextWorkload
  ) throws -> Double {
    let provider = EmptyRendererPerformanceProvider()
    let plan = try InlineRenderPlan(prepared: workload.prepared, layout: workload.layout)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, workload.layout.width), height: max(1, workload.layout.height))
    let clock = ContinuousClock()
    for _ in 0..<2 {
      let content = try InlineSwiftUIRenderContent(plan: plan, assets: provider)
      let renderer = InlineSwiftUIRenderer(content: content, viewport: viewport)
      XCTAssertEqual(renderer.renderedTextPathsForTesting.count, workload.fragmentCount)
      XCTAssertEqual(
        renderer.renderedTextPathsForTesting.values.reduce(0) { $0 + $1.count },
        workload.glyphCount
      )
    }
    var samples: [Double] = []
    samples.reserveCapacity(5)
    for _ in 0..<5 {
      let start = clock.now
      let content = try InlineSwiftUIRenderContent(plan: plan, assets: provider)
      let renderer = InlineSwiftUIRenderer(content: content, viewport: viewport)
      let elapsed = start.duration(to: clock.now)
      XCTAssertEqual(renderer.renderedTextPathsForTesting.count, workload.fragmentCount)
      XCTAssertEqual(
        renderer.renderedTextPathsForTesting.values.reduce(0) { $0 + $1.count },
        workload.glyphCount
      )
      samples.append(durationInSeconds(elapsed))
    }
    return samples.sorted()[samples.count / 2]
  }

  private func canvasInitializationDuration(
    for workload: RendererTextWorkload
  ) throws -> Double {
    let provider = EmptyRendererPerformanceProvider()
    let plan = try InlineRenderPlan(prepared: workload.prepared, layout: workload.layout)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, workload.layout.width), height: max(1, workload.layout.height))
    let clock = ContinuousClock()
    for _ in 0..<2 {
      let content = try InlineCanvasRenderContent(plan: plan, assets: provider)
      let renderer = InlineCanvasRenderer(content: content, viewport: viewport)
      XCTAssertEqual(renderer.renderedTextPathsForTesting.count, workload.fragmentCount)
      XCTAssertEqual(
        renderer.renderedTextPathsForTesting.values.reduce(0) { $0 + $1.count },
        workload.glyphCount
      )
    }
    var samples: [Double] = []
    samples.reserveCapacity(5)
    for _ in 0..<5 {
      let start = clock.now
      let content = try InlineCanvasRenderContent(plan: plan, assets: provider)
      let renderer = InlineCanvasRenderer(content: content, viewport: viewport)
      let elapsed = start.duration(to: clock.now)
      XCTAssertEqual(renderer.renderedTextPathsForTesting.count, workload.fragmentCount)
      XCTAssertEqual(
        renderer.renderedTextPathsForTesting.values.reduce(0) { $0 + $1.count },
        workload.glyphCount
      )
      samples.append(durationInSeconds(elapsed))
    }
    return samples.sorted()[samples.count / 2]
  }

  func testReleaseWorkloadPerformance() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 14))
    let text = try InlineAtom.text(
      InlineTextAtom(
        id: "text",
        text: String(repeating: "alpha beta gamma ", count: 80),
        style: style
      ))
    let vectorPath = try InlineSVGBridge.parsePath("M0 0 C2 4 6 4 8 0 L8 8")
    let vectorAsset = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "performance-vector"),
      metrics: try InlineMetrics(advance: 8, ascent: 8, descent: 0),
      coordinateBounds: vectorPath.bounds,
      coveragePath: vectorPath,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: vectorPath,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let vector = try InlineAtom.vector(
      InlineVectorAtom(id: "vector", asset: vectorAsset))
    let text2 = try InlineAtom.text(
      InlineTextAtom(
        id: "text-2",
        text: String(repeating: "alpha beta gamma ", count: 80),
        style: style
      ))
    let document = try InlineDocument(atoms: [text, vector, text2])
    let engine = try InlineLayoutEngine()
    let pathPlan = try InlinePathRevealPlanBuilder().plan(asset: vectorAsset)
    let cache = try InlineAssetCache(maximumEntries: 16)
    let prepared = try InlinePreparation().prepare(document: document)
    let layout = try engine.layout(prepared: prepared, width: 320)
    let provider = RendererPerformanceProvider(asset: vectorAsset)
    let registry = try InlineAssetRegistry(records: [try InlineAssetRecord(asset: vectorAsset)])
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let schedule = try InlineRenderRevealSchedule(
      plan: renderPlan,
      assets: InlineAssetStore(values: [
        InlineAssetKey(id: vectorAsset.id, version: vectorAsset.version): vectorAsset
      ]),
      vectorPlans: ["vector": pathPlan])
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))

    let options = XCTMeasureOptions()
    options.iterationCount = 5
    measure(options: options) {
      MainActor.assumeIsolated {
        guard let swiftContent = try? InlineSwiftUIRenderContent(
          plan: renderPlan, assets: provider, registry: registry, schedule: schedule),
          let canvasContent = try? InlineCanvasRenderContent(
            plan: renderPlan, assets: provider, registry: registry, schedule: schedule)
        else {
          XCTFail("renderer content initialization failed")
          return
        }
        let swiftUI = InlineSwiftUIRenderer(
          content: swiftContent, phase: try! InlineRenderRevealPhase(rawValue: 0.5), viewport: viewport)
        let canvas = InlineCanvasRenderer(
          content: canvasContent, phase: try! InlineRenderRevealPhase(rawValue: 0.5), viewport: viewport)
        XCTAssertFalse(swiftUI.renderedTextPathsForTesting.isEmpty)
        XCTAssertFalse(canvas.renderedTextPathsForTesting.isEmpty)
      }
      _ = schedule.sample(at: try! InlineRenderRevealPhase(rawValue: 0.5))
      _ = try? cache.insert(vectorAsset)
    }
  }

  func testSwiftUIRendererInitializationDoesNotScaleQuadraticallyWithFragments() throws {
    let small = try rendererTextWorkload(fragmentCount: 8)
    let large = try rendererTextWorkload(fragmentCount: 256)
    let smallSeconds = try swiftUIInitializationDuration(for: small)
    let largeSeconds = try swiftUIInitializationDuration(for: large)
    let ratio = largeSeconds / max(smallSeconds, Double.leastNonzeroMagnitude)
    XCTAssertLessThan(
      ratio, 12,
      "SwiftUI renderer initialization ratio \(ratio) exceeded the linear-work ceiling"
    )
  }

  func testCanvasRendererInitializationDoesNotScaleQuadraticallyWithFragments() throws {
    let small = try rendererTextWorkload(fragmentCount: 8)
    let large = try rendererTextWorkload(fragmentCount: 256)
    let smallSeconds = try canvasInitializationDuration(for: small)
    let largeSeconds = try canvasInitializationDuration(for: large)
    let ratio = largeSeconds / max(smallSeconds, Double.leastNonzeroMagnitude)
    XCTAssertLessThan(
      ratio, 12,
      "Canvas renderer initialization ratio \(ratio) exceeded the linear-work ceiling"
    )
  }
}
