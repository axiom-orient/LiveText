import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LiveTextCore
@testable import LiveTextCanvas
import LiveTextWritingUI
@testable import LiveTextLayout
@testable import LiveTextSwiftUI
import LiveTextEffects
import SwiftUI
import UniformTypeIdentifiers
import XCTest

/// Render-back proof for the material slice. The test intentionally uses a
/// 21pt text atom plus an open and a closed SVG path: a material that only
/// changes a large decorative path can pass plumbing tests while remaining
/// invisible on ordinary text.
@MainActor
final class MaterialReferenceVisualTests: XCTestCase {
  private struct Fixture {
    let swift: InlineSwiftUIRenderContent
    let canvas: InlineCanvasRenderContent
    let viewport: InlineRenderViewport
    let size: CGSize
    let rois: [String: CGRect]
  }

  private struct EmptyProvider: InlineAssetGeometryProvider {
    let assets: [InlineAssetKey: InlineSVGAsset]

    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      let key = InlineAssetKey(id: assetID, version: version)
      guard let asset = assets[key] else {
        throw InlineAssetResolutionError.missingGeometry(assetID, version: version)
      }
      return asset
    }
  }

  private struct Metric: Codable {
    let material: String
    let adapter: String
    let roi: String
    let scale: Int
    let width: Int
    let height: Int
    let foregroundPixels: Int
    let coverage: Double
    let meanStrength: Double
    let strengthStandardDeviation: Double
    let edgeStepRMS: Double
    let directionalSignal: Double
    let haloRatio: Double
    let textureFrequency: Double
    let medianThickness: Double
    let p10Thickness: Double
    let p90Thickness: Double
    let terminalThickness: Double
    let middleThickness: Double
    let boundingBox: [Int]
    let targetInteriorPixels: Int
    let targetInteriorStrengthStandardDeviation: Double
    let targetInteriorTextureFrequency: Double
    let edgeBandPixels: Int
    let edgeBandStrengthStandardDeviation: Double
    let edgeBandTextureFrequency: Double
  }

  private struct SurfaceBandMetrics {
    let pixels: Int
    let strengthStandardDeviation: Double
    let textureFrequency: Double

    static let empty = SurfaceBandMetrics(
      pixels: 0,
      strengthStandardDeviation: 0,
      textureFrequency: 0
    )
  }

  private struct Manifest: Codable {
    let viewport: [Double]
    let scale: Double
    let notes: [String]
    let externalReference: ExternalReferenceManifest
  }

  private struct ExternalReferenceManifest: Codable {
    let status: String
    let directory: String?
    let digestSHA256: String?
    let files: [ExternalReferenceFile]
    let featureMetrics: [ExternalReferenceFeature]
    let comparisons: [ExternalReferenceComparison]
  }

  private struct ExternalReferenceFile: Codable {
    let name: String
    let byteCount: Int
  }

  private struct ExternalReferenceFeature: Codable {
    let name: String
    let width: Int
    let height: Int
    let foregroundPixels: Int
    let coverage: Double
    let strengthStandardDeviation: Double
    let edgeStepRMS: Double
    let medianThickness: Double
    let p10Thickness: Double
    let p90Thickness: Double
    let directionalSignal: Double
    let haloRatio: Double
    let textureFrequency: Double
  }

  private struct ExternalReferenceComparison: Codable {
    let material: String
    let referenceFiles: [String]
    let candidateAdapter: String?
    let candidateROI: String?
    let comparableFeatures: [String]
    let referenceMean: [String: Double]
    let candidateMean: [String: Double]
    let absoluteDelta: [String: Double]
    let status: String
  }

  private struct ExternalReferenceContract {
    let material: String
    let features: [String]
  }

  /// Intrinsic material-contract lower bounds. These are not a claim of
  /// similarity to an external reference; external comparison is opt-in and
  /// is recorded separately in the artifact manifest.
  private struct IntrinsicProfile {
    let minimumVariation: Double
    let minimumEdgeStep: Double
  }

  /// High-resolution chalk acceptance contract. The values describe a
  /// visible surface signal inside a 21pt glyph, not a whole-ROI edge effect.
  /// The headroom multiplier makes a marginal threshold pass impossible while
  /// keeping the contract independent of any one generated artifact.
  private enum ChalkSurfaceAcceptance {
    static let minimumInteriorVariation = 0.040
    static let minimumInteriorTextureFrequency = 0.040
    static let minimumEdgeVariation = 0.070
    static let minimumEdgeTextureFrequency = 0.100
    static let requiredHeadroom = 1.20
  }

  private let intrinsicProfiles: [String: IntrinsicProfile] = [
    "chalk": IntrinsicProfile(minimumVariation: 0.035, minimumEdgeStep: 0.015),
    "colored-pencil": IntrinsicProfile(minimumVariation: 0.070, minimumEdgeStep: 0.035),
    "brush": IntrinsicProfile(minimumVariation: 0.060, minimumEdgeStep: 0.035),
    "pen": IntrinsicProfile(minimumVariation: 0.018, minimumEdgeStep: 0.012),
    "ink": IntrinsicProfile(minimumVariation: 0.075, minimumEdgeStep: 0.040),
  ]

  func testRendererNeutralTexturePlansAreDeterministicAndMaterialSpecific() throws {
    let chalkFirst = WritingChalkSurfacePlan(configuration: .default)
    let chalkSecond = WritingChalkSurfacePlan(configuration: .default)
    XCTAssertEqual(chalkFirst, chalkSecond)
    XCTAssertEqual(chalkFirst.textureStyle, .fineGrain)
    XCTAssertGreaterThan(chalkFirst.texturePointSize, 48)

    let chalkResources = try WritingChalkTextureStyle.allCases.map {
      try WritingChalkTextureResource.data(for: $0)
    }
    XCTAssertEqual(chalkResources.count, WritingChalkTextureStyle.allCases.count)
    XCTAssertTrue(chalkResources.allSatisfy { !$0.isEmpty })
    XCTAssertEqual(Set(chalkResources).count, chalkResources.count)

    let brush = WritingMaterial.brush(.default)
    let pencil = WritingMaterial.pen(.default)
    let brushPlan = WritingMaterialTexturePlan(material: brush)
    let pencilPlan = WritingMaterialTexturePlan(material: pencil)
    XCTAssertEqual(brushPlan.pixels.count, brushPlan.dimension * brushPlan.dimension * 4)
    XCTAssertEqual(brushPlan.dimension, WritingMaterialTexturePlan.defaultDimension)
    XCTAssertEqual(brushPlan.pointSize, WritingMaterialTexturePlan.defaultPointSize)
    XCTAssertNotEqual(brushPlan.pixels, pencilPlan.pixels)
    XCTAssertGreaterThan(brushPlan.pixels.filter { $0 > 0 }.count, brushPlan.pixels.count / 20)
  }

  func testLegibleChalkKeepsCenterPigmentAboveTextureLoss() {
    let plan = WritingChalkSurfacePlan(configuration: .legible)

    XCTAssertEqual(plan.textureStyle, .referenceSampled)
    XCTAssertGreaterThanOrEqual(plan.baseOpacity, 0.90)
    XCTAssertLessThanOrEqual(plan.erosionOpacity, 0.12)
    XCTAssertLessThanOrEqual(plan.grainCutoutOpacity, 0.24)
    XCTAssertGreaterThan(plan.grainPigmentOpacity, 0)
    XCTAssertTrue(plan.edgeDustRecipe.isEnabled)
  }

  func testNonChalkMaterialTexturePlanByteSamplesArePeriodicAcrossTwoByTwoRepeats() throws {
    let materials: [WritingMaterial] = [
      .brush(.default), .pen(.default), .ink(.default),
    ]
    for material in materials {
      let plan = WritingMaterialTexturePlan(material: material)
      let (seam, interior) = twoByTwoSeamGradients(plan)
      XCTAssertFalse(seam.isEmpty)
      XCTAssertFalse(interior.isEmpty)
      let seamP95 = percentile(seam, 0.95)
      let interiorP95 = percentile(interior, 0.95)
      let interiorMedian = percentile(interior, 0.50)
      // A periodic field may have a naturally stronger border than the
      // median interior step, but a tile seam must stay inside the interior
      // distribution rather than become a discontinuity.
      XCTAssertLessThanOrEqual(
        seamP95,
        max(interiorP95 * 1.65, interiorMedian + 0.045),
        "non-periodic " + material.kind.rawValue
          + " tile seam: p95=" + String(seamP95)
          + ", interior p95=" + String(interiorP95)
      )
    }
  }

  func testComplexPathMaterialParityUsesStrictAlphaThreshold() throws {
    let fixture = try makeFixture()
    let background = try render(
      Color.white.frame(width: fixture.size.width, height: fixture.size.height),
      size: fixture.size
    )
    let swift = try render(
      LiveTextWritingRenderer(
        content: fixture.swift,
        viewport: fixture.viewport,
        configuration: .brush
      ).background(Color.white),
      size: fixture.size
    )
    let canvas = try render(
      LiveTextCanvasWritingRenderer(
        content: fixture.canvas,
        viewport: fixture.viewport,
        configuration: .brush
      ).background(Color.white),
      size: fixture.size
    )
    for roiName in ["openPath", "closedShape"] {
      guard let roi = fixture.rois[roiName] else { continue }
      let difference = meanAbsoluteDifference(swift, canvas, region: roi, scale: 1)
      // Media stamps are rotated bitmap deposits rasterized at each
      // adapter's fractional atom translation, so identical plans and one
      // shared painter still differ by raster phase inside the stamps.
      // The threshold tracks the measured phase envelope, not plan drift.
      XCTAssertLessThan(
        difference,
        0.14,
        "strict complex-path SwiftUI/Canvas alpha parity failed for \(roiName): \(difference)"
      )
      XCTAssertGreaterThan(
        measure(
          swift,
          material: "brush",
          adapter: "SwiftUI",
          roi: roiName,
          scale: 1,
          region: roi,
          background: background
        ).foregroundPixels,
        0
      )
    }
  }

  func testInkRenderBackParityUsesStrictHaloThreshold() throws {
    let fixture = try makeFixture()
    let swift = try render(
      LiveTextWritingRenderer(
        content: fixture.swift,
        viewport: fixture.viewport,
        configuration: .ink
      ).background(Color.white),
      size: fixture.size
    )
    let canvas = try render(
      LiveTextCanvasWritingRenderer(
        content: fixture.canvas,
        viewport: fixture.viewport,
        configuration: .ink
      ).background(Color.white),
      size: fixture.size
    )
    for roiName in ["openPath", "closedShape"] {
      guard let roi = fixture.rois[roiName] else { continue }
      let difference = meanAbsoluteDifference(swift, canvas, region: roi, scale: 1)
      // SwiftUI's per-atom Canvas now owns the complete 2.40pt ink halo
      // extent (blur radius + 1.05pt). The larger fractional surface changes
      // only the rasterization phase at this render-back boundary; keep the
      // threshold tight around the measured shared-halo envelope.
      // Stamp raster phase (see the complex-path parity note) widens the
      // shared-halo envelope for ink.
      let maximumDifference = roiName == "openPath" ? 0.08 : 0.11
      XCTAssertLessThan(
        difference,
        maximumDifference,
        "ink halo SwiftUI/Canvas render-back parity failed for \(roiName): \(difference)"
      )
    }
  }

  func testMultiCommandOpenRevealTapersOnlyAtVisibleTerminalAndClosedSubpathDoesNotTaper() throws {
    let openID = try InlineAssetID(rawValue: "material-three-command-open")
    let openMetrics = try InlineMetrics(advance: 120, ascent: 40, descent: 0)
    let openPath = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 20)),
      .line(try InlinePathPoint(x: 40, y: 20)),
      .line(try InlinePathPoint(x: 80, y: 20)),
      .line(try InlinePathPoint(x: 120, y: 20)),
    ])
    let openAsset = try InlineSVGAsset(
      id: openID,
      metrics: openMetrics,
      coordinateBounds: openPath.bounds,
      coveragePath: openPath,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: openPath,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let openAtom = try InlineAtom.vector(
      InlineVectorAtom(id: "three-command-open", asset: openAsset)
    )
    let openPrepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [openAtom]))
    let openLayout = try InlineLayoutEngine().layout(prepared: openPrepared, width: 128)
    let openPlan = try InlineRenderPlan(prepared: openPrepared, layout: openLayout)
    let openReveal = try InlinePathRevealPlanBuilder(secondsPerUnit: 0.01).plan(asset: openAsset)
    let openSchedule = try InlineRenderRevealSchedule(
      plan: openPlan,
      assets: InlineAssetStore(values: [
        InlineAssetKey(id: openAsset.id, version: openAsset.version): openAsset
      ]),
      vectorPlans: [openAtom.id: openReveal]
    )
    let provider = EmptyProvider(assets: [
      InlineAssetKey(id: openID, version: openAsset.version): openAsset,
    ])
    let swiftContent = try InlineSwiftUIRenderContent(
      plan: openPlan, assets: provider, schedule: openSchedule)
    let canvasContent = try InlineCanvasRenderContent(
      plan: openPlan, assets: provider, schedule: openSchedule)
    let openViewport = try InlineRenderViewport(
      x: 0, y: 0, width: 128, height: 44)
    // The first two 40pt commands complete at t=.8; the third is 40% visible
    // at this phase. The final visible endpoint is therefore inside command 3.
    let partialPhase = try InlineRenderRevealPhase(rawValue: 0.8)
    let openBackground = try render(
      Color.white.frame(width: 128, height: 44), size: CGSize(width: 128, height: 44))
    let openSwift = try render(
      LiveTextWritingRenderer(
        content: swiftContent,
        phase: partialPhase,
        viewport: openViewport,
        configuration: .brush
      ).background(Color.white),
      size: CGSize(width: 128, height: 44)
    )
    let openCanvas = try render(
      LiveTextCanvasWritingRenderer(
        content: canvasContent,
        phase: partialPhase,
        viewport: openViewport,
        configuration: .brush
      ).background(Color.white),
      size: CGSize(width: 128, height: 44)
    )
    let openPositioned = try XCTUnwrap(openLayout.lines.first?.atoms.first)
    let openROI = CGRect(
      x: openPositioned.originX,
      y: openPositioned.baselineY - openPositioned.metrics.baselineOffset
        - openPositioned.metrics.ascent,
      width: openPositioned.width,
      height: openPositioned.height
    ).insetBy(dx: -2, dy: -2)
    let openSwiftMetric = measure(
      openSwift,
      material: "brush",
      adapter: "SwiftUI",
      roi: "openPath",
      scale: 1,
      region: openROI,
      background: openBackground
    )
    let openCanvasMetric = measure(
      openCanvas,
      material: "brush",
      adapter: "Canvas",
      roi: "openPath",
      scale: 1,
      region: openROI,
      background: openBackground
    )
    XCTAssertGreaterThan(openSwiftMetric.foregroundPixels, 0)
    XCTAssertGreaterThan(openCanvasMetric.foregroundPixels, 0)
    XCTAssertLessThan(
      openSwiftMetric.terminalThickness,
      openSwiftMetric.middleThickness * 0.92,
      "open reveal must visibly taper at its current terminal"
    )
    XCTAssertLessThan(
      openCanvasMetric.terminalThickness,
      openCanvasMetric.middleThickness * 0.92,
      "Canvas open reveal must visibly taper at its current terminal"
    )

    // A command boundary is an implementation seam, not a writing endpoint.
    // At the current .8 phase the terminal is 96pt, so the shared absolute
    // arclength contract predicts x=40 is still body width while x=80 is in
    // the final 28% taper. Both adapters must show that same monotonic change
    // without a boundary-local reset or notch.
    let openSwiftProfile = columnThicknesses(
      bytes: rgba(openSwift),
      background: rgba(openBackground),
      image: openSwift,
      region: pixelRegion(openROI, scale: 1, width: openSwift.width, height: openSwift.height),
      scale: 1
    )
    let openCanvasProfile = columnThicknesses(
      bytes: rgba(openCanvas),
      background: rgba(openBackground),
      image: openCanvas,
      region: pixelRegion(openROI, scale: 1, width: openCanvas.width, height: openCanvas.height),
      scale: 1
    )
    let expectedBodyTaper = expectedOpenTaper(at: 40, terminal: 96)
    let expectedBoundaryTaper = expectedOpenTaper(at: 80, terminal: 96)
    XCTAssertEqual(expectedBodyTaper, 1, accuracy: 1.0e-9)
    XCTAssertLessThan(expectedBoundaryTaper, expectedBodyTaper)
    for (adapter, profile) in [
      ("SwiftUI", openSwiftProfile), ("Canvas", openCanvasProfile),
    ] {
      let body = try XCTUnwrap(thicknessNear(profile, x: 40))
      let boundary = try XCTUnwrap(thicknessNear(profile, x: 80))
      XCTAssertGreaterThan(body, 0, "\(adapter) body segment disappeared")
      XCTAssertGreaterThan(boundary, 0, "\(adapter) boundary segment disappeared")
      XCTAssertLessThan(
        boundary,
        body * 0.94,
        "\(adapter) did not apply the absolute terminal taper at x=80"
      )
      let neighborhood = profile.filter { abs($0.x - 80) <= 2 }.map(\.value)
      XCTAssertFalse(neighborhood.isEmpty)
      let localMin = neighborhood.min() ?? 0
      let localMax = neighborhood.max() ?? 0
      // A command seam may be thinner than the body because the real taper
      // crosses it, but it must not collapse and recover within the join.
      XCTAssertLessThanOrEqual(
        localMax - localMin,
        max(2.0, body * 0.70),
        "\(adapter) command boundary produced an artificial notch: \(neighborhood)"
      )
    }

    // Equal-length commands are checked at a terminal inside command two and
    // exactly at the command-two/command-three boundary.  The expected taper
    // start is 60 - 0.28*60 = 43.2pt and 80 - 0.28*80 = 57.6pt respectively;
    // neither value is allowed to use command-two's local start (40pt).
    let midPhase = try InlineRenderRevealPhase(rawValue: 0.5)
    let boundaryPhase = try InlineRenderRevealPhase(rawValue: 2.0 / 3.0)
    let midSwift = try render(
      LiveTextWritingRenderer(
        content: swiftContent,
        phase: midPhase,
        viewport: openViewport,
        configuration: .brush
      ).background(Color.white),
      size: CGSize(width: 128, height: 44)
    )
    let midCanvas = try render(
      LiveTextCanvasWritingRenderer(
        content: canvasContent,
        phase: midPhase,
        viewport: openViewport,
        configuration: .brush
      ).background(Color.white),
      size: CGSize(width: 128, height: 44)
    )
    let boundarySwift = try render(
      LiveTextWritingRenderer(
        content: swiftContent,
        phase: boundaryPhase,
        viewport: openViewport,
        configuration: .brush
      ).background(Color.white),
      size: CGSize(width: 128, height: 44)
    )
    let boundaryCanvas = try render(
      LiveTextCanvasWritingRenderer(
        content: canvasContent,
        phase: boundaryPhase,
        viewport: openViewport,
        configuration: .brush
      ).background(Color.white),
      size: CGSize(width: 128, height: 44)
    )
    let midTerminal = expectedOpenTaper(at: 50, terminal: 60)
    let boundaryBody = expectedOpenTaper(at: 50, terminal: 80)
    let boundaryTerminal = expectedOpenTaper(at: 70, terminal: 80)
    XCTAssertLessThan(midTerminal, 1)
    XCTAssertEqual(boundaryBody, 1, accuracy: 1.0e-9)
    XCTAssertLessThan(boundaryTerminal, boundaryBody)
    let renderProfiles: [(String, CGImage, CGImage)] = [
      ("SwiftUI-mid", midSwift, openBackground),
      ("Canvas-mid", midCanvas, openBackground),
      ("SwiftUI-boundary", boundarySwift, openBackground),
      ("Canvas-boundary", boundaryCanvas, openBackground),
    ]
    for (label, image, background) in renderProfiles {
      let profile = columnThicknesses(
        bytes: rgba(image),
        background: rgba(background),
        image: image,
        region: pixelRegion(openROI, scale: 1, width: image.width, height: image.height),
        scale: 1
      )
      let bodyX = label.contains("mid") ? 40 : 50
      let taperX = label.contains("mid") ? 50 : 70
      let body = try XCTUnwrap(thicknessNear(profile, x: bodyX))
      let taper = try XCTUnwrap(thicknessNear(profile, x: taperX))
      XCTAssertGreaterThan(body, 0, "\(label) body disappeared")
      XCTAssertGreaterThan(taper, 0, "\(label) terminal disappeared")
      let expectedBody = label.contains("mid") ? 1.0 : boundaryBody
      let expectedTerminal = label.contains("mid") ? midTerminal : boundaryTerminal
      let expectedRatio = expectedTerminal / expectedBody
      let observedRatio = taper / body
      XCTAssertLessThan(taper, body * 0.97, "\(label) did not taper at absolute distance")
      // Pressure marks can change the local width independently of taper, so
      // compare against a deliberately antialias-tolerant interval around the
      // shared arclength multiplier rather than demanding a pixel-exact ratio.
      XCTAssertGreaterThan(
        observedRatio,
        expectedRatio * 0.25,
        "\(label) fell below the absolute-distance width floor"
      )
      XCTAssertLessThan(
        observedRatio,
        min(0.97, expectedRatio * 2.0),
        "\(label) did not track the absolute-distance taper interval"
      )
    }

    // A closed contour uses the same four-command geometry but must not treat
    // its final close command as an open terminal. Compare the opposite edge
    // runs at the center of the square; a taper would make the closing edge
    // materially thinner than the first edge.
    let closedID = try InlineAssetID(rawValue: "material-closed-square")
    let closedMetrics = try InlineMetrics(advance: 92, ascent: 84, descent: 0)
    let closedPath = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 4, y: 0)),
      .line(try InlinePathPoint(x: 88, y: 0)),
      .line(try InlinePathPoint(x: 88, y: 84)),
      .line(try InlinePathPoint(x: 4, y: 84)),
      .close,
    ])
    let closedAsset = try InlineSVGAsset(
      id: closedID,
      metrics: closedMetrics,
      coordinateBounds: closedPath.bounds,
      coveragePath: closedPath,
      coveragePaint: .fill(.nonZero),
      trajectoryPath: closedPath,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let closedAtom = try InlineAtom.vector(
      InlineVectorAtom(id: "closed-square", asset: closedAsset))
    let closedPrepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [closedAtom]))
    let closedLayout = try InlineLayoutEngine().layout(prepared: closedPrepared, width: 100)
    let closedPlan = try InlineRenderPlan(prepared: closedPrepared, layout: closedLayout)
    let closedProvider = EmptyProvider(assets: [
      InlineAssetKey(id: closedID, version: closedAsset.version): closedAsset,
    ])
    let closedSwiftContent = try InlineSwiftUIRenderContent(
      plan: closedPlan, assets: closedProvider)
    let closedCanvasContent = try InlineCanvasRenderContent(
      plan: closedPlan, assets: closedProvider)
    let closedViewport = try InlineRenderViewport(x: 0, y: 0, width: 100, height: 90)
    let closedBackground = try render(
      Color.white.frame(width: 100, height: 90), size: CGSize(width: 100, height: 90))
    let closedPositioned = try XCTUnwrap(closedLayout.lines.first?.atoms.first)
    let closedROI = CGRect(
      x: closedPositioned.originX,
      y: closedPositioned.baselineY - closedPositioned.metrics.baselineOffset
        - closedPositioned.metrics.ascent,
      width: closedPositioned.width,
      height: closedPositioned.height
    ).insetBy(dx: -2, dy: -2)

    func renderClosed(
      phase: InlineRenderRevealPhase,
      adapter: String
    ) throws -> CGImage {
      switch adapter {
      case "SwiftUI":
        return try render(
          LiveTextWritingRenderer(
            content: closedSwiftContent,
            phase: phase,
            viewport: closedViewport,
            configuration: .brush
          ).background(Color.white),
          size: CGSize(width: 100, height: 90)
        )
      case "Canvas":
        return try render(
          LiveTextCanvasWritingRenderer(
            content: closedCanvasContent,
            phase: phase,
            viewport: closedViewport,
            configuration: .brush
          ).background(Color.white),
          size: CGSize(width: 100, height: 90)
        )
      default:
        throw NSError(domain: "MaterialReferenceVisualTests", code: 1)
      }
    }

    // A complete closed contour and a nearly-complete prefix of that same
    // originally-closed contour both keep constant width. Product contract:
    // the close flag is semantic, so a partial reveal has no artificial open
    // terminal at its current endpoint.
    for (adapter, phase) in [
      ("SwiftUI", InlineRenderRevealPhase.complete),
      ("Canvas", InlineRenderRevealPhase.complete),
      ("SwiftUI", try InlineRenderRevealPhase(rawValue: 0.95)),
      ("Canvas", try InlineRenderRevealPhase(rawValue: 0.95)),
    ] {
      let closedImage = try renderClosed(phase: phase, adapter: adapter)
      let closedMetric = measure(
        closedImage,
        material: "brush",
        adapter: adapter,
        roi: "closedShape",
        scale: 1,
        region: closedROI,
        background: closedBackground
      )
      XCTAssertGreaterThan(closedMetric.foregroundPixels, 0)
      let rowRegion = pixelRegion(
        closedROI,
        scale: 1,
        width: closedImage.width,
        height: closedImage.height
      )
      let rows = [
        rowRegion.minY + rowRegion.height / 3,
        rowRegion.minY + rowRegion.height / 2,
        rowRegion.minY + rowRegion.height * 2 / 3,
      ]
      let rightEdgeWidths = rows.compactMap { row -> Double? in
        let rowRuns = horizontalForegroundRuns(
          bytes: rgba(closedImage),
          background: rgba(closedBackground),
          image: closedImage,
          y: row,
          region: rowRegion
        )
        guard rowRuns.count >= 2 else { return nil }
        return Double(rowRuns[rowRuns.count - 1].width)
      }
      guard rightEdgeWidths.count == rows.count else {
        XCTFail("\(adapter) closed contour right-edge rows are incomplete")
        continue
      }
      let middleThickness = rightEdgeWidths[1]
      let terminalThickness = rightEdgeWidths[2]
      XCTAssertGreaterThan(
        min(terminalThickness, middleThickness) / max(terminalThickness, middleThickness),
        0.80,
        "\(adapter) closed contour terminal/middle widths diverged: terminal=\(terminalThickness), middle=\(middleThickness), phase=\(phase.rawValue)"
      )
    }

    // Retain a metric record for the complete SwiftUI contour so the test
    // still exercises the same background-aware ROI path used by the gallery.
    let closedImage = try render(
      LiveTextWritingRenderer(
        content: closedSwiftContent,
        viewport: closedViewport,
        configuration: .brush
      ).background(Color.white),
      size: CGSize(width: 100, height: 90)
    )
    let closedMetric = measure(
      closedImage,
      material: "brush",
      adapter: "SwiftUI",
      roi: "closedShape",
      scale: 1,
      region: closedROI,
      background: closedBackground
    )
    XCTAssertGreaterThan(closedMetric.foregroundPixels, 0)
  }

  func testRendererTextureTileSeamsUseActualTwoByTwoRenderBackAtAllScales() throws {
    let assetID = try InlineAssetID(rawValue: "material-large-periodic-rectangle")
    let metrics = try InlineMetrics(advance: 198, ascent: 96, descent: 0)
    let phaseX = 0.37
    let phaseY = 8.23
    let rightX = phaseX + 192
    let bottomY = phaseY + 80
    let assetPath = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: phaseX, y: phaseY)),
      .line(try InlinePathPoint(x: rightX, y: phaseY)),
      .line(try InlinePathPoint(x: rightX, y: bottomY)),
      .line(try InlinePathPoint(x: phaseX, y: bottomY)),
      .close,
    ])
    let asset = try InlineSVGAsset(
      id: assetID,
      metrics: metrics,
      coordinateBounds: assetPath.bounds,
      coveragePath: assetPath,
      coveragePaint: .fill(.nonZero),
      trajectoryPath: assetPath,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let atom = try InlineAtom.vector(
      InlineVectorAtom(id: "large-periodic-rectangle", asset: asset)
    )
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [atom])
    )
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 204)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let provider = EmptyProvider(assets: [
      InlineAssetKey(id: assetID, version: asset.version): asset,
    ])
    let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: provider)
    let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: provider)
    // Both coordinates intentionally include fractional values. The viewport
    // crop is fractional as well, so the repeated image is sampled at real
    // non-integral tile phases rather than only at integer test coordinates.
    let viewport = try InlineRenderViewport(
      x: 0.37, y: 0.23, width: 180.0, height: 100.0
    )
    let positioned = try XCTUnwrap(layout.lines.first?.atoms.first)
    let rectangleROI = CGRect(
      x: positioned.originX,
      y: positioned.baselineY - positioned.metrics.baselineOffset
        - positioned.metrics.ascent,
      width: positioned.width,
      height: positioned.height
    ).insetBy(dx: -2, dy: -2)
    let materials: [(String, InlineWritingConfiguration, Color)] = [
      ("chalk", try configuration(for: .chalk(.default)),
       Color(red: 0.08, green: 0.10, blue: 0.16)),
      ("brush", try configuration(for: .brush(.default)), .white),
      ("pen", try configuration(for: .pen(.default)), .white),
      ("ink", try configuration(for: .ink(.default)), .white),
    ]
    let seamDocuments = [48.0, 96.0, 144.0].map {
      positioned.originX + $0
    }
    let seamYDocuments = [48.0].map {
      positioned.baselineY - positioned.metrics.baselineOffset
        - positioned.metrics.ascent + $0
    }
    for (name, configuration, background) in materials {
      for scale in [1, 2, 3] {
        let backgroundImage = try render(
          background.frame(width: viewport.width, height: viewport.height),
          size: CGSize(width: viewport.width, height: viewport.height),
          scale: scale
        )
        let swiftImage = try render(
          LiveTextWritingRenderer(
            content: swiftContent,
            viewport: viewport,
            configuration: configuration
          ).background(background),
          size: CGSize(width: viewport.width, height: viewport.height),
          scale: scale
        )
        let canvasImage = try render(
          LiveTextCanvasWritingRenderer(
            content: canvasContent,
            viewport: viewport,
            configuration: configuration
          ).background(background),
          size: CGSize(width: viewport.width, height: viewport.height),
          scale: scale
        )
        let swiftSeam = tileRenderBackSeamGradients(
          image: swiftImage,
          background: backgroundImage,
          documentXSeams: seamDocuments,
          documentYSeams: seamYDocuments,
          viewport: viewport,
          scale: scale,
          region: rectangleROI
        )
        let canvasSeam = tileRenderBackSeamGradients(
          image: canvasImage,
          background: backgroundImage,
          documentXSeams: seamDocuments,
          documentYSeams: seamYDocuments,
          viewport: viewport,
          scale: scale,
          region: rectangleROI
        )
        XCTAssertFalse(swiftSeam.seam.isEmpty, "SwiftUI \(name) \(scale)x seam ROI is empty")
        XCTAssertFalse(canvasSeam.seam.isEmpty, "Canvas \(name) \(scale)x seam ROI is empty")
        XCTAssertFalse(swiftSeam.interior.isEmpty, "SwiftUI \(name) \(scale)x interior ROI is empty")
        XCTAssertFalse(canvasSeam.interior.isEmpty, "Canvas \(name) \(scale)x interior ROI is empty")
        for (adapter, values) in [("SwiftUI", swiftSeam), ("Canvas", canvasSeam)] {
          let seamP95 = percentile(values.seam, 0.95)
          let interiorP95 = percentile(values.interior, 0.95)
          let interiorMedian = percentile(values.interior, 0.50)
          XCTAssertLessThanOrEqual(
            seamP95,
            max(interiorP95 * 1.90, interiorMedian + 0.10),
            "\(adapter) \(name) \(scale)x actual tile seam exceeded internal gradient range: seamP95=\(seamP95), interiorP95=\(interiorP95)"
          )
        }
      }
    }
  }

  func testMaterialReferenceRenderBackProducesProofArtifactsAndSeparatesMaterials() throws {
    let fixture = try makeFixture()
    let materials: [(String, InlineRendererMaterial, Color)] = [
      // Chalk is judged on a board; the other materials are judged on white
      // paper, matching the supplied reference crops.
      ("chalk", .chalk(.default), Color(red: 0.08, green: 0.10, blue: 0.16)),
      ("colored-pencil", .coloredPencil(.textured), Color.white),
      ("brush", .brush(.default), Color.white),
      ("pen", .pen(.default), Color.white),
      ("ink", .ink(.default), Color.white),
    ]

    var metrics: [Metric] = []
    var images: [(String, String, CGImage)] = []
    for (name, material, background) in materials {
      for scale in [1, 2, 3] {
        let backgroundImage = try render(
          background.frame(width: fixture.size.width, height: fixture.size.height),
          size: fixture.size,
          scale: scale
        )
        let swiftImage = try render(
          LiveTextWritingRenderer(
            content: fixture.swift,
            viewport: fixture.viewport,
            configuration: try configuration(for: material)
          )
          .background(background),
          size: fixture.size,
          scale: scale
        )
        let canvasImage = try render(
          LiveTextCanvasWritingRenderer(
            content: fixture.canvas,
            viewport: fixture.viewport,
            configuration: try configuration(for: material)
          )
          .background(background),
          size: fixture.size,
          scale: scale
        )
        writePNG(swiftImage, name: "\(name)-swiftui-\(scale)x.png")
        writePNG(canvasImage, name: "\(name)-canvas-\(scale)x.png")
        for roiName in ["text", "openPath", "closedShape"] {
          guard let roi = fixture.rois[roiName] else { continue }
          metrics.append(measure(
            swiftImage,
            material: name,
            adapter: "SwiftUI",
            roi: roiName,
            scale: scale,
            region: roi,
            background: backgroundImage
          ))
          metrics.append(measure(
            canvasImage,
            material: name,
            adapter: "Canvas",
            roi: roiName,
            scale: scale,
            region: roi,
            background: backgroundImage
          ))
          let difference = meanAbsoluteDifference(
            swiftImage,
            canvasImage,
            region: roi,
            scale: scale
          )
          // Stamp raster phase (see the complex-path parity note): pen
          // schedules no stamps and keeps the original strict bound.
          let parityThreshold: Double
          switch name {
          // Grain-coupled edge bite (shared with stamp baking) adds raster
          // phase sensitivity on closed contours even for pen, whose bite
          // amplitude is small but no longer zero.
          case "pen": parityThreshold = 0.08
          case "chalk": parityThreshold = 0.10
          case "brush": parityThreshold = 0.13
          default: parityThreshold = 0.11
          }
          XCTAssertLessThan(
            difference,
            parityThreshold,
            "SwiftUI/Canvas mask parity drifted for \(name)/\(roiName) at \(scale)x: \(difference)"
          )
        }
        if scale == 1 {
          images.append((name, "SwiftUI", swiftImage))
          images.append((name, "Canvas", canvasImage))
        }
      }
    }

    // Render a zero-variation chalk configuration through both adapters. This
    // is a negative control for the interior/edge contract: if the production
    // chalk surface regresses to a solid fill, this control remains smooth and
    // the assertions below prove that the acceptance threshold would reject it.
    let solidChalk = try WritingChalkConfiguration(
      grainAmount: 0,
      erosionAmount: 0,
      grainScale: 3.5,
      edgeRoughness: 0
    )
    let solidConfiguration = InlineWritingConfiguration(
      effect: .chalk(solidChalk),
      color: .warmWhite
    )
    let solidSwiftImage = try render(
      LiveTextWritingRenderer(
        content: fixture.swift,
        viewport: fixture.viewport,
        configuration: solidConfiguration
      )
      .background(Color(red: 0.08, green: 0.10, blue: 0.16)),
      size: fixture.size,
      scale: 3
    )
    let solidCanvasImage = try render(
      LiveTextCanvasWritingRenderer(
        content: fixture.canvas,
        viewport: fixture.viewport,
        configuration: solidConfiguration
      )
      .background(Color(red: 0.08, green: 0.10, blue: 0.16)),
      size: fixture.size,
      scale: 3
    )
    writePNG(solidSwiftImage, name: "chalk-solid-control-swiftui-3x.png")
    writePNG(solidCanvasImage, name: "chalk-solid-control-canvas-3x.png")
    if let textROI = fixture.rois["text"] {
      let solidBackground = try render(
        Color(red: 0.08, green: 0.10, blue: 0.16)
          .frame(width: fixture.size.width, height: fixture.size.height),
        size: fixture.size,
        scale: 3
      )
      metrics.append(measure(
        solidSwiftImage,
        material: "chalk-solid-control",
        adapter: "SwiftUI",
        roi: "text",
        scale: 3,
        region: textROI,
        background: solidBackground
      ))
      metrics.append(measure(
        solidCanvasImage,
        material: "chalk-solid-control",
        adapter: "Canvas",
        roi: "text",
        scale: 3,
        region: textROI,
        background: solidBackground
      ))
    }

    let swiftMetrics = metrics.filter {
      $0.adapter == "SwiftUI" && $0.scale == 1 && $0.roi == "text"
    }
    let pairwiseDifferences = stride(from: 0, to: swiftMetrics.count, by: 1).flatMap { index in
      (index + 1..<swiftMetrics.count).map { other in
        abs(swiftMetrics[index].meanStrength - swiftMetrics[other].meanStrength)
          + abs(swiftMetrics[index].coverage - swiftMetrics[other].coverage)
      }
    }
    XCTAssertGreaterThan(
      pairwiseDifferences.filter { $0 > 0.04 }.count,
      5,
      "material profiles must remain separable: \(swiftMetrics)"
    )
    for metric in swiftMetrics {
      XCTAssertGreaterThan(
        metric.strengthStandardDeviation,
        0.012,
        "\(metric.material) lacks measurable internal material variation"
      )
      if let profile = intrinsicProfiles[metric.material] {
        XCTAssertGreaterThanOrEqual(
          metric.strengthStandardDeviation,
          profile.minimumVariation,
          "\(metric.material) variation is below the intrinsic material-contract range"
        )
      XCTAssertGreaterThanOrEqual(
          metric.edgeStepRMS,
          profile.minimumEdgeStep,
          "\(metric.material) edge structure is below the intrinsic material-contract range"
        )
      }
    }
    let chalkHighResolutionText = metrics.filter {
      $0.material == "chalk" && $0.roi == "text" && $0.scale == 3
    }
    XCTAssertEqual(chalkHighResolutionText.count, 2)
    for metric in chalkHighResolutionText {
      // A plain solid line can vary at its antialiased edge, but its eroded
      // glyph core remains constant. These target-interior and edge-band
      // guards therefore require material structure rather than ROI-wide
      // background/edge noise. The 3x render is intentional: it avoids
      // allowing one-pixel quantization to satisfy the chalk contract.
      XCTAssertGreaterThan(
        metric.targetInteriorPixels,
        100,
        "chalk target interior was not measurable at 3x for \(metric.adapter)"
      )
      XCTAssertGreaterThan(
        metric.targetInteriorStrengthStandardDeviation,
        ChalkSurfaceAcceptance.minimumInteriorVariation
          * ChalkSurfaceAcceptance.requiredHeadroom,
        "chalk glyph interior is too plain at 3x for \(metric.adapter)"
      )
      XCTAssertGreaterThan(
        metric.targetInteriorTextureFrequency,
        ChalkSurfaceAcceptance.minimumInteriorTextureFrequency
          * ChalkSurfaceAcceptance.requiredHeadroom,
        "chalk glyph interior has no high-resolution texture transitions for \(metric.adapter)"
      )
      XCTAssertGreaterThan(
        metric.edgeBandPixels,
        100,
        "chalk edge band was not measurable at 3x for \(metric.adapter)"
      )
      XCTAssertGreaterThan(
        metric.edgeBandStrengthStandardDeviation,
        ChalkSurfaceAcceptance.minimumEdgeVariation
          * ChalkSurfaceAcceptance.requiredHeadroom,
        "chalk edge band is too plain at 3x for \(metric.adapter)"
      )
      XCTAssertGreaterThan(
        metric.edgeBandTextureFrequency,
        ChalkSurfaceAcceptance.minimumEdgeTextureFrequency
          * ChalkSurfaceAcceptance.requiredHeadroom,
        "chalk edge band has no high-resolution texture transitions for \(metric.adapter)"
      )
    }
    let solidControlMetrics = metrics.filter {
      $0.material == "chalk-solid-control" && $0.roi == "text" && $0.scale == 3
    }
    XCTAssertEqual(solidControlMetrics.count, 2)
    for metric in solidControlMetrics {
      XCTAssertGreaterThan(
        metric.targetInteriorPixels,
        100,
        "solid chalk control did not produce a measurable glyph interior for \(metric.adapter)"
      )
      XCTAssertLessThan(
        metric.targetInteriorStrengthStandardDeviation,
        ChalkSurfaceAcceptance.minimumInteriorVariation
          * ChalkSurfaceAcceptance.requiredHeadroom,
        "solid chalk control unexpectedly contains interior variation for \(metric.adapter)"
      )
      XCTAssertLessThan(
        metric.targetInteriorTextureFrequency,
        ChalkSurfaceAcceptance.minimumInteriorTextureFrequency
          * ChalkSurfaceAcceptance.requiredHeadroom,
        "solid chalk control unexpectedly contains interior texture transitions for \(metric.adapter)"
      )
    }
    for name in materials.map(\.0) {
      for roiName in ["text", "openPath", "closedShape"] {
        let adapterMetrics = metrics.filter {
          $0.material == name && $0.scale == 1 && $0.roi == roiName
        }
        XCTAssertEqual(adapterMetrics.count, 2)
        XCTAssertGreaterThan(adapterMetrics[0].foregroundPixels, 0)
        XCTAssertGreaterThan(adapterMetrics[1].foregroundPixels, 0)
      }
      assertScaleStability(metrics, material: name, roi: "text")
      assertScaleStability(metrics, material: name, roi: "openPath")
      assertScaleStability(metrics, material: name, roi: "closedShape")
    }

    writeJSON(metrics, name: "metrics.json")
    let contact = try makeContactSheet(images: images)
    writePNG(contact, name: "contact-sheet.png")
    writeJSON(
      Manifest(
        viewport: [fixture.viewport.width, fixture.viewport.height],
        scale: 1,
        notes: [
          "Metrics use a same-size rendered background baseline and separate text, open-path, and closed-shape ROIs.",
          "The same fixture is rendered at 1x, 2x, and 3x; PNGs are written for every scale.",
          "Chalk 3x glyph acceptance requires target-interior and edge-band variation with 1.20x headroom; chalk-solid-control is a negative control for the target-interior checks.",
          "Intrinsic material assertions are not a claim of pixel similarity to external references.",
          "External comparison is opt-in through LIVETEXT_MATERIAL_REFERENCE_DIR and is marked [NOT_PROVEN] when absent.",
        ],
        externalReference: externalReferenceManifest(candidateMetrics: metrics)
      ),
      name: "manifest.json"
    )
  }

  private func expectedOpenTaper(at distance: Double, terminal: Double) -> Double {
    guard distance.isFinite, terminal.isFinite, terminal > 0 else { return 1 }
    let taperLength = terminal * 0.28
    let progress = min(1, max(0, (distance - (terminal - taperLength)) / taperLength))
    let smooth = progress * progress * (3 - 2 * progress)
    return max(0.08, 1 - smooth * 0.92)
  }

  private func configuration(for material: InlineRendererMaterial) throws -> InlineWritingConfiguration {
    switch material {
    case .coloredPencil(let value):
      return InlineWritingConfiguration(
        effect: .coloredPencil(value),
        color: nil
      )
    case .chalk(let value):
      return InlineWritingConfiguration(
        effect: .chalk(value),
        color: .warmWhite
      )
    case .brush(let value):
      return InlineWritingConfiguration(
        effect: .brush(try .init(
          seed: value.seed, coverage: value.coverage, streakScale: value.streakScale
        )),
        color: .black
      )
    case .pen(let value):
      return InlineWritingConfiguration(
        effect: .pen(try .init(seed: value.seed, coverage: value.coverage, dotScale: value.dotScale)),
        color: .black
      )
    case .ink(let value):
      return InlineWritingConfiguration(
        effect: .ink(try .init(
          seed: value.seed,
          coverage: value.coverage,
          bleed: value.bleed,
          pooling: value.pooling
        )),
        color: .black
      )
    case .marker(let value):
      return InlineWritingConfiguration(
        effect: .marker(try .init(
          seed: value.seed, coverage: value.coverage, bleed: value.bleed
        )),
        color: .chalkPink
      )
    case .knockout(let value):
      return InlineWritingConfiguration(
        effect: .knockout(try .init(seed: value.seed, edgeSoftness: value.edgeSoftness)),
        color: nil
      )
    case .none:
      return .default
    }
  }

  private func makeFixture() throws -> Fixture {
    let textStyle = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica-Bold", pointSize: 21)
    )
    let openID = try InlineAssetID(rawValue: "material-open-line")
    let starID = try InlineAssetID(rawValue: "material-star")
    let openMetrics = try InlineMetrics(advance: 116, ascent: 32, descent: 4)
    let starMetrics = try InlineMetrics(advance: 36, ascent: 36, descent: 0)
    let openPath = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 22)),
      .quadratic(
        control: try InlinePathPoint(x: 29, y: 3),
        to: try InlinePathPoint(x: 58, y: 22)
      ),
      .quadratic(
        control: try InlinePathPoint(x: 87, y: 41),
        to: try InlinePathPoint(x: 116, y: 22)
      ),
    ])
    let open = try InlineSVGAsset(
      id: openID,
      metrics: openMetrics,
      coordinateBounds: openPath.bounds,
      coveragePath: openPath,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: openPath,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let starPath = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 18, y: 0)),
      .line(try InlinePathPoint(x: 22, y: 13)),
      .line(try InlinePathPoint(x: 36, y: 18)),
      .line(try InlinePathPoint(x: 22, y: 23)),
      .line(try InlinePathPoint(x: 18, y: 36)),
      .line(try InlinePathPoint(x: 14, y: 23)),
      .line(try InlinePathPoint(x: 0, y: 18)),
      .line(try InlinePathPoint(x: 14, y: 13)),
      .close,
    ])
    let star = try InlineSVGAsset(
      id: starID,
      metrics: starMetrics,
      coordinateBounds: starPath.bounds,
      coveragePath: starPath,
      coveragePaint: .fill(.nonZero),
      trajectoryPath: starPath,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let atoms: [InlineAtom] = [
      .text(try InlineTextAtom(id: "material-text", text: "Material", style: textStyle)),
      .vector(try InlineVectorAtom(id: "material-open", assetID: openID, metrics: openMetrics)),
      .vector(try InlineVectorAtom(id: "material-star", assetID: starID, metrics: starMetrics)),
    ]
    let document = try InlineDocument(atoms: atoms)
    let prepared = try InlinePreparation().prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 300)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let provider = EmptyProvider(assets: [
      InlineAssetKey(id: openID, version: open.version): open,
      InlineAssetKey(id: starID, version: star.version): star,
    ])
    let swift = try InlineSwiftUIRenderContent(plan: plan, assets: provider)
    let canvas = try InlineCanvasRenderContent(plan: plan, assets: provider)
    let viewport = try InlineRenderViewport(
      x: 0,
      y: 0,
      width: max(1, layout.width),
      height: max(52, layout.height)
    )
    let positioned = layout.lines.flatMap(\.atoms)
    var rois: [String: CGRect] = [:]
    for (name, value) in [
      ("text", positioned.first { $0.atomID == "material-text" }),
      ("openPath", positioned.first { $0.atomID == "material-open" }),
      ("closedShape", positioned.first { $0.atomID == "material-star" }),
    ] {
      guard let value else { continue }
      let rect = CGRect(
        x: value.originX,
        y: value.baselineY - value.metrics.baselineOffset - value.metrics.ascent,
        width: value.width,
        height: value.height
      )
      rois[name] = rect.insetBy(dx: -2, dy: -2)
    }
    return Fixture(
      swift: swift,
      canvas: canvas,
      viewport: viewport,
      size: CGSize(width: viewport.width, height: viewport.height),
      rois: rois
    )
  }

  private func render<Content: View>(
    _ content: Content,
    size: CGSize,
    scale: Int = 1
  ) throws -> CGImage {
    let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
    renderer.scale = CGFloat(scale)
    guard let image = renderer.cgImage else {
      throw XCTSkip("SwiftUI ImageRenderer did not produce a CGImage")
    }
    return image
  }

  private func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
      data: &bytes,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return [] }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
  }

  private func measure(
    _ image: CGImage,
    material: String,
    adapter: String,
    roi: String,
    scale: Int,
    region: CGRect,
    background: CGImage
  ) -> Metric {
    let bytes = rgba(image)
    let backgroundBytes = rgba(background)
    guard image.width == background.width, image.height == background.height,
      backgroundBytes.count == bytes.count, !bytes.isEmpty
    else {
      return Metric(
        material: material,
        adapter: adapter,
        roi: roi,
        scale: scale,
        width: image.width,
        height: image.height,
        foregroundPixels: 0,
        coverage: 0,
        meanStrength: 0,
        strengthStandardDeviation: 0,
        edgeStepRMS: 0,
        directionalSignal: 0,
        haloRatio: 0,
        textureFrequency: 0,
        medianThickness: 0,
        p10Thickness: 0,
        p90Thickness: 0,
        terminalThickness: 0,
        middleThickness: 0,
        boundingBox: [0, 0, 0, 0],
        targetInteriorPixels: 0,
        targetInteriorStrengthStandardDeviation: 0,
        targetInteriorTextureFrequency: 0,
        edgeBandPixels: 0,
        edgeBandStrengthStandardDeviation: 0,
        edgeBandTextureFrequency: 0
      )
    }
    let pixelRegion = pixelRegion(
      region,
      scale: scale,
      width: image.width,
      height: image.height
    )
    var values: [(x: Int, y: Int, strength: Double)] = []
    var minX = pixelRegion.maxX
    var minY = pixelRegion.maxY
    var maxX = -1
    var maxY = -1
    for y in pixelRegion.minY..<pixelRegion.maxY {
      for x in pixelRegion.minX..<pixelRegion.maxX {
        let offset = (y * image.width + x) * 4
        let backgroundOffset = (y * background.width + x) * 4
        let red = (Double(bytes[offset]) - Double(backgroundBytes[backgroundOffset])) / 255
        let green = (Double(bytes[offset + 1]) - Double(backgroundBytes[backgroundOffset + 1])) / 255
        let blue = (Double(bytes[offset + 2]) - Double(backgroundBytes[backgroundOffset + 2])) / 255
        let strength = sqrt((red * red + green * green + blue * blue) / 3)
        guard strength > 0.035 else { continue }
        values.append((x, y, strength))
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    let strengths = values.map(\.strength)
    let mean = strengths.reduce(0, +) / Double(max(1, strengths.count))
    let variance = strengths.reduce(0) { partial, value in
      partial + (value - mean) * (value - mean)
    } / Double(max(1, strengths.count))
    var edgeSquares: [Double] = []
    if pixelRegion.width > 1 {
      for y in pixelRegion.minY..<pixelRegion.maxY {
        for x in (pixelRegion.minX + 1)..<pixelRegion.maxX {
          let left = Self.pixelStrength(
            bytes: bytes,
            background: backgroundBytes,
            image: image,
            x: x - 1,
            y: y
          )
          let right = Self.pixelStrength(
            bytes: bytes,
            background: backgroundBytes,
            image: image,
            x: x,
            y: y
          )
          edgeSquares.append((right - left) * (right - left))
        }
      }
    }
    let edgeRMS = sqrt(edgeSquares.reduce(0, +) / Double(max(1, edgeSquares.count)))
    let textureFeatures = gradientFeatures(
      bytes: bytes,
      background: backgroundBytes,
      image: image,
      region: pixelRegion
    )
    let bands = surfaceBandMetrics(
      bytes: bytes,
      background: backgroundBytes,
      image: image,
      region: pixelRegion
    )
    let bboxWidth = max(1, maxX - minX + 1)
    let bboxHeight = max(1, maxY - minY + 1)
    let thicknessByColumn = columnThicknesses(
      bytes: bytes,
      background: backgroundBytes,
      image: image,
      region: pixelRegion,
      scale: scale
    )
    let thicknesses = thicknessByColumn.map(\.value)
    let activeColumns = thicknessByColumn.map(\.x)
    let activeMinX = activeColumns.min() ?? pixelRegion.minX
    let activeMaxX = activeColumns.max() ?? activeMinX
    let activeWidth = max(1, activeMaxX - activeMinX)
    let middleMinX = Double(activeMinX) + Double(activeWidth) * 0.40
    let middleMaxX = Double(activeMinX) + Double(activeWidth) * 0.60
    let middleThickness = percentile(
      thicknessByColumn
        .filter { Double($0.x) >= middleMinX && Double($0.x) <= middleMaxX }
        .map(\.value),
      0.50
    )
    let terminalThickness = percentile(
      thicknessByColumn
        // Keep this ROI statistic terminal-local. A last-tenth median can
        // hide a short but intentional tapered tip on a partially revealed
        // command because most of that tenth is still body width.
        .filter { $0.x >= activeMaxX - max(1, activeWidth / 40) }
      .map(\.value),
      0.50
    )
    return Metric(
      material: material,
      adapter: adapter,
      roi: roi,
      scale: scale,
      width: image.width,
      height: image.height,
      foregroundPixels: values.count,
      coverage: Double(values.count) / Double(bboxWidth * bboxHeight),
      meanStrength: mean,
      strengthStandardDeviation: sqrt(variance),
      edgeStepRMS: edgeRMS,
      directionalSignal: textureFeatures.directionalSignal,
      haloRatio: textureFeatures.haloRatio,
      textureFrequency: textureFeatures.textureFrequency,
      medianThickness: percentile(thicknesses, 0.50),
      p10Thickness: percentile(thicknesses, 0.10),
      p90Thickness: percentile(thicknesses, 0.90),
      terminalThickness: terminalThickness,
      middleThickness: middleThickness,
      boundingBox: [minX, minY, maxX, maxY],
      targetInteriorPixels: bands.interior.pixels,
      targetInteriorStrengthStandardDeviation: bands.interior.strengthStandardDeviation,
      targetInteriorTextureFrequency: bands.interior.textureFrequency,
      edgeBandPixels: bands.edge.pixels,
      edgeBandStrengthStandardDeviation: bands.edge.strengthStandardDeviation,
      edgeBandTextureFrequency: bands.edge.textureFrequency
    )
  }

  private func surfaceBandMetrics(
    bytes: [UInt8],
    background: [UInt8],
    image: CGImage,
    region: (minX: Int, minY: Int, maxX: Int, maxY: Int, width: Int, height: Int)
  ) -> (interior: SurfaceBandMetrics, edge: SurfaceBandMetrics) {
    guard region.width > 0, region.height > 0 else {
      return (.empty, .empty)
    }
    let count = region.width * region.height
    var strengths = [Double](repeating: 0, count: count)
    var foreground = [Bool](repeating: false, count: count)
    for y in region.minY..<region.maxY {
      for x in region.minX..<region.maxX {
        let local = (y - region.minY) * region.width + (x - region.minX)
        let value = Self.pixelStrength(
          bytes: bytes,
          background: background,
          image: image,
          x: x,
          y: y
        )
        strengths[local] = value
        foreground[local] = value > 0.035
      }
    }

    // Erode the measured foreground by a bounded radius. The surviving core
    // is the target interior; everything else is the edge band. A fixed
    // radius in high-resolution pixels avoids treating the board or the
    // antialiased ROI boundary as chalk texture.
    let radius = max(2, min(6, min(region.width, region.height) / 24))
    var interiorMask = [Bool](repeating: false, count: count)
    var edgeMask = [Bool](repeating: false, count: count)
    for y in 0..<region.height {
      for x in 0..<region.width {
        let local = y * region.width + x
        guard foreground[local] else { continue }
        var isInterior = true
        for offsetY in -radius...radius where isInterior {
          for offsetX in -radius...radius {
            let neighborX = x + offsetX
            let neighborY = y + offsetY
            guard neighborX >= 0, neighborX < region.width,
              neighborY >= 0, neighborY < region.height,
              foreground[neighborY * region.width + neighborX]
            else {
              isInterior = false
              break
            }
          }
        }
        if isInterior {
          interiorMask[local] = true
        } else {
          edgeMask[local] = true
        }
      }
    }

    func summarize(_ mask: [Bool]) -> SurfaceBandMetrics {
      let selected = mask.indices.filter { mask[$0] }
      guard !selected.isEmpty else { return .empty }
      let values = selected.map { strengths[$0] }
      let mean = values.reduce(0, +) / Double(values.count)
      let variance = values.reduce(0) { partial, value in
        partial + (value - mean) * (value - mean)
      } / Double(values.count)
      var transitions = 0
      var comparisons = 0
      for y in 0..<region.height {
        for x in 0..<region.width {
          let local = y * region.width + x
          guard mask[local] else { continue }
          if x + 1 < region.width, mask[local + 1] {
            comparisons += 1
            if abs(strengths[local + 1] - strengths[local]) > 0.08 {
              transitions += 1
            }
          }
          if y + 1 < region.height, mask[local + region.width] {
            comparisons += 1
            if abs(strengths[local + region.width] - strengths[local]) > 0.08 {
              transitions += 1
            }
          }
        }
      }
      return SurfaceBandMetrics(
        pixels: values.count,
        strengthStandardDeviation: sqrt(variance),
        textureFrequency: Double(transitions) / Double(max(1, comparisons))
      )
    }

    return (summarize(interiorMask), summarize(edgeMask))
  }

  private func pixelRegion(
    _ region: CGRect,
    scale: Int,
    width: Int,
    height: Int
  ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, width: Int, height: Int) {
    let scaledMinX = max(0, Int(floor(region.minX * CGFloat(scale))))
    let scaledMaxX = min(width, Int(ceil(region.maxX * CGFloat(scale))))
    let scaledMinY = max(0, Int(floor(region.minY * CGFloat(scale))))
    let scaledMaxY = min(height, Int(ceil(region.maxY * CGFloat(scale))))
    return (
      minX: min(scaledMinX, scaledMaxX),
      minY: min(scaledMinY, scaledMaxY),
      maxX: max(scaledMinX, scaledMaxX),
      maxY: max(scaledMinY, scaledMaxY),
      width: max(0, scaledMaxX - scaledMinX),
      height: max(0, scaledMaxY - scaledMinY)
    )
  }

  /// Returns renderer-neutral texture diagnostics for a background-aware ROI.
  /// Direction is the normalized horizontal/vertical gradient imbalance;
  /// frequency is the fraction of gradients above a fixed perceptual step;
  /// halo is the low-strength fringe adjacent to foreground pixels. These are
  /// deliberately diagnostic features, not a pixel-similarity score.
  private func gradientFeatures(
    bytes: [UInt8],
    background: [UInt8],
    image: CGImage,
    region: (minX: Int, minY: Int, maxX: Int, maxY: Int, width: Int, height: Int)
  ) -> (directionalSignal: Double, haloRatio: Double, textureFrequency: Double) {
    guard region.width > 0, region.height > 0 else {
      return (0, 0, 0)
    }
    let count = region.width * region.height
    var strengths = [Double](repeating: 0, count: count)
    var foreground = [Bool](repeating: false, count: count)
    for y in region.minY..<region.maxY {
      for x in region.minX..<region.maxX {
        let local = (y - region.minY) * region.width + (x - region.minX)
        let value = Self.pixelStrength(
          bytes: bytes,
          background: background,
          image: image,
          x: x,
          y: y
        )
        strengths[local] = value
        foreground[local] = value > 0.035
      }
    }

    var horizontalTotal = 0.0
    var verticalTotal = 0.0
    var gradientCount = 0
    var highGradientCount = 0
    for y in 0..<region.height {
      for x in 0..<region.width {
        let local = y * region.width + x
        if x > 0 {
          let gradient = abs(strengths[local] - strengths[local - 1])
          horizontalTotal += gradient
          gradientCount += 1
          if gradient > 0.08 { highGradientCount += 1 }
        }
        if y > 0 {
          let gradient = abs(strengths[local] - strengths[local - region.width])
          verticalTotal += gradient
          gradientCount += 1
          if gradient > 0.08 { highGradientCount += 1 }
        }
      }
    }
    let horizontalMean = horizontalTotal / Double(max(1, region.height * max(0, region.width - 1)))
    let verticalMean = verticalTotal / Double(max(1, region.width * max(0, region.height - 1)))
    let directionalSignal = abs(horizontalMean - verticalMean)
      / max(1.0e-9, horizontalMean + verticalMean)

    var haloPixels = 0
    var foregroundPixels = 0
    if region.width > 2, region.height > 2 {
      for y in 1..<(region.height - 1) {
        for x in 1..<(region.width - 1) {
          let local = y * region.width + x
          if foreground[local] {
            continue
          }
          guard strengths[local] > 0.01, strengths[local] <= 0.035 else { continue }
          var touchesForeground = false
          for offsetY in -1...1 where !touchesForeground {
            for offsetX in -1...1 {
              let neighbor = (y + offsetY) * region.width + (x + offsetX)
              if foreground[neighbor] {
                touchesForeground = true
                break
              }
            }
          }
          if touchesForeground { haloPixels += 1 }
        }
      }
      // Count foreground pixels separately from the halo traversal so the
      // ratio remains stable when the loop encounters low-strength pixels.
      foregroundPixels = foreground.reduce(into: 0) { count, isForeground in
        if isForeground { count += 1 }
      }
    } else {
      foregroundPixels = foreground.reduce(into: 0) { count, isForeground in
        if isForeground { count += 1 }
      }
    }
    return (
      directionalSignal: directionalSignal.isFinite ? directionalSignal : 0,
      haloRatio: Double(haloPixels) / Double(max(1, foregroundPixels)),
      textureFrequency: Double(highGradientCount) / Double(max(1, gradientCount))
    )
  }

  private func columnThicknesses(
    bytes: [UInt8],
    background: [UInt8],
    image: CGImage,
    region: (minX: Int, minY: Int, maxX: Int, maxY: Int, width: Int, height: Int),
    scale: Int
  ) -> [(x: Int, value: Double)] {
    guard region.width > 0, region.height > 0 else { return [] }
    var result: [(x: Int, value: Double)] = []
    for x in region.minX..<region.maxX {
      var current = 0
      var longest = 0
      for y in region.minY..<region.maxY {
        let strength = Self.pixelStrength(
          bytes: bytes,
          background: background,
          image: image,
          x: x,
          y: y
        )
        if strength > 0.035 {
          current += 1
          longest = max(longest, current)
        } else {
          current = 0
        }
      }
      if longest > 0 {
        result.append((x: x, value: Double(longest) / Double(max(1, scale))))
      }
    }
    return result
  }

  private func thicknessNear(
    _ profile: [(x: Int, value: Double)],
    x: Int,
    radius: Int = 1
  ) -> Double? {
    let values = profile
      .filter { abs($0.x - x) <= radius }
      .map(\.value)
    guard !values.isEmpty else { return nil }
    return percentile(values, 0.50)
  }

  private func horizontalForegroundRuns(
    bytes: [UInt8],
    background: [UInt8],
    image: CGImage,
    y: Int,
    region: (minX: Int, minY: Int, maxX: Int, maxY: Int, width: Int, height: Int)
  ) -> [(x: Int, width: Int)] {
    guard region.width > 0, region.height > 0,
      y >= region.minY, y < region.maxY
    else { return [] }
    var result: [(x: Int, width: Int)] = []
    var start: Int?
    for x in region.minX..<region.maxX {
      let active = Self.pixelStrength(
        bytes: bytes,
        background: background,
        image: image,
        x: x,
        y: y
      ) > 0.035
      if active, start == nil {
        start = x
      } else if !active, let activeStart = start {
        result.append((x: activeStart, width: x - activeStart))
        // The optional binding is scoped to this branch; reset explicitly
        // before the next foreground run.
        start = nil
      }
    }
    if let start {
      result.append((x: start, width: region.maxX - start))
    }
    return result
  }

  private func tileRenderBackSeamGradients(
    image: CGImage,
    background: CGImage,
    documentXSeams: [Double],
    documentYSeams: [Double],
    viewport: InlineRenderViewport,
    scale: Int,
    region: CGRect
  ) -> (seam: [Double], interior: [Double]) {
    let imageBytes = rgba(image)
    let backgroundBytes = rgba(background)
    let pixels = pixelRegion(
      region,
      scale: scale,
      width: image.width,
      height: image.height
    )
    guard imageBytes.count == backgroundBytes.count,
      pixels.width > 1,
      pixels.height > 0
    else {
      return ([], [])
    }
    let seamXPixels = documentXSeams.map {
      Int(round(($0 - viewport.x) * Double(scale)))
    }
    let seamYPixels = documentYSeams.map {
      Int(round(($0 - viewport.y) * Double(scale)))
    }
    var seam: [Double] = []
    var interior: [Double] = []
    seam.reserveCapacity((seamXPixels.count + seamYPixels.count) * pixels.height)
    interior.reserveCapacity(pixels.width * pixels.height)
    for y in pixels.minY..<pixels.maxY {
      for x in pixels.minX..<(pixels.maxX - 1) {
        let left = Self.pixelStrength(
          bytes: imageBytes,
          background: backgroundBytes,
          image: image,
          x: x,
          y: y
        )
        let right = Self.pixelStrength(
          bytes: imageBytes,
          background: backgroundBytes,
          image: image,
          x: x + 1,
          y: y
        )
        guard max(left, right) > 0.035 else { continue }
        let gradient = abs(right - left)
        if seamXPixels.contains(where: { abs($0 - (x + 1)) <= 1 }) {
          seam.append(gradient)
        } else if seamXPixels.allSatisfy({ abs($0 - (x + 1)) > 3 }) {
          interior.append(gradient)
        }
      }
    }
    if pixels.height > 1 {
      for y in pixels.minY..<(pixels.maxY - 1) {
        for x in pixels.minX..<pixels.maxX {
          let top = Self.pixelStrength(
            bytes: imageBytes,
            background: backgroundBytes,
            image: image,
            x: x,
            y: y
          )
          let bottom = Self.pixelStrength(
            bytes: imageBytes,
            background: backgroundBytes,
            image: image,
            x: x,
            y: y + 1
          )
          guard max(top, bottom) > 0.035 else { continue }
          let gradient = abs(bottom - top)
          if seamYPixels.contains(where: { abs($0 - (y + 1)) <= 1 }) {
            seam.append(gradient)
          } else if seamYPixels.allSatisfy({ abs($0 - (y + 1)) > 3 }) {
            interior.append(gradient)
          }
        }
      }
    }
    return (seam, interior)
  }

  private static func pixelStrength(
    bytes: [UInt8],
    background: [UInt8],
    image: CGImage,
    x: Int,
    y: Int
  ) -> Double {
    guard image.width > 0, image.height > 0, !background.isEmpty else { return 0 }
    let offset = (y * image.width + x) * 4
    guard background.count == image.width * image.height * 4 else { return 0 }
    let backgroundOffset = (y * image.width + x) * 4
    let red = (Double(bytes[offset]) - Double(background[backgroundOffset])) / 255
    let green = (Double(bytes[offset + 1]) - Double(background[backgroundOffset + 1])) / 255
    let blue = (Double(bytes[offset + 2]) - Double(background[backgroundOffset + 2])) / 255
    return sqrt((red * red + green * green + blue * blue) / 3)
  }

  private func meanAbsoluteDifference(
    _ first: CGImage,
    _ second: CGImage,
    region: CGRect? = nil,
    scale: Int = 1
  ) -> Double {
    guard first.width == second.width, first.height == second.height else { return 1 }
    let a = rgba(first)
    let b = rgba(second)
    guard a.count == b.count, !a.isEmpty else { return 1 }
    let region = region.map {
      pixelRegion($0, scale: scale, width: first.width, height: first.height)
    } ?? (minX: 0, minY: 0, maxX: first.width, maxY: first.height,
      width: first.width, height: first.height)
    var total = 0.0
    var pixelCount = 0
    for y in region.minY..<region.maxY {
      for x in region.minX..<region.maxX {
        let index = (y * first.width + x) * 4
        total += abs(Double(a[index]) - Double(b[index]))
        total += abs(Double(a[index + 1]) - Double(b[index + 1]))
        total += abs(Double(a[index + 2]) - Double(b[index + 2]))
        pixelCount += 1
      }
    }
    return total / Double(max(1, pixelCount) * 3 * 255)
  }

  private func assertScaleStability(
    _ metrics: [Metric],
    material: String,
    roi: String
  ) {
    let values = metrics.filter {
      $0.material == material && $0.roi == roi && $0.adapter == "SwiftUI"
    }.sorted { $0.scale < $1.scale }
    guard values.count == 3 else {
      XCTFail("missing 1x/2x/3x metrics for \(material)/\(roi)")
      return
    }
    let coverages = values.map(\.coverage)
    let thicknesses = values.map(\.medianThickness)
    let coverageRange = (coverages.max() ?? 0) - (coverages.min() ?? 0)
    let thicknessMaximum = thicknesses.max() ?? 0
    let thicknessMinimum = thicknesses.min() ?? 0
    XCTAssertLessThan(
      coverageRange,
      0.22,
      "coverage drifted across scales for \(material)/\(roi): \(coverages)"
    )
    XCTAssertGreaterThan(
      thicknessMinimum / max(0.001, thicknessMaximum),
      0.25,
      "thickness became unstable across scales for \(material)/\(roi): \(thicknesses)"
    )
  }

  /// Unit-level check of the RGBA byte plan: render two copies of the tile in
  /// both axes and measure adjacent samples at the x/y joins. This does not
  /// replace the adapter render-back seam test below; it catches a broken
  /// periodic recipe before platform image sampling is involved.
  private func twoByTwoSeamGradients(
    _ plan: WritingMaterialTexturePlan
  ) -> (seam: [Double], interior: [Double]) {
    let dimension = plan.dimension
    guard dimension > 1 else { return ([], []) }
    let doubled = dimension * 2
    var repeated = [Double](repeating: 0, count: doubled * doubled)
    for y in 0..<doubled {
      for x in 0..<doubled {
        repeated[y * doubled + x] = textureAlpha(
          plan,
          x: x % dimension,
          y: y % dimension
        )
      }
    }

    var seam: [Double] = []
    var interior: [Double] = []
    seam.reserveCapacity(doubled * 2)
    interior.reserveCapacity(doubled * max(0, doubled - 2) * 2)
    // The joins at x == dimension - 1 -> dimension and
    // y == dimension - 1 -> dimension are the seams in the repeated field.
    for y in 0..<doubled {
      for x in 0..<(doubled - 1) {
        let difference = abs(
          repeated[y * doubled + x + 1] - repeated[y * doubled + x]
        )
        if x == dimension - 1 {
          seam.append(difference)
        } else {
          interior.append(difference)
        }
      }
    }
    for y in 0..<(doubled - 1) {
      for x in 0..<doubled {
        let difference = abs(
          repeated[(y + 1) * doubled + x] - repeated[y * doubled + x]
        )
        if y == dimension - 1 {
          seam.append(difference)
        } else {
          interior.append(difference)
        }
      }
    }
    return (seam, interior)
  }

  private func textureAlpha(
    _ plan: WritingMaterialTexturePlan,
    x: Int,
    y: Int
  ) -> Double {
    let index = (y * plan.dimension + x) * 4 + 3
    return Double(plan.pixels[index]) / 255
  }

  private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let position = min(
      sorted.count - 1,
      max(0, Int((Double(sorted.count - 1) * fraction).rounded()))
    )
    return sorted[position]
  }

  private func writePNG(_ image: CGImage, name: String) {
    let url = artifactURL(name)
    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    _ = CGImageDestinationFinalize(destination)
  }

  private func writeJSON<T: Encodable>(_ value: T, name: String) {
    guard let data = try? JSONEncoder.pretty.encode(value) else { return }
    try? data.write(to: artifactURL(name), options: .atomic)
  }

  private func artifactURL(_ name: String) -> URL {
    let environment = ProcessInfo.processInfo.environment
    let root: URL
    if let configuredRoot = environment["LIVETEXT_ARTIFACT_DIR"], !configuredRoot.isEmpty {
      root = URL(fileURLWithPath: configuredRoot, isDirectory: true)
    } else {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LiveTextMaterialReference", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent(name)
  }

  private func externalReferenceManifest(
    candidateMetrics: [Metric]
  ) -> ExternalReferenceManifest {
    let environment = ProcessInfo.processInfo.environment
    let configuredPath = environment["LIVETEXT_MATERIAL_REFERENCE_DIR"]
      ?? environment["LIVETEXT_REFERENCE_DIR"]
    guard let configuredPath, !configuredPath.isEmpty else {
      return ExternalReferenceManifest(
        status: "[NOT_PROVEN] external reference directory not configured",
        directory: nil,
        digestSHA256: nil,
        files: [],
        featureMetrics: [],
        comparisons: []
      )
    }
    let root = URL(fileURLWithPath: configuredPath, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return ExternalReferenceManifest(
        status: "[NOT_PROVEN] configured external reference directory is unavailable",
        directory: configuredPath,
        digestSHA256: nil,
        files: [],
        featureMetrics: [],
        comparisons: []
      )
    }
    let urls = (try? FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ))?.filter { url in
      ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased())
    }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    guard !urls.isEmpty else {
      return ExternalReferenceManifest(
        status: "[NOT_PROVEN] external reference directory contains no supported images",
        directory: configuredPath,
        digestSHA256: nil,
        files: [],
        featureMetrics: [],
        comparisons: []
      )
    }

    var hasher = SHA256()
    var files: [ExternalReferenceFile] = []
    var featureMetrics: [ExternalReferenceFeature] = []
    for url in urls {
      guard let data = try? Data(contentsOf: url) else { continue }
      hasher.update(data: Data(url.lastPathComponent.utf8))
      hasher.update(data: data)
      files.append(ExternalReferenceFile(
        name: url.lastPathComponent,
        byteCount: data.count
      ))
      if let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let feature = externalFeature(image, name: url.lastPathComponent)
      {
        featureMetrics.append(feature)
      }
    }
    guard !files.isEmpty else {
      return ExternalReferenceManifest(
        status: "[NOT_PROVEN] external reference files could not be read",
        directory: configuredPath,
        digestSHA256: nil,
        files: [],
        featureMetrics: [],
        comparisons: []
      )
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return ExternalReferenceManifest(
      status: "[MEASURED_EXTERNAL_INPUT] feature metrics recorded; visual alignment remains unproven",
      directory: configuredPath,
      digestSHA256: digest,
      files: files,
      featureMetrics: featureMetrics,
      comparisons: externalComparisons(
        files: files,
        references: featureMetrics,
        candidateMetrics: candidateMetrics
      )
    )
  }

  /// Maps the six supplied reference captures by their stable timestamped
  /// names. The mapping is intentionally explicit: no automatic crop or
  /// semantic classifier is used to manufacture a comparison.
  private func externalContract(for name: String) -> ExternalReferenceContract? {
    let lowercased = name.lowercased()
    if lowercased.contains("10.18.50") {
      return ExternalReferenceContract(
        material: "colored-pencil",
        features: [
          "coverage", "strengthStandardDeviation", "medianThickness",
          "directionalSignal", "textureFrequency",
        ]
      )
    }
    if lowercased.contains("10.18.58") {
      return ExternalReferenceContract(
        material: "pen",
        features: ["medianThickness", "p10Thickness", "p90Thickness", "edgeStepRMS"]
      )
    }
    if lowercased.contains("10.19.09") || lowercased.contains("10.20.13") {
      return ExternalReferenceContract(
        material: "brush",
        features: ["coverage", "strengthStandardDeviation", "edgeStepRMS", "medianThickness"]
      )
    }
    if lowercased.contains("10.19.39") {
      return ExternalReferenceContract(
        material: "chalk",
        features: [
          "coverage", "strengthStandardDeviation", "edgeStepRMS",
          "haloRatio", "textureFrequency",
        ]
      )
    }
    if lowercased.contains("10.21.09") {
      return ExternalReferenceContract(
        material: "ink",
        features: [
          "coverage", "strengthStandardDeviation", "edgeStepRMS",
          "haloRatio", "textureFrequency",
        ]
      )
    }
    return nil
  }

  private func externalComparisons(
    files: [ExternalReferenceFile],
    references: [ExternalReferenceFeature],
    candidateMetrics: [Metric]
  ) -> [ExternalReferenceComparison] {
    let knownMaterials = ["chalk", "colored-pencil", "brush", "pen", "ink"]
    var comparisons: [ExternalReferenceComparison] = []
    for material in knownMaterials {
      let referenceNames = files.map(\.name).filter {
        externalContract(for: $0)?.material == material
      }
      guard !referenceNames.isEmpty else { continue }
      let referenceValues = references.filter { referenceNames.contains($0.name) }
      let contract = externalContract(for: referenceNames[0])!
      let candidates = candidateMetrics.filter {
        $0.material == material && $0.adapter == "SwiftUI"
          && $0.roi == "text" && $0.scale == 1
      }
      let referenceMean = meanReferenceFeatures(referenceValues, names: contract.features)
      let candidateMean = meanCandidateFeatures(candidates, names: contract.features)
      let comparable = contract.features.filter {
        referenceMean[$0] != nil && candidateMean[$0] != nil
      }
      let deltas = Dictionary(uniqueKeysWithValues: comparable.map { name in
        (name, abs((referenceMean[name] ?? 0) - (candidateMean[name] ?? 0)))
      })
      let status: String
      if referenceValues.isEmpty {
        status = "[NOT_PROVEN] reference image could not be decoded"
      } else if candidates.isEmpty {
        status = "[NOT_PROVEN] candidate SwiftUI/text/1x ROI is unavailable"
      } else if comparable.isEmpty {
        status = "[NOT_PROVEN] no common normalized feature values"
      } else {
        status = "[NOT_PROVEN] normalized diagnostic deltas recorded; content/crop differ; no SSIM or pixel-equivalence claim"
      }
      comparisons.append(ExternalReferenceComparison(
        material: material,
        referenceFiles: referenceNames,
        candidateAdapter: candidates.isEmpty ? nil : "SwiftUI",
        candidateROI: candidates.isEmpty ? nil : "text/1x",
        comparableFeatures: comparable,
        referenceMean: referenceMean,
        candidateMean: candidateMean,
        absoluteDelta: deltas,
        status: status
      ))
    }

    for file in files where externalContract(for: file.name) == nil {
      comparisons.append(ExternalReferenceComparison(
        material: "unmapped",
        referenceFiles: [file.name],
        candidateAdapter: nil,
        candidateROI: nil,
        comparableFeatures: [],
        referenceMean: [:],
        candidateMean: [:],
        absoluteDelta: [:],
        status: "[NOT_PROVEN] unrecognized reference filename; automatic crop/material mapping was not attempted"
      ))
    }
    return comparisons
  }

  private func meanReferenceFeatures(
    _ references: [ExternalReferenceFeature],
    names: [String]
  ) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: names.compactMap { name in
      let values = references.compactMap { externalFeatureValue($0, name: name) }
      guard !values.isEmpty else { return nil }
      return (name, values.reduce(0, +) / Double(values.count))
    })
  }

  private func meanCandidateFeatures(
    _ candidates: [Metric],
    names: [String]
  ) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: names.compactMap { name in
      let values = candidates.compactMap { candidateFeatureValue($0, name: name) }
      guard !values.isEmpty else { return nil }
      return (name, values.reduce(0, +) / Double(values.count))
    })
  }

  private func externalFeatureValue(
    _ feature: ExternalReferenceFeature,
    name: String
  ) -> Double? {
    switch name {
    case "coverage": return feature.coverage
    case "strengthStandardDeviation": return feature.strengthStandardDeviation
    case "edgeStepRMS": return feature.edgeStepRMS
    case "medianThickness": return feature.medianThickness
    case "p10Thickness": return feature.p10Thickness
    case "p90Thickness": return feature.p90Thickness
    case "directionalSignal": return feature.directionalSignal
    case "haloRatio": return feature.haloRatio
    case "textureFrequency": return feature.textureFrequency
    default: return nil
    }
  }

  private func candidateFeatureValue(_ metric: Metric, name: String) -> Double? {
    switch name {
    case "coverage": return metric.coverage
    case "strengthStandardDeviation": return metric.strengthStandardDeviation
    case "edgeStepRMS": return metric.edgeStepRMS
    case "directionalSignal": return metric.directionalSignal
    case "haloRatio": return metric.haloRatio
    case "textureFrequency": return metric.textureFrequency
    case "medianThickness": return normalizedCandidateThickness(metric.medianThickness, metric)
    case "p10Thickness": return normalizedCandidateThickness(metric.p10Thickness, metric)
    case "p90Thickness": return normalizedCandidateThickness(metric.p90Thickness, metric)
    default: return nil
    }
  }

  private func normalizedCandidateThickness(_ value: Double, _ metric: Metric) -> Double {
    guard metric.boundingBox.count >= 4 else { return 0 }
    let width = max(1, metric.boundingBox[2] - metric.boundingBox[0] + 1)
    let height = max(1, metric.boundingBox[3] - metric.boundingBox[1] + 1)
    let scale = Double(max(1, metric.scale))
    let minorDimension = Double(min(width, height)) / scale
    return value / max(1, minorDimension)
  }

  private func externalFeature(
    _ image: CGImage,
    name: String
  ) -> ExternalReferenceFeature? {
    let bytes = rgba(image)
    guard image.width > 0, image.height > 0,
      bytes.count == image.width * image.height * 4
    else { return nil }
    var background = [Double](repeating: 0, count: 3)
    var sampleCount = 0
    for y in 0..<image.height {
      for x in 0..<image.width where x < 2 || x >= image.width - 2
        || y < 2 || y >= image.height - 2
      {
        let index = (y * image.width + x) * 4
        background[0] += Double(bytes[index])
        background[1] += Double(bytes[index + 1])
        background[2] += Double(bytes[index + 2])
        sampleCount += 1
      }
    }
    guard sampleCount > 0 else { return nil }
    background = background.map { $0 / Double(sampleCount) }
    let pixelCount = image.width * image.height
    var strengthGrid = [Double](repeating: 0, count: pixelCount)
    var strengths: [Double] = []
    var minX = image.width
    var minY = image.height
    var maxX = -1
    var maxY = -1
    for y in 0..<image.height {
      for x in 0..<image.width {
        let index = (y * image.width + x) * 4
        let red = (Double(bytes[index]) - background[0]) / 255
        let green = (Double(bytes[index + 1]) - background[1]) / 255
        let blue = (Double(bytes[index + 2]) - background[2]) / 255
        let strength = sqrt((red * red + green * green + blue * blue) / 3)
        strengthGrid[y * image.width + x] = strength
        guard strength > 0.035 else { continue }
        strengths.append(strength)
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    let emptyFeature = ExternalReferenceFeature(
      name: name,
      width: image.width,
      height: image.height,
      foregroundPixels: 0,
      coverage: 0,
      strengthStandardDeviation: 0,
      edgeStepRMS: 0,
      medianThickness: 0,
      p10Thickness: 0,
      p90Thickness: 0,
      directionalSignal: 0,
      haloRatio: 0,
      textureFrequency: 0
    )
    guard !strengths.isEmpty else { return emptyFeature }

    let mean = strengths.reduce(0, +) / Double(strengths.count)
    let variance = strengths.reduce(0) { partial, value in
      partial + (value - mean) * (value - mean)
    } / Double(strengths.count)
    var horizontalGradients: [Double] = []
    var verticalGradients: [Double] = []
    horizontalGradients.reserveCapacity(image.height * max(0, image.width - 1))
    verticalGradients.reserveCapacity(max(0, image.height - 1) * image.width)
    for y in 0..<image.height {
      for x in 1..<image.width {
        horizontalGradients.append(abs(
          strengthGrid[y * image.width + x]
            - strengthGrid[y * image.width + x - 1]
        ))
      }
    }
    for y in 1..<image.height {
      for x in 0..<image.width {
        verticalGradients.append(abs(
          strengthGrid[y * image.width + x]
            - strengthGrid[(y - 1) * image.width + x]
        ))
      }
    }
    let horizontalMean = horizontalGradients.reduce(0, +)
      / Double(max(1, horizontalGradients.count))
    let verticalMean = verticalGradients.reduce(0, +)
      / Double(max(1, verticalGradients.count))
    let directionalSignal = abs(horizontalMean - verticalMean)
      / max(1.0e-9, horizontalMean + verticalMean)
    let allGradients = horizontalGradients + verticalGradients
    let textureFrequency = Double(allGradients.filter { $0 > 0.08 }.count)
      / Double(max(1, allGradients.count))
    let edgeRMS = sqrt(horizontalGradients.reduce(0) { $0 + $1 * $1 }
      / Double(max(1, horizontalGradients.count)))

    var foreground = [Bool](repeating: false, count: pixelCount)
    for index in 0..<pixelCount {
      foreground[index] = strengthGrid[index] > 0.035
    }
    var haloPixels = 0
    if image.width > 2, image.height > 2 {
      for y in 1..<(image.height - 1) {
        for x in 1..<(image.width - 1) {
          let index = y * image.width + x
          guard !foreground[index], strengthGrid[index] > 0.01,
            strengthGrid[index] <= 0.035
          else { continue }
          var touchesForeground = false
          for offsetY in -1...1 where !touchesForeground {
            for offsetX in -1...1 {
              if foreground[(y + offsetY) * image.width + x + offsetX] {
                touchesForeground = true
                break
              }
            }
          }
          if touchesForeground { haloPixels += 1 }
        }
      }
    }

    let bboxWidth = max(1, maxX - minX + 1)
    let bboxHeight = max(1, maxY - minY + 1)
    let minorDimension = Double(max(1, min(bboxWidth, bboxHeight)))
    var thicknesses: [Double] = []
    for y in 0..<image.height {
      var current = 0
      var longest = 0
      for x in 0..<image.width {
        if foreground[y * image.width + x] {
          current += 1
          longest = max(longest, current)
        } else {
          current = 0
        }
      }
      if longest > 0 { thicknesses.append(Double(longest) / minorDimension) }
    }
    for x in 0..<image.width {
      var current = 0
      var longest = 0
      for y in 0..<image.height {
        if foreground[y * image.width + x] {
          current += 1
          longest = max(longest, current)
        } else {
          current = 0
        }
      }
      if longest > 0 { thicknesses.append(Double(longest) / minorDimension) }
    }
    return ExternalReferenceFeature(
      name: name,
      width: image.width,
      height: image.height,
      foregroundPixels: strengths.count,
      coverage: Double(strengths.count) / Double(bboxWidth * bboxHeight),
      strengthStandardDeviation: sqrt(variance),
      edgeStepRMS: edgeRMS,
      medianThickness: percentile(thicknesses, 0.50),
      p10Thickness: percentile(thicknesses, 0.10),
      p90Thickness: percentile(thicknesses, 0.90),
      directionalSignal: directionalSignal.isFinite ? directionalSignal : 0,
      haloRatio: Double(haloPixels) / Double(max(1, strengths.count)),
      textureFrequency: textureFrequency
    )
  }

  private func makeContactSheet(images: [(String, String, CGImage)]) throws -> CGImage {
    let cellWidth = images.map { $0.2.width }.max() ?? 1
    let cellHeight = images.map { $0.2.height }.max() ?? 1
    let columns = 2
    let rows = Int(ceil(Double(images.count) / Double(columns)))
    let width = cellWidth * columns
    let height = cellHeight * rows
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    guard let context = CGContext(
      data: &bytes,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw XCTSkip("Could not allocate material contact sheet")
    }
    context.setFillColor(CGColor(gray: 0.96, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (index, image) in images.enumerated() {
      let x = (index % columns) * cellWidth
      let y = (index / columns) * cellHeight
      context.draw(image.2, in: CGRect(x: x, y: y, width: image.2.width, height: image.2.height))
    }
    guard let result = context.makeImage() else {
      throw XCTSkip("Could not create material contact sheet")
    }
    return result
  }
}

private extension JSONEncoder {
  static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
