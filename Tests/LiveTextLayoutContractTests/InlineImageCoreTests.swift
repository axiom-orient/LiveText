import Foundation
import LiveTextCore
import LiveTextLayout
import XCTest

final class InlineImageCoreTests: XCTestCase {
  func testImageDigestUsesCanonicalSHA256() {
    XCTAssertEqual(
      InlineAssetDigest(data: Data("abc".utf8)).hex,
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
  }

  func testImageReferenceAtomAndRegistryRoundTripPreservesStableIdentity() throws {
    let bytes = Data([0x89, 0x50, 0x4E, 0x47])
    let asset = try makeAsset(data: bytes)
    let atom = try InlineImageAtom(
      id: "thumbnail",
      asset: asset,
      accessibilityLabel: "Preview thumbnail"
    )
    let document = try InlineDocument(atoms: [.image(atom)])

    let encodedDocument = try JSONEncoder().encode(document)
    XCTAssertEqual(
      try JSONDecoder().decode(InlineDocument.self, from: encodedDocument),
      document
    )

    let registry = try InlineAssetRegistry(records: [try InlineAssetRecord(image: asset)])
    let encodedRegistry = try JSONEncoder().encode(registry)
    XCTAssertEqual(
      try JSONDecoder().decode(InlineAssetRegistry.self, from: encodedRegistry),
      registry
    )
    XCTAssertNoThrow(try registry.validate(document: document))
    XCTAssertEqual(atom.reference.digest, InlineAssetDigest(data: bytes))
    XCTAssertEqual(atom.reference.version, 1)
  }

  func testImageAtomRejectsSerializationWithoutCanonicalPresentation() throws {
    let bytes = Data([0x89, 0x50, 0x4E, 0x47])
    let asset = try makeAsset(data: bytes)
    let atom = try InlineImageAtom(
      id: "thumbnail", asset: asset, accessibilityLabel: "Preview thumbnail")
    let document = try InlineDocument(atoms: [.image(atom)])
    let encoded = try JSONEncoder().encode(document)
    var root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var atoms = try XCTUnwrap(root["atoms"] as? [[String: Any]])
    var imageAtom = try XCTUnwrap(atoms[0]["image"] as? [String: Any])
    XCTAssertNotNil(imageAtom.removeValue(forKey: "presentation"))
    atoms[0]["image"] = imageAtom
    root["atoms"] = atoms
    let incompleteData = try JSONSerialization.data(withJSONObject: root)

    XCTAssertThrowsError(try JSONDecoder().decode(InlineDocument.self, from: incompleteData)) {
      guard case DecodingError.keyNotFound(let key, _) = $0 else {
        return XCTFail("expected missing canonical presentation, received \($0)")
      }
      XCTAssertEqual(key.stringValue, "presentation")
    }
  }

  func testImageValidationRejectsBadDigestVersionAccessibilityAndLimits() throws {
    let assetID = try InlineAssetID(rawValue: "thumbnail")
    let bytes = Data([1, 2, 3])
    let digest = InlineAssetDigest(data: bytes)

    XCTAssertThrowsError(try InlineAssetDigest(hex: "not-a-digest")) { error in
      XCTAssertEqual(error as? InlineImageAssetError, .invalidDigest)
    }
    XCTAssertThrowsError(
      try InlineImageReference(assetID: assetID, version: -1, digest: digest)
    ) { error in
      guard case .invalidMetric = error as? InlineLayoutError else {
        return XCTFail("expected a typed negative-version error")
      }
    }

    let metrics = try InlineMetrics(advance: 8, ascent: 6, descent: 2)
    let reference = try InlineImageReference(assetID: assetID, data: bytes)
    XCTAssertThrowsError(
      try InlineImageAtom(
        id: "thumbnail",
        reference: reference,
        metrics: metrics,
        accessibility: .label("   ")
      )
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidImageAccessibility)
    }

    XCTAssertThrowsError(
      try InlineEncodedImageAsset(
        reference: reference,
        metrics: metrics,
        encoding: .png,
        encodedBytes: Data([9]),
        pixelWidth: 1,
        pixelHeight: 1
      )
    ) { error in
      guard case .digestMismatch = error as? InlineImageAssetError else {
        return XCTFail("expected a typed digest mismatch")
      }
    }

    let normal = try InlineEncodedImageAsset(
      reference: reference,
      metrics: metrics,
      encoding: .png,
      encodedBytes: bytes,
      pixelWidth: 100,
      pixelHeight: 100
    )
    XCTAssertThrowsError(
      try InlineImageAssetLimits(
        maximumEncodedBytes: 2,
        maximumPixelWidth: 100,
        maximumPixelHeight: 100,
        maximumPixels: 10_000
      ).validatedAsset(
        reference: normal.reference,
        metrics: normal.metrics,
        encoding: normal.encoding,
        encodedBytes: normal.encodedBytes,
        pixelWidth: normal.pixelWidth,
        pixelHeight: normal.pixelHeight
      )
    ) { error in
      XCTAssertEqual(
        error as? InlineImageAssetError,
        .encodedBytesLimitExceeded(actual: bytes.count, limit: 2)
      )
    }
    XCTAssertThrowsError(
      try InlineImageAssetLimits(
        maximumEncodedBytes: 10,
        maximumPixelWidth: 10,
        maximumPixelHeight: 100,
        maximumPixels: 10_000
      ).validatedAsset(
        reference: normal.reference,
        metrics: normal.metrics,
        encoding: normal.encoding,
        encodedBytes: normal.encodedBytes,
        pixelWidth: normal.pixelWidth,
        pixelHeight: normal.pixelHeight
      )
    ) { error in
      guard case .pixelDimensionLimitExceeded = error as? InlineImageAssetError else {
        return XCTFail("expected a typed dimension-limit error")
      }
    }
    XCTAssertThrowsError(
      try InlineImageAssetLimits(
        maximumEncodedBytes: 10,
        maximumPixelWidth: 100,
        maximumPixelHeight: 100,
        maximumPixels: 1_000
      ).validatedAsset(
        reference: normal.reference,
        metrics: normal.metrics,
        encoding: normal.encoding,
        encodedBytes: normal.encodedBytes,
        pixelWidth: normal.pixelWidth,
        pixelHeight: normal.pixelHeight
      )
    ) { error in
      guard case .pixelCountLimitExceeded = error as? InlineImageAssetError else {
        return XCTFail("expected a typed pixel-limit error")
      }
    }
  }

  func testProviderResolutionValidatesReferenceMetricsAndLimitsBeforeReturningStore() throws {
    let asset = try makeAsset()
    let labeled = try InlineImageAtom(
      id: "thumbnail", asset: asset, accessibilityLabel: "Thumbnail")
    let document = try InlineDocument(atoms: [.image(labeled)])

    let store = try resolveInlineImageAssets(
      document: document,
      provider: FixtureImageProvider(asset: asset)
    )
    XCTAssertEqual(store.value(for: asset.reference), asset)

    let mismatchedMetrics = try InlineEncodedImageAsset(
      reference: asset.reference,
      metrics: try InlineMetrics(advance: 9, ascent: 6, descent: 2),
      encoding: asset.encoding,
      encodedBytes: asset.encodedBytes,
      pixelWidth: asset.pixelWidth,
      pixelHeight: asset.pixelHeight
    )
    XCTAssertThrowsError(
      try resolveInlineImageAssets(
        document: document,
        provider: FixtureImageProvider(asset: mismatchedMetrics)
      )
    ) { error in
      XCTAssertEqual(error as? InlineImageAssetError, .metricsMismatch(asset.reference.assetID))
    }

    let limited = try InlineImageAssetLimits(
      maximumEncodedBytes: 2,
      maximumPixelWidth: 100,
      maximumPixelHeight: 100,
      maximumPixels: 10_000
    )
    XCTAssertThrowsError(
      try resolveInlineImageAssets(
        document: document,
        provider: FixtureImageProvider(asset: asset),
        limits: limited
      )
    ) { error in
      guard case .encodedBytesLimitExceeded = error as? InlineImageAssetError else {
        return XCTFail("expected provider result limit validation")
      }
    }

    let otherAsset = try makeAsset(id: "other")
    XCTAssertThrowsError(
      try resolveInlineImageAssets(
        document: document,
        provider: FixtureImageProvider(asset: otherAsset)
      )
    ) { error in
      guard case .referenceMismatch = error as? InlineImageAssetError else {
        return XCTFail("expected provider reference validation")
      }
    }
  }

  func testMixedTextAndImagesPlaceAndWrapAsAtomicUnits() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 10))
    let textBefore = try InlineAtom.text(
      InlineTextAtom(id: "before", text: "a", style: style))
    let asset = try makeAsset(
      metrics: try InlineMetrics(advance: 8, ascent: 6, descent: 2))
    let image = try InlineAtom.image(
      InlineImageAtom(id: "thumbnail", asset: asset, accessibilityLabel: "Thumbnail"))
    let textAfter = try InlineAtom.text(
      InlineTextAtom(id: "after", text: "b", style: style))
    let document = try InlineDocument(atoms: [textBefore, image, textAfter])
    let prepared = try InlinePreparation(shaper: FixtureShaper(advance: 4)).prepare(
      document: document)
    XCTAssertEqual(prepared.totalImageAtoms, 1)

    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 16)
    XCTAssertEqual(layout.lines.count, 1)
    XCTAssertEqual(layout.lines[0].atoms.map(\.atomID), ["before", "thumbnail", "after"])
    let positionedImage = try XCTUnwrap(layout.lines[0].atoms.first { $0.kind == .image })
    XCTAssertEqual(positionedImage.scale, 1)
    XCTAssertEqual(positionedImage.width, 8, accuracy: 0.0001)
    XCTAssertNil(positionedImage.sourceRange)
    XCTAssertNoThrow(try layout.validate(for: prepared))

    let first = try InlineAtom.image(
      InlineImageAtom(id: "first", asset: asset, accessibilityLabel: "First"))
    let second = try InlineAtom.image(
      InlineImageAtom(id: "second", asset: asset, isDecorative: true))
    let wrappedPrepared = try InlinePreparation(shaper: FixtureShaper(advance: 1)).prepare(
      document: InlineDocument(atoms: [first, second]))
    let wrapped = try InlineLayoutEngine().layout(prepared: wrappedPrepared, width: 8)
    XCTAssertEqual(wrapped.lines.count, 2)
    XCTAssertEqual(wrapped.lines.flatMap(\.atoms).map(\.kind), [.image, .image])
    XCTAssertEqual(wrapped.lines.map(\.width), [8, 8])

    XCTAssertThrowsError(
      try InlineLayoutEngine().layout(prepared: prepared, width: 7)
    ) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .oversizedImage(id: "thumbnail", advance: 8, width: 7)
      )
    }
  }

  func testImageContinuationHitGeometryAndAccessibilitySemantics() throws {
    let asset = try makeAsset(
      metrics: try InlineMetrics(advance: 8, ascent: 6, descent: 2))
    let labeled = try InlineAtom.image(
      InlineImageAtom(id: "labeled", asset: asset, accessibilityLabel: "A thumbnail"))
    let decorative = try InlineAtom.image(
      InlineImageAtom(id: "decorative", asset: asset, isDecorative: true))
    let document = try InlineDocument(atoms: [labeled, decorative])
    let prepared = try InlinePreparation(shaper: FixtureShaper(advance: 1)).prepare(
      document: document)
    let engine = try InlineLayoutEngine()
    let first = try engine.layout(prepared: prepared, width: 8, maximumLines: 1)
    let continuation = try XCTUnwrap(first.continuation)
    XCTAssertEqual(continuation.cursor, InlineCursor(atomIndex: 1, graphemeIndex: 0))
    let tail = try engine.layoutTail(
      prepared: prepared, from: continuation, width: 8, maximumLines: 1)
    XCTAssertEqual(tail.lines.first?.atoms.first?.atomID, "decorative")

    let full = try engine.layout(prepared: prepared, width: 8)
    let plan = try InlineRenderPlan(prepared: prepared, layout: full)
    let semantics = try InlineAccessibilitySemantics(prepared: prepared)
    XCTAssertEqual(semantics.elements.map(\.atomID), ["labeled", "decorative"])
    XCTAssertEqual(semantics.element(forAtomID: "labeled")?.label, "A thumbnail")
    XCTAssertEqual(semantics.element(forAtomID: "decorative")?.isDecorative, true)

    let positioned = try XCTUnwrap(full.lines[0].atoms.first)
    let point = try InlineHitPoint(
      x: positioned.originX + 1,
      y: positioned.baselineY - positioned.metrics.baselineOffset
        - positioned.metrics.ascent + 1
    )
    guard case .image(let hit) = plan.hitIndex.hitTest(point) else {
      return XCTFail("expected an image hit result")
    }
    XCTAssertEqual(hit.atomID, "labeled")
    XCTAssertEqual(hit.accessibilityLabel, "A thumbnail")
    XCTAssertFalse(hit.isDecorative)

    let excluded = try InlineHitTestIndex.build(
      prepared: prepared,
      layout: full,
      profile: InlineTextUnitHitProfile(includeImages: false)
    )
    XCTAssertEqual(excluded.hitTest(point), .none)
  }

  func testImageRevealIsAtomicAndCancellationOrAppendFailureDoesNotPublish() throws {
    let asset = try makeAsset(
      metrics: try InlineMetrics(advance: 8, ascent: 6, descent: 2))
    let first = try InlineAtom.image(
      InlineImageAtom(id: "first", asset: asset, accessibilityLabel: "First"))
    let second = try InlineAtom.image(
      InlineImageAtom(id: "second", asset: asset, isDecorative: true))
    let document = try InlineDocument(atoms: [first, second])
    let preparation = InlinePreparation(shaper: FixtureShaper(advance: 1))
    let prepared = try preparation.prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 8)
    let renderPlan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let imagePlan = try InlineRevealPlanBuilder(secondsPerUnit: 0.1).imagePlan(
      prepared: prepared)
    let schedule = try InlineRenderRevealSchedule(
      plan: renderPlan, assets: InlineAssetStore(), imagePlan: imagePlan)
    XCTAssertEqual(imagePlan.units.map(\.kind), [.image, .image])
    XCTAssertFalse(schedule.sample(at: .zero).imageIsVisible(atomID: "first"))
    let halfPhase = try InlineRenderRevealPhase(rawValue: 0.5)
    let halfFrame = schedule.sample(at: halfPhase)
    XCTAssertTrue(halfFrame.imageIsVisible(atomID: "first"))
    XCTAssertFalse(halfFrame.imageIsVisible(atomID: "second"))
    XCTAssertTrue(schedule.sample(at: .complete).imageIsVisible(atomID: "second"))

    XCTAssertThrowsError(
      try preparation.prepare(
        document: document, cancellation: { throw InlineLayoutError.cancelled })
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .cancelled)
    }

    var reducer = try InlineAppendReducer(
      streamID: UUID(), preparation: preparation, engine: InlineLayoutEngine(), width: 8)
    let wideAsset = try makeAsset(
      id: "wide",
      metrics: try InlineMetrics(advance: 9, ascent: 6, descent: 2))
    let wide = try InlineAtom.image(
      InlineImageAtom(id: "wide", asset: wideAsset, accessibilityLabel: "Wide"))
    let batch = InlineAppendBatch(
      streamID: reducer.streamID,
      sequence: 0,
      baseRevision: reducer.revision,
      atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: wide)]
    )
    let originalRevision = reducer.revision
    XCTAssertThrowsError(try reducer.apply(.append(batch))) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .oversizedImage(id: "wide", advance: 9, width: 8)
      )
    }
    XCTAssertEqual(reducer.revision, originalRevision)
    XCTAssertEqual(reducer.nextSequence, 0)
    XCTAssertFalse(reducer.isFinished)

    let valid = try InlineAtom.image(
      InlineImageAtom(id: "valid", asset: asset, accessibilityLabel: "Valid"))
    let validBatch = InlineAppendBatch(
      streamID: reducer.streamID,
      sequence: 0,
      baseRevision: reducer.revision,
      atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: valid)]
    )
    let delta = try reducer.apply(.append(validBatch))
    XCTAssertEqual(delta.appendedPreparedAtoms.count, 1)
    let finish = InlineAppendEvent.finish(
      streamID: reducer.streamID,
      sequence: 1,
      baseRevision: reducer.revision
    )
    _ = try reducer.apply(finish)
    XCTAssertEqual(try reducer.finalizedResult().prepared.totalImageAtoms, 1)
  }

  private func makeAsset(
    id: String = "thumbnail",
    data: Data = Data([1, 2, 3]),
    metrics: InlineMetrics? = nil
  ) throws -> InlineEncodedImageAsset {
    let assetID = try InlineAssetID(rawValue: id)
    let reference = try InlineImageReference(assetID: assetID, data: data)
    return try InlineEncodedImageAsset(
      reference: reference,
      metrics: metrics ?? (try InlineMetrics(advance: 8, ascent: 6, descent: 2)),
      encoding: .png,
      encodedBytes: data,
      pixelWidth: 2,
      pixelHeight: 2
    )
  }
}

private struct FixtureImageProvider: InlineImageAssetProvider {
  let asset: InlineEncodedImageAsset

  func resolveImage(
    reference: InlineImageReference,
    metrics: InlineMetrics,
    limits: InlineImageAssetLimits
  ) throws -> InlineEncodedImageAsset {
    asset
  }
}

private struct FixtureShaper: InlineTextShaping {
  let advance: Double

  func shape(
    text: String,
    style: InlineTextStyle,
    sourceRange: InlineSourceRange
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
      metrics: InlineMetrics(
        advance: advance * Double(ranges.count),
        ascent: style.font.pointSize,
        descent: 2,
        baselineOffset: style.baselineOffset
      )
    )
  }
}

extension InlineImageAssetLimits {
  fileprivate func validatedAsset(
    reference: InlineImageReference,
    metrics: InlineMetrics,
    encoding: InlineImageEncoding,
    encodedBytes: Data,
    pixelWidth: Int,
    pixelHeight: Int
  ) throws -> InlineEncodedImageAsset {
    try InlineEncodedImageAsset(
      reference: reference,
      metrics: metrics,
      encoding: encoding,
      encodedBytes: encodedBytes,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      limits: self
    )
  }
}
