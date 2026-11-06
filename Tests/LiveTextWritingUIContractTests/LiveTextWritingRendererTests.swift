import CoreGraphics
import CoreText
import ChalkLineEffects
@testable import LiveTextWritingUI
import LiveTextCanvas
import LiveTextCore
import LiveTextAppleRendering
import LiveTextLayout
import LiveTextEffects
import LiveTextSwiftUI
import SwiftUI
import XCTest

@MainActor
final class LiveTextWritingRendererTests: XCTestCase {
  func testBrushPenAndInkConfigurationsRejectInvalidValues() {
    XCTAssertThrowsError(
      try InlineWritingConfiguration.BrushConfiguration(coverage: -0.1)
    ) { error in
      XCTAssertEqual(
        error as? WritingMaterialError,
        .invalidConfiguration(field: "coverage", value: -0.1)
      )
    }
    XCTAssertThrowsError(try InlineWritingConfiguration.PenConfiguration(dotScale: .infinity)) {
      error in
      XCTAssertEqual(
        error as? WritingMaterialError,
        .invalidConfiguration(field: "dotScale", value: .infinity)
      )
    }
    XCTAssertThrowsError(try InlineWritingConfiguration.InkConfiguration(bleed: -0.1)) { error in
      XCTAssertEqual(
        error as? WritingMaterialError,
        .invalidConfiguration(field: "bleed", value: -0.1)
      )
    }
    XCTAssertThrowsError(
      try WritingChalkConfiguration(grainAmount: 1.1)
    ) { error in
      XCTAssertEqual(
        error as? WritingMaterialError,
        .invalidConfiguration(field: "grainAmount", value: 1.1)
      )
    }
  }

  func testWritingPresetsAreDistinct() {
    let configurations = [
      InlineWritingConfiguration.chalk,
      InlineWritingConfiguration.brush,
      InlineWritingConfiguration.pen,
      InlineWritingConfiguration.ink,
    ]
    XCTAssertEqual(configurations.count, 4)
    XCTAssertNotEqual(configurations[0], configurations[1])
    XCTAssertNotEqual(configurations[1], configurations[2])
    XCTAssertNotEqual(configurations[2], configurations[3])
    for configuration in configurations {
      let decoded = try? JSONDecoder().decode(
        InlineWritingConfiguration.self,
        from: JSONEncoder().encode(configuration)
      )
      XCTAssertEqual(decoded, configuration)
    }
  }

  func testWritingMaterialPlansAreDeterministicDistinctAndBounded() throws {
    let destination = try WritingMaterialRect(width: 320, height: 180)
    let materials: [WritingMaterial] = [
      .brush(.default), .pen(.default), .ink(.default),
    ]
    let plans = materials.map { material in
      WritingMaterialPlan(
        material: material,
        targetID: "paragraph|text|0",
        documentOriginX: 10,
        documentOriginY: 20,
        destination: destination
      )
    }
    for (material, plan) in zip(materials, plans) {
      XCTAssertEqual(
        plan,
        WritingMaterialPlan(
          material: material,
          targetID: "paragraph|text|0",
          documentOriginX: 10,
          documentOriginY: 20,
          destination: destination
        )
      )
      XCTAssertEqual(
        plan.marks.count,
        WritingMaterialPlan.requestedMarkCount(
          material: material, destination: destination)
      )
      XCTAssertLessThanOrEqual(
        plan.marks.count, WritingMaterialPlan.maximumMarksPerTarget)
    }
    XCTAssertNotEqual(plans[0].marks, plans[1].marks)
    XCTAssertNotEqual(plans[1].marks, plans[2].marks)
    XCTAssertNotEqual(plans[0].kind, plans[1].kind)
    XCTAssertNotEqual(plans[1].kind, plans[2].kind)

    let extremeDestination = try WritingMaterialRect(
      width: .greatestFiniteMagnitude, height: 1)
    XCTAssertEqual(
      WritingMaterialPlan.requestedMarkCount(
        material: .ink(.default), destination: extremeDestination),
      WritingMaterialPlan.maximumMarksPerTarget
    )

    let shifted = WritingMaterialPlan(
      material: materials[0],
      targetID: "paragraph|text|0",
      documentOriginX: 11,
      documentOriginY: 20,
      destination: destination
    )
    let differentTarget = WritingMaterialPlan(
      material: materials[0],
      targetID: "paragraph|text|1",
      documentOriginX: 10,
      documentOriginY: 20,
      destination: destination
    )
    XCTAssertNotEqual(plans[0].marks, shifted.marks)
    XCTAssertNotEqual(plans[0].marks, differentTarget.marks)

    let large = try WritingMaterialRect(width: 20_000, height: 20_000)
    for material in materials {
      let plan = WritingMaterialPlan(
        material: material,
        targetID: "large",
        documentOriginX: 0,
        documentOriginY: 0,
        destination: large
      )
      XCTAssertEqual(plan.marks.count, WritingMaterialPlan.maximumMarksPerTarget)
    }
    let allocations = WritingMaterialPlan.boundedMarkAllocations(
      requestedCounts: Array(repeating: WritingMaterialPlan.maximumMarksPerTarget, count: 100),
      maximumMarks: WritingMaterialPlan.maximumMarks
    )
    XCTAssertLessThanOrEqual(allocations.reduce(0, +), WritingMaterialPlan.maximumMarks)
    XCTAssertTrue(allocations.allSatisfy { $0 <= WritingMaterialPlan.maximumMarksPerTarget })
    XCTAssertGreaterThan(allocations.first ?? 0, 0)
    XCTAssertGreaterThan(allocations.last ?? 0, 0)
  }

  func testChalkTextureProfilesChangeGeometryBeyondSeedAndDensity() throws {
    let styles: [WritingChalkTextureStyle] = [.fineGrain, .photographic, .referenceSampled]
    let plans = try styles.map { style in
      WritingChalkSurfacePlan(
        configuration: try WritingChalkConfiguration(textureStyle: style))
    }
    let repeatedPlans = try styles.map { style in
      WritingChalkSurfacePlan(
        configuration: try WritingChalkConfiguration(textureStyle: style))
    }
    XCTAssertEqual(plans, repeatedPlans)
    XCTAssertNotEqual(plans[0].texturePointSize, plans[1].texturePointSize)
    XCTAssertNotEqual(plans[1].texturePointSize, plans[2].texturePointSize)
    XCTAssertNotEqual(plans[0].textureOpacity, plans[1].textureOpacity)
    XCTAssertNotEqual(plans[1].textureOpacity, plans[2].textureOpacity)
    XCTAssertEqual(
      Set(styles.map { WritingChalkTextureResource.name(for: $0) }).count,
      styles.count
    )
  }

  func testChalkGrainScaleChangesPhysicalTextureSizeDeterministically() throws {
    let fine = WritingChalkSurfacePlan(
      configuration: try WritingChalkConfiguration(grainScale: 1))
    let coarse = WritingChalkSurfacePlan(
      configuration: try WritingChalkConfiguration(grainScale: 8))
    let repeated = WritingChalkSurfacePlan(
      configuration: try WritingChalkConfiguration(grainScale: 8))

    XCTAssertEqual(coarse, repeated)
    XCTAssertLessThan(fine.texturePointSize, coarse.texturePointSize)
    XCTAssertGreaterThanOrEqual(fine.texturePointSize, 32)
    XCTAssertLessThanOrEqual(coarse.texturePointSize, 256)
    XCTAssertEqual(
      WritingChalkSurfacePlan(configuration: .rough).paintOutset,
      WritingChalkSurfacePlan.maximumPaintOutset
    )
  }

  func testChalkEdgeDustRecipeIsSeedDrivenAndSharedByPlan() throws {
    let configuration = try WritingChalkConfiguration(
      seed: 0xD057,
      grainAmount: 0.78,
      erosionAmount: 0.28,
      grainScale: 4.2,
      edgeRoughness: 0.62,
      textureStyle: .photographic
    )
    let sameSeed = try WritingChalkConfiguration(
      seed: 0xD057,
      grainAmount: 0.78,
      erosionAmount: 0.28,
      grainScale: 4.2,
      edgeRoughness: 0.62,
      textureStyle: .photographic
    )
    let otherSeed = try WritingChalkConfiguration(
      seed: 0xD058,
      grainAmount: 0.78,
      erosionAmount: 0.28,
      grainScale: 4.2,
      edgeRoughness: 0.62,
      textureStyle: .photographic
    )
    let plan = WritingChalkSurfacePlan(configuration: configuration)
    let repeated = WritingChalkSurfacePlan(configuration: sameSeed)
    let shifted = WritingChalkSurfacePlan(configuration: otherSeed)
    let recipe = plan.edgeDustRecipe

    XCTAssertEqual(recipe, repeated.edgeDustRecipe)
    XCTAssertNotEqual(recipe, shifted.edgeDustRecipe)
    XCTAssertNotEqual(recipe.phaseX, shifted.edgeDustRecipe.phaseX)
    XCTAssertNotEqual(recipe.phaseY, shifted.edgeDustRecipe.phaseY)
    XCTAssertTrue(recipe.isEnabled)
    XCTAssertTrue(recipe.usesTextureMask)
    XCTAssertEqual(recipe.opacity, configuration.edgeRoughness * 0.26, accuracy: 0.000_001)
    XCTAssertEqual(
      recipe.firstDepositOpacity,
      recipe.opacity * recipe.firstDepositScale,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      recipe.secondDepositOpacity,
      recipe.opacity * recipe.secondDepositScale,
      accuracy: 0.000_001
    )
    XCTAssertNotEqual(recipe.firstDepositOpacity, recipe.secondDepositOpacity)

    let encodedRecipe = try JSONEncoder().encode(recipe)
    let encodedObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encodedRecipe) as? [String: Any]
    )
    XCTAssertNil(encodedObject["firstDepositOpacity"])
    XCTAssertNil(encodedObject["secondDepositOpacity"])
    var inconsistentObject = encodedObject
    inconsistentObject["firstDepositOpacity"] = 1
    inconsistentObject["secondDepositOpacity"] = 1
    let decodedRecipe = try JSONDecoder().decode(
      WritingChalkEdgeDustRecipe.self,
      from: JSONSerialization.data(withJSONObject: inconsistentObject)
    )
    XCTAssertEqual(decodedRecipe, recipe)
    XCTAssertEqual(
      decodedRecipe.firstDepositOpacity,
      decodedRecipe.opacity * decodedRecipe.firstDepositScale,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      decodedRecipe.secondDepositOpacity,
      decodedRecipe.opacity * decodedRecipe.secondDepositScale,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      recipe.radius,
      min(2.25, 0.35 + configuration.edgeRoughness * 1.90),
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      recipe.firstOffsetX,
      recipe.phaseX + recipe.radius * 0.5,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      recipe.firstOffsetY,
      recipe.phaseY - recipe.radius * 0.5,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      recipe.secondOffsetX,
      recipe.phaseX - recipe.radius * 0.5,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      recipe.secondOffsetY,
      recipe.phaseY + recipe.radius * 0.5,
      accuracy: 0.000_001
    )
    let texturePhase = plan.phase(tileSize: plan.texturePointSize, pass: .edgeDust)
    XCTAssertEqual(recipe.texturePhaseX, texturePhase.x, accuracy: 0.000_001)
    XCTAssertEqual(recipe.texturePhaseY, texturePhase.y, accuracy: 0.000_001)
  }

  func testPublicChalkFacadeAndLiveTextPainterUseCanonicalConfiguration() throws {
    let configuration = try WritingChalkConfiguration(
      seed: 0xFADE,
      grainAmount: 0.74,
      erosionAmount: 0.22,
      grainScale: 4.0,
      edgeRoughness: 0.58,
      textureStyle: .referenceSampled
    )
    let color = try ChalkColor(red: 0.92, green: 0.18, blue: 0.08)
    let size = CGSize(width: 240, height: 84)
    let facade = Text("Chalk")
      .font(.system(size: 52, weight: .bold))
      .chalkEffect(configuration, color: color)
    let repeatedFacade = Text("Chalk")
      .font(.system(size: 52, weight: .bold))
      .chalkEffect(configuration, color: color)
    let facadeImage = try renderBack(facade, size: size)
    let repeatedFacadeImage = try renderBack(repeatedFacade, size: size)

    let plan = WritingChalkSurfacePlan(configuration: configuration)
    let inlineStyle = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica-Bold", pointSize: 52))
    let inlineAtom = try InlineAtom.text(
      InlineTextAtom(id: "canonical-painter", text: "Chalk", style: inlineStyle))
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [inlineAtom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: size.width)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let canvasContent = try InlineCanvasRenderContent(
      plan: renderPlan, assets: EmptyAssetProvider(), foregroundColor: .white)
    let canvasViewport = try InlineRenderViewport(
      x: 0, y: 0, width: size.width, height: size.height)
    let painterImage = try renderBack(
      LiveTextCanvasWritingRenderer(
        content: canvasContent,
        viewport: canvasViewport,
        configuration: InlineWritingConfiguration(effect: .chalk(configuration), color: color)
      ),
      size: size
    )

    XCTAssertEqual(
      pixelDifferenceCount(facadeImage, repeatedFacadeImage),
      0,
      "public chalkEffect must be deterministic for one configuration"
    )
    XCTAssertTrue(plan.edgeDustRecipe.isEnabled)
    let channels = channelMeans(facadeImage)
    XCTAssertGreaterThan(channels.red, channels.green)
    XCTAssertGreaterThan(channels.red, channels.blue)
    XCTAssertGreaterThan(chromaticPixelCount(facadeImage), 0)
    let painterChannels = channelMeans(painterImage)
    XCTAssertGreaterThan(alphaPixelCount(painterImage), 0)
    XCTAssertGreaterThan(painterChannels.red, painterChannels.green)
    XCTAssertGreaterThan(painterChannels.red, painterChannels.blue)
    XCTAssertGreaterThan(chromaticPixelCount(painterImage), 0)
  }

  func testChalkTextureLossLayersDoNotInheritPreviousFilters() throws {
    let configuration = try WritingChalkConfiguration(
      seed: 0xED6E,
      grainAmount: 0.68,
      erosionAmount: 0.18,
      grainScale: 3.8,
      edgeRoughness: 0,
      textureStyle: .photographic
    )
    let color = Color(red: 0.86, green: 0.19, blue: 0.07)
    let chalkColor = try ChalkColor(red: 0.86, green: 0.19, blue: 0.07)
    let size = CGSize(width: 128, height: 96)
    let rect = CGRect(x: 32, y: 28, width: 64, height: 32)
    let view = ZStack(alignment: .topLeading) {
      Color.clear
      Color.white.frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .chalkEffect(configuration, color: chalkColor)
    let target = try WritingMaterialTarget(
      targetID: "independent-loss-layers",
      documentOriginX: 0,
      documentOriginY: 0,
      destination: WritingMaterialRect(width: size.width, height: size.height)
    )
    let painter = Canvas { context, _ in
      InlineWritingChalkPainter.paint(
        mask: Path(rect), target: target, configuration: configuration,
        color: color, documentOriginAtContextZero: .zero, in: &context
      )
    }.frame(width: size.width, height: size.height)
    let viewCoverage = alphaCoverage(try renderBack(view, size: size))
    let painterCoverage = alphaCoverage(try renderBack(painter, size: size))
    let baseline = max(viewCoverage, painterCoverage)
    XCTAssertGreaterThan(baseline, 0)
    XCTAssertLessThanOrEqual(
      Double(abs(viewCoverage - painterCoverage)) / Double(max(baseline, 1)),
      0.05,
      "Texture loss layers must use independent filters in both renderers"
    )
  }

  func testChalkSurfaceViewAndPainterShareTexturedEdgeCoverage() throws {
    let configuration = try WritingChalkConfiguration(
      seed: 0xED6E,
      grainAmount: 0.68,
      erosionAmount: 0.18,
      grainScale: 3.8,
      edgeRoughness: 0.72,
      textureStyle: .photographic,
      style: .fineLine
    )
    let chalkColor = try ChalkColor(red: 0.86, green: 0.19, blue: 0.07)
    let color = Color(red: 0.86, green: 0.19, blue: 0.07)
    let size = CGSize(width: 128, height: 96)
    let maskRect = CGRect(x: 32, y: 28, width: 64, height: 32)
    let viewSurface = ZStack(alignment: .topLeading) {
      Color.clear
      Color.white
        .frame(width: maskRect.width, height: maskRect.height)
        .offset(x: maskRect.minX, y: maskRect.minY)
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .chalkEffect(configuration, color: chalkColor)
    let target = try WritingMaterialTarget(
      targetID: "edge-dust-parity",
      documentOriginX: 0,
      documentOriginY: 0,
      destination: try WritingMaterialRect(width: size.width, height: size.height)
    )
    let painterSurface = Canvas { context, _ in
      InlineWritingChalkPainter.paint(
        mask: Path(maskRect),
        target: target,
        configuration: configuration,
        color: color,
        documentOriginAtContextZero: .zero,
        in: &context
      )
    }
    .frame(width: size.width, height: size.height)
    let viewImage = try renderBack(viewSurface, size: size)
    let painterImage = try renderBack(painterSurface, size: size)
    let viewAlpha = alphaPixelCount(viewImage)
    let painterAlpha = alphaPixelCount(painterImage)
    let alphaDelta = abs(viewAlpha - painterAlpha)
    let alphaBaseline = max(viewAlpha, painterAlpha)
    let viewCoverage = alphaCoverage(viewImage)
    let painterCoverage = alphaCoverage(painterImage)
    let coverageDelta = abs(viewCoverage - painterCoverage)
    let coverageBaseline = max(viewCoverage, painterCoverage)
    let viewDustCoverageWeight = alphaCoverage(viewImage, outside: maskRect)
    let painterDustCoverageWeight = alphaCoverage(painterImage, outside: maskRect)
    let dustCoverageWeightDelta = abs(viewDustCoverageWeight - painterDustCoverageWeight)
    let dustCoverageWeightBaseline = max(viewDustCoverageWeight, painterDustCoverageWeight)
    let viewDustCoverage = alphaPixelCount(viewImage, outside: maskRect)
    let painterDustCoverage = alphaPixelCount(painterImage, outside: maskRect)
    let dustCoverageDelta = abs(viewDustCoverage - painterDustCoverage)
    let viewBounds = try XCTUnwrap(alphaPixelBounds(viewImage))
    let painterBounds = try XCTUnwrap(alphaPixelBounds(painterImage))

    XCTAssertGreaterThan(viewAlpha, 0)
    XCTAssertGreaterThan(painterAlpha, 0)
    XCTAssertGreaterThan(viewDustCoverage, 0)
    XCTAssertGreaterThan(painterDustCoverage, 0)
    XCTAssertLessThanOrEqual(alphaDelta, 16)
    XCTAssertLessThanOrEqual(
      Double(alphaDelta) / Double(alphaBaseline),
      0.01,
      "View and painter total coverage drifted beyond 1%"
    )
    XCTAssertGreaterThan(coverageBaseline, 0)
    XCTAssertLessThanOrEqual(
      Double(coverageDelta) / Double(max(coverageBaseline, 1)), 0.05,
      "View and painter total alpha coverage drifted beyond 5%"
    )
    XCTAssertGreaterThan(dustCoverageWeightBaseline, 0)
    // Allow raster rounding while requiring the textured edge to contribute
    // comparable coverage in both rendering paths.
    XCTAssertLessThanOrEqual(dustCoverageWeightDelta, 192)
    XCTAssertLessThanOrEqual(
      Double(dustCoverageWeightDelta) / Double(dustCoverageWeightBaseline),
      0.10,
      "View and painter weighted edge coverage drifted beyond 10%"
    )
    XCTAssertLessThanOrEqual(dustCoverageDelta, 16)
    XCTAssertLessThanOrEqual(
      abs(viewBounds.minX - painterBounds.minX), 1
    )
    XCTAssertLessThanOrEqual(
      abs(viewBounds.maxX - painterBounds.maxX), 1
    )
    XCTAssertLessThanOrEqual(
      abs(viewBounds.minY - painterBounds.minY), 1
    )
    XCTAssertLessThanOrEqual(
      abs(viewBounds.maxY - painterBounds.maxY), 1
    )
    print(
      "[chalk-edge-parity] viewAlpha=\(viewAlpha) "
        + "painterAlpha=\(painterAlpha) alphaDelta=\(alphaDelta) "
        + "viewCoverage=\(viewCoverage) painterCoverage=\(painterCoverage) "
        + "coverageDelta=\(coverageDelta) "
        + "viewDustWeight=\(viewDustCoverageWeight) "
        + "painterDustWeight=\(painterDustCoverageWeight) "
        + "dustWeightDelta=\(dustCoverageWeightDelta) "
        + "viewDust=\(viewDustCoverage) painterDust=\(painterDustCoverage) "
        + "dustDelta=\(dustCoverageDelta) "
        + "bounds=\(viewBounds)/\(painterBounds)"
    )
  }

  func testChalkTextureUsesCallerColorAcrossSwiftUIAndCanvas() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica-Bold", pointSize: 36))
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "chalk-tint", text: "Tint", style: style))
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 160)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let swiftContent = try InlineSwiftUIRenderContent(
      plan: plan, assets: EmptyAssetProvider(), foregroundColor: .white)
    let canvasContent = try InlineCanvasRenderContent(
      plan: plan, assets: EmptyAssetProvider(), foregroundColor: .white)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
    let size = CGSize(width: viewport.width, height: viewport.height)
    let red = InlineWritingConfiguration(
      effect: .chalk(.default),
      color: try ChalkColor(red: 1, green: 0, blue: 0)
    )
    let blue = InlineWritingConfiguration(
      effect: .chalk(.default),
      color: try ChalkColor(red: 0, green: 0, blue: 1)
    )

    let redSwift = try renderBack(
      LiveTextWritingRenderer(
        content: swiftContent, viewport: viewport, configuration: red),
      size: size
    )
    let blueSwift = try renderBack(
      LiveTextWritingRenderer(
        content: swiftContent, viewport: viewport, configuration: blue),
      size: size
    )
    let redCanvas = try renderBack(
      LiveTextCanvasWritingRenderer(
        content: canvasContent, viewport: viewport, configuration: red),
      size: size
    )
    let blueCanvas = try renderBack(
      LiveTextCanvasWritingRenderer(
        content: canvasContent, viewport: viewport, configuration: blue),
      size: size
    )

    let redSwiftChannels = channelMeans(redSwift)
    let blueSwiftChannels = channelMeans(blueSwift)
    let redCanvasChannels = channelMeans(redCanvas)
    let blueCanvasChannels = channelMeans(blueCanvas)
    XCTAssertGreaterThan(redSwiftChannels.red, redSwiftChannels.blue + 0.05)
    XCTAssertGreaterThan(blueSwiftChannels.blue, blueSwiftChannels.red + 0.05)
    XCTAssertGreaterThan(redCanvasChannels.red, redCanvasChannels.blue + 0.05)
    XCTAssertGreaterThan(blueCanvasChannels.blue, blueCanvasChannels.red + 0.05)
    XCTAssertGreaterThan(pixelDifferenceCount(redSwift, blueSwift), 0)
    XCTAssertGreaterThan(pixelDifferenceCount(redCanvas, blueCanvas), 0)
  }

  func testWritingMaterialZeroCoverageProducesNoMarks() throws {
    let destination = try WritingMaterialRect(width: 320, height: 180)
    let materials: [WritingMaterial] = [
      .chalk(try WritingChalkConfiguration(
        grainAmount: 0, erosionAmount: 0, edgeRoughness: 0)),
      .brush(try WritingBrushConfiguration(coverage: 0)),
      .pen(try WritingPenConfiguration(coverage: 0)),
      .ink(try WritingInkConfiguration(coverage: 0)),
    ]
    for material in materials {
      let plan = WritingMaterialPlan(
        material: material,
        targetID: "zero",
        documentOriginX: 0,
        documentOriginY: 0,
        destination: destination
      )
      XCTAssertEqual(plan.marks.count, 0)
    }
    XCTAssertEqual(
      WritingMaterialPlan.requestedMarkCount(
        material: .brush(.default),
        destination: try WritingMaterialRect(width: 0, height: 0)),
      0
    )
  }

  func testWritingMaterialPlanCacheUsesDeterministicTwoEntryLRU() throws {
    let destination = try WritingMaterialRect(width: 80, height: 20)
    let targets = [
      try WritingMaterialTarget(
        targetID: "first", documentOriginX: 0, documentOriginY: 0,
        destination: destination),
    ]
    let brush: WritingMaterial = .brush(.default)
    let pen: WritingMaterial = .pen(.default)
    let ink: WritingMaterial = .ink(.default)
    var cache = WritingMaterialPlanCache()
    let targetSet = WritingMaterialTargetSet(targets: targets)
    let first = cache.allocations(for: brush, targetSet: targetSet)
    XCTAssertEqual(cache.buildCount, 1)
    let firstPlans = cache.plans(for: brush, targetSet: targetSet)
    XCTAssertEqual(firstPlans.count, 1)
    XCTAssertEqual(firstPlans[0]?.marks.count, first[0])
    XCTAssertEqual(cache.plans(for: brush, targetSet: targetSet), firstPlans)
    XCTAssertEqual(cache.buildCount, 1)
    XCTAssertEqual(cache.allocations(for: brush, targetSet: targetSet), first)
    XCTAssertEqual(cache.buildCount, 1)
    _ = cache.allocations(for: pen, targetSet: targetSet)
    _ = cache.allocations(for: ink, targetSet: targetSet)
    XCTAssertEqual(cache.cachedConfigurationCount, WritingMaterialPlanCache.capacity)
    XCTAssertEqual(cache.buildCount, 3)
    _ = cache.allocations(for: pen, targetSet: targetSet)
    XCTAssertEqual(cache.buildCount, 3)
    _ = cache.allocations(for: brush, targetSet: targetSet)
    XCTAssertEqual(cache.buildCount, 4)

    let changedTarget = try WritingMaterialTarget(
      targetID: "first", documentOriginX: 0, documentOriginY: 0,
      destination: try WritingMaterialRect(width: 160, height: 20))
    let changedSet = WritingMaterialTargetSet(targets: [changedTarget])
    let changed = cache.allocations(for: brush, targetSet: changedSet)
    XCTAssertNotEqual(changedSet.signature, targetSet.signature)
    XCTAssertNotEqual(changed, first)
    XCTAssertEqual(cache.buildCount, 5)

    let zeroMaterial = WritingMaterial.chalk(
      try WritingChalkConfiguration(grainAmount: 0, erosionAmount: 0, edgeRoughness: 0))
    var zeroCache = WritingMaterialPlanCache()
    XCTAssertTrue(zeroCache.plans(for: zeroMaterial, targetSet: targetSet).isEmpty)
    XCTAssertEqual(zeroCache.cachedConfigurationCount, 1)
    XCTAssertEqual(zeroCache.buildCount, 1)
  }

  func testSemanticWritingPreparationSupportsMixedHandwritingCorpus() throws {
    let text = "한글 ㄱㄴㅏㅑ ABC abc 0123 .!?"
    let preparation = try ChalkWritingPreparation(
      text: text,
      layout: try WritingLayoutOptions(
        glyphHeight: 86,
        tracking: 8,
        lineSpacing: 12,
        margin: 16,
        baseStrokeWidth: 6,
        maximumLineWidth: 760
      )
    )

    XCTAssertEqual(preparation.scene.text, text)
    XCTAssertEqual(preparation.scene.glyphs.count, Array(text).count)
    XCTAssertGreaterThan(preparation.scene.strokes.count, 0)
    XCTAssertEqual(preparation.duration, preparation.timeline.duration, accuracy: 0.000_001)

    let encoded = try JSONEncoder().encode(preparation)
    let decoded = try JSONDecoder().decode(ChalkWritingPreparation.self, from: encoded)
    XCTAssertEqual(decoded, preparation)
  }

  func testWritingRendererPreservesAssetResolutionFailures() throws {
    let assetID = try InlineAssetID(rawValue: "marker")
    let metrics = try InlineMetrics(advance: 4, ascent: 8, descent: 2)
    let atom = try InlineAtom.vector(
      InlineVectorAtom(id: "marker-atom", assetID: assetID, metrics: metrics))
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 20)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)

    struct MissingProvider: InlineAssetGeometryProvider {
      let assetID: InlineAssetID
      func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
        throw InlineAssetResolutionError.missingGeometry(assetID, version: version)
      }
    }

    for _ in [
      InlineWritingConfiguration.chalk,
      InlineWritingConfiguration.brush,
      InlineWritingConfiguration.pen,
      InlineWritingConfiguration.ink,
    ] {
      XCTAssertThrowsError(
        try InlineSwiftUIRenderContent(
          plan: renderPlan, assets: MissingProvider(assetID: assetID))
      ) { error in
        XCTAssertEqual(
          error as? InlineAssetResolutionError,
          .missingGeometry(assetID, version: 1)
        )
      }
    }
  }

  func testWritingRendererPreservesBaseHitTesting() throws {
    let assetID = try InlineAssetID(rawValue: "chalk-marker")
    let metrics = try InlineMetrics(
      advance: 4, ascent: 8, descent: 2, baselineOffset: -2)
    let path = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 1, y: 1)),
    ])
    let asset = try InlineSVGAsset(
      id: assetID, metrics: metrics, coordinateBounds: path.bounds,
      coveragePath: path, coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let atom = try InlineAtom.vector(
      InlineVectorAtom(id: "chalk-marker-atom", assetID: assetID, metrics: metrics))
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 20)
    struct Provider: InlineAssetGeometryProvider {
      let asset: InlineSVGAsset
      func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
        asset
      }
    }
    let provider = Provider(asset: asset)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let content = try InlineSwiftUIRenderContent(plan: renderPlan, assets: provider)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
    let base = InlineSwiftUIRenderer(content: content, viewport: viewport)
    let points = [
      try InlineHitPoint(x: 1, y: 5),
      try InlineHitPoint(x: 100, y: 100),
    ]
    for configuration in [
      InlineWritingConfiguration.chalk,
      InlineWritingConfiguration.brush,
      InlineWritingConfiguration.pen,
      InlineWritingConfiguration.ink,
    ] {
      let writing = LiveTextWritingRenderer(
        content: content, viewport: viewport, configuration: configuration)
      for point in points {
        XCTAssertEqual(writing.hitTest(point), base.hitTest(point))
      }
    }
  }

  func testSwiftUIAndCanvasConsumeTheSameNativeMaterialPlan() throws {
    let assetID = try InlineAssetID(rawValue: "native-material")
    let metrics = try InlineMetrics(advance: 24, ascent: 18, descent: 4)
    let assetPath = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 1, y: 0)),
      .line(try InlinePathPoint(x: 1, y: 1)),
      .line(try InlinePathPoint(x: 0, y: 1)),
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
      InlineVectorAtom(id: "native-material-atom", assetID: assetID, metrics: metrics))
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 40)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    struct Provider: InlineAssetGeometryProvider {
      let asset: InlineSVGAsset
      func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
        asset
      }
    }
    let provider = Provider(asset: asset)
    let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: provider)
    let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: provider)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
    let material = InlineRendererMaterial.chalk(.default)
    let swift = InlineSwiftUIRenderer(
      content: swiftContent, viewport: viewport, material: material)
    let canvas = InlineCanvasRenderer(
      content: canvasContent, viewport: viewport, material: material)

    let size = CGSize(width: viewport.width, height: viewport.height)
    let plainSwiftImage = try renderBack(
      InlineSwiftUIRenderer(content: swiftContent, viewport: viewport), size: size)
    let plainCanvasImage = try renderBack(
      InlineCanvasRenderer(content: canvasContent, viewport: viewport), size: size)
    let nativeSwiftImage = try renderBack(swift, size: size)
    let nativeCanvasImage = try renderBack(canvas, size: size)
    XCTAssertEqual(swift.writingMaterialPlanCountForTesting, 0)
    XCTAssertEqual(canvas.writingMaterialPlanCountForTesting, 0)
    XCTAssertEqual(
      swift.writingMaterialPlansForTesting,
      canvas.writingMaterialPlansForTesting
    )
    XCTAssertEqual(swift.writingMaterialMarkCountForTesting, 0)
    XCTAssertEqual(canvas.writingMaterialMarkCountForTesting, 0)
    XCTAssertGreaterThan(pixelDifferenceCount(plainSwiftImage, nativeSwiftImage), 0)
    XCTAssertGreaterThan(pixelDifferenceCount(plainCanvasImage, nativeCanvasImage), 0)

    // The two adapters must consume the same document-space plan. Raster
    // output is allowed a small platform/compositor tolerance, but should not
    // diverge wholesale.
    XCTAssertLessThanOrEqual(
      pixelDifferenceCount(nativeSwiftImage, nativeCanvasImage),
      max(512, nativeSwiftImage.width * nativeSwiftImage.height / 2)
    )

    // Culling a viewport must be equivalent to cropping the same full render;
    // the cached plan is document anchored, so changing the viewport cannot
    // reseed or regenerate visible marks.
    let crop = try InlineRenderViewport(x: 2, y: 0, width: 20, height: 24)
    let wholeViewport = try InlineRenderViewport(x: 0, y: 0, width: 40, height: 24)
    let wholeSwiftImage = try renderBack(
      InlineSwiftUIRenderer(content: swiftContent, viewport: wholeViewport, material: material),
      size: CGSize(width: 40, height: 24)
    )
    let wholeCanvasImage = try renderBack(
      InlineCanvasRenderer(content: canvasContent, viewport: wholeViewport, material: material),
      size: CGSize(width: 40, height: 24)
    )
    let croppedSwiftImage = try renderBack(
      InlineSwiftUIRenderer(content: swiftContent, viewport: crop, material: material),
      size: CGSize(width: 20, height: 24)
    )
    let croppedCanvasImage = try renderBack(
      InlineCanvasRenderer(content: canvasContent, viewport: crop, material: material),
      size: CGSize(width: 20, height: 24)
    )
    let sourceCrop = CGRect(x: 2, y: 0, width: 20, height: 24)
    let wholeSwiftCrop = try XCTUnwrap(wholeSwiftImage.cropping(to: sourceCrop))
    let wholeCanvasCrop = try XCTUnwrap(wholeCanvasImage.cropping(to: sourceCrop))
    // Viewport-sized rasterization resamples the document-anchored grain
    // texture at a shifted sub-texel phase versus cropping a whole render
    // (measured Apple silicon: identical RGB, alpha tail to ~92, 53px beyond
    // a 32-unit channel tolerance). A reseeded/regenerated plan diverges far
    // more (measured ~230px beyond tolerance for a changed seed), so the
    // tolerance admits sampling noise while the count still rejects reseed.
    XCTAssertLessThanOrEqual(
      pixelDifferenceCount(croppedSwiftImage, wholeSwiftCrop, channelTolerance: 32),
      max(128, croppedSwiftImage.width * croppedSwiftImage.height / 4)
    )
    XCTAssertLessThanOrEqual(
      pixelDifferenceCount(croppedCanvasImage, wholeCanvasCrop, channelTolerance: 32),
      max(128, croppedCanvasImage.width * croppedCanvasImage.height / 4)
    )
  }

  func testMaxMaterialConfigsRemainVisibleAtViewportEdgesInBothAdapters() throws {
    let assetID = try InlineAssetID(rawValue: "material-edge-culling")
    let metrics = try InlineMetrics(advance: 100, ascent: 20, descent: 0)
    let assetPath = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 10)),
      .line(try InlinePathPoint(x: 100, y: 10)),
    ])
    let asset = try InlineSVGAsset(
      id: assetID,
      metrics: metrics,
      coordinateBounds: assetPath.bounds,
      coveragePath: assetPath,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: assetPath,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let atom = try InlineAtom.vector(
      InlineVectorAtom(id: "material-edge", assetID: assetID, metrics: metrics)
    )
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 120)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    struct Provider: InlineAssetGeometryProvider {
      let asset: InlineSVGAsset
      func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
        asset
      }
    }
    let provider = Provider(asset: asset)
    let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: provider)
    let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: provider)
    let brush = InlineRendererMaterial.brush(
      try WritingBrushConfiguration(coverage: 1, streakScale: 64))
    let ink = InlineRendererMaterial.ink(
      try WritingInkConfiguration(coverage: 1, bleed: 1, pooling: 1))
    let brushViewport = try InlineRenderViewport(x: 109, y: 7, width: 2, height: 6)
    let inkViewport = try InlineRenderViewport(x: 118, y: 7, width: 2, height: 6)

    let swiftBrush = InlineSwiftUIRenderer(
      content: swiftContent, viewport: brushViewport, material: brush)
    let canvasBrush = InlineCanvasRenderer(
      content: canvasContent, viewport: brushViewport, material: brush)
    let swiftInk = InlineSwiftUIRenderer(
      content: swiftContent, viewport: inkViewport, material: ink)
    let canvasInk = InlineCanvasRenderer(
      content: canvasContent, viewport: inkViewport, material: ink)

    XCTAssertTrue(swiftBrush.visibleAtomIDsForWritingTesting(in: brushViewport).contains("material-edge"))
    XCTAssertTrue(canvasBrush.visibleAtomIDsForWritingTesting(in: brushViewport).contains("material-edge"))
    XCTAssertTrue(swiftInk.visibleAtomIDsForWritingTesting(in: inkViewport).contains("material-edge"))
    XCTAssertTrue(canvasInk.visibleAtomIDsForWritingTesting(in: inkViewport).contains("material-edge"))
  }

  func testChalkNarrowSVGRemainsVisibleAtFarDocumentCoordinatesAcrossRevealPhases() throws {
    let assetID = try InlineAssetID(rawValue: "far-narrow-svg")
    let metrics = try InlineMetrics(advance: 1, ascent: 1, descent: 0)
    let assetPath = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0.5)),
      .line(try InlinePathPoint(x: 1, y: 0.5)),
    ])
    let asset = try InlineSVGAsset(
      id: assetID,
      metrics: metrics,
      coordinateBounds: assetPath.bounds,
      coveragePath: assetPath,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: assetPath,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let textStyle = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 10))
    let line = String(repeating: "X", count: 48)
    let prefix = String(repeating: line + "\n", count: 40) + line
    let text = try InlineAtom.text(
      InlineTextAtom(id: "far-prefix", text: prefix, style: textStyle))
    let vector = try InlineAtom.vector(
      InlineVectorAtom(id: "far-narrow-vector", asset: asset))
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [text, vector]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 800)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let reveal = try InlinePathRevealPlanBuilder(secondsPerUnit: 0.01).plan(asset: asset)
    let schedule = try InlineRenderRevealSchedule(
      plan: renderPlan,
      assets: InlineAssetStore(values: [
        InlineAssetKey(id: asset.id, version: asset.version): asset
      ]),
      vectorPlans: [vector.id: reveal]
    )
    struct Provider: InlineAssetGeometryProvider {
      let asset: InlineSVGAsset
      func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
        asset
      }
    }
    let provider = Provider(asset: asset)
    let swiftContent = try InlineSwiftUIRenderContent(
      plan: renderPlan, assets: provider, schedule: schedule)
    let canvasContent = try InlineCanvasRenderContent(
      plan: renderPlan, assets: provider, schedule: schedule)
    let positioned = try XCTUnwrap(
      layout.lines.flatMap(\.atoms).first { $0.atomID == vector.id }
    )
    XCTAssertGreaterThan(positioned.originX, 256)
    XCTAssertGreaterThan(positioned.baselineY, 256)
    XCTAssertEqual(asset.metrics.advance, 1, accuracy: 0.000_001)
    XCTAssertEqual(positioned.width, 1, accuracy: 0.000_001)
    let originY = positioned.baselineY - positioned.metrics.baselineOffset
      - positioned.metrics.ascent
    let viewport = try InlineRenderViewport(
      x: positioned.originX - 2,
      y: originY - 2,
      width: 5,
      height: 5
    )
    let size = CGSize(width: viewport.width, height: viewport.height)
    let material = InlineRendererMaterial.chalk(
      try WritingChalkConfiguration(
        grainAmount: 0.82,
        erosionAmount: 0.04,
        grainScale: 3.5,
        edgeRoughness: 0.3
      )
    )
    let plainSwift = try renderBack(
      InlineSwiftUIRenderer(content: swiftContent, viewport: viewport), size: size)
    let plainCanvas = try renderBack(
      InlineCanvasRenderer(content: canvasContent, viewport: viewport), size: size)
    let plainSwiftAlpha = alphaPixelCount(plainSwift)
    let plainCanvasAlpha = alphaPixelCount(plainCanvas)
    let vectorActivation = try XCTUnwrap(schedule.vectorActivation(for: vector.id))
    let firstVectorUnit = try XCTUnwrap(vectorActivation.units.first)
    let vectorMidTime = firstVectorUnit.startTime + firstVectorUnit.duration / 2
    let partial = try InlineRenderRevealPhase(rawValue: vectorMidTime / schedule.duration)
    let renders: [(String, CGImage, CGImage)] = [
      (
        "complete",
        try renderBack(
          InlineSwiftUIRenderer(
            content: swiftContent, viewport: viewport, material: material),
          size: size
        ),
        try renderBack(
          InlineCanvasRenderer(
            content: canvasContent, viewport: viewport, material: material),
          size: size
        )
      ),
      (
        "partial",
        try renderBack(
          InlineSwiftUIRenderer(
            content: swiftContent, phase: partial, viewport: viewport, material: material),
          size: size
        ),
        try renderBack(
          InlineCanvasRenderer(
            content: canvasContent, phase: partial, viewport: viewport, material: material),
          size: size
        )
      ),
    ]
    for (phase, swift, canvas) in renders {
      XCTAssertGreaterThanOrEqual(
        alphaPixelCount(swift), max(1, plainSwiftAlpha / 4),
        "chalk \(phase) SwiftUI path severely dropped out"
      )
      XCTAssertGreaterThanOrEqual(
        alphaPixelCount(canvas), max(1, plainCanvasAlpha / 4),
        "chalk \(phase) Canvas path severely dropped out"
      )
      XCTAssertGreaterThan(
        pixelDifferenceCount(plainSwift, swift), 0,
        "chalk \(phase) SwiftUI did not change the narrow source line"
      )
      XCTAssertGreaterThan(
        pixelDifferenceCount(plainCanvas, canvas), 0,
        "chalk \(phase) Canvas did not change the narrow source line"
      )
      XCTAssertLessThanOrEqual(
        pixelDifferenceCount(swift, canvas),
        16,
        "chalk \(phase) SwiftUI/Canvas narrow-path parity diverged"
      )
    }
  }

  func testPoolingZeroInkHaloAtLocalCropEdgeStaysInSwiftUICanvasParity() throws {
    let assetID = try InlineAssetID(rawValue: "pooling-zero-edge")
    let metrics = try InlineMetrics(advance: 48, ascent: 40, descent: 0)
    let assetPath = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 48, y: 0)),
      .line(try InlinePathPoint(x: 48, y: 40)),
      .line(try InlinePathPoint(x: 0, y: 40)),
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
      InlineVectorAtom(id: "pooling-zero-edge", assetID: assetID, metrics: metrics))
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 64)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    struct Provider: InlineAssetGeometryProvider {
      let asset: InlineSVGAsset
      func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
        asset
      }
    }
    let provider = Provider(asset: asset)
    let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: provider)
    let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: provider)
    let material = InlineRendererMaterial.ink(
      try WritingInkConfiguration(seed: 41, coverage: 1, bleed: 1, pooling: 0))
    let positioned = try XCTUnwrap(layout.lines.first?.atoms.first)
    let originY = positioned.baselineY - positioned.metrics.baselineOffset
      - positioned.metrics.ascent
    let expansion = WritingStrokeGeometryPlan.conservativeMaximumHalfWidth(
      for: material.writingMaterial!, destinationHeight: positioned.height)
      + WritingStrokeGeometryPlan.inkHaloBlurRadius + 1.05
    // Keep the crop across the left edge of the actual ink at the vertical
    // center; the conservative expansion is intentionally only used for x.
    let viewport = try InlineRenderViewport(
      x: positioned.originX - expansion + 6.05,
      y: originY + positioned.height / 2 - 4,
      width: 8,
      height: 8
    )
    XCTAssertLessThan(viewport.x, positioned.originX)
    XCTAssertGreaterThan(viewport.x + viewport.width, positioned.originX)
    XCTAssertGreaterThanOrEqual(viewport.y, originY)
    XCTAssertLessThanOrEqual(viewport.y + viewport.height, originY + positioned.height)
    let size = CGSize(width: viewport.width, height: viewport.height)
    let swiftImage = try renderBack(
      InlineSwiftUIRenderer(
        content: swiftContent, viewport: viewport, material: material),
      size: size
    )
    let canvasImage = try renderBack(
      InlineCanvasRenderer(
        content: canvasContent, viewport: viewport, material: material),
      size: size
    )
    XCTAssertGreaterThan(alphaPixelCount(swiftImage), 0)
    XCTAssertGreaterThan(alphaPixelCount(canvasImage), 0)
    XCTAssertLessThanOrEqual(
      pixelDifferenceCount(swiftImage, canvasImage),
      16,
      "pooling-zero ink halo diverged at the local crop edge"
    )
  }

  func testNativeOutlineMaskFollowsTextActivationAcrossRevealPhases() throws {
    let sourceRange = try InlineSourceRange(startUTF16: 0, endUTF16: 1)
    let unitID = try InlineRevealUnitID(rawValue: "native-outline")
    let outline = Path(CGRect(x: 2, y: 3, width: 12, height: 16))
    let entry = try InlineTextPaintEntry(
      outlinePath: outline,
      sourceRange: sourceRange,
      localPaintBounds: outline.boundingRect
    )
    let activation = try InlineRenderRevealTextActivation(
      atomID: "native-outline",
      units: [try InlineRenderRevealTextUnit(
        id: unitID,
        kind: .nativeAtomic,
        sourceRange: sourceRange,
        startTime: 0,
        duration: 1
      )]
    )

    XCTAssertTrue(
      InlineAppleSemanticStrokePainter.maskPath(
        [entry], activation: activation, time: 0).isEmpty
    )
    XCTAssertFalse(
      InlineAppleSemanticStrokePainter.maskPath(
        [entry], activation: activation, time: 0.5).isEmpty
    )
    XCTAssertFalse(
      InlineAppleSemanticStrokePainter.maskPath(
        [entry], activation: activation, time: 1).isEmpty
    )
    XCTAssertFalse(InlineAppleSemanticStrokePainter.maskPath([entry]).isEmpty)
  }

  func testPublicConfigurationsMapToRendererMaterials() {
    XCTAssertEqual(
      InlineWritingConfiguration.brush.effect.writingMaterial?.kind, .brush)
    XCTAssertEqual(
      InlineWritingConfiguration.pen.effect.writingMaterial?.kind, .pen)
    XCTAssertEqual(
      InlineWritingConfiguration.ink.effect.writingMaterial?.kind, .ink)
    guard case .chalk(let chalk) = InlineWritingConfiguration.chalk.effect else {
      return XCTFail("chalk must use the renderer-native material pipeline")
    }
    XCTAssertEqual(chalk, WritingChalkConfiguration.default)
    XCTAssertNotNil(
      InlineWritingConfiguration.coloredPencil.effect.coloredPencilConfiguration)
  }

  func testNativeMaterialChangesOrdinaryTextPixelsButNotLayoutOrHitTesting() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 32))
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "native-text", text: "Native material text", style: style))
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 280)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let swiftContent = try InlineSwiftUIRenderContent(plan: renderPlan, assets: EmptyAssetProvider())
    let canvasContent = try InlineCanvasRenderContent(plan: renderPlan, assets: EmptyAssetProvider())
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
    let plain = InlineSwiftUIRenderer(content: swiftContent, viewport: viewport)
    let size = CGSize(width: viewport.width, height: viewport.height)
    let plainImage = try renderBack(plain, size: size)
    XCTAssertGreaterThan(alphaPixelCount(plainImage), 0)
    let materials: [InlineRendererMaterial] = [
      InlineWritingConfiguration.brush.effect,
      InlineWritingConfiguration.pen.effect,
      InlineWritingConfiguration.ink.effect,
    ]
    var swiftCachedConfigurationCount = 0
    var canvasCachedConfigurationCount = 0
    for material in materials {
      let nativeSwift = InlineSwiftUIRenderer(
        content: swiftContent, viewport: viewport, material: material)
      let nativeCanvas = InlineCanvasRenderer(
        content: canvasContent, viewport: viewport, material: material)
      let swiftImage = try renderBack(nativeSwift, size: size)
      let canvasImage = try renderBack(nativeCanvas, size: size)

      XCTAssertGreaterThan(alphaPixelCount(swiftImage), 0)
      XCTAssertGreaterThan(alphaPixelCount(canvasImage), 0)
      XCTAssertGreaterThan(pixelDifferenceCount(plainImage, swiftImage), 0)
      XCTAssertGreaterThan(pixelDifferenceCount(plainImage, canvasImage), 0)
      XCTAssertEqual(
        nativeSwift.writingMaterialPlansForTesting,
        nativeCanvas.writingMaterialPlansForTesting
      )
      let point = try InlineHitPoint(x: 4, y: max(1, layout.height / 2))
      XCTAssertEqual(nativeSwift.hitTest(point), plain.hitTest(point))
      swiftCachedConfigurationCount = nativeSwift.writingMaterialCachedConfigurationCountForTesting
      canvasCachedConfigurationCount = nativeCanvas.writingMaterialCachedConfigurationCountForTesting
    }
    XCTAssertEqual(swiftCachedConfigurationCount, 2)
    XCTAssertEqual(canvasCachedConfigurationCount, 2)
  }

  func testNativeChalkChangesOrdinaryTextAndPreservesMixedColorGlyphs() throws {
    let ordinaryStyle = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica-Bold", pointSize: 34))
    let ordinary = try InlineAtom.text(
      InlineTextAtom(id: "chalk-ordinary", text: "Chalk material", style: ordinaryStyle))
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [ordinary]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 280)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: EmptyAssetProvider())
    let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: EmptyAssetProvider())
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
    let size = CGSize(width: viewport.width, height: viewport.height)
    let plainSwift = try renderBack(
      InlineSwiftUIRenderer(content: swiftContent, viewport: viewport), size: size)
    let plainCanvas = try renderBack(
      InlineCanvasRenderer(content: canvasContent, viewport: viewport), size: size)
    let chalkMaterial = InlineRendererMaterial.chalk(.default)
    let chalkSwift = InlineSwiftUIRenderer(
      content: swiftContent, viewport: viewport, material: chalkMaterial)
    let chalkCanvas = InlineCanvasRenderer(
      content: canvasContent, viewport: viewport, material: chalkMaterial)
    let chalkSwiftImage = try renderBack(chalkSwift, size: size)
    let chalkCanvasImage = try renderBack(chalkCanvas, size: size)

    XCTAssertEqual(chalkSwift.writingMaterialPlanCountForTesting, 0)
    XCTAssertEqual(chalkCanvas.writingMaterialPlanCountForTesting, 0)
    XCTAssertEqual(chalkSwift.writingMaterialMarkCountForTesting, 0)
    XCTAssertEqual(chalkCanvas.writingMaterialMarkCountForTesting, 0)
    XCTAssertGreaterThan(pixelDifferenceCount(plainSwift, chalkSwiftImage), 0)
    XCTAssertGreaterThan(pixelDifferenceCount(plainCanvas, chalkCanvasImage), 0)
    XCTAssertLessThanOrEqual(
      pixelDifferenceCount(chalkSwiftImage, chalkCanvasImage),
      max(512, chalkSwiftImage.width * chalkSwiftImage.height / 2)
    )

    for textureStyle in [WritingChalkTextureStyle.photographic, .referenceSampled] {
      let styleMaterial = InlineRendererMaterial.chalk(
        try WritingChalkConfiguration(textureStyle: textureStyle))
      let styleSwiftImage = try renderBack(
        InlineSwiftUIRenderer(
          content: swiftContent, viewport: viewport, material: styleMaterial),
        size: size
      )
      let styleCanvasImage = try renderBack(
        InlineCanvasRenderer(
          content: canvasContent, viewport: viewport, material: styleMaterial),
        size: size
      )
      XCTAssertGreaterThan(pixelDifferenceCount(chalkSwiftImage, styleSwiftImage), 0)
      XCTAssertGreaterThan(pixelDifferenceCount(chalkCanvasImage, styleCanvasImage), 0)
    }
  }

  func testNativeMaterialLeavesImagesUntouchedAcrossAdapters() throws {
    let data = try XCTUnwrap(Data(base64Encoded: Self.twoByOnePNG))
    let rendition = try InlineImageRendition(
      encoding: .png, encodedBytes: data, pixelWidth: 2, pixelHeight: 1)
    let assetID = try InlineAssetID(rawValue: "native-image")
    let reference = try InlineImageReference(
      assetID: assetID, version: 1, digest: InlineAssetDigest(data: data))
    let payload = try InlineImagePayload(reference: reference, rendition: rendition)
    let metrics = try InlineMetrics(advance: 24, ascent: 18, descent: 6)
    let atom = try InlineImageAtom(
      id: "native-image",
      reference: reference,
      metrics: metrics,
      presentation: .thumbnail(contentMode: .fit),
      accessibility: .label("Native image")
    )
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [.image(atom)]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 64)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let imageStore = try InlineImageAssetStore(payloads: [payload])
    let swiftContent = try InlineSwiftUIRenderContent(
      plan: plan, assets: EmptyAssetProvider(), imageAssets: imageStore)
    let canvasContent = try InlineCanvasRenderContent(
      plan: plan, assets: EmptyAssetProvider(), imageAssets: imageStore)
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 64, height: 32)
    let plainSwift = try renderBack(
      InlineSwiftUIRenderer(content: swiftContent, viewport: viewport),
      size: CGSize(width: 64, height: 32))
    let plainCanvas = try renderBack(
      InlineCanvasRenderer(content: canvasContent, viewport: viewport),
      size: CGSize(width: 64, height: 32))

    let materials: [InlineRendererMaterial] = [
      .chalk(.default), .brush(.default), .pen(.default), .ink(.default),
    ]
    for material in materials {
      let swift = InlineSwiftUIRenderer(
        content: swiftContent, viewport: viewport, material: material)
      let canvas = InlineCanvasRenderer(
        content: canvasContent, viewport: viewport, material: material)
      XCTAssertEqual(swift.writingMaterialTargetCountForTesting, 0)
      XCTAssertEqual(canvas.writingMaterialTargetCountForTesting, 0)
      XCTAssertEqual(
        pixelDifferenceCount(
          plainSwift,
          try renderBack(swift, size: CGSize(width: 64, height: 32))),
        0
      )
      XCTAssertEqual(
        pixelDifferenceCount(
          plainCanvas,
          try renderBack(canvas, size: CGSize(width: 64, height: 32))),
        0
      )
    }
  }

  func testNativeMaterialBypassesMixedCoreTextColorGlyphs() throws {
    let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 28, nil)
    guard CTFontCopyPostScriptName(font) as String? == "AppleColorEmoji" else {
      throw XCTSkip("AppleColorEmoji is unavailable on this platform")
    }
    let ordinaryStyle = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 28))
    let emojiStyle = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "AppleColorEmoji", pointSize: 28))
    let ordinary = try InlineAtom.text(
      InlineTextAtom(id: "ordinary", text: "ordinary ", style: ordinaryStyle))
    let emoji = try InlineAtom.text(
      InlineTextAtom(id: "emoji", text: "🧪✨👩‍💻", style: emojiStyle))
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [ordinary, emoji]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 320)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: EmptyAssetProvider())
    let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: EmptyAssetProvider())
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 320, height: 64)
    let size = CGSize(width: 320, height: 64)
    let plainSwift = InlineSwiftUIRenderer(content: swiftContent, viewport: viewport)
    let plainCanvas = InlineCanvasRenderer(content: canvasContent, viewport: viewport)
    let nativeSwift = InlineSwiftUIRenderer(
      content: swiftContent, viewport: viewport, material: .chalk(.default))
    let nativeCanvas = InlineCanvasRenderer(
      content: canvasContent, viewport: viewport, material: .chalk(.default))
    let plainSwiftImage = try renderBack(plainSwift, size: size)
    let plainCanvasImage = try renderBack(plainCanvas, size: size)
    let nativeSwiftImage = try renderBack(nativeSwift, size: size)
    let nativeCanvasImage = try renderBack(nativeCanvas, size: size)

    XCTAssertGreaterThan(pixelDifferenceCount(plainSwiftImage, nativeSwiftImage), 0)
    XCTAssertGreaterThan(pixelDifferenceCount(plainCanvasImage, nativeCanvasImage), 0)
    XCTAssertGreaterThan(chromaticPixelCount(plainSwiftImage), 0)
    XCTAssertGreaterThan(chromaticPixelCount(nativeSwiftImage), 0)
    XCTAssertGreaterThan(chromaticPixelCount(plainCanvasImage), 0)
    XCTAssertGreaterThan(chromaticPixelCount(nativeCanvasImage), 0)
    XCTAssertEqual(nativeSwift.writingMaterialPlanCountForTesting, 0)
    XCTAssertEqual(nativeCanvas.writingMaterialPlanCountForTesting, 0)
    let swiftEmojiID = try XCTUnwrap(
      plan.geometry.compactMap { item -> PositionedInlineAtom? in
        guard case .text(let positioned, let prepared) = item,
          prepared.atom.id == "emoji"
        else { return nil }
        return positioned
      }.first
    )
    let canvasEmojiID = swiftEmojiID
    XCTAssertNil(nativeSwift.writingMaterialPlansForTesting[swiftEmojiID])
    XCTAssertNil(nativeCanvas.writingMaterialPlansForTesting[canvasEmojiID])
  }

  func testNativeMaterialRevealPhasesAndAdapterParity() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica-Bold", pointSize: 30))
    let atom = try InlineAtom.text(
      InlineTextAtom(
        id: "revealed-material",
        text: String(repeating: "material reveal ", count: 8),
        style: style
      ))
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 340)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let textPlan = try InlineRevealPlanBuilder().graphemePlan(prepared: prepared)
    let schedule = try InlineRenderRevealSchedule(
      plan: plan, assets: InlineAssetStore(), textPlan: textPlan)
    let swiftContent = try InlineSwiftUIRenderContent(
      plan: plan, assets: EmptyAssetProvider(), schedule: schedule)
    let canvasContent = try InlineCanvasRenderContent(
      plan: plan, assets: EmptyAssetProvider(), schedule: schedule)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
    let size = CGSize(width: viewport.width, height: viewport.height)
    let zero = try InlineRenderRevealPhase(rawValue: 0)
    let middle = try InlineRenderRevealPhase(rawValue: 0.5)
    let materials: [InlineRendererMaterial] = [
      .chalk(.default), .brush(.default), .pen(.default), .ink(.default),
    ]
    for material in materials {
      let swiftZero = try renderBack(
        InlineSwiftUIRenderer(
          content: swiftContent, phase: zero, viewport: viewport, material: material),
        size: size)
      let swiftMiddleRenderer = InlineSwiftUIRenderer(
        content: swiftContent, phase: middle, viewport: viewport, material: material)
      let canvasMiddleRenderer = InlineCanvasRenderer(
        content: canvasContent, phase: middle, viewport: viewport, material: material)
      let swiftMiddle = try renderBack(swiftMiddleRenderer, size: size)
      let swiftComplete = try renderBack(
        InlineSwiftUIRenderer(content: swiftContent, viewport: viewport, material: material),
        size: size)
      let canvasComplete = try renderBack(
        InlineCanvasRenderer(content: canvasContent, viewport: viewport, material: material),
        size: size)
      XCTAssertEqual(alphaPixelCount(swiftZero), 0)
      XCTAssertGreaterThan(alphaPixelCount(swiftMiddle), 0)
      XCTAssertGreaterThan(alphaPixelCount(swiftComplete), alphaPixelCount(swiftMiddle))
      XCTAssertLessThanOrEqual(
        abs(alphaPixelCount(swiftComplete) - alphaPixelCount(canvasComplete)),
        max(32, alphaPixelCount(swiftComplete) / 10)
      )
      XCTAssertLessThanOrEqual(
        pixelDifferenceCount(swiftMiddle, try renderBack(canvasMiddleRenderer, size: size)),
        max(512, swiftMiddle.width * swiftMiddle.height / 2)
      )
    }

    // Repeated reveal frames must reuse the one immutable positive plan for a
    // material/target set. The viewport/reveal selection is allowed to change,
    // but plan construction must not run once per frame.
    let phaseProbeSwift = InlineSwiftUIRenderer(
      content: swiftContent, phase: middle, viewport: viewport, material: .chalk(.default))
    let phaseProbeCanvas = InlineCanvasRenderer(
      content: canvasContent, phase: middle, viewport: viewport, material: .chalk(.default))
    _ = try renderBack(phaseProbeSwift, size: size)
    _ = try renderBack(phaseProbeCanvas, size: size)
    let swiftBuildCount = phaseProbeSwift.writingMaterialPlanBuildCountForTesting
    let canvasBuildCount = phaseProbeCanvas.writingMaterialPlanBuildCountForTesting
    for rawValue in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0] {
      let phase = try InlineRenderRevealPhase(rawValue: rawValue)
      _ = try renderBack(
        InlineSwiftUIRenderer(
          content: swiftContent, phase: phase, viewport: viewport, material: .chalk(.default)),
        size: size
      )
      _ = try renderBack(
        InlineCanvasRenderer(
          content: canvasContent, phase: phase, viewport: viewport, material: .chalk(.default)),
        size: size
      )
    }
    XCTAssertEqual(phaseProbeSwift.writingMaterialPlanBuildCountForTesting, swiftBuildCount)
    XCTAssertEqual(phaseProbeCanvas.writingMaterialPlanBuildCountForTesting, canvasBuildCount)
  }

  func testLongDocumentMaterializationIsSparseAndGloballyBounded() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 16))
    let atoms = try (0..<2_000).map { index in
      try InlineAtom.text(
        InlineTextAtom(id: "long-" + String(index), text: "x", style: style))
    }
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: atoms))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 320)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let swiftContent = try InlineSwiftUIRenderContent(
      plan: renderPlan, assets: EmptyAssetProvider())
    let canvasContent = try InlineCanvasRenderContent(
      plan: renderPlan, assets: EmptyAssetProvider())
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: 320, height: 32)
    let material = InlineRendererMaterial.brush(.default)
    let swift = InlineSwiftUIRenderer(
      content: swiftContent, viewport: viewport, material: material)
    let canvas = InlineCanvasRenderer(
      content: canvasContent, viewport: viewport, material: material)
    let shifted = InlineSwiftUIRenderer(
      content: swiftContent,
      viewport: try InlineRenderViewport(x: 0, y: 1, width: 320, height: 32),
      material: material)

    XCTAssertGreaterThan(swift.writingMaterialTargetCountForTesting, 1_000)
    XCTAssertEqual(
      swift.writingMaterialTargetCountForTesting,
      canvas.writingMaterialTargetCountForTesting)
    XCTAssertLessThan(
      swift.writingMaterialPlanCountForTesting,
      swift.writingMaterialTargetCountForTesting / 10)
    XCTAssertLessThan(
      canvas.writingMaterialPlanCountForTesting,
      canvas.writingMaterialTargetCountForTesting / 10)
    XCTAssertLessThanOrEqual(
      swift.writingMaterialMarkCountForTesting,
      WritingMaterialPlan.maximumMarks)
    XCTAssertLessThanOrEqual(
      canvas.writingMaterialMarkCountForTesting,
      WritingMaterialPlan.maximumMarks)
    XCTAssertEqual(swift.writingMaterialPlanBuildCountForTesting, 1)
    XCTAssertEqual(canvas.writingMaterialPlanBuildCountForTesting, 1)
    let commonTargets = Set(swift.writingMaterialPlansForTesting.keys).intersection(
      shifted.writingMaterialPlansForTesting.keys)
    XCTAssertFalse(commonTargets.isEmpty)
    for target in commonTargets {
      XCTAssertEqual(
        swift.writingMaterialPlansForTesting[target],
        shifted.writingMaterialPlansForTesting[target]
      )
    }

    let chalk = InlineRendererMaterial.chalk(.default)
    let chalkSwift = InlineSwiftUIRenderer(
      content: swiftContent, viewport: viewport, material: chalk)
    let chalkShifted = InlineSwiftUIRenderer(
      content: swiftContent,
      viewport: try InlineRenderViewport(x: 0, y: 1, width: 320, height: 32),
      material: chalk)
    XCTAssertEqual(chalkSwift.writingMaterialPlanBuildCountForTesting, 1)
    XCTAssertEqual(chalkShifted.writingMaterialPlanBuildCountForTesting, 1)
    XCTAssertTrue(chalkSwift.writingMaterialPlansForTesting.isEmpty)
    XCTAssertTrue(chalkShifted.writingMaterialPlansForTesting.isEmpty)
  }

  private struct EmptyAssetProvider: InlineAssetGeometryProvider {
    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      throw InlineAssetResolutionError.missingGeometry(assetID, version: version)
    }
  }

  private func renderBack<Content: View>(_ content: Content, size: CGSize) throws -> CGImage {
    let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
    renderer.scale = 1
    guard let image = renderer.cgImage else {
      throw XCTSkip("SwiftUI ImageRenderer did not produce a CGImage")
    }
    return image
  }

  private func alphaPixelCount(_ image: CGImage) -> Int {
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
      data: &rgba,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return stride(from: 3, to: rgba.count, by: 4).reduce(into: 0) { count, index in
      if rgba[index] > 0 { count += 1 }
    }
  }

  private func alphaCoverage(_ image: CGImage) -> Int {
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
      data: &rgba,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return stride(from: 3, to: rgba.count, by: 4).reduce(into: 0) { coverage, index in
      coverage += Int(rgba[index])
    }
  }

  private func alphaCoverage(_ image: CGImage, outside rect: CGRect) -> Int {
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
      data: &rgba,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    var coverage = 0
    for y in 0..<image.height {
      for x in 0..<image.width {
        let index = (y * image.width + x) * 4
        guard !rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) else {
          continue
        }
        coverage += Int(rgba[index + 3])
      }
    }
    return coverage
  }

  private func alphaPixelCount(_ image: CGImage, outside rect: CGRect) -> Int {
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
      data: &rgba,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    var count = 0
    for y in 0..<image.height {
      for x in 0..<image.width {
        let index = (y * image.width + x) * 4
        guard rgba[index + 3] > 0 else { continue }
        guard !rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) else {
          continue
        }
        count += 1
      }
    }
    return count
  }

  private func alphaPixelBounds(_ image: CGImage) -> CGRect? {
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
      data: &rgba,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    var minX = image.width
    var minY = image.height
    var maxX = -1
    var maxY = -1
    for y in 0..<image.height {
      for x in 0..<image.width {
        let index = (y * image.width + x) * 4
        guard rgba[index + 3] > 0 else { continue }
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(
      x: minX,
      y: minY,
      width: maxX - minX + 1,
      height: maxY - minY + 1
    )
  }

  private func channelMeans(_ image: CGImage) -> (red: Double, green: Double, blue: Double) {
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
      data: &rgba,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return (0, 0, 0) }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    var totalAlpha = 0.0
    var channels = (red: 0.0, green: 0.0, blue: 0.0)
    for index in stride(from: 0, to: rgba.count, by: 4) {
      let alpha = Double(rgba[index + 3])
      guard alpha > 0 else { continue }
      totalAlpha += alpha
      channels.red += Double(rgba[index])
      channels.green += Double(rgba[index + 1])
      channels.blue += Double(rgba[index + 2])
    }
    guard totalAlpha > 0 else { return (0, 0, 0) }
    return (
      channels.red / totalAlpha,
      channels.green / totalAlpha,
      channels.blue / totalAlpha
    )
  }

  private func chromaticPixelCount(_ image: CGImage) -> Int {
    var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
      data: &rgba,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return stride(from: 0, to: rgba.count, by: 4).reduce(into: 0) { count, index in
      guard rgba[index + 3] > 0 else { return }
      if rgba[index] != rgba[index + 1] || rgba[index + 1] != rgba[index + 2] {
        count += 1
      }
    }
  }

  private func pixelDifferenceCount(
    _ lhs: CGImage, _ rhs: CGImage, channelTolerance: Int = 0
  ) -> Int {
    guard lhs.width == rhs.width, lhs.height == rhs.height else { return Int.max }
    func bytes(_ image: CGImage) -> [UInt8] {
      var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
      guard let context = CGContext(
        data: &values,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return [] }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return values
    }
    let left = bytes(lhs)
    let right = bytes(rhs)
    guard left.count == right.count else { return Int.max }
    return stride(from: 0, to: left.count, by: 4).reduce(into: 0) { count, index in
      if abs(Int(left[index]) - Int(right[index])) > channelTolerance
        || abs(Int(left[index + 1]) - Int(right[index + 1])) > channelTolerance
        || abs(Int(left[index + 2]) - Int(right[index + 2])) > channelTolerance
        || abs(Int(left[index + 3]) - Int(right[index + 3])) > channelTolerance
      {
        count += 1
      }
    }
  }

  private static let twoByOnePNG =
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADUlEQVR4nGP4z8AAQgAL/AL+XdyCPwAAAABJRU5ErkJggg=="
}
