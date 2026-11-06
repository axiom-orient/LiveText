import Combine
import CoreGraphics
import CoreText
import Foundation
@testable import LiveTextAppleRendering
@testable import LiveTextCanvas
import LiveTextCore
import LiveTextEffects
@testable import LiveTextLayout
@testable import LiveTextSwiftUI
import SwiftUI
import XCTest

@MainActor
final class InlineAppendRendererTests: XCTestCase {
  private static let streamID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

  private struct FixedShaper: CancellableInlineTextShaping {
    func shape(
      text: String, style: InlineTextStyle, sourceRange: InlineSourceRange
    ) throws -> InlineShapedText {
      try shape(text: text, style: style, sourceRange: sourceRange, cancellation: {})
    }

    func shape(
      text: String,
      style: InlineTextStyle,
      sourceRange: InlineSourceRange,
      cancellation: InlineCancellationCheck
    ) throws -> InlineShapedText {
      var ranges: [InlineSourceRange] = []
      var glyphs: [InlineGlyph] = []
      var offset = sourceRange.startUTF16
      var position = 0.0
      for (index, grapheme) in text.enumerated() {
        try cancellation()
        let length = String(grapheme).utf16.count
        let range = try InlineSourceRange(startUTF16: offset, endUTF16: offset + length)
        ranges.append(range)
        glyphs.append(
          try InlineGlyph(
            glyphID: UInt16(index + 1), positionX: position, positionY: 0,
            sourceUTF16Index: offset, sourceRange: range))
        offset += length
        position += 1
      }
      let metrics = try InlineMetrics(
        advance: position, ascent: style.font.pointSize, descent: 2,
        baselineOffset: style.baselineOffset)
      let runs: [InlineShapedRun]
      if let first = ranges.first, let last = ranges.last {
        runs = [
          try InlineShapedRun(
            glyphs: glyphs, font: style.font,
            sourceRange: try InlineSourceRange(
              startUTF16: first.startUTF16, endUTF16: last.endUTF16),
            advance: position, ascent: metrics.ascent, descent: metrics.descent)
        ]
      } else {
        runs = []
      }
      return try InlineShapedText(
        graphemeRanges: ranges,
        graphemeAdvances: Array(repeating: 1, count: ranges.count),
        runs: runs, metrics: metrics)
    }
  }

  private struct AssetProvider: InlineAssetGeometryProvider {
    let values: [InlineAssetKey: InlineSVGAsset]

    init(_ assets: [InlineSVGAsset]) {
      values = Dictionary(
        uniqueKeysWithValues: assets.map {
          (InlineAssetKey(id: $0.id, version: $0.version), $0)
        })
    }

    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      guard let value = values[InlineAssetKey(id: assetID, version: version)] else {
        throw InlineAssetResolutionError.missingGeometry(assetID, version: version)
      }
      return value
    }
  }

  private struct FailingProvider: InlineAssetGeometryProvider {
    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      throw InlineAssetResolutionError.missingGeometry(assetID, version: version)
    }
  }

  private struct MalformedProvider: InlineAssetGeometryProvider {
    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      throw InlineLayoutError.invalidSVGPath("malformed provider geometry")
    }
  }

  private struct VersionMismatchProvider: InlineAssetGeometryProvider {
    let actualVersion: Int

    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      throw InlineAssetResolutionError.versionMismatch(
        assetID, expected: version, actual: actualVersion)
    }
  }

  private enum ProviderFailure: Error, Equatable, Sendable {
    case io
  }

  private struct IOProvider: InlineAssetGeometryProvider {
    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      throw ProviderFailure.io
    }
  }

  private struct ReturningProvider: InlineAssetGeometryProvider {
    let asset: InlineSVGAsset

    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      asset
    }
  }

  private final class CancellationController: @unchecked Sendable {
    var calls = 0
    var cancelOnCall: Int?

    func check() throws {
      calls += 1
      if calls == cancelOnCall { throw InlineLayoutError.cancelled }
    }
  }

  private func makeStyle(
    font: String = "Helvetica", pointSize: Double = 10, baselineOffset: Double = 0
  ) throws -> InlineTextStyle {
    try InlineTextStyle(
      font: FontDescriptor(postScriptName: font, pointSize: pointSize),
      baselineOffset: baselineOffset)
  }

  private func text(id: String, value: String = "x") throws -> InlineAtom {
    .text(try InlineTextAtom(id: id, text: value, style: makeStyle()))
  }

  private func asset(
    id rawID: String = "star",
    paint: InlineSVGCoveragePaint = .fill(.nonZero),
    label: String? = "Star"
  ) throws -> InlineSVGAsset {
    let path = try InlineSVGBridge.parsePath("M0 0 L1 0 L1 1 Z")
    let trajectory = try InlineSVGBridge.parsePath("M0.1 0.1 L0.8 0.8")
    return try InlineSVGAsset(
      id: try InlineAssetID(rawValue: rawID),
      metrics: try InlineMetrics(advance: 1, ascent: 8, descent: 2),
      coordinateBounds: path.bounds,
      coveragePath: path,
      coveragePaint: paint,
      trajectoryPath: trajectory,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 0.2),
      accessibilityLabel: label)
  }

  private func makeReducer(
    width: Double = 32,
    preparation: InlinePreparation? = nil
  ) throws -> InlineAppendReducer {
    try InlineAppendReducer(
      streamID: Self.streamID,
      preparation: preparation ?? InlinePreparation(shaper: FixedShaper()),
      engine: InlineLayoutEngine(), width: width)
  }

  private func makeSession<Provider: InlineAssetGeometryProvider>(
    width: Double = 32,
    assets: Provider,
    preparation: InlinePreparation? = nil,
    registry: InlineAssetRegistry = .empty,
    assetCache: InlineAssetCache? = nil,
    imageAssets: InlineImageAssetStore = InlineImageAssetStore(),
    imageCache: InlineImageRenderCache? = nil
  ) throws -> InlineAppleAppendSession<Provider> {
    try InlineAppleAppendSession(
      reducer: makeReducer(width: width, preparation: preparation), assets: assets,
      registry: registry,
      assetCache: assetCache, imageAssets: imageAssets, imageCache: imageCache)
  }

  private func appendEvent<Provider: InlineAssetGeometryProvider>(
    _ session: InlineAppleAppendSession<Provider>, atoms: [InlineAtom]
  ) throws -> InlineAppendEvent {
    .append(
      InlineAppendBatch(
        streamID: Self.streamID,
        sequence: session.snapshot.nextSequence,
        baseRevision: session.snapshot.revision,
        atoms: try atoms.map {
          try InlineSealedAppendAtom(sealingCompleteSemanticAtom: $0)
        }))
  }

  private func finishEvent<Provider: InlineAssetGeometryProvider>(
    _ session: InlineAppleAppendSession<Provider>
  ) -> InlineAppendEvent {
    .finish(
      streamID: Self.streamID,
      sequence: session.snapshot.nextSequence,
      baseRevision: session.snapshot.revision)
  }

  private func vectorAtom(id: String, asset: InlineSVGAsset) throws -> InlineAtom {
    .vector(
      try InlineVectorAtom(
        id: id, assetID: asset.id, assetVersion: asset.version,
        metrics: asset.metrics, accessibilityLabel: asset.accessibilityLabel))
  }

  func testOneSessionFeedsBothRenderersAndPreservesOrderAndHits() throws {
    let vectorAsset = try asset()
    let atoms: [InlineAtom] = [
      try text(id: "left", value: "ab"),
      try vectorAtom(id: "vector", asset: vectorAsset),
      try text(id: "right", value: "cd"),
    ]
    let session = try makeSession(
      assets: AssetProvider([vectorAsset]), preparation: InlinePreparation())
    try session.send(appendEvent(session, atoms: atoms))
    try session.send(finishEvent(session))

    XCTAssertEqual(session.projection.documentAtoms, atoms)
    XCTAssertEqual(session.snapshot.nextSequence, 2)
    XCTAssertTrue(session.projection.tailLines.isEmpty)
    XCTAssertTrue(session.sectionIndex.validateInvariantsForTesting())
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 32, height: 100)
    let chunks = session.visibleSections(for: viewport).flatMap(\.chunks)
    XCTAssertEqual(chunks.map(\.id), ["0:left:0-2", "0:vector:vector", "0:right:2-4"])
    XCTAssertEqual(session.accessibilityEntries.map(\.id), ["left", "vector", "right"])

    let swift = try InlineSwiftUIAppendRenderer(session: session, viewport: viewport)
    let canvas = try InlineCanvasAppendRenderer(session: session, viewport: viewport)
    let positioned = try XCTUnwrap(session.projection.committedLines.first?.atoms.first)
    let point = try InlineHitPoint(
      x: positioned.originX + positioned.width * 0.5,
      y: positioned.baselineY - positioned.metrics.baselineOffset
        - positioned.metrics.ascent + positioned.height * 0.5)
    XCTAssertEqual(swift.hitTest(at: point), canvas.hitTest(at: point))
    let local = try InlineHitPoint(x: point.x - viewport.x, y: point.y - viewport.y)
    XCTAssertEqual(viewport.layoutPoint(fromLocal: local), point)
    XCTAssertEqual(swift.hitTest(atViewportPoint: local), canvas.hitTest(atViewportPoint: local))
  }

  func testAppendEffectsBindHostSelectionCompositionAndSharedAccessibility() throws {
    let vectorAsset = try asset(id: "effects-vector")
    let atoms: [InlineAtom] = [
      try text(id: "word", value: "hello world"),
      try vectorAtom(id: "vector", asset: vectorAsset),
    ]
    let session = try makeSession(
      width: 32, assets: AssetProvider([vectorAsset]), preparation: InlinePreparation())
    try session.send(appendEvent(session, atoms: atoms))

    guard
      case .textUnit(let hit) = try XCTUnwrap(
        session.hitTest(
          at: try InlineHitPoint(x: 2, y: 5)))
    else {
      return XCTFail("append hit did not resolve to a word")
    }
    let state = try InlineTextUnitSelectionState(
      preparationRevision: session.snapshot.revision)
    let selection = try XCTUnwrap(
      try state.applying(try state.activationEvent(for: hit)).selected)
    let artwork = try InlineSVGCompositionInstance(
      instanceID: "artwork", assetID: vectorAsset.id,
      assetVersion: vectorAsset.version, sourceAtomID: "vector",
      role: .artwork, declarationOrder: 2)
    let textMask = try InlineSVGCompositionInstance(
      instanceID: "text-mask", assetID: vectorAsset.id,
      assetVersion: vectorAsset.version, role: .mask,
      targetID: "word", operation: .reveal, declarationOrder: 1)
    let composition = try InlineSVGCompositionPlan(
      preparationRevision: session.snapshot.revision,
      instances: [artwork, textMask])
    let effects = try session.makeEffectsPlan(
      selection: selection, style: .defaultHighlighter, composition: composition)

    XCTAssertEqual(effects.preparationRevision, session.snapshot.revision)
    XCTAssertEqual(effects.highlight?.selection, selection)
    XCTAssertEqual(effects.accessibility.units.filter(\.isSelected).count, 1)
    XCTAssertEqual(effects.artworkAtomIDs, Set(["vector"]))
    XCTAssertFalse(effects.masksByChunkID.isEmpty)

    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 32, height: 100)
    var swiftActivation: InlineTextUnitHit?
    var canvasActivation: InlineTextUnitHit?
    let swift = try InlineSwiftUIAppendRenderer(
      validating: session, viewport: viewport, effects: effects,
      onTextUnitActivation: { swiftActivation = $0 })
    let canvas = try InlineCanvasAppendRenderer(
      validating: session, viewport: viewport, effects: effects,
      onTextUnitActivation: { canvasActivation = $0 })
    let point = try InlineHitPoint(
      x: hit.rect.minX + hit.rect.width / 2,
      y: hit.rect.minY + hit.rect.height / 2)
    let local = try InlineHitPoint(x: point.x - viewport.x, y: point.y - viewport.y)
    XCTAssertEqual(swift.activate(atViewportPoint: local), .textUnit(hit))
    XCTAssertEqual(canvas.activate(atViewportPoint: local), .textUnit(hit))
    XCTAssertEqual(swiftActivation, hit)
    XCTAssertEqual(canvasActivation, hit)
    XCTAssertEqual(
      swift.effectsPlanForTesting?.accessibility, canvas.effectsPlanForTesting?.accessibility)

    let before = session.snapshot
    try session.send(appendEvent(session, atoms: [try text(id: "later", value: "later")]))
    XCTAssertNotEqual(session.snapshot.revision, before.revision)
    XCTAssertFalse(session.isCurrent(effects: effects))
    XCTAssertThrowsError(try session.validate(effects: effects)) { error in
      let failure = error as? InlineSelectionTransitionError
      XCTAssertEqual(failure?.operation, "append.effects.validate")
      XCTAssertEqual(failure?.preparationRevision, session.snapshot.revision)
    }
    XCTAssertThrowsError(
      try InlineSwiftUIAppendRenderer(
        validating: session, viewport: viewport, effects: effects))
    XCTAssertThrowsError(
      try InlineCanvasAppendRenderer(
        validating: session, viewport: viewport, effects: effects))
  }

  func testFailedAppendEffectsBuildDoesNotPublishSessionState() throws {
    let vectorAsset = try asset(id: "effects-missing")
    let session = try makeSession(
      assets: AssetProvider([vectorAsset]), preparation: InlinePreparation())
    try session.send(appendEvent(session, atoms: [try text(id: "word", value: "word")]))
    let missingMask = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "not-provided"),
      metrics: vectorAsset.metrics,
      coordinateBounds: vectorAsset.coordinateBounds,
      coveragePath: vectorAsset.coveragePath,
      coveragePaint: vectorAsset.coveragePaint,
      trajectoryPath: vectorAsset.trajectoryPath,
      trajectoryStyle: vectorAsset.trajectoryStyle)
    let composition = try InlineSVGCompositionPlan(
      preparationRevision: session.snapshot.revision,
      instances: [
        try InlineSVGCompositionInstance(
          instanceID: "missing", assetID: missingMask.id,
          assetVersion: missingMask.version, role: .mask,
          targetID: "word", operation: .reveal, declarationOrder: 1)
      ])
    let before = session.snapshot
    let beforeAccounting = session.operationAccounting
    XCTAssertThrowsError(try session.makeEffectsPlan(composition: composition)) { error in
      XCTAssertEqual((error as? InlineSVGCompositionError)?.operation, "composition.resolve")
    }
    XCTAssertEqual(session.snapshot, before)
    XCTAssertEqual(session.operationAccounting, beforeAccounting)
  }

  func testEffectsProviderFailuresRemainTypedAndDoNotBecomeMissingAsset() throws {
    let maskAsset = try asset(id: "effects-provider-error")

    let malformedSession = try makeSession(
      assets: MalformedProvider(), preparation: InlinePreparation())
    try malformedSession.send(
      appendEvent(
        malformedSession, atoms: [try text(id: "word", value: "word")]))
    let malformedComposition = try InlineSVGCompositionPlan(
      preparationRevision: malformedSession.snapshot.revision,
      instances: [
        try InlineSVGCompositionInstance(
          instanceID: "malformed", assetID: maskAsset.id,
          assetVersion: maskAsset.version, role: .mask,
          targetID: "word", operation: .reveal, declarationOrder: 1)
      ])
    let malformedBefore = malformedSession.snapshot
    XCTAssertThrowsError(
      try malformedSession.makeEffectsPlan(
        composition: malformedComposition)
    ) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .invalidSVGPath("malformed provider geometry"))
    }
    XCTAssertEqual(malformedSession.snapshot, malformedBefore)

    let mismatchSession = try makeSession(
      assets: VersionMismatchProvider(actualVersion: maskAsset.version + 1),
      preparation: InlinePreparation())
    try mismatchSession.send(
      appendEvent(
        mismatchSession, atoms: [try text(id: "word", value: "word")]))
    let mismatchComposition = try InlineSVGCompositionPlan(
      preparationRevision: mismatchSession.snapshot.revision,
      instances: [
        try InlineSVGCompositionInstance(
          instanceID: "mismatch", assetID: maskAsset.id,
          assetVersion: maskAsset.version, role: .mask,
          targetID: "word", operation: .reveal, declarationOrder: 1)
      ])
    XCTAssertThrowsError(
      try mismatchSession.makeEffectsPlan(
        composition: mismatchComposition)
    ) { error in
      XCTAssertEqual(
        error as? InlineAssetResolutionError,
        .versionMismatch(
          maskAsset.id, expected: maskAsset.version, actual: maskAsset.version + 1))
    }

    let ioSession = try makeSession(
      assets: IOProvider(), preparation: InlinePreparation())
    try ioSession.send(
      appendEvent(
        ioSession, atoms: [try text(id: "word", value: "word")]))
    let ioComposition = try InlineSVGCompositionPlan(
      preparationRevision: ioSession.snapshot.revision,
      instances: [
        try InlineSVGCompositionInstance(
          instanceID: "io", assetID: maskAsset.id,
          assetVersion: maskAsset.version, role: .mask,
          targetID: "word", operation: .reveal, declarationOrder: 1)
      ])
    let ioBefore = ioSession.snapshot
    XCTAssertThrowsError(
      try ioSession.makeEffectsPlan(
        composition: ioComposition)
    ) { error in
      XCTAssertEqual(error as? ProviderFailure, .io)
    }
    XCTAssertEqual(ioSession.snapshot, ioBefore)
  }

  func testEffectsBuildCancellationLeavesSessionAndAssetCacheUntouched() throws {
    let maskAsset = try asset(id: "effects-cancel")
    let cache = try InlineAssetCache(maximumEntries: 4)
    let session = try makeSession(
      assets: AssetProvider([maskAsset]), preparation: InlinePreparation(), assetCache: cache)
    try session.send(appendEvent(session, atoms: [try text(id: "word", value: "word")]))
    let composition = try InlineSVGCompositionPlan(
      preparationRevision: session.snapshot.revision,
      instances: [
        try InlineSVGCompositionInstance(
          instanceID: "cancel-mask", assetID: maskAsset.id,
          assetVersion: maskAsset.version, role: .mask,
          targetID: "word", operation: .reveal, declarationOrder: 1)
      ])
    let before = session.snapshot
    let beforeAccounting = session.operationAccounting
    let beforeCacheCount = cache.count
    let beforeCacheHits = cache.hitCount
    let beforeCacheMisses = cache.missCount
    let controller = CancellationController()
    // The provider is reached before the final publication checkpoint. The
    // effects plan remains local, so cancellation must leave every owner/cache
    // observable unchanged.
    controller.cancelOnCall = 10
    XCTAssertThrowsError(
      try session.makeEffectsPlan(
        composition: composition, cancellation: controller.check)
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .cancelled)
    }
    XCTAssertGreaterThanOrEqual(controller.calls, 8)
    XCTAssertEqual(session.snapshot, before)
    XCTAssertEqual(session.operationAccounting, beforeAccounting)
    XCTAssertEqual(cache.count, beforeCacheCount)
    XCTAssertEqual(cache.hitCount, beforeCacheHits)
    XCTAssertEqual(cache.missCount, beforeCacheMisses)
  }

  func testEffectsMasksRemainTargetLocalAndMaskOnlyVectorsAreSuppressed() throws {
    let maskAsset = try asset(id: "effects-local-mask")
    let payload = try makeImagePayload(id: "effects-local-image")
    let image = try InlineImageAtom(
      id: "image-target", reference: payload.reference,
      metrics: try InlineMetrics(advance: 12, ascent: 8, descent: 4),
      presentation: .thumbnail(contentMode: .fit), accessibility: .label("Image"))
    let atoms: [InlineAtom] = [
      try vectorAtom(id: "mask-source", asset: maskAsset),
      try vectorAtom(id: "vector-target", asset: maskAsset),
      .image(image),
    ]
    let session = try makeSession(
      width: 32, assets: AssetProvider([maskAsset]),
      imageAssets: try InlineImageAssetStore(payloads: [payload]))
    try session.send(appendEvent(session, atoms: atoms))
    try session.send(finishEvent(session))
    let composition = try InlineSVGCompositionPlan(
      preparationRevision: session.snapshot.revision,
      instances: [
        try InlineSVGCompositionInstance(
          instanceID: "vector-artwork", assetID: maskAsset.id,
          assetVersion: maskAsset.version, sourceAtomID: "vector-target",
          role: .artwork, declarationOrder: 1),
        try InlineSVGCompositionInstance(
          instanceID: "vector-mask", assetID: maskAsset.id,
          assetVersion: maskAsset.version, sourceAtomID: "mask-source",
          role: .mask, targetID: "vector-target", operation: .reveal,
          declarationOrder: 2),
        try InlineSVGCompositionInstance(
          instanceID: "image-mask", assetID: maskAsset.id,
          assetVersion: maskAsset.version, sourceAtomID: "mask-source",
          role: .mask, targetID: "image-target", operation: .erase,
          declarationOrder: 3),
      ])
    let effects = try session.makeEffectsPlan(composition: composition)
    let chunks = session.committedSections.flatMap(\.chunks)
    let source = try XCTUnwrap(chunks.first { $0.positioned.atomID == "mask-source" })
    let vectorTarget = try XCTUnwrap(
      chunks.first { $0.positioned.atomID == "vector-target" })
    let imageTarget = try XCTUnwrap(
      chunks.first { $0.positioned.atomID == "image-target" })

    XCTAssertFalse(effects.shouldRenderArtwork(for: source))
    XCTAssertTrue(effects.shouldRenderArtwork(for: vectorTarget))
    XCTAssertTrue(effects.shouldRenderArtwork(for: imageTarget))
    let vectorMasks = effects.masks(for: vectorTarget)
    let imageMasks = effects.masks(for: imageTarget)
    XCTAssertEqual(vectorMasks.map(\.operation), [.reveal])
    XCTAssertEqual(imageMasks.map(\.operation), [.erase])
    XCTAssertFalse(vectorMasks[0].path.isEmpty)
    XCTAssertFalse(imageMasks[0].path.isEmpty)
    let vectorBounds = vectorMasks[0].path.boundingRect
    let imageBounds = imageMasks[0].path.boundingRect
    XCTAssertLessThanOrEqual(vectorBounds.maxX, CGFloat(vectorTarget.positioned.width) + 0.0001)
    XCTAssertLessThanOrEqual(vectorBounds.maxY, CGFloat(vectorTarget.positioned.height) + 0.0001)
    XCTAssertLessThanOrEqual(imageBounds.maxX, CGFloat(imageTarget.positioned.width) + 0.0001)
    XCTAssertLessThanOrEqual(imageBounds.maxY, CGFloat(imageTarget.positioned.height) + 0.0001)
    XCTAssertEqual(effects.masksByChunkID.count, 2)
  }

  func testSessionCommitReplayAndReentrantSendUseOneSynchronousOwner() throws {
    let session = try makeSession(
      assets: FailingProvider(), preparation: InlinePreparation())
    let event = try appendEvent(session, atoms: [try text(id: "a")])
    let before = session.snapshot
    let beforeAccounting = session.operationAccounting
    var notifications = 0
    var callbackSnapshot: InlineAppendSnapshot?
    var reentrantError: Error?
    let subscription = session.objectWillChange.sink { _ in
      notifications += 1
      callbackSnapshot = session.snapshot
      do { _ = try session.send(event) } catch { reentrantError = error }
    }

    let delta = try session.send(event)
    XCTAssertEqual(notifications, 1)
    XCTAssertEqual(callbackSnapshot, before)
    XCTAssertEqual(reentrantError as? InlineLayoutError, .invalidContinuation)
    XCTAssertNotEqual(session.snapshot, before)
    let committed = session.snapshot
    let committedAccounting = session.operationAccounting
    let replay = try session.send(event)
    XCTAssertEqual(replay, delta)
    XCTAssertEqual(session.snapshot, committed)
    XCTAssertEqual(session.operationAccounting, committedAccounting)
    XCTAssertEqual(notifications, 1)
    XCTAssertNotEqual(committedAccounting, beforeAccounting)
    _ = subscription
  }

  func testStreamIdentitySequenceRevisionReplayAndFinishFailuresAreAtomic() throws {
    let vectorAsset = try asset()
    let session = try makeSession(
      assets: AssetProvider([vectorAsset]), preparation: InlinePreparation())
    let first = try appendEvent(session, atoms: [try text(id: "first")])
    try session.send(first)
    let beforeFailures = session.snapshot

    let wrongStream = InlineAppendEvent.append(
      InlineAppendBatch(
        streamID: UUID(), sequence: session.snapshot.nextSequence,
        baseRevision: session.snapshot.revision,
        atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: try text(id: "wrong"))]))
    XCTAssertThrowsError(try session.send(wrongStream)) { error in
      guard case .streamIdentityMismatch = error as? InlineLayoutError else {
        return XCTFail("wrong stream must be rejected by the session")
      }
    }
    XCTAssertEqual(session.snapshot, beforeFailures)

    let future = InlineAppendEvent.append(
      InlineAppendBatch(
        streamID: Self.streamID, sequence: session.snapshot.nextSequence + 1,
        baseRevision: session.snapshot.revision,
        atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: try text(id: "future"))]))
    XCTAssertThrowsError(try session.send(future)) { error in
      guard case .streamSequenceMismatch = error as? InlineLayoutError else {
        return XCTFail("future sequence must be rejected by the session")
      }
    }
    XCTAssertEqual(session.snapshot, beforeFailures)

    let wrongRevision = InlineAppendEvent.append(
      InlineAppendBatch(
        streamID: Self.streamID, sequence: session.snapshot.nextSequence,
        baseRevision: "stale-revision",
        atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: try text(id: "stale"))]))
    XCTAssertThrowsError(try session.send(wrongRevision)) { error in
      guard case .streamRevisionMismatch = error as? InlineLayoutError else {
        return XCTFail("stale revision must be rejected by the session")
      }
    }
    XCTAssertEqual(session.snapshot, beforeFailures)

    let conflicting = InlineAppendEvent.append(
      InlineAppendBatch(
        streamID: Self.streamID, sequence: session.snapshot.nextSequence - 1,
        baseRevision: session.snapshot.revision,
        atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: try text(id: "conflict"))]))
    XCTAssertThrowsError(try session.send(conflicting)) { error in
      guard case .conflictingStreamReplay = error as? InlineLayoutError else {
        return XCTFail("conflicting replay must be rejected by the session")
      }
    }
    XCTAssertEqual(session.snapshot, beforeFailures)

    try session.send(finishEvent(session))
    let finished = session.snapshot
    let finishAfterFinish = InlineAppendEvent.finish(
      streamID: Self.streamID, sequence: session.snapshot.nextSequence - 1,
      baseRevision: "different-finish")
    XCTAssertThrowsError(try session.send(finishAfterFinish)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .conflictingStreamReplay(sequence: session.snapshot.nextSequence - 1))
    }
    XCTAssertEqual(session.snapshot, finished)

    let newSequenceFinish = InlineAppendEvent.finish(
      streamID: Self.streamID, sequence: session.snapshot.nextSequence,
      baseRevision: session.snapshot.revision)
    XCTAssertThrowsError(try session.send(newSequenceFinish)) { error in
      XCTAssertEqual(error as? InlineLayoutError, .streamAlreadyFinished)
    }
    XCTAssertEqual(session.snapshot, finished)
  }

  func testProviderMismatchMalformedAndMissingFailuresDoNotPublishOrCache() throws {
    let vectorAsset = try asset()
    let vector = try vectorAtom(id: "vector", asset: vectorAsset)
    let missingSession = try makeSession(assets: FailingProvider())
    let missingEvent = try appendEvent(missingSession, atoms: [vector])
    let missingBefore = missingSession.snapshot
    let missingAccounting = missingSession.operationAccounting
    XCTAssertThrowsError(try missingSession.send(missingEvent)) { error in
      XCTAssertEqual(
        error as? InlineAssetResolutionError,
        .missingGeometry(vectorAsset.id, version: vectorAsset.version))
    }
    XCTAssertEqual(missingSession.snapshot, missingBefore)
    XCTAssertEqual(missingSession.operationAccounting, missingAccounting)

    let malformedSession = try makeSession(assets: MalformedProvider())
    let malformedEvent = try appendEvent(malformedSession, atoms: [vector])
    let malformedBefore = malformedSession.snapshot
    XCTAssertThrowsError(try malformedSession.send(malformedEvent)) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidSVGPath("malformed provider geometry"))
    }
    XCTAssertEqual(malformedSession.snapshot, malformedBefore)

    let mismatched = try asset(id: "different")
    let session = try makeSession(assets: ReturningProvider(asset: mismatched))
    let event = try appendEvent(session, atoms: [vector])
    let before = session.snapshot
    XCTAssertThrowsError(try session.send(event)) { error in
      XCTAssertEqual(error as? InlineAssetResolutionError, .metricsMismatch(vectorAsset.id))
    }
    XCTAssertEqual(session.snapshot, before)
  }

  func testCancellationAtCandidateCheckpointsRollsBackStateAndImageTransaction() throws {
    let vectorAsset = try asset()
    let session = try makeSession(assets: AssetProvider([vectorAsset]))
    let event = try appendEvent(session, atoms: [try vectorAtom(id: "cancel", asset: vectorAsset)])
    let before = session.snapshot
    let controller = CancellationController()
    controller.cancelOnCall = 1
    XCTAssertThrowsError(try session.send(event, cancellation: controller.check)) { error in
      XCTAssertEqual(error as? InlineLayoutError, .cancelled)
    }
    XCTAssertEqual(session.snapshot, before)
    XCTAssertNil(session.tailSection)

    controller.calls = 0
    controller.cancelOnCall = 3
    XCTAssertThrowsError(try session.send(event, cancellation: controller.check)) { error in
      XCTAssertEqual(error as? InlineLayoutError, .cancelled)
    }
    XCTAssertEqual(session.snapshot, before)

    let imageCache = try InlineImageRenderCache(maximumBytes: 1_024)
    let imageSession = try makeSession(assets: FailingProvider(), imageCache: imageCache)
    let imageEvent = try appendEvent(imageSession, atoms: [try text(id: "image-stream")])
    let cacheTransaction = imageCache.beginTransaction()
    XCTAssertThrowsError(try imageSession.send(imageEvent)) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidContinuation)
    }
    XCTAssertEqual(imageSession.snapshot.nextSequence, 0)
    cacheTransaction.rollback()
    XCTAssertFalse(imageCache.hasActiveTransaction)
  }

  func testActiveImageCacheTransactionIsRejectedAtSessionCreation() throws {
    let cache = try InlineImageRenderCache(maximumBytes: 1_024)
    let transaction = cache.beginTransaction()
    XCTAssertThrowsError(try makeSession(assets: FailingProvider(), imageCache: cache)) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidContinuation)
    }
    transaction.rollback()
    XCTAssertFalse(cache.hasActiveTransaction)
  }

  func testVectorFillAndStrokeCoverageRemainSeparateFromTrajectory() throws {
    let fillAsset = try asset(id: "fill", paint: .fill(.evenOdd), label: "Filled")
    let strokePath = try InlineSVGBridge.parsePath("M0 0 L1 0")
    let strokeAsset = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "stroke"),
      metrics: try InlineMetrics(advance: 1, ascent: 8, descent: 2),
      coordinateBounds: strokePath.bounds,
      coveragePath: strokePath,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 0.4, cap: .round, join: .round)),
      trajectoryPath: strokePath,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 0.4),
      accessibilityLabel: "Stroked")
    let session = try makeSession(assets: AssetProvider([fillAsset, strokeAsset]))
    try session.send(
      appendEvent(
        session,
        atoms: [
          try vectorAtom(id: "fill-atom", asset: fillAsset),
          try vectorAtom(id: "stroke-atom", asset: strokeAsset),
        ]))
    try session.send(finishEvent(session))
    let chunks = session.committedSections.flatMap(\.chunks)
    guard chunks.count == 2,
      case .vector(_, _, let fillPath, let fillPaint, _) = chunks[0],
      case .vector(_, _, let strokePathValue, let strokePaint, _) = chunks[1]
    else { return XCTFail("expected two vector chunks") }
    XCTAssertFalse(fillPath.isEmpty)
    XCTAssertEqual(fillPaint, .fill(.evenOdd))
    XCTAssertFalse(strokePathValue.isEmpty)
    guard case .stroke(let stroke) = strokePaint else {
      return XCTFail("stroke coverage style was not retained")
    }
    XCTAssertEqual(stroke.width, 0.4, accuracy: 0.0001)
    XCTAssertEqual(stroke.cap, .round)

    let vectorSections = session.committedSections.filter { section in
      section.chunks.contains { chunk in
        if case .vector = chunk { return true }
        return false
      }
    }
    XCTAssertEqual(vectorSections.count, 1)
    for section in vectorSections {
      for chunk in section.chunks {
        guard case .vector = chunk else { continue }
        guard
          case .vector(let trajectoryCommands, let trajectoryStyle, let activation) =
            section.revealByChunkID[chunk.id]
        else { return XCTFail("vector trajectory reveal payload was not retained") }
        XCTAssertFalse(trajectoryCommands.isEmpty)
        XCTAssertGreaterThan(trajectoryStyle.width, 0)
        XCTAssertFalse(activation.units.isEmpty)
        XCTAssertEqual(activation.completedCommandCount(at: 0), 0)
        XCTAssertEqual(
          activation.completedCommandCount(at: activation.duration), activation.units.count)
      }
    }
  }

  func testAppendRevealPhasesAndMaterialUseOneAdapterPainter() throws {
    let vectorAsset = try asset(id: "paint", paint: .fill(.nonZero), label: "Paint")
    let session = try makeSession(
      assets: AssetProvider([vectorAsset]), preparation: InlinePreparation())
    try session.send(
      appendEvent(
        session,
        atoms: [
          try text(id: "text", value: "ab"),
          try vectorAtom(id: "vector", asset: vectorAsset),
        ]))
    try session.send(finishEvent(session))
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 64, height: 80)
    let zero = try InlineRenderRevealPhase(0)
    let mid = try InlineRenderRevealPhase(0.5)
    let brush = InlineRendererMaterial.brush(.default)
    let swift = try InlineSwiftUIAppendRenderer(
      session: session, viewport: viewport, phase: zero, material: brush)
    let canvas = try InlineCanvasAppendRenderer(
      session: session, viewport: viewport, phase: mid, material: brush)
    XCTAssertNotNil(swift)
    XCTAssertNotNil(canvas)

    for section in session.committedSections {
      for chunk in section.chunks {
        guard let reveal = section.revealByChunkID[chunk.id] else {
          return XCTFail("append reveal payload was not retained")
        }
        switch reveal {
        case .text(let activation):
          XCTAssertEqual(
            activation.progress(at: 0, sourceRange: activation.units[0].sourceRange), 0)
        case .vector(_, _, let activation):
          XCTAssertEqual(activation.completedCommandCount(at: 0), 0)
        case .image(let activation):
          XCTAssertEqual(activation.progress(at: 0), 0)
        }
      }
    }
  }

  func testAppendVectorPaintPlanKeepsCoverageAndTrajectoryRoles() throws {
    let fill = try asset(id: "plan-fill", paint: .fill(.evenOdd))
    let strokePath = try InlineSVGBridge.parsePath("M0 0 L8 0")
    let stroke = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "plan-stroke"),
      metrics: try InlineMetrics(advance: 8, ascent: 8, descent: 2),
      coordinateBounds: strokePath.bounds,
      coveragePath: strokePath,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 3)),
      trajectoryPath: try InlineSVGBridge.parsePath("M0 0 L8 0"),
      trajectoryStyle: try InlineSVGStrokeStyle(width: 5),
      accessibilityLabel: "Stroke")
    let session = try makeSession(width: 8, assets: AssetProvider([fill, stroke]))
    try session.send(
      appendEvent(
        session,
        atoms: [
          try vectorAtom(id: "fill-atom", asset: fill),
          try vectorAtom(id: "stroke-atom", asset: stroke),
        ]))
    try session.send(finishEvent(session))
    let chunks = session.committedSections.flatMap(\.chunks)
    guard chunks.count == 2,
      case .vector(_, let fillPositioned, let fillPath, let fillPaint, _) = chunks[0],
      case .vector(_, let strokePositioned, let strokeCoverage, let strokePaint, _) = chunks[1]
    else { return XCTFail("expected vector chunks and reveal payloads") }
    XCTAssertNotEqual(fillPositioned.lineIndex, strokePositioned.lineIndex)
    guard
      let fillSection = session.committedSections.first(where: {
        $0.record.lineIndex == fillPositioned.lineIndex
      })
    else {
      return XCTFail("fill chunk has no owning line section")
    }
    guard
      let strokeSection = session.committedSections.first(where: {
        $0.record.lineIndex == strokePositioned.lineIndex
      })
    else {
      return XCTFail("stroke chunk has no owning line section")
    }
    guard
      case .vector(let fillCommands, let fillTrajectoryStyle, let fillActivation) =
        fillSection.revealByChunkID[chunks[0].id]
    else { return XCTFail("fill chunk reveal payload is missing from its owning section") }
    guard
      case .vector(let strokeCommands, let strokeTrajectoryStyle, let strokeActivation) =
        strokeSection.revealByChunkID[chunks[1].id]
    else { return XCTFail("stroke chunk reveal payload is missing from its owning section") }

    let zero = InlineAppleAppendPainter.vectorPaintPlan(
      coverage: fillPath, coveragePaint: fillPaint,
      trajectoryCommands: fillCommands, trajectoryStyle: fillTrajectoryStyle,
      activation: fillActivation, totalDuration: fillActivation.duration,
      phase: .zero)
    XCTAssertTrue(zero.isEmpty)

    let middle = try InlineRenderRevealPhase(0.5)
    let partial = InlineAppleAppendPainter.vectorPaintPlan(
      coverage: fillPath, coveragePaint: fillPaint,
      trajectoryCommands: fillCommands, trajectoryStyle: fillTrajectoryStyle,
      activation: fillActivation, totalDuration: fillActivation.duration,
      phase: middle)
    guard
      case .partialCoverage(
        let partialCoverage, let partialPaint, let partialTrajectory,
        let partialStyle) = partial.mask
    else {
      return XCTFail("middle phase must intersect coverage with a trajectory mask")
    }
    XCTAssertEqual(partialPaint, .fill(.evenOdd))
    XCTAssertEqual(partialCoverage.boundingRect, fillPath.boundingRect)
    XCTAssertFalse(partialTrajectory.isEmpty)
    XCTAssertEqual(partialStyle.width, fillTrajectoryStyle.width)
    XCTAssertNotEqual(partialTrajectory.boundingRect, partialCoverage.boundingRect)

    let complete = InlineAppleAppendPainter.vectorPaintPlan(
      coverage: fillPath, coveragePaint: fillPaint,
      trajectoryCommands: fillCommands, trajectoryStyle: fillTrajectoryStyle,
      activation: fillActivation, totalDuration: fillActivation.duration,
      phase: .complete)
    guard case .completeCoverage(let completeCoverage, let completePaint) = complete.mask else {
      return XCTFail("complete phase must select full coverage")
    }
    XCTAssertEqual(completeCoverage.boundingRect, fillPath.boundingRect)
    XCTAssertEqual(completePaint, .fill(.evenOdd))

    guard case .stroke(let strokeCoverageStyle) = strokePaint else {
      return XCTFail("stroke coverage style was not retained")
    }
    XCTAssertEqual(strokeCoverageStyle.width, 3)
    let strokeComplete = InlineAppleAppendPainter.vectorPaintPlan(
      coverage: strokeCoverage, coveragePaint: strokePaint,
      trajectoryCommands: strokeCommands, trajectoryStyle: strokeTrajectoryStyle,
      activation: strokeActivation, totalDuration: strokeActivation.duration,
      phase: .complete)
    guard case .completeCoverage(_, let strokeCompletePaint) = strokeComplete.mask,
      case .stroke(let completeStyle) = strokeCompletePaint
    else { return XCTFail("complete stroke plan lost coverage stroke semantics") }
    XCTAssertEqual(completeStyle.width, 3)
    XCTAssertEqual(strokeTrajectoryStyle.width, 5)

    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 64, height: 80)
    let chalk = InlineRendererMaterial.chalk(.default)
    XCTAssertNotNil(
      try InlineSwiftUIAppendRenderer(
        session: session, viewport: viewport, phase: middle, material: chalk))
    XCTAssertNotNil(
      try InlineCanvasAppendRenderer(
        session: session, viewport: viewport, phase: middle, material: chalk))
    XCTAssertNotNil(
      try InlineSwiftUIAppendRenderer(
        session: session, viewport: viewport, phase: middle, material: .brush(.default)))
    XCTAssertNotNil(
      try InlineCanvasAppendRenderer(
        session: session, viewport: viewport, phase: middle, material: .brush(.default)))
    let pencil = try ColoredPencilConfiguration()
    XCTAssertThrowsError(
      try InlineSwiftUIAppendRenderer(
        session: session, viewport: viewport, phase: middle,
        material: .coloredPencil(pencil))
    ) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .unsupportedShaping("append renderer material is not supported by the shared painter"))
    }
  }

  func testAppendBrushGeometryUsesVisiblePrefixBeforeBuildingRibbon() throws {
    func segment(
      startX: Double,
      endX: Double,
      startDistance: Double,
      endDistance: Double,
      commandIndex: Int
    ) -> InlineWritingMaterialSegment {
      InlineWritingMaterialSegment(
        start: CGPoint(x: startX, y: 0), end: CGPoint(x: endX, y: 0),
        startDistance: startDistance, endDistance: endDistance,
        subpathLength: 80, subpathID: 0, isClosed: false,
        commandIndex: commandIndex)
    }

    let segments = [
      segment(startX: 0, endX: 40, startDistance: 0, endDistance: 40, commandIndex: 0),
      segment(startX: 40, endX: 80, startDistance: 40, endDistance: 80, commandIndex: 1),
    ]
    let assetID = try InlineAssetID(rawValue: "append-brush")
    let activation = try InlineRenderRevealVectorActivation(
      atomID: "append-brush", assetID: assetID, assetVersion: 0,
      units: [
        try InlineRenderRevealVectorUnit(commandIndex: 0, startTime: 0, duration: 1),
        try InlineRenderRevealVectorUnit(commandIndex: 1, startTime: 1, duration: 1),
      ])
    let material = WritingMaterial.brush(.default)
    let middlePhase = try InlineRenderRevealPhase(0.75)
    let middleTime = activation.duration * middlePhase.rawValue

    let zero = InlineAppleAppendPainter.visibleMaterialGeometries(
      segments: segments, activation: activation, time: 0,
      material: material, destinationHeight: 24)
    let middle = InlineAppleAppendPainter.visibleMaterialGeometries(
      segments: segments, activation: activation, time: middleTime,
      material: material, destinationHeight: 24)
    let complete = InlineAppleAppendPainter.visibleMaterialGeometries(
      segments: segments, activation: activation, time: activation.duration,
      material: material, destinationHeight: 24)

    XCTAssertTrue(zero.isEmpty)
    let visibleMiddle = InlineWritingMaterialSampler.visibleSegments(
      segments, activation: activation, time: middleTime)
    let visibleComplete = InlineWritingMaterialSampler.visibleSegments(
      segments, activation: activation, time: activation.duration)
    let middleTerminal = try XCTUnwrap(visibleMiddle.last)
    let completeTerminal = try XCTUnwrap(visibleComplete.last)
    XCTAssertEqual(middleTerminal.endDistance, 60, accuracy: 0.0001)
    XCTAssertEqual(completeTerminal.endDistance, 80, accuracy: 0.0001)

    let middleGeometry = try XCTUnwrap(middle.first)
    let completeGeometry = try XCTUnwrap(complete.first)
    let middleBodyMaxX = try XCTUnwrap(middleGeometry.body.map(\.x).max())
    let completeBodyMaxX = try XCTUnwrap(completeGeometry.body.map(\.x).max())
    XCTAssertLessThan(middleBodyMaxX, completeBodyMaxX)

    func verticalExtent(_ body: [WritingPlanPoint], nearX x: Double) -> Double {
      let values = body.filter { abs($0.x - x) < 2 }.map(\.y)
      guard let minimum = values.min(), let maximum = values.max() else { return 0 }
      return maximum - minimum
    }
    let middleBodyWidth = verticalExtent(middleGeometry.body, nearX: 30)
    let middleTerminalWidth = verticalExtent(middleGeometry.body, nearX: 60)
    XCTAssertGreaterThan(middleBodyWidth, 0)
    XCTAssertGreaterThan(middleTerminalWidth, 0)
    XCTAssertLessThan(middleTerminalWidth, middleBodyWidth * 0.65)
  }

  func testAppendVectorRevealUsesCompletedCommandsThenCurrentPrefix() throws {
    let trajectory = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 10, y: 0)),
      .move(try InlinePathPoint(x: 100, y: 0)),
      .line(try InlinePathPoint(x: 110, y: 0)),
      .line(try InlinePathPoint(x: 110, y: 10)),
    ])
    let asset = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "command-order"),
      metrics: try InlineMetrics(advance: 110, ascent: 12, descent: 2),
      coordinateBounds: trajectory.bounds,
      coveragePath: trajectory,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: trajectory,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 2))
    let commands = try InlineAppleRenderContent.makeVectorRevealCommands(
      asset: asset, destination: CGRect(x: 0, y: 0, width: 220, height: 20))
    let activation = try InlineRenderRevealVectorActivation(
      atomID: "command-order-atom", assetID: asset.id, assetVersion: asset.version,
      units: [
        try InlineRenderRevealVectorUnit(commandIndex: 1, startTime: 0, duration: 1),
        try InlineRenderRevealVectorUnit(commandIndex: 3, startTime: 1, duration: 1),
        try InlineRenderRevealVectorUnit(commandIndex: 4, startTime: 2, duration: 1),
      ])

    let reveal = InlineAppleRenderContent.makeVectorRevealPath(
      commands: commands, activation: activation, time: 2.5)
    XCTAssertFalse(reveal.isComplete)
    XCTAssertEqual(reveal.path.cgPath.boundingBoxOfPath.minX, 0, accuracy: 0.0001)
    XCTAssertEqual(reveal.path.cgPath.boundingBoxOfPath.maxX, 220, accuracy: 0.0001)
    XCTAssertEqual(reveal.path.cgPath.boundingBoxOfPath.maxY, 10, accuracy: 0.0001)

    var elements: [CGPathElementType] = []
    reveal.path.cgPath.applyWithBlock { element in
      elements.append(element.pointee.type)
    }
    XCTAssertEqual(
      elements,
      [
        .moveToPoint, .addLineToPoint, .moveToPoint, .addLineToPoint,
        .moveToPoint, .addLineToPoint,
      ])
  }

  func testAppendVectorCoverageAndTrajectoryStylesShareUniformScale() throws {
    let path = try InlinePathData(commands: [
      .move(try InlinePathPoint(x: 0, y: 0)),
      .line(try InlinePathPoint(x: 8, y: 0)),
      .line(try InlinePathPoint(x: 8, y: 4)),
    ])
    let asset = try InlineSVGAsset(
      id: try InlineAssetID(rawValue: "uniform-scale"),
      metrics: try InlineMetrics(advance: 8, ascent: 8, descent: 2),
      coordinateBounds: path.bounds,
      coveragePath: path,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 2)),
      trajectoryPath: path,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 3))
    let destination = CGRect(x: 0, y: 0, width: 80, height: 20)
    guard
      case .stroke(let coverageStyle) =
        InlineAppleRenderContent.makeLocalCoveragePaint(asset, destination: destination)
    else { return XCTFail("coverage stroke style was not retained") }
    let trajectoryStyle = InlineAppleRenderContent.makeLocalTrajectoryStyle(
      asset, destination: destination)
    XCTAssertEqual(coverageStyle.width, 10, accuracy: 0.0001)
    XCTAssertEqual(trajectoryStyle.width, 15, accuracy: 0.0001)
  }

  func testAppendPainterUsesPositionedDocumentOriginForMaterialTexture() throws {
    let metrics = try InlineMetrics(advance: 10, ascent: 12, descent: 3)
    let positioned = try PositionedInlineAtom(
      atomID: "origin", kind: .text, lineIndex: 0, originX: 13.5, baselineY: 40,
      width: 10, height: 20, metrics: metrics)
    let origin = InlineAppleAppendPainter.documentOrigin(for: positioned)
    XCTAssertEqual(origin.x, 13.5, accuracy: 0.0001)
    XCTAssertEqual(origin.y, 28, accuracy: 0.0001)
  }

  func testImageChunksPreserveLabelsAndDecorativeAccessibility() throws {
    let payload = try makeImagePayload(id: "image")
    let labeled = try InlineImageAtom(
      id: "labeled", reference: payload.reference,
      metrics: try InlineMetrics(advance: 12, ascent: 8, descent: 4),
      presentation: .thumbnail(contentMode: .fit), accessibility: .label("Picture"))
    let decorative = try InlineImageAtom(
      id: "decorative", reference: payload.reference,
      metrics: try InlineMetrics(advance: 12, ascent: 8, descent: 4),
      presentation: .thumbnail(contentMode: .fit), accessibility: .decorative)
    let session = try makeSession(
      assets: FailingProvider(), imageAssets: try InlineImageAssetStore(payloads: [payload]))
    try session.send(appendEvent(session, atoms: [.image(labeled), .image(decorative)]))
    try session.send(finishEvent(session))
    let chunks = session.committedSections.flatMap(\.chunks)
    guard chunks.count == 2,
      case .image(_, _, _, let firstLabel, let firstDecorative) = chunks[0],
      case .image(_, _, _, let secondLabel, let secondDecorative) = chunks[1]
    else { return XCTFail("expected two image chunks") }
    XCTAssertEqual(firstLabel, "Picture")
    XCTAssertFalse(firstDecorative)
    XCTAssertEqual(secondLabel, "decorative")
    XCTAssertTrue(secondDecorative)
    XCTAssertEqual(session.accessibilityEntries.map(\.text), ["Picture", "decorative"])
    XCTAssertEqual(session.accessibilityEntries.map(\.isDecorative), [false, true])
  }

  func testInvalidImagePayloadFailureIsAtomic() throws {
    let bytes = Data([0x01, 0x02, 0x03])
    let id = try InlineAssetID(rawValue: "invalid-image")
    let rendition = try InlineImageRendition(
      encoding: .png, encodedBytes: bytes, pixelWidth: 1, pixelHeight: 1)
    let reference = try InlineImageReference(
      assetID: id, version: 1, digest: InlineAssetDigest(data: bytes))
    let payload = try InlineImagePayload(reference: reference, rendition: rendition)
    let atom = try InlineImageAtom(
      id: "invalid-image", reference: reference,
      metrics: try InlineMetrics(advance: 12, ascent: 8, descent: 4),
      presentation: .thumbnail(contentMode: .fit), accessibility: .label("Invalid"))
    let session = try makeSession(
      assets: FailingProvider(), imageAssets: try InlineImageAssetStore(payloads: [payload]))
    let before = session.snapshot
    let beforeAccounting = session.operationAccounting
    XCTAssertThrowsError(try session.send(appendEvent(session, atoms: [.image(atom)])))
    XCTAssertEqual(session.snapshot, before)
    XCTAssertEqual(session.operationAccounting, beforeAccounting)
  }

  func testRegistryAndAssetCachePreserveProviderHitMissSemantics() throws {
    let vectorAsset = try asset()
    let vector = try vectorAtom(id: "cached", asset: vectorAsset)
    let registry = try InlineAssetRegistry(records: [try InlineAssetRecord(asset: vectorAsset)])
    let registrySession = try makeSession(
      assets: FailingProvider(), registry: registry)
    try registrySession.send(appendEvent(registrySession, atoms: [vector]))
    XCTAssertEqual(registrySession.snapshot.nextSequence, 1)

    let cache = try InlineAssetCache(maximumEntries: 4)
    _ = try cache.insert(vectorAsset)
    let cachedSession = try makeSession(
      assets: FailingProvider(), assetCache: cache)
    try cachedSession.send(appendEvent(cachedSession, atoms: [vector]))
    XCTAssertGreaterThanOrEqual(cache.hitCount, 1)
    XCTAssertEqual(cache.missCount, 0)

    let missCache = try InlineAssetCache(maximumEntries: 4)
    let resolvedSession = try makeSession(
      assets: AssetProvider([vectorAsset]), assetCache: missCache)
    try resolvedSession.send(appendEvent(resolvedSession, atoms: [vector]))
    XCTAssertEqual(missCache.missCount, 1)
    XCTAssertEqual(missCache.count, 1)
  }

  func testIncrementalPrefixSectionOrderViewportCullingAndAccounting() throws {
    let vectorAsset = try asset()
    let session = try makeSession(width: 1, assets: AssetProvider([vectorAsset]))
    var previousIDs: [String] = []
    var previousGeometry = 0
    for index in 0..<32 {
      try session.send(
        appendEvent(
          session,
          atoms: [
            try vectorAtom(id: "line-\(index)", asset: vectorAsset)
          ]))
      let ids = session.committedSections.map(\.id)
      XCTAssertEqual(Array(ids.prefix(previousIDs.count)), previousIDs)
      XCTAssertGreaterThanOrEqual(session.operationAccounting.geometryItemCount, previousGeometry)
      previousIDs = ids
      previousGeometry = session.operationAccounting.geometryItemCount
    }
    try session.send(finishEvent(session))
    XCTAssertEqual(session.projection.committedLines.count, 32)
    XCTAssertEqual(
      session.committedSections.map(\.record.lineIndex),
      Array(0..<32))
    XCTAssertLessThanOrEqual(session.operationAccounting.geometryItemCount, 65)
    XCTAssertTrue(session.sectionIndex.validateInvariantsForTesting())

    let line = try XCTUnwrap(session.projection.committedLines[16])
    let viewport = try InlineRenderViewport(
      x: 0, y: line.baselineY - line.ascent, width: 1, height: line.ascent + line.descent)
    let visible = session.visibleSections(for: viewport)
    XCTAssertFalse(visible.isEmpty)
    XCTAssertLessThan(visible.count, session.committedSections.count)
    let positioned = try XCTUnwrap(line.atoms.first)
    let point = try InlineHitPoint(
      x: positioned.originX + positioned.width * 0.5,
      y: positioned.baselineY - positioned.metrics.baselineOffset
        - positioned.metrics.ascent + positioned.height * 0.5)
    XCTAssertNotNil(session.hitTest(at: point))
    XCTAssertNil(session.hitTest(at: try InlineHitPoint(x: 10_000, y: 10_000)))
  }

  func testPersistentSectionIndexCullsThousandLinesWithinVisitBudget() throws {
    let vectorAsset = try asset(id: "thousand-line-vector")
    let session = try makeSession(
      width: 1, assets: AssetProvider([vectorAsset]), preparation: InlinePreparation())

    for index in 0..<1_000 {
      try session.send(
        appendEvent(
          session,
          atoms: [
            try vectorAtom(id: "thousand-line-\(index)", asset: vectorAsset)
          ]))
    }
    try session.send(finishEvent(session))

    XCTAssertEqual(session.projection.committedLines.count, 1_000)
    XCTAssertEqual(session.committedSections.count, 1_000)
    XCTAssertTrue(session.sectionIndex.validateInvariantsForTesting())

    let firstVisibleLine = try XCTUnwrap(session.projection.committedLines[499])
    let secondVisibleLine = try XCTUnwrap(session.projection.committedLines[500])
    let viewportTop = firstVisibleLine.baselineY - firstVisibleLine.ascent
    let viewportBottom = secondVisibleLine.baselineY + secondVisibleLine.descent
    let viewport = try InlineRenderViewport(
      x: 0,
      y: viewportTop,
      width: 1,
      height: viewportBottom - viewportTop)

    let query = session.sectionIndex.query(viewport: viewport, kind: .paint)
    XCTAssertEqual(query.sections.map(\.lineIndex), [499, 500])
    XCTAssertLessThanOrEqual(query.nodeVisitCount, 32)

    let visible = session.visibleSections(for: viewport)
    XCTAssertEqual(visible.map(\.record.lineIndex), [499, 500])
    XCTAssertEqual(visible.flatMap(\.chunks).count, 2)

    let offscreenLine = try XCTUnwrap(session.projection.committedLines[900])
    let offscreenAtom = try XCTUnwrap(offscreenLine.atoms.first)
    let offscreenPoint = try InlineHitPoint(
      x: offscreenAtom.originX + offscreenAtom.width * 0.5,
      y: offscreenAtom.baselineY - offscreenAtom.metrics.baselineOffset
        - offscreenAtom.metrics.ascent + offscreenAtom.height * 0.5)
    guard case .vector(let offscreenHit) = session.hitTest(at: offscreenPoint) else {
      return XCTFail("viewport culling must not hide an offscreen hit")
    }
    XCTAssertEqual(offscreenHit.atomID, "thousand-line-900")
  }

  func testCoreTextEmojiAndRendererConstructionUseSameSession() throws {
    let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 24, nil)
    guard CTFontCopyPostScriptName(font) as String? == "AppleColorEmoji" else {
      throw XCTSkip("AppleColorEmoji is unavailable on this platform")
    }
    let atom = InlineAtom.text(
      try InlineTextAtom(
        id: "emoji", text: "🧪✨👩‍💻",
        style: try InlineTextStyle(
          font: FontDescriptor(postScriptName: "AppleColorEmoji", pointSize: 24))))
    let reducer = try InlineAppendReducer(
      streamID: Self.streamID, preparation: InlinePreparation(),
      engine: InlineLayoutEngine(), width: 240)
    let session = try InlineAppleAppendSession(reducer: reducer, assets: FailingProvider())
    try session.send(appendEvent(session, atoms: [atom]))
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 240, height: 64)
    let swift = try InlineSwiftUIAppendRenderer(session: session, viewport: viewport)
    let canvas = try InlineCanvasAppendRenderer(session: session, viewport: viewport)
    XCTAssertNotNil(ImageRenderer(content: swift).cgImage)
    XCTAssertNotNil(ImageRenderer(content: canvas).cgImage)
    let entries = session.visibleSections(for: viewport).flatMap(\.chunks).compactMap {
      chunk -> [InlineTextPaintEntry]? in
      guard case .text(_, _, let entries) = chunk else { return nil }
      return entries
    }.flatMap { $0 }
    XCTAssertEqual(entries.count, 3)
    XCTAssertTrue(entries.allSatisfy { $0.kind == .coreText })
  }

  private func makeImagePayload(id rawID: String) throws -> InlineImagePayload {
    let data = try XCTUnwrap(Data(base64Encoded: Self.transparentPNG))
    let assetID = try InlineAssetID(rawValue: rawID)
    let rendition = try InlineImageRendition(
      encoding: .png, encodedBytes: data, pixelWidth: 1, pixelHeight: 1)
    let reference = try InlineImageReference(
      assetID: assetID, version: 1, digest: InlineAssetDigest(data: data))
    return try InlineImagePayload(reference: reference, rendition: rendition)
  }

  private static let transparentPNG =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
}
