import ChalkLineEffects
import CoreGraphics
import LiveTextCore
@testable import LiveTextCanvas
import LiveTextLayout
@testable import LiveTextWritingUI
@testable import LiveTextSwiftUI
import LiveTextEffects
import SwiftUI
import XCTest

@MainActor
final class ColoredPencilTests: XCTestCase {
  func testConfigurationValidatesAndRoundTrips() throws {
    let configuration = try ColoredPencilConfiguration(
      seed: 17,
      jitterAmount: 0.3,
      fiberAmount: 0.2,
      paperTooth: 0.4,
      taperAmount: 0.8,
      fiberDensity: 0.7
    )
    let encoded = try JSONEncoder().encode(configuration)
    XCTAssertEqual(
      try JSONDecoder().decode(ColoredPencilConfiguration.self, from: encoded),
      configuration
    )
    XCTAssertThrowsError(try ColoredPencilConfiguration(jitterAmount: -0.01)) { error in
      XCTAssertEqual(
        error as? ColoredPencilError,
        .invalidConfiguration(field: "jitterAmount", value: -0.01)
      )
    }
    XCTAssertThrowsError(
      try ColoredPencilConfiguration(fiberDensity: ColoredPencilConfiguration.maximumFiberDensity + 1)
    )
  }

  func testPlanIsDeterministicAndPlansOpenTaperButNotClosedContours() throws {
    let openAsset = try makeAsset(
      commands: [
        .move(try InlinePathPoint(x: 0, y: 0)),
        .line(try InlinePathPoint(x: 100, y: 0)),
        .line(try InlinePathPoint(x: 200, y: 0)),
      ]
    )
    let destination = try ColoredPencilRect(width: 200, height: 1)
    let configuration = try ColoredPencilConfiguration(seed: 99)
    let first = ColoredPencilPathPlan(
      asset: openAsset, destination: destination, configuration: configuration)
    let second = ColoredPencilPathPlan(
      asset: openAsset, destination: destination, configuration: configuration)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.sampleCount, first.strokes.reduce(0) { $0 + $1.points.count })
    XCTAssertLessThanOrEqual(first.fiberCount, ColoredPencilPathPlan.maximumFibers)

    let open = try XCTUnwrap(first.strokes.first)
    XCTAssertTrue(open.isOpen)
    XCTAssertTrue(open.hasTaper)
    XCTAssertEqual(open.bodyWidth, 1, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(open.points.first).width, 1, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(open.points.last).width, open.tipWidth, accuracy: 0.000_001)
    XCTAssertLessThan(open.tipWidth, open.bodyWidth)
    XCTAssertTrue(
      open.points.dropFirst().dropLast().contains { abs($0.y - 0.5) > 0.000_001 },
      "a straight open stroke must retain deterministic interior pencil jitter"
    )

    let closedAsset = try makeAsset(
      commands: [
        .move(try InlinePathPoint(x: 0, y: 0)),
        .line(try InlinePathPoint(x: 100, y: 0)),
        .line(try InlinePathPoint(x: 100, y: 100)),
        .line(try InlinePathPoint(x: 0, y: 100)),
        .close,
      ]
    )
    let closed = try XCTUnwrap(
      ColoredPencilPathPlan(
        asset: closedAsset,
        destination: try ColoredPencilRect(width: 100, height: 100),
        configuration: configuration
      ).strokes.first
    )
    XCTAssertTrue(closed.isClosed)
    XCTAssertFalse(closed.hasTaper)
    XCTAssertEqual(closed.tipWidth, closed.bodyWidth, accuracy: 0.000_001)
    XCTAssertTrue(closed.points.allSatisfy { abs($0.width - 1) < 0.000_001 })
  }

  func testRevealPlanUsesCommandOrderWithoutCrossSubpathBleed() throws {
    let asset = try makeAsset(
      commands: [
        .move(try InlinePathPoint(x: 0, y: 0)),
        .line(try InlinePathPoint(x: 100, y: 0)),
        .move(try InlinePathPoint(x: 0, y: 20)),
        .line(try InlinePathPoint(x: 100, y: 20)),
      ]
    )
    let plan = ColoredPencilPathPlan(
      asset: asset,
      destination: try ColoredPencilRect(width: 100, height: 20)
    )
    let assetID = asset.id
    let activation = try InlineRenderRevealVectorActivation(
      atomID: "vector",
      assetID: assetID,
      assetVersion: asset.version,
      units: [
        try InlineRenderRevealVectorUnit(commandIndex: 1, startTime: 0, duration: 1),
        try InlineRenderRevealVectorUnit(commandIndex: 3, startTime: 1, duration: 1),
      ]
    )
    XCTAssertEqual(plan.visibleDistance(for: plan.strokes[0], activation: activation, time: 0.5), 50, accuracy: 0.001)
    XCTAssertEqual(plan.visibleDistance(for: plan.strokes[1], activation: activation, time: 0.5), 0, accuracy: 0.001)
    XCTAssertEqual(plan.visibleDistance(for: plan.strokes[0], activation: activation, time: 1.5), plan.strokes[0].length, accuracy: 0.001)
    XCTAssertGreaterThan(plan.visibleDistance(for: plan.strokes[1], activation: activation, time: 1.5), 0)
  }

  func testClosedGlyphHatchesAreBoundedOffsetAndRevealWithTimeline() throws {
    let asset = try makeAsset(
      commands: [
        .move(try InlinePathPoint(x: 0, y: 0)),
        .line(try InlinePathPoint(x: 100, y: 0)),
        .line(try InlinePathPoint(x: 100, y: 100)),
        .line(try InlinePathPoint(x: 0, y: 100)),
        .close,
      ]
    )
    let destination = try ColoredPencilRect(x: 10, y: 20, width: 100, height: 100)
    let plan = ColoredPencilPathPlan(
      asset: asset,
      destination: destination,
      configuration: .textured
    )
    XCTAssertFalse(plan.hatches.isEmpty)
    XCTAssertLessThanOrEqual(plan.hatches.count, ColoredPencilPathPlan.maximumHatches)
    XCTAssertTrue(plan.hatches.allSatisfy {
      $0.start.y >= destination.y - 1 && $0.end.y >= destination.y
    })
    let hatch = try XCTUnwrap(plan.hatches.first)
    XCTAssertEqual(hatch.points.count, 7)
    XCTAssertEqual(hatch.points[0].width, hatch.points[4].width, accuracy: 0.000_001)
    XCTAssertEqual(
      (hatch.points[4].y - hatch.start.y) / (hatch.end.y - hatch.start.y),
      0.72,
      accuracy: 0.000_001
    )
    XCTAssertLessThan(hatch.points[5].width, hatch.points[4].width)
    XCTAssertLessThan(hatch.points[6].width, hatch.points[5].width)
    XCTAssertEqual(hatch.end.width, hatch.points[6].width, accuracy: 0.000_001)

    let activation = try InlineRenderRevealVectorActivation(
      atomID: "glyph",
      assetID: asset.id,
      assetVersion: asset.version,
      units: [
        try InlineRenderRevealVectorUnit(commandIndex: 1, startTime: 0, duration: 1),
        try InlineRenderRevealVectorUnit(commandIndex: 2, startTime: 1, duration: 1),
        try InlineRenderRevealVectorUnit(commandIndex: 3, startTime: 2, duration: 1),
        try InlineRenderRevealVectorUnit(commandIndex: 4, startTime: 3, duration: 1),
      ]
    )
    XCTAssertEqual(plan.visibleHatchCount(activation: activation, time: 0), 0)
    XCTAssertGreaterThan(plan.visibleHatchCount(activation: activation, time: 2), 0)
    XCTAssertLessThan(
      plan.visibleHatchCount(activation: activation, time: 2),
      plan.hatches.count
    )
    XCTAssertEqual(
      plan.visibleHatchCount(activation: activation, time: activation.duration),
      plan.hatches.count
    )
  }

  func testDocumentHatchBudgetSamplesOversizedInputWithoutGoingBlank() {
    let budget = 16_384
    let allocations = ColoredPencilFillPlan.boundedHatchAllocations(
      requestedCounts: Array(repeating: 12, count: budget + 1),
      maximumHatches: budget
    )

    XCTAssertEqual(allocations.count, budget + 1)
    XCTAssertEqual(allocations.reduce(0, +), budget)
    XCTAssertEqual(allocations.filter { $0 > 0 }.count, budget)
    XCTAssertTrue(allocations.prefix(budget / 4).contains(1))
    XCTAssertTrue(allocations.suffix(budget / 4).contains(1))
    XCTAssertEqual(
      ColoredPencilFillPlan.boundedHatchAllocations(
        requestedCounts: [20, 20, 20], maximumHatches: 6),
      [2, 2, 2]
    )
  }

  func testColoredPencilRenderBackFillsClosedInteriorAndAdaptersStayClose() throws {
    let id = try InlineAssetID(rawValue: "colored-pencil-render-back")
    let metrics = try InlineMetrics(advance: 100, ascent: 100, descent: 0)
    let assetPath = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 100, y: 0)),
      .line(try InlinePathPoint(x: 100, y: 100)),
      .line(try InlinePathPoint(x: 0, y: 100)),
      .close,
      .move(try InlinePathPoint(x: 30, y: 30)),
      .line(try InlinePathPoint(x: 70, y: 30)),
      .line(try InlinePathPoint(x: 70, y: 70)),
      .line(try InlinePathPoint(x: 30, y: 70)),
      .close,
    ])
    let asset = try InlineSVGAsset(
      id: id,
      metrics: metrics,
      coordinateBounds: assetPath.bounds,
      coveragePath: assetPath,
      coveragePaint: .fill(.evenOdd),
      trajectoryPath: assetPath,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let atom = try InlineAtom.vector(
      InlineVectorAtom(id: "render-back", assetID: id, metrics: metrics)
    )
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 100)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let pathPlan = try InlinePathRevealPlanBuilder(secondsPerUnit: 0.1).plan(asset: asset)
    let schedule = try InlineRenderRevealSchedule(
      plan: renderPlan,
      assets: InlineAssetStore(values: [
        InlineAssetKey(id: asset.id, version: asset.version): asset
      ]),
      vectorPlans: ["render-back": pathPlan]
    )
    let provider = TestProvider(asset: asset)
    let swiftContent = try InlineSwiftUIRenderContent(
      plan: renderPlan, assets: provider, schedule: schedule)
    let canvasContent = try InlineCanvasRenderContent(
      plan: renderPlan, assets: provider, schedule: schedule)
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 100, height: 100)
    let zero = try InlineRenderRevealPhase(rawValue: 0)
    let middle = try InlineRenderRevealPhase(rawValue: 0.5)

    let plain = try alphaPixelCount(
      InlineSwiftUIRenderer(content: swiftContent, viewport: viewport),
      size: CGSize(width: 100, height: 100)
    )
    let swiftZero = try alphaPixelCount(
      InlineSwiftUIRenderer(
        content: swiftContent, phase: zero, viewport: viewport,
        material: .coloredPencil(.textured)),
      size: CGSize(width: 100, height: 100)
    )
    let swiftMiddle = try alphaPixelCount(
      InlineSwiftUIRenderer(
        content: swiftContent, phase: middle, viewport: viewport,
        material: .coloredPencil(.textured)),
      size: CGSize(width: 100, height: 100)
    )
    let swiftComplete = try alphaPixelCount(
      InlineSwiftUIRenderer(
        content: swiftContent, viewport: viewport, material: .coloredPencil(.textured)),
      size: CGSize(width: 100, height: 100)
    )
    let canvasComplete = try alphaPixelCount(
      InlineCanvasRenderer(
        content: canvasContent, viewport: viewport, material: .coloredPencil(.textured)),
      size: CGSize(width: 100, height: 100)
    )
    let swiftHoleAlpha = try alphaPixel(
      InlineSwiftUIRenderer(
        content: swiftContent, viewport: viewport, material: .coloredPencil(.textured)),
      size: CGSize(width: 100, height: 100), x: 50, y: 50
    )
    let canvasHoleAlpha = try alphaPixel(
      InlineCanvasRenderer(
        content: canvasContent, viewport: viewport, material: .coloredPencil(.textured)),
      size: CGSize(width: 100, height: 100), x: 50, y: 50
    )

    print(
      "[colored-pencil-pixels] plain=\(plain) zero=\(swiftZero) "
        + "middle=\(swiftMiddle) swift_complete=\(swiftComplete) "
        + "canvas_complete=\(canvasComplete)"
    )

    XCTAssertEqual(swiftZero, 0)
    XCTAssertGreaterThan(swiftMiddle, swiftZero)
    XCTAssertGreaterThan(swiftComplete, swiftMiddle)
    XCTAssertLessThan(swiftComplete, plain, "pencil texture must retain uncovered interior pixels")
    XCTAssertGreaterThan(
      Double(swiftComplete), Double(plain) * 0.9,
      "pencil coverage must densely fill the closed interior"
    )
    XCTAssertEqual(swiftHoleAlpha, 0, "SwiftUI pencil must preserve the even-odd hole center")
    XCTAssertEqual(canvasHoleAlpha, 0, "Canvas pencil must preserve the even-odd hole center")
    XCTAssertLessThan(swiftComplete, 9_200, "even-odd glyph counters must remain unpainted")
    XCTAssertLessThanOrEqual(abs(swiftComplete - canvasComplete), max(24, swiftComplete / 20))
  }

  func testColoredPencilChangesOrdinaryTextAndAdaptersStayClose() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica-Bold", pointSize: 72)
    )
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "pencil-text", text: "TEXT", style: style)
    )
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 240)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let provider = EmptyProvider()
    let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: provider)
    let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: provider)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height)
    )
    let size = CGSize(width: viewport.width, height: viewport.height)

    let plain = try alphaPixelCount(
      InlineSwiftUIRenderer(content: swiftContent, viewport: viewport), size: size)
    let swiftPencil = try alphaPixelCount(
      InlineSwiftUIRenderer(
        content: swiftContent, viewport: viewport, material: .coloredPencil(.textured)),
      size: size
    )
    let canvasPencil = try alphaPixelCount(
      InlineCanvasRenderer(
        content: canvasContent, viewport: viewport, material: .coloredPencil(.textured)),
      size: size
    )

    XCTAssertGreaterThan(plain, 0)
    XCTAssertNotEqual(swiftPencil, plain, "text-only content must visibly consume pencil material")
    XCTAssertLessThanOrEqual(abs(swiftPencil - canvasPencil), max(24, swiftPencil / 20))
  }

  func testTextPencilPlansAreReusedAcrossRevealFramesAndGloballyBounded() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 48)
    )
    let atom = try InlineAtom.text(
      InlineTextAtom(
        id: "long-pencil-text",
        text: String(repeating: "ordinary colored pencil text ", count: 120),
        style: style
      )
    )
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 240)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: EmptyProvider())
    let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: EmptyProvider())
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 240, height: 160)
    let phases = try [0.1, 0.5, 0.9].map(InlineRenderRevealPhase.init(rawValue:))

    let swiftRenderers = phases.map {
      InlineSwiftUIRenderer(
        content: swiftContent, phase: $0, viewport: viewport,
        material: .coloredPencil(.textured))
    }
    let canvasRenderers = phases.map {
      InlineCanvasRenderer(
        content: canvasContent, phase: $0, viewport: viewport,
        material: .coloredPencil(.textured))
    }

    XCTAssertEqual(swiftRenderers.map(\.coloredPencilPlanBuildCountForTesting), [1, 1, 1])
    XCTAssertEqual(canvasRenderers.map(\.coloredPencilPlanBuildCountForTesting), [1, 1, 1])
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(swiftRenderers.last).coloredPencilTextHatchCountForTesting,
      16_384
    )
    XCTAssertEqual(
      try XCTUnwrap(swiftRenderers.last).coloredPencilTextHatchCountForTesting,
      try XCTUnwrap(canvasRenderers.last).coloredPencilTextHatchCountForTesting
    )
  }

  func testTextPencilAllocationIsViewportOrderIndependentAndAdapterNeutral() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 44)
    )
    let atom = try InlineAtom.text(
      InlineTextAtom(
        id: "viewport-pencil-text",
        text: String(repeating: "tapered ordinary pencil text ", count: 90),
        style: style
      )
    )
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 220)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let top = try InlineRenderViewport(x: 0, y: 0, width: 220, height: 150)
    let bottom = try InlineRenderViewport(
      x: 0, y: max(0, layout.height - 150), width: 220, height: 150)

    let sequentialContent = try InlineSwiftUIRenderContent(plan: plan, assets: EmptyProvider())
    _ = InlineSwiftUIRenderer(
      content: sequentialContent, viewport: top, material: .coloredPencil(.textured))
    let bottomAfterTop = InlineSwiftUIRenderer(
      content: sequentialContent, viewport: bottom, material: .coloredPencil(.textured))

    let bottomOnlyContent = try InlineSwiftUIRenderContent(plan: plan, assets: EmptyProvider())
    let bottomOnly = InlineSwiftUIRenderer(
      content: bottomOnlyContent, viewport: bottom, material: .coloredPencil(.textured))
    let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: EmptyProvider())
    let canvasBottom = InlineCanvasRenderer(
      content: canvasContent, viewport: bottom, material: .coloredPencil(.textured))

    XCTAssertFalse(bottomOnly.coloredPencilVisibleTextHatchCountsForTesting.isEmpty)
    XCTAssertTrue(
      bottomOnly.coloredPencilVisibleTextHatchCountsForTesting.values.allSatisfy { $0 > 0 },
      "a long document's later ordinary text must retain pencil material"
    )
    XCTAssertEqual(
      bottomAfterTop.coloredPencilVisibleTextHatchCountsForTesting,
      bottomOnly.coloredPencilVisibleTextHatchCountsForTesting
    )
    XCTAssertEqual(
      bottomOnly.coloredPencilVisibleTextHatchCountsForTesting,
      canvasBottom.coloredPencilVisibleTextHatchCountsForTesting
    )
  }

  func testTextPencilConfigurationCachesAreBounded() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 42)
    )
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "cache-pencil-text", text: "ordinary pencil", style: style)
    )
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 320)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height)
    )
    let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: EmptyProvider())
    let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: EmptyProvider())

    let swiftRenderers = [ColoredPencilConfiguration.default, .soft, .textured].map {
      InlineSwiftUIRenderer(
        content: swiftContent, viewport: viewport, material: .coloredPencil($0))
    }
    let canvasRenderers = [ColoredPencilConfiguration.default, .soft, .textured].map {
      InlineCanvasRenderer(
        content: canvasContent, viewport: viewport, material: .coloredPencil($0))
    }

    XCTAssertEqual(
      try XCTUnwrap(swiftRenderers.last).coloredPencilCachedConfigurationCountForTesting, 2)
    XCTAssertEqual(
      try XCTUnwrap(canvasRenderers.last).coloredPencilCachedConfigurationCountForTesting, 2)
  }

  func testChalkFacadeUsesConfiguredColorInBothAdapters() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica-Bold", pointSize: 64)
    )
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "chalk-color", text: "A", style: style)
    )
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 96)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let provider = EmptyProvider()
    let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: provider)
    let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: provider)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height)
    )
    let size = CGSize(width: viewport.width, height: viewport.height)
    let red = try ChalkColor(red: 1, green: 0, blue: 0)
    let configuration = InlineWritingConfiguration(effect: .chalk(.default), color: red)

    let swiftChannels = try visibleChannelTotals(
      LiveTextWritingRenderer(
        content: swiftContent, viewport: viewport, configuration: configuration),
      size: size
    )
    let canvasChannels = try visibleChannelTotals(
      LiveTextCanvasWritingRenderer(
        content: canvasContent, viewport: viewport, configuration: configuration),
      size: size
    )
    XCTAssertGreaterThan(swiftChannels.red, swiftChannels.green * 2)
    XCTAssertGreaterThan(canvasChannels.red, canvasChannels.green * 2)
  }

  func testMaximumSizeCurveGeometryStaysWithinTheGlobalSampleLimit() throws {
    var commands: [InlinePathCommand] = [
      .move(try InlinePathPoint(x: 0, y: 0))
    ]
    commands.reserveCapacity(8_193)
    for index in 1...8_192 {
      let x = Double(index)
      commands.append(
        .quadratic(
          control: try InlinePathPoint(x: x - 0.5, y: index.isMultiple(of: 2) ? 1 : -1),
          to: try InlinePathPoint(x: x, y: 0)
        )
      )
    }

    let asset = try makeAsset(commands: commands)
    let plan = ColoredPencilPathPlan(
      asset: asset,
      destination: try ColoredPencilRect(width: 8_192, height: 2)
    )
    XCTAssertLessThanOrEqual(plan.sampleCount, ColoredPencilPathPlan.maximumSamples)
    XCTAssertFalse(plan.strokes.isEmpty)
  }

  func testExtremeFiniteCoordinatesAndDestinationDoNotTrapOrOverflowFiberCount() throws {
    let source = try makeAsset(
      commands: [
        .move(try InlinePathPoint(x: -Double.greatestFiniteMagnitude, y: 0)),
        .line(try InlinePathPoint(x: Double.greatestFiniteMagnitude, y: 0)),
      ]
    )
    let sourcePlan = ColoredPencilPathPlan(
      asset: source,
      destination: try ColoredPencilRect(width: 100, height: 1)
    )
    XCTAssertFalse(sourcePlan.strokes.isEmpty)
    XCTAssertTrue(sourcePlan.strokes.flatMap(\.points).allSatisfy {
      $0.x.isFinite && $0.y.isFinite && $0.width.isFinite
    })

    let ordinary = try makeAsset(
      commands: [
        .move(try InlinePathPoint(x: 0, y: 0)),
        .line(try InlinePathPoint(x: 1, y: 0)),
      ]
    )
    let destinationPlan = ColoredPencilPathPlan(
      asset: ordinary,
      destination: try ColoredPencilRect(width: Double.greatestFiniteMagnitude, height: 1),
      configuration: try ColoredPencilConfiguration(
        fiberAmount: 1,
        fiberDensity: ColoredPencilConfiguration.maximumFiberDensity
      )
    )
    XCTAssertLessThanOrEqual(destinationPlan.fiberCount, 24)
    XCTAssertLessThanOrEqual(destinationPlan.fiberCount, ColoredPencilPathPlan.maximumFibers)
    XCTAssertTrue(destinationPlan.strokes.flatMap(\.points).allSatisfy {
      $0.x.isFinite && $0.y.isFinite && $0.width.isFinite
    })

    let twoLongSubpaths = try makeAsset(
      commands: [
        .move(try InlinePathPoint(x: 0, y: 0)),
        .line(try InlinePathPoint(x: 1, y: 0)),
        .move(try InlinePathPoint(x: 0, y: 1)),
        .line(try InlinePathPoint(x: 1, y: 1)),
      ]
    )
    let aggregatePlan = ColoredPencilPathPlan(
      asset: twoLongSubpaths,
      destination: try ColoredPencilRect(
        width: Double.greatestFiniteMagnitude,
        height: 1
      )
    )
    XCTAssertTrue(aggregatePlan.totalLength.isFinite)
    XCTAssertEqual(aggregatePlan.totalLength, Double.greatestFiniteMagnitude)

    let longRoundTrip = try makeAsset(
      commands: [
        .move(try InlinePathPoint(x: 0, y: 0)),
        .line(try InlinePathPoint(x: 1, y: 0)),
        .line(try InlinePathPoint(x: 0, y: 0)),
      ]
    )
    let roundTripPlan = ColoredPencilPathPlan(
      asset: longRoundTrip,
      destination: try ColoredPencilRect(
        width: Double.greatestFiniteMagnitude,
        height: 1
      )
    )
    let roundTripStroke = try XCTUnwrap(roundTripPlan.strokes.first)
    XCTAssertTrue(roundTripStroke.length.isFinite)
    XCTAssertTrue(roundTripStroke.cumulativeLengths.allSatisfy(\.isFinite))
    XCTAssertFalse(roundTripStroke.points.isEmpty)
  }

  func testPolylineInitializerPreservesItsCoordinateOrigin() throws {
    let source = [
      try ColoredPencilPoint(x: 10, y: 20),
      try ColoredPencilPoint(x: 20, y: 20),
    ]
    let plan = try ColoredPencilPathPlan(points: source)
    let stroke = try XCTUnwrap(plan.strokes.first)

    XCTAssertEqual(try XCTUnwrap(stroke.points.first).x, 10, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(stroke.points.first).y, 20, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(stroke.points.last).x, 20, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(stroke.points.last).y, 20, accuracy: 0.000_001)
  }

  func testFiberBudgetIsGlobalAcrossSubpaths() throws {
    var commands: [InlinePathCommand] = []
    commands.reserveCapacity(400)
    for index in 0..<200 {
      let y = Double(index)
      commands.append(.move(try InlinePathPoint(x: 0, y: y)))
      commands.append(.line(try InlinePathPoint(x: 100, y: y)))
    }
    let plan = try ColoredPencilPathPlan(
      asset: makeAsset(commands: commands),
      destination: try ColoredPencilRect(width: 100, height: 200),
      configuration: try ColoredPencilConfiguration(
        fiberAmount: 1,
        fiberDensity: ColoredPencilConfiguration.maximumFiberDensity
      )
    )

    XCTAssertEqual(plan.fiberCount, ColoredPencilPathPlan.maximumFibers)
    XCTAssertEqual(plan.fiberCount, plan.strokes.reduce(0) { $0 + $1.fibers.count })
  }

  func testColoredPencilDefaultsToCurrentColorAndBothFacadesKeepHitTesting() throws {
    XCTAssertNil(InlineWritingConfiguration.coloredPencil.color)
    guard case .coloredPencil(let configuration) = InlineWritingConfiguration.coloredPencil.effect else {
      return XCTFail("colored-pencil preset must carry its effect payload")
    }
    XCTAssertEqual(configuration, .default)

    let asset = try makeAsset(
      commands: [
        .move(try InlinePathPoint(x: 0, y: 0)),
        .line(try InlinePathPoint(x: 20, y: 20)),
      ]
    )
    let atomID = asset.id
    let atom = try InlineAtom.vector(
      InlineVectorAtom(
        id: "pencil-vector",
        assetID: atomID,
        metrics: asset.metrics
      )
    )
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 40)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let provider = TestProvider(asset: asset)
    let swiftContent = try InlineSwiftUIRenderContent(plan: renderPlan, assets: provider)
    let canvasContent = try InlineCanvasRenderContent(plan: renderPlan, assets: provider)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))

    let swiftBase = InlineSwiftUIRenderer(content: swiftContent, viewport: viewport)
    let canvasBase = InlineCanvasRenderer(content: canvasContent, viewport: viewport)
    let swiftWriting = LiveTextWritingRenderer(
      content: swiftContent, viewport: viewport, configuration: .coloredPencil)
    let canvasWriting = LiveTextCanvasWritingRenderer(
      content: canvasContent, viewport: viewport, configuration: .coloredPencil)
    let points = [try InlineHitPoint(x: 0, y: 0), try InlineHitPoint(x: 100, y: 100)]
    for point in points {
      XCTAssertEqual(swiftWriting.hitTest(point), swiftBase.hitTest(point))
      XCTAssertEqual(canvasWriting.hitTest(point), canvasBase.hitTest(point))
    }
  }

  func testRendererConsumesSharedPencilPlanAndRevealsVectorAtZeroMidAndComplete() throws {
    let asset = try makeAsset(
      commands: [
        .move(try InlinePathPoint(x: 0, y: 0)),
        .line(try InlinePathPoint(x: 20, y: 20)),
        .line(try InlinePathPoint(x: 40, y: 0)),
      ]
    )
    let atom = try InlineAtom.vector(
      InlineVectorAtom(id: "pencil-reveal-vector", assetID: asset.id, metrics: asset.metrics)
    )
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 50)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let pathPlan = try InlinePathRevealPlanBuilder(secondsPerUnit: 0.01).plan(asset: asset)
    let schedule = try InlineRenderRevealSchedule(
      plan: renderPlan,
      assets: InlineAssetStore(values: [
        InlineAssetKey(id: asset.id, version: asset.version): asset
      ]),
      vectorPlans: [atomID: pathPlan]
    )
    let provider = TestProvider(asset: asset)
    let swiftContent = try InlineSwiftUIRenderContent(
      plan: renderPlan, assets: provider, schedule: schedule)
    let canvasContent = try InlineCanvasRenderContent(
      plan: renderPlan, assets: provider, schedule: schedule)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
    let positioned = try XCTUnwrap(layout.lines.first?.atoms.first)

    let phases = try [0.0, 0.5, 1.0].map(InlineRenderRevealPhase.init(rawValue:))
    let swiftRenderers = phases.map {
      InlineSwiftUIRenderer(
        content: swiftContent,
        phase: $0,
        viewport: viewport,
        material: .coloredPencil(.textured)
      )
    }
    let canvasRenderers = phases.map {
      InlineCanvasRenderer(
        content: canvasContent,
        phase: $0,
        viewport: viewport,
        material: .coloredPencil(.textured)
      )
    }

    XCTAssertEqual(swiftRenderers.map(\.coloredPencilPlanCountForTesting), [1, 1, 1])
    XCTAssertEqual(canvasRenderers.map(\.coloredPencilPlanCountForTesting), [1, 1, 1])
    let swiftSamples = swiftRenderers.compactMap {
      $0.coloredPencilVisibleSampleCountForTesting(positioned)
    }
    let canvasSamples = canvasRenderers.compactMap {
      $0.coloredPencilVisibleSampleCountForTesting(positioned)
    }
    XCTAssertEqual(swiftSamples, canvasSamples)
    XCTAssertGreaterThan(swiftSamples[0], 0)
    XCTAssertGreaterThan(swiftSamples[1], swiftSamples[0])
    XCTAssertGreaterThan(swiftSamples[2], swiftSamples[1])
  }

  private func makeAsset(commands: [InlinePathCommand]) throws -> InlineSVGAsset {
    let id = try InlineAssetID(rawValue: "colored-pencil-test")
    let metrics = try InlineMetrics(advance: 20, ascent: 100, descent: 0)
    let path = try InlinePathData(commands: commands)
    return try InlineSVGAsset(
      id: id,
      metrics: metrics,
      coordinateBounds: path.bounds,
      coveragePath: path,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
  }

  private func alphaPixelCount<Content: View>(
    _ content: Content,
    size: CGSize
  ) throws -> Int {
    let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
    renderer.scale = 1
    guard let image = renderer.cgImage else {
      throw XCTSkip("SwiftUI ImageRenderer did not produce a CGImage")
    }
    let width = image.width
    let height = image.height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &rgba,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw XCTSkip("Could not allocate render-back context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return stride(from: 3, to: rgba.count, by: 4).reduce(into: 0) { count, index in
      if rgba[index] > 0 { count += 1 }
    }
  }

  private func alphaPixel<Content: View>(
    _ content: Content,
    size: CGSize,
    x: Int,
    y: Int
  ) throws -> UInt8 {
    let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
    renderer.scale = 1
    guard let image = renderer.cgImage else {
      throw XCTSkip("SwiftUI ImageRenderer did not produce a CGImage")
    }
    guard x >= 0, y >= 0, x < image.width, y < image.height else {
      throw XCTSkip("sample point is outside the rendered image")
    }
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
      data: &rgba,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw XCTSkip("Could not allocate render-back context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return rgba[(y * image.width + x) * 4 + 3]
  }

  private func visibleChannelTotals<Content: View>(
    _ content: Content,
    size: CGSize
  ) throws -> (red: Int, green: Int, blue: Int) {
    let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
    renderer.scale = 1
    guard let image = renderer.cgImage else {
      throw XCTSkip("SwiftUI ImageRenderer did not produce a CGImage")
    }
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
      data: &rgba,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw XCTSkip("Could not allocate render-back context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    var totals = (red: 0, green: 0, blue: 0)
    for offset in stride(from: 0, to: rgba.count, by: 4) where rgba[offset + 3] > 0 {
      totals.red += Int(rgba[offset])
      totals.green += Int(rgba[offset + 1])
      totals.blue += Int(rgba[offset + 2])
    }
    return totals
  }

  private var atomID: String { "pencil-reveal-vector" }

  private struct TestProvider: InlineAssetGeometryProvider {
    let asset: InlineSVGAsset

    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      asset
    }
  }

  private struct EmptyProvider: InlineAssetGeometryProvider {
    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      throw InlineAssetResolutionError.missingGeometry(assetID, version: version)
    }
  }
}
