import CoreGraphics
import LiveTextLayout
import LiveTextCore
@testable import LiveTextAppleRendering
@testable import LiveTextCanvas
@testable import LiveTextSwiftUI
import SwiftUI
import XCTest

private struct EffectsFixedShaper: InlineTextShaping {
  let advance: Double

  func shape(
    text: String, style: InlineTextStyle, sourceRange: InlineSourceRange
  ) throws -> InlineShapedText {
    var ranges: [InlineSourceRange] = []
    var offset = sourceRange.startUTF16
    for grapheme in text {
      let length = String(grapheme).utf16.count
      ranges.append(try InlineSourceRange(startUTF16: offset, endUTF16: offset + length))
      offset += length
    }
    return try InlineShapedText(
      graphemeRanges: ranges,
      graphemeAdvances: Array(repeating: advance, count: ranges.count),
      runs: [],
      metrics: try InlineMetrics(
        advance: advance * Double(ranges.count),
        ascent: style.font.pointSize,
        descent: 2,
        baselineOffset: style.baselineOffset
      )
    )
  }
}

private struct EffectsGeometryProvider: InlineAssetGeometryProvider {
  let values: [InlineAssetID: InlineSVGAsset]

  func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
    guard let asset = values[assetID] else {
      throw InlineAssetResolutionError.missingGeometry(assetID, version: version)
    }
    return asset
  }
}

private struct EffectsEmptyGeometryProvider: InlineAssetGeometryProvider {
  func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
    throw InlineAssetResolutionError.missingGeometry(assetID, version: version)
  }
}

private struct StaticCompositionFailureProvider: InlineAssetGeometryProvider {
  let artwork: InlineSVGAsset

  func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
    if assetID == artwork.id { return artwork }
    throw InlineAssetResolutionError.versionMismatch(
      assetID, expected: version, actual: version + 1)
  }
}

@MainActor
final class InlineEffectsContractTests: XCTestCase {
  private func style() throws -> InlineTextStyle {
    try InlineTextStyle(font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
  }

  private func multilinePlan() throws -> InlineRenderPlan {
    let text = try InlineAtom.text(
      InlineTextAtom(id: "wrapped", text: String(repeating: "a", count: 6), style: style()))
    let prepared = try InlinePreparation(shaper: EffectsFixedShaper(advance: 1))
      .prepare(document: InlineDocument(atoms: [text]))
    guard case .text(let preparedText) = prepared.atoms[0] else {
      throw InlineLayoutError.invalidRenderPlan
    }
    let lineHeight = preparedText.metrics.ascent + preparedText.metrics.descent
    let lines = try (0..<6).map { index in
      let range = try InlineSourceRange(startUTF16: index, endUTF16: index + 1)
      let positioned = try PositionedInlineAtom(
        atomID: "wrapped",
        kind: .text,
        lineIndex: index,
        originX: 0,
        baselineY: preparedText.metrics.ascent + Double(index) * lineHeight,
        width: 1,
        height: lineHeight,
        metrics: preparedText.metrics,
        sourceRange: range)
      return try InlineLayoutLine(
        index: index,
        baselineY: positioned.baselineY,
        ascent: preparedText.metrics.ascent,
        descent: preparedText.metrics.descent,
        leading: 0,
        width: 1,
        start: InlineCursor(atomIndex: 0, graphemeIndex: index),
        end: InlineCursor(atomIndex: 0, graphemeIndex: index + 1),
        atoms: [positioned])
    }
    let layout = InlineLayoutResult(
      lines: lines,
      width: 1,
      height: lineHeight * 6,
      preparationRevision: prepared.revision,
      continuation: nil)
    return try InlineRenderPlan(prepared: prepared, layout: layout)
  }

  func testHostSelectionUsesLogicalIdentityAndEveryMultilineFragment() throws {
    let plan = try multilinePlan()
    let original = plan
    let expectedRange = try InlineSourceRange(startUTF16: 0, endUTF16: 6)
    let hits = plan.hitIndex.textUnitHits(atomID: "wrapped", sourceRange: expectedRange)
    XCTAssertEqual(hits.count, 6)
    XCTAssertEqual(Set(hits.map(\.lineIndex)), Set(0..<6))

    let state = try InlineTextUnitSelectionState(
      preparationRevision: plan.prepared.revision,
      hitProfile: plan.hitIndex.profile)
    let next = try state.applying(try state.activationEvent(for: hits[0]))
    let selection = try XCTUnwrap(next.selected)
    let effect = try InlineHighlightPlan(renderPlan: plan, selection: selection)
    XCTAssertEqual(effect.fragments.count, hits.count)
    XCTAssertEqual(effect.fragments.map(\.lineIndex), hits.map(\.lineIndex))
    XCTAssertEqual(plan, original, "effects must not mutate layout, hit, or reveal input")
  }

  func testSelectionCJKRTLAndLigatureSourceIdentityDoesNotStoreGeometry() throws {
    let source = "ffi אבג 한글"
    let atom = try InlineAtom.text(InlineTextAtom(id: "mixed", text: source, style: style()))
    let prepared = try InlinePreparation(shaper: EffectsFixedShaper(advance: 8))
      .prepare(document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 500)
    let index = try InlineHitTestIndex.build(prepared: prepared, layout: layout)
    let ffi = try InlineSourceRange(startUTF16: 0, endUTF16: 3)
    let rtl = try InlineSourceRange(startUTF16: 4, endUTF16: 7)
    let cjkFirst = try InlineSourceRange(startUTF16: 8, endUTF16: 9)

    let ffiHit = try XCTUnwrap(index.textUnitHits(atomID: "mixed", sourceRange: ffi).first)
    XCTAssertNotNil(index.textUnitHits(atomID: "mixed", sourceRange: rtl).first)
    XCTAssertNotNil(index.textUnitHits(atomID: "mixed", sourceRange: cjkFirst).first)

    let key = try InlineSelectionKey(
      hit: ffiHit, preparationRevision: prepared.revision, hitProfile: index.profile)
    XCTAssertEqual(key.atomID, "mixed")
    XCTAssertEqual(key.sourceRange, ffi)
    XCTAssertFalse(String(describing: key).contains("rect"))
  }

  func testSelectionRejectsStaleAndCancelledEffectsWithoutChangingState() throws {
    let plan = try multilinePlan()
    let hit = try XCTUnwrap(plan.hitIndex.allTextUnitHits.first)
    let state = try InlineTextUnitSelectionState(
      preparationRevision: plan.prepared.revision,
      hitProfile: plan.hitIndex.profile)
    let staleKey = try InlineSelectionKey(
      hit: hit,
      preparationRevision: plan.prepared.revision + "-stale",
      hitProfile: plan.hitIndex.profile)
    XCTAssertThrowsError(try state.applying(.select(staleKey))) { error in
      let transition = error as? InlineSelectionTransitionError
      XCTAssertEqual(transition?.operation, "selection.select")
      XCTAssertEqual(transition?.targetID, hit.atomID)
      XCTAssertEqual(transition?.preparationRevision, plan.prepared.revision)
    }

    XCTAssertThrowsError(
      try InlineHighlightPlan(
        renderPlan: plan,
        selection: try XCTUnwrap(try state.applying(try state.activationEvent(for: hit)).selected),
        cancellation: { throw InlineLayoutError.cancelled })
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .cancelled)
    }
    XCTAssertNil(state.selected)
  }

  func testHighlightStylesValidateAndDecodeStrictly() throws {
    let color = try InlineHighlightColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.7)
    let styles: [InlineHighlightStyle] = [
      .highlighter(color: color, opacity: 0.4, cornerRadius: 2),
      .underline(color: color, thickness: 1, offset: 2),
      .outline(color: color, thickness: 1),
    ]
    for style in styles {
      let decoded = try JSONDecoder().decode(
        InlineHighlightStyle.self, from: JSONEncoder().encode(style))
      XCTAssertEqual(decoded, style)
    }

    let invalidColor = try JSONSerialization.data(withJSONObject: [
      "red": 2.0, "green": 0.0, "blue": 0.0, "alpha": 1.0,
    ])
    XCTAssertThrowsError(
      try JSONDecoder().decode(InlineHighlightColor.self, from: invalidColor))

    let invalidStyle = try JSONSerialization.data(withJSONObject: [
      "kind": "highlighter",
      "color": ["red": 1.0, "green": 0.0, "blue": 0.0, "alpha": 1.0],
      "opacity": 2.0,
      "cornerRadius": 1.0,
    ])
    XCTAssertThrowsError(
      try JSONDecoder().decode(InlineHighlightStyle.self, from: invalidStyle))

    let invalidFragment = try JSONSerialization.data(withJSONObject: [
      "atomID": "word",
      "sourceRange": ["startUTF16": 0, "endUTF16": 1],
      "lineIndex": -1,
      "rect": ["minX": 0.0, "minY": 0.0, "width": 1.0, "height": 1.0],
    ])
    XCTAssertThrowsError(
      try JSONDecoder().decode(InlineHighlightFragment.self, from: invalidFragment))

    let missingSelectionKey = try JSONSerialization.data(withJSONObject: [
      "sourceRange": ["startUTF16": 0, "endUTF16": 1],
      "preparationRevision": "revision",
      "hitProfile": [
        "cjk": "eachGrapheme", "punctuation": "exclude",
        "includeWhitespace": false, "includeVectors": true, "includeImages": true,
      ],
    ])
    XCTAssertThrowsError(
      try JSONDecoder().decode(InlineSelectionKey.self, from: missingSelectionKey))

    let invalidState = try JSONSerialization.data(withJSONObject: [
      "preparationRevision": "revision",
      "hitProfile": [
        "cjk": "eachGrapheme", "punctuation": "exclude",
        "includeWhitespace": false, "includeVectors": true, "includeImages": true,
      ],
      "selected": [
        "atomID": "word",
        "sourceRange": ["startUTF16": 0, "endUTF16": 1],
        "preparationRevision": "other",
        "hitProfile": [
          "cjk": "eachGrapheme", "punctuation": "exclude",
          "includeWhitespace": false, "includeVectors": true, "includeImages": true,
        ],
      ],
    ])
    XCTAssertThrowsError(
      try JSONDecoder().decode(InlineTextUnitSelectionState.self, from: invalidState))
  }

  func testRendererThrowingInitRejectsStaleHighlightHandoff() throws {
    let plan = try multilinePlan()
    let hit = try XCTUnwrap(plan.hitIndex.allTextUnitHits.first)
    let state = try InlineTextUnitSelectionState(
      preparationRevision: plan.prepared.revision,
      hitProfile: plan.hitIndex.profile)
    let selection = try XCTUnwrap(
      try state.applying(try state.activationEvent(for: hit)).selected)
    let valid = try InlineHighlightPlan(renderPlan: plan, selection: selection)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
    object["preparationRevision"] = "stale"
    var encodedSelection = try XCTUnwrap(object["selection"] as? [String: Any])
    encodedSelection["preparationRevision"] = "stale"
    object["selection"] = encodedSelection
    let stale = try JSONDecoder().decode(
      InlineHighlightPlan.self,
      from: JSONSerialization.data(withJSONObject: object))
    let provider = EffectsEmptyGeometryProvider()
    let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: provider)
    let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: provider)
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 1, height: 84)
    XCTAssertThrowsError(
      try InlineSwiftUIRenderer(
        validating: swiftContent, viewport: viewport, highlight: stale)) { error in
      let failure = error as? InlineSelectionTransitionError
      XCTAssertEqual(failure?.operation, "highlight.validate")
      XCTAssertEqual(failure?.preparationRevision, plan.prepared.revision)
    }
    XCTAssertThrowsError(
      try InlineCanvasRenderer(
        validating: canvasContent, viewport: viewport, highlight: stale)) { error in
      let failure = error as? InlineSelectionTransitionError
      XCTAssertEqual(failure?.operation, "highlight.validate")
      XCTAssertEqual(failure?.preparationRevision, plan.prepared.revision)
    }
  }

  func testPublicAccessibilityRepresentationRejectsStaleWordInput() throws {
    let plan = try multilinePlan()
    let hit = try XCTUnwrap(plan.hitIndex.allTextUnitHits.first)
    let staleSelection = try InlineSelectionKey(
      hit: hit,
      preparationRevision: plan.prepared.revision + "-stale",
      hitProfile: plan.hitIndex.profile)
    XCTAssertThrowsError(
      try InlineAccessibilityRepresentation(
        validating: plan.prepared,
        hitIndex: plan.hitIndex,
        selection: staleSelection)) { error in
      let failure = error as? InlineSelectionTransitionError
      XCTAssertEqual(failure?.operation, "accessibility.textUnits")
      XCTAssertEqual(failure?.targetID, staleSelection.atomID)
      XCTAssertEqual(failure?.preparationRevision, plan.prepared.revision)
    }

    let otherAtom = try InlineAtom.text(
      InlineTextAtom(id: "other", text: "b", style: style()))
    let otherPrepared = try InlinePreparation(shaper: EffectsFixedShaper(advance: 1))
      .prepare(document: InlineDocument(atoms: [otherAtom]))
    let otherLayout = try InlineLayoutEngine().layout(prepared: otherPrepared, width: 1)
    let staleHitIndex = try InlineHitTestIndex.build(
      prepared: otherPrepared, layout: otherLayout)
    XCTAssertThrowsError(
      try InlineAccessibilityRepresentation(
        validating: plan.prepared, hitIndex: staleHitIndex)) { error in
      let failure = error as? InlineSelectionTransitionError
      XCTAssertEqual(failure?.operation, "accessibility.textUnits")
      XCTAssertEqual(failure?.preparationRevision, plan.prepared.revision)
    }
  }

  func testSwiftUICanvasActivationCallbacksReceiveTheSameWordHit() throws {
    let plan = try multilinePlan()
    let hit = try XCTUnwrap(plan.hitIndex.allTextUnitHits.first)
    let swiftContent = try InlineSwiftUIRenderContent(
      plan: plan, assets: EffectsEmptyGeometryProvider())
    let canvasContent = try InlineCanvasRenderContent(
      plan: plan, assets: EffectsEmptyGeometryProvider())
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 1, height: 84)
    var swiftActivation: InlineTextUnitHit?
    var canvasActivation: InlineTextUnitHit?
    let swift = InlineSwiftUIRenderer(
      content: swiftContent,
      viewport: viewport,
      onTextUnitActivation: { swiftActivation = $0 })
    let canvas = InlineCanvasRenderer(
      content: canvasContent,
      viewport: viewport,
      onTextUnitActivation: { canvasActivation = $0 })
    let point = try InlineHitPoint(
      x: hit.rect.minX + hit.rect.width / 2,
      y: hit.rect.minY + hit.rect.height / 2)
    XCTAssertEqual(swift.activate(atViewportPoint: point), .textUnit(hit))
    XCTAssertEqual(canvas.activate(atViewportPoint: point), .textUnit(hit))
    XCTAssertEqual(swiftActivation, hit)
    XCTAssertEqual(canvasActivation, hit)
  }

  func testSwiftUICanvasShareDeduplicatedWordAccessibilityProjection() throws {
    let plan = try multilinePlan()
    let hit = try XCTUnwrap(plan.hitIndex.allTextUnitHits.first)
    let state = try InlineTextUnitSelectionState(
      preparationRevision: plan.prepared.revision,
      hitProfile: plan.hitIndex.profile)
    let selection = try XCTUnwrap(
      try state.applying(try state.activationEvent(for: hit)).selected)
    let projection = try InlineAccessibilityProjection(
      prepared: plan.prepared, hitIndex: plan.hitIndex, selection: selection)
    let textAtom = try XCTUnwrap(projection.atoms.first { $0.atomID == "wrapped" })
    XCTAssertEqual(textAtom.kind, .text)
    XCTAssertEqual(textAtom.label, "aaaaaa")
    XCTAssertEqual(projection.units.count, 1, "wrapped fragments must dedupe to one word")
    XCTAssertEqual(projection.units[0].label, "aaaaaa")
    XCTAssertEqual(projection.units[0].sourceRange, selection.sourceRange)
    XCTAssertTrue(projection.units[0].isSelected)
    XCTAssertTrue(projection.units[0].isButton)
    XCTAssertEqual(projection.units[0].accessibilityValue, "Selected text unit")
    XCTAssertEqual(projection.units[0].id, "wrapped:word:-:0:6")

    let encodedProjection = try JSONEncoder().encode(projection)
    XCTAssertEqual(
      try JSONDecoder().decode(InlineAccessibilityProjection.self, from: encodedProjection),
      projection)
    var missingUnits = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encodedProjection) as? [String: Any])
    missingUnits.removeValue(forKey: "units")
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlineAccessibilityProjection.self,
        from: JSONSerialization.data(withJSONObject: missingUnits)))
    var invalidUnit = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encodedProjection) as? [String: Any])
    var units = try XCTUnwrap(invalidUnit["units"] as? [[String: Any]])
    units[0]["label"] = ""
    invalidUnit["units"] = units
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlineAccessibilityProjection.self,
        from: JSONSerialization.data(withJSONObject: invalidUnit)))

    let swiftContent = try InlineSwiftUIRenderContent(
      plan: plan, assets: EffectsEmptyGeometryProvider())
    let canvasContent = try InlineCanvasRenderContent(
      plan: plan, assets: EffectsEmptyGeometryProvider())
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 1, height: 84)
    let swift = try InlineSwiftUIRenderer(
      validating: swiftContent, viewport: viewport,
      highlight: try InlineHighlightPlan(renderPlan: plan, selection: selection))
    let canvas = try InlineCanvasRenderer(
      validating: canvasContent, viewport: viewport,
      highlight: try InlineHighlightPlan(renderPlan: plan, selection: selection))
    XCTAssertEqual(swift.accessibilityProjectionForTesting, canvas.accessibilityProjectionForTesting)
    XCTAssertEqual(swift.accessibilityProjectionForTesting.units, projection.units)
  }

  func testSVGCompositionSeparatesArtworkFromCanonicalDeclarationOrder() throws {
    let fixture = try vectorFixture()
    let artwork = try InlineSVGCompositionInstance(
      instanceID: "artwork-instance",
      assetID: fixture.artwork.id,
      assetVersion: fixture.artwork.version,
      sourceAtomID: "vector",
      role: .artwork,
      declarationOrder: 10)
    let mask = try InlineSVGCompositionInstance(
      instanceID: "mask-instance",
      assetID: fixture.artwork.id,
      assetVersion: fixture.artwork.version,
      role: .mask,
      targetID: "vector",
      operation: .reveal,
      declarationOrder: 20)
    let composition = try InlineSVGCompositionPlan(
      preparationRevision: fixture.plan.prepared.revision,
      instances: [mask, artwork])
    XCTAssertEqual(composition.instances.map(\.declarationOrder), [10, 20])
    XCTAssertNoThrow(try composition.validate(prepared: fixture.plan.prepared, assets: fixture.store))

    let duplicateOrder = try InlineSVGCompositionInstance(
      instanceID: "other-mask", assetID: fixture.artwork.id,
      assetVersion: fixture.artwork.version, role: .mask,
      targetID: "vector", operation: .erase, declarationOrder: 20)
    XCTAssertThrowsError(
      try InlineSVGCompositionPlan(
        preparationRevision: fixture.plan.prepared.revision,
        instances: [mask, duplicateOrder])) { error in
      let failure = error as? InlineSVGCompositionError
      XCTAssertEqual(failure?.operation, "composition.declarationOrder")
      XCTAssertEqual(failure?.targetID, "vector")
    }

    let invalidTarget = try InlineSVGCompositionPlan(
      preparationRevision: fixture.plan.prepared.revision,
      instances: [try InlineSVGCompositionInstance(
        instanceID: "invalid-target", assetID: fixture.artwork.id,
        assetVersion: fixture.artwork.version, role: .mask,
        targetID: "missing", operation: .reveal, declarationOrder: 1)])
    XCTAssertThrowsError(
      try invalidTarget.validate(prepared: fixture.plan.prepared, assets: fixture.store)) { error in
      let failure = error as? InlineSVGCompositionError
      XCTAssertEqual(failure?.operation, "composition.mask")
      XCTAssertEqual(failure?.targetID, "missing")
      XCTAssertEqual(failure?.preparationRevision, fixture.plan.prepared.revision)
    }

    let stale = try InlineSVGCompositionPlan(
      preparationRevision: "stale",
      instances: [artwork])
    XCTAssertThrowsError(try stale.validate(prepared: fixture.plan.prepared, assets: fixture.store)) {
      error in
      let failure = error as? InlineSVGCompositionError
      XCTAssertEqual(failure?.operation, "composition.validate")
      XCTAssertEqual(failure?.preparationRevision, fixture.plan.prepared.revision)
    }
  }

  func testStaticCompositionPreservesTypedProviderFailureCause() throws {
    let fixture = try vectorFixture()
    let maskID = try InlineAssetID(rawValue: "mask-only")
    let mask = try InlineSVGCompositionInstance(
      instanceID: "mask-instance", assetID: maskID, assetVersion: 1,
      role: .mask, targetID: "vector", operation: .reveal, declarationOrder: 1)
    let composition = try InlineSVGCompositionPlan(
      preparationRevision: fixture.plan.prepared.revision, instances: [mask])
    let provider = StaticCompositionFailureProvider(artwork: fixture.artwork)

    XCTAssertThrowsError(try InlineAppleRenderContent(
      plan: fixture.plan, assets: provider, composition: composition)) { error in
      XCTAssertEqual(
        error as? InlineAssetResolutionError,
        .versionMismatch(maskID, expected: 1, actual: 2))
    }
  }

  func testSVGCompositionRejectsHostileDecodedRolesAndVersions() throws {
    let fixture = try vectorFixture()
    let instance = try InlineSVGCompositionInstance(
      instanceID: "mask", assetID: fixture.artwork.id,
      assetVersion: fixture.artwork.version, role: .mask,
      targetID: "vector", operation: .reveal, declarationOrder: 1)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(instance)) as? [String: Any])
    object["role"] = "artwork"
    object["sourceAtomID"] = NSNull()
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlineSVGCompositionInstance.self,
        from: JSONSerialization.data(withJSONObject: object)))

    let wrongVersion = try InlineSVGAsset(
      id: fixture.artwork.id, version: fixture.artwork.version + 1,
      metrics: fixture.artwork.metrics,
      coordinateBounds: fixture.artwork.coordinateBounds,
      coveragePath: fixture.artwork.coveragePath,
      coveragePaint: fixture.artwork.coveragePaint,
      trajectoryPath: fixture.artwork.trajectoryPath,
      trajectoryStyle: fixture.artwork.trajectoryStyle)
    let wrongStore = InlineAssetStore(values: [
      InlineAssetKey(id: fixture.artwork.id, version: fixture.artwork.version): wrongVersion,
    ])
    let composition = try InlineSVGCompositionPlan(
      preparationRevision: fixture.plan.prepared.revision, instances: [instance])
    XCTAssertThrowsError(
      try composition.validate(prepared: fixture.plan.prepared, assets: wrongStore)) { error in
      let failure = error as? InlineSVGCompositionError
      XCTAssertEqual(failure?.operation, "composition.resolve")
      XCTAssertEqual(failure?.targetID, "vector")
      XCTAssertEqual(failure?.preparationRevision, fixture.plan.prepared.revision)
      XCTAssertEqual(failure?.assetID, fixture.artwork.id)
      XCTAssertEqual(failure?.assetVersion, fixture.artwork.version)
      XCTAssertFalse(failure?.cause.isEmpty ?? true)
    }

    let encoded = try JSONEncoder().encode(composition)
    XCTAssertEqual(
      try JSONDecoder().decode(InlineSVGCompositionPlan.self, from: encoded), composition)
    var missingInstances = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    missingInstances.removeValue(forKey: "instances")
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlineSVGCompositionPlan.self,
        from: JSONSerialization.data(withJSONObject: missingInstances)))
  }

  func testSwiftUICanvasCompositionProjectionAndRenderBackStayIsolated() throws {
    let fixture = try vectorFixture(withHalfMask: true)
    let artwork = try InlineSVGCompositionInstance(
      instanceID: "artwork", assetID: fixture.artwork.id,
      assetVersion: fixture.artwork.version, sourceAtomID: "vector",
      role: .artwork, declarationOrder: 1)
    let mask = try InlineSVGCompositionInstance(
      instanceID: "mask", assetID: fixture.mask.id,
      assetVersion: fixture.mask.version, role: .mask,
      targetID: "vector", operation: .reveal, declarationOrder: 2)
    let composition = try InlineSVGCompositionPlan(
      preparationRevision: fixture.plan.prepared.revision, instances: [artwork, mask])
    let provider = EffectsGeometryProvider(values: [
      fixture.artwork.id: fixture.artwork, fixture.mask.id: fixture.mask,
    ])
    let swiftContent = try InlineSwiftUIRenderContent(
      plan: fixture.plan, assets: provider, composition: composition)
    let canvasContent = try InlineCanvasRenderContent(
      plan: fixture.plan, assets: provider, composition: composition)
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 20, height: 20)
    let swift = InlineSwiftUIRenderer(content: swiftContent, viewport: viewport)
    let canvas = InlineCanvasRenderer(content: canvasContent, viewport: viewport)
    XCTAssertEqual(swift.compositionMasksForTesting.keys, canvas.compositionMasksForTesting.keys)
    let positioned = try XCTUnwrap(fixture.plan.geometry.compactMap { item -> PositionedInlineAtom? in
      if case .vector(let value, _) = item { return value }
      return nil
    }.first)
    let swiftMasks = try XCTUnwrap(swift.compositionMasksForTesting[positioned])
    let canvasMasks = try XCTUnwrap(canvas.compositionMasksForTesting[positioned])
    XCTAssertEqual(swiftMasks.map(\.instanceID), ["mask"])
    XCTAssertEqual(canvasMasks.map(\.instanceID), ["mask"])
    XCTAssertEqual(swiftMasks[0].path.boundingRect, canvasMasks[0].path.boundingRect)
    XCTAssertEqual(swiftMasks[0].path.boundingRect.width, 10, accuracy: 0.01)

    let maskedSwift = try renderBack(swift, size: CGSize(width: 20, height: 20))
    let maskedCanvas = try renderBack(canvas, size: CGSize(width: 20, height: 20))
    let unmaskedContent = try InlineSwiftUIRenderContent(plan: fixture.plan, assets: provider)
    let unmasked = try renderBack(
      InlineSwiftUIRenderer(content: unmaskedContent, viewport: viewport),
      size: CGSize(width: 20, height: 20))
    XCTAssertLessThan(alphaCoverage(maskedSwift), alphaCoverage(unmasked))
    XCTAssertLessThanOrEqual(pixelDifferenceCount(maskedSwift, maskedCanvas), 256)

    let eraseMask = try InlineSVGCompositionInstance(
      instanceID: "erase-mask", assetID: fixture.mask.id,
      assetVersion: fixture.mask.version, role: .mask,
      targetID: "vector", operation: .erase, declarationOrder: 2)
    let eraseComposition = try InlineSVGCompositionPlan(
      preparationRevision: fixture.plan.prepared.revision,
      instances: [artwork, eraseMask])
    let eraseSwiftContent = try InlineSwiftUIRenderContent(
      plan: fixture.plan, assets: provider, composition: eraseComposition)
    let eraseCanvasContent = try InlineCanvasRenderContent(
      plan: fixture.plan, assets: provider, composition: eraseComposition)
    let erasedSwift = try renderBack(
      InlineSwiftUIRenderer(content: eraseSwiftContent, viewport: viewport),
      size: CGSize(width: 20, height: 20))
    let erasedCanvas = try renderBack(
      InlineCanvasRenderer(content: eraseCanvasContent, viewport: viewport),
      size: CGSize(width: 20, height: 20))
    XCTAssertLessThan(alphaCoverage(erasedSwift), alphaCoverage(unmasked))
    XCTAssertLessThanOrEqual(pixelDifferenceCount(erasedSwift, erasedCanvas), 256)

    let mixedReveal = try InlineSVGCompositionInstance(
      instanceID: "mixed-reveal", assetID: fixture.artwork.id,
      assetVersion: fixture.artwork.version, role: .mask,
      targetID: "vector", operation: .reveal, declarationOrder: 2)
    let mixedErase = try InlineSVGCompositionInstance(
      instanceID: "mixed-erase", assetID: fixture.mask.id,
      assetVersion: fixture.mask.version, role: .mask,
      targetID: "vector", operation: .erase, declarationOrder: 3)
    let mixedComposition = try InlineSVGCompositionPlan(
      preparationRevision: fixture.plan.prepared.revision,
      instances: [mixedErase, artwork, mixedReveal])
    let canonicalMixedComposition = try InlineSVGCompositionPlan(
      preparationRevision: fixture.plan.prepared.revision,
      instances: [artwork, mixedReveal, mixedErase])
    XCTAssertEqual(
      mixedComposition.instances, canonicalMixedComposition.instances,
      "declaration order canonicalizes input without claiming pixel-order semantics")
    XCTAssertEqual(mixedComposition.instances.map(\.instanceID),
      ["artwork", "mixed-reveal", "mixed-erase"])
    let mixedSwift = try InlineSwiftUIRenderContent(
      plan: fixture.plan, assets: provider, composition: mixedComposition)
    let mixedCanvas = try InlineCanvasRenderContent(
      plan: fixture.plan, assets: provider, composition: mixedComposition)
    let mixedSwiftRenderer = InlineSwiftUIRenderer(content: mixedSwift, viewport: viewport)
    let mixedCanvasRenderer = InlineCanvasRenderer(content: mixedCanvas, viewport: viewport)
    let mixedPositioned = try XCTUnwrap(
      mixedSwiftRenderer.compositionMasksForTesting.keys.first)
    XCTAssertEqual(
      mixedSwiftRenderer.compositionMasksForTesting[mixedPositioned]?.map(\.operation),
      [.reveal, .erase])
    XCTAssertEqual(
      mixedSwiftRenderer.compositionMasksForTesting[mixedPositioned]?.map(\.declarationOrder),
      [2, 3])
    XCTAssertEqual(
      mixedCanvasRenderer.compositionMasksForTesting[mixedPositioned]?.map(\.declarationOrder), [2, 3])
    let mixedSwiftPixels = try renderBack(
      mixedSwiftRenderer,
      size: CGSize(width: 20, height: 20))
    let mixedCanvasPixels = try renderBack(
      mixedCanvasRenderer,
      size: CGSize(width: 20, height: 20))
    XCTAssertLessThan(alphaCoverage(mixedSwiftPixels), alphaCoverage(unmasked))
    XCTAssertLessThanOrEqual(pixelDifferenceCount(mixedSwiftPixels, mixedCanvasPixels), 256)
  }

  func testImageCompositionTargetRendersRevealAndEraseInBothAdapters() throws {
    let bytes = try XCTUnwrap(Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    let imageID = try InlineAssetID(rawValue: "image")
    let imageMetrics = try InlineMetrics(advance: 20, ascent: 20, descent: 0)
    let reference = try InlineImageReference(assetID: imageID, version: 1, data: bytes)
    let imageAsset = try InlineEncodedImageAsset(
      reference: reference, metrics: imageMetrics, encoding: .png,
      encodedBytes: bytes, pixelWidth: 1, pixelHeight: 1)
    let image = try InlineImageAtom(
      id: "image", asset: imageAsset, accessibilityLabel: "image")
    let prepared = try InlinePreparation(shaper: EffectsFixedShaper(advance: 8))
      .prepare(document: InlineDocument(atoms: [.image(image)]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 20)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let maskPath = try rectanglePath(width: 10, height: 20)
    let maskID = try InlineAssetID(rawValue: "image-mask")
    let mask = try InlineSVGAsset(
      id: maskID, metrics: imageMetrics,
      coordinateBounds: try InlinePathBounds(minX: 0, minY: 0, maxX: 20, maxY: 20),
      coveragePath: maskPath, coveragePaint: .fill(.nonZero),
      trajectoryPath: maskPath, trajectoryStyle: try InlineSVGStrokeStyle(width: 1))
    let instance = try InlineSVGCompositionInstance(
      instanceID: "image-mask", assetID: mask.id, assetVersion: mask.version,
      role: .mask, targetID: "image", operation: .erase, declarationOrder: 1)
    let composition = try InlineSVGCompositionPlan(
      preparationRevision: prepared.revision, instances: [instance])
    let provider = EffectsGeometryProvider(values: [mask.id: mask])
    let imageStore = InlineImageAssetStore(values: [reference: imageAsset])
    let registry = try InlineAssetRegistry(records: [try InlineAssetRecord(image: imageAsset)])
    let swift = try InlineSwiftUIRenderContent(
      plan: plan, assets: provider, registry: registry, imageAssets: imageStore,
      composition: composition)
    let canvas = try InlineCanvasRenderContent(
      plan: plan, assets: provider, registry: registry, imageAssets: imageStore,
      composition: composition)
    let swiftRenderer = InlineSwiftUIRenderer(
      content: swift,
      viewport: try InlineRenderViewport(x: 0, y: 0, width: 20, height: 20))
    let canvasRenderer = InlineCanvasRenderer(
      content: canvas,
      viewport: try InlineRenderViewport(x: 0, y: 0, width: 20, height: 20))
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 20, height: 20)
    let unmaskedSwift = try renderBack(
      InlineSwiftUIRenderer(
        content: try InlineSwiftUIRenderContent(
          plan: plan, assets: provider, registry: registry, imageAssets: imageStore),
        viewport: viewport),
      size: CGSize(width: 20, height: 20))
    let unmaskedCanvas = try renderBack(
      InlineCanvasRenderer(
        content: try InlineCanvasRenderContent(
          plan: plan, assets: provider, registry: registry, imageAssets: imageStore),
        viewport: viewport),
      size: CGSize(width: 20, height: 20))
    XCTAssertGreaterThan(alphaCoverage(unmaskedSwift), 0)
    XCTAssertEqual(alphaCoverage(unmaskedSwift), alphaCoverage(unmaskedCanvas))

    let revealInstance = try InlineSVGCompositionInstance(
      instanceID: "image-reveal", assetID: mask.id, assetVersion: mask.version,
      role: .mask, targetID: "image", operation: .reveal, declarationOrder: 1)
    let revealComposition = try InlineSVGCompositionPlan(
      preparationRevision: prepared.revision, instances: [revealInstance])
    let revealSwift = try renderBack(
      InlineSwiftUIRenderer(
        content: try InlineSwiftUIRenderContent(
          plan: plan, assets: provider, registry: registry, imageAssets: imageStore,
          composition: revealComposition),
        viewport: viewport),
      size: CGSize(width: 20, height: 20))
    let revealCanvas = try renderBack(
      InlineCanvasRenderer(
        content: try InlineCanvasRenderContent(
          plan: plan, assets: provider, registry: registry, imageAssets: imageStore,
          composition: revealComposition),
        viewport: viewport),
      size: CGSize(width: 20, height: 20))
    XCTAssertLessThan(alphaCoverage(revealSwift), alphaCoverage(unmaskedSwift))
    XCTAssertEqual(alphaCoverage(revealSwift), alphaCoverage(revealCanvas))

    let eraseSwift = try renderBack(
      InlineSwiftUIRenderer(content: swift, viewport: viewport),
      size: CGSize(width: 20, height: 20))
    let eraseCanvas = try renderBack(
      InlineCanvasRenderer(content: canvas, viewport: viewport),
      size: CGSize(width: 20, height: 20))
    XCTAssertEqual(swiftRenderer.compositionMasksForTesting.keys,
      canvasRenderer.compositionMasksForTesting.keys)
    XCTAssertEqual(swiftRenderer.compositionMasksForTesting.values.first?.first?.operation, .erase)
    XCTAssertLessThan(alphaCoverage(eraseSwift), alphaCoverage(unmaskedSwift))
    XCTAssertEqual(alphaCoverage(eraseSwift), alphaCoverage(eraseCanvas))
  }

  func testMovingExclusionsRebuildOnePlanForBothAdaptersWithoutOverlap() throws {
    let text = try InlineAtom.text(InlineTextAtom(
      id: "moving", text: String(repeating: "move around ", count: 12), style: style()))
    let prepared = try InlinePreparation(shaper: EffectsFixedShaper(advance: 7))
      .prepare(document: InlineDocument(atoms: [text]))
    let positions: [(photo: InlineFlowRect, button: InlineFlowRect)] = [
      (
        photo: try InlineFlowRect(x: 194, y: 0, width: 74, height: 70),
        button: try InlineFlowRect(x: 8, y: 84, width: 92, height: 32)),
      (
        photo: try InlineFlowRect(x: 8, y: 70, width: 74, height: 70),
        button: try InlineFlowRect(x: 176, y: 0, width: 92, height: 32)),
    ]
    var layouts: [InlineLayoutResult] = []
    for (index, position) in positions.enumerated() {
      let photo = try InlineFlowExclusion(
        id: "photo", rect: position.photo,
        insets: try InlineFlowInsets(top: 3, leading: 3, bottom: 3, trailing: 3))
      let button = try InlineFlowExclusion(id: "button", rect: position.button)
      let flow = try InlineFlowRegion(
        rect: try InlineFlowRect(x: 0, y: 0, width: 276, height: 520),
        exclusions: [photo, button], revision: UInt64(index + 1))
      let layout = try InlineLayoutEngine(leading: 5).layout(prepared: prepared, flow: flow)
      let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
      let viewport = try InlineRenderViewport(
        x: 0, y: 0, width: 276, height: max(1, layout.height))
      let swiftContent = try InlineSwiftUIRenderContent(
        plan: plan, assets: EffectsEmptyGeometryProvider())
      let canvasContent = try InlineCanvasRenderContent(
        plan: plan, assets: EffectsEmptyGeometryProvider())
      let swift = InlineSwiftUIRenderer(content: swiftContent, viewport: viewport)
      let canvas = InlineCanvasRenderer(content: canvasContent, viewport: viewport)
      XCTAssertEqual(swift.visibleGeometryForTesting, canvas.visibleGeometryForTesting)

      let blocked: [CGRect] = [
        CGRect(
          x: position.photo.x - 3, y: position.photo.y - 3,
          width: position.photo.width + 6, height: position.photo.height + 6),
        CGRect(
          x: position.button.x, y: position.button.y,
          width: position.button.width, height: position.button.height),
      ]
      for item in plan.geometry {
        let positioned: PositionedInlineAtom
        switch item {
        case .text(let value, _), .vector(let value, _), .image(let value, _):
          positioned = value
        }
        let rect = CGRect(
          x: positioned.originX,
          y: positioned.baselineY - positioned.metrics.baselineOffset - positioned.metrics.ascent,
          width: positioned.width,
          height: positioned.height)
        XCTAssertFalse(
          blocked.contains { rect.intersects($0) },
          "position \(index) placed text in an external exclusion")
      }
      layouts.append(layout)
    }
    XCTAssertNotEqual(layouts[0].lines, layouts[1].lines)
  }

  private func vectorFixture(withHalfMask: Bool = false) throws -> (
    plan: InlineRenderPlan,
    artwork: InlineSVGAsset,
    mask: InlineSVGAsset,
    store: InlineAssetStore
  ) {
    let metrics = try InlineMetrics(advance: 20, ascent: 20, descent: 0)
    let artworkID = try InlineAssetID(rawValue: "artwork")
    let maskID = try InlineAssetID(rawValue: "mask")
    let artworkPath = try rectanglePath(width: 20, height: 20)
    let maskPath = try rectanglePath(width: withHalfMask ? 10 : 20, height: 20)
    let coordinateBounds = try InlinePathBounds(minX: 0, minY: 0, maxX: 20, maxY: 20)
    let style = try InlineSVGStrokeStyle(width: 1)
    let artwork = try InlineSVGAsset(
      id: artworkID, metrics: metrics, coordinateBounds: coordinateBounds,
      coveragePath: artworkPath, coveragePaint: .fill(.nonZero),
      trajectoryPath: artworkPath, trajectoryStyle: style)
    let mask = try InlineSVGAsset(
      id: maskID, metrics: metrics, coordinateBounds: coordinateBounds,
      coveragePath: maskPath, coveragePaint: .fill(.nonZero),
      trajectoryPath: maskPath, trajectoryStyle: style)
    let vector = try InlineAtom.vector(InlineVectorAtom(id: "vector", asset: artwork))
    let prepared = try InlinePreparation().prepare(document: InlineDocument(atoms: [vector]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 20)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let store = InlineAssetStore(values: [
      InlineAssetKey(id: artwork.id, version: artwork.version): artwork,
      InlineAssetKey(id: mask.id, version: mask.version): mask,
    ])
    return (plan, artwork, mask, store)
  }

  private func rectanglePath(width: Double, height: Double) throws -> InlinePathData {
    try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: width, y: 0)),
      .line(try InlinePathPoint(x: width, y: height)),
      .line(try InlinePathPoint(x: 0, y: height)),
      .close,
    ])
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

  private func rgba(_ image: CGImage) -> [UInt8] {
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

  private func alphaCoverage(_ image: CGImage) -> Int {
    let values = rgba(image)
    return stride(from: 3, to: values.count, by: 4).reduce(into: 0) { total, index in
      if values[index] > 0 { total += 1 }
    }
  }

  private func pixelDifferenceCount(_ lhs: CGImage, _ rhs: CGImage) -> Int {
    let left = rgba(lhs)
    let right = rgba(rhs)
    guard left.count == right.count else { return Int.max }
    return zip(left, right).reduce(into: 0) { total, pair in
      if abs(Int(pair.0) - Int(pair.1)) > 2 { total += 1 }
    }
  }
}
