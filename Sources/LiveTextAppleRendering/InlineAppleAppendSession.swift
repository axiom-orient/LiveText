import Combine
import CoreGraphics
public import LiveTextLayout
import SwiftUI

/// Shared immutable append-render payload.  SwiftUI and Canvas consume this
/// exact value; neither adapter prepares, resolves, or retains a second copy.
@MainActor
package struct InlineAppleAppendSection {
  public let record: InlineRenderSectionRecord
  public let chunks: [InlineAppleAppendChunk]
  public let hitChunk: InlineHitTestChunk
  public let revealByChunkID: [String: InlineAppleAppendChunkReveal]
  /// Immutable source-arclength samples for vector material rendering. The
  /// append painter consumes these samples to build the same pressure/taper
  /// ribbon as the static adapters; it never re-flattens a path per frame.
  public let materialSegmentsByChunkID: [String: [InlineWritingMaterialSegment]]

  public var id: String { record.id }
}

/// Immutable frame-time reveal payload prepared by the append session.
/// Coverage and trajectory are intentionally separate values.
@MainActor
package enum InlineAppleAppendChunkReveal {
  case text(InlineRenderRevealTextActivation)
  case vector(
    commands: [Int: InlineAppleVectorRevealCommand],
    style: InlineSVGStrokeStyle,
    activation: InlineRenderRevealVectorActivation
  )
  case image(InlineRenderRevealImageActivation)
}

@MainActor
package struct InlineAppleAppendMaterialResources {
  public let chalkTexture: CGImage?

  public init(chalkTexture: CGImage? = nil) {
    self.chalkTexture = chalkTexture
  }
}

/// Immutable effects published for one append projection.  The append session
/// remains the owner of selection transitions and layout; this value only
/// contains the derived decoration, composition, and accessibility data that
/// an adapter may consume for the bound revision.
@MainActor
package struct InlineAppleAppendEffectsPlan {
  public let preparationRevision: String
  public let hitProfile: InlineTextUnitHitProfile
  public let selection: InlineSelectionKey?
  public let highlight: InlineHighlightPlan?
  public let composition: InlineSVGCompositionPlan?
  public let accessibility: InlineAccessibilityProjection
  public let accessibilityAtomLabels: [String: String]

  /// Target-local masks are keyed by the immutable chunk identity.  The
  /// artwork set is nil when composition is absent (all vector chunks paint),
  /// and empty when a composition declares masks without artwork.
  public let masksByChunkID: [String: [InlineAppleSVGMask]]
  public let artworkAtomIDs: Set<String>?

  fileprivate init(
    preparationRevision: String,
    hitProfile: InlineTextUnitHitProfile,
    selection: InlineSelectionKey?,
    highlight: InlineHighlightPlan?,
    composition: InlineSVGCompositionPlan?,
    accessibility: InlineAccessibilityProjection,
    accessibilityAtomLabels: [String: String],
    masksByChunkID: [String: [InlineAppleSVGMask]],
    artworkAtomIDs: Set<String>?
  ) {
    self.preparationRevision = preparationRevision
    self.hitProfile = hitProfile
    self.selection = selection
    self.highlight = highlight
    self.composition = composition
    self.accessibility = accessibility
    self.accessibilityAtomLabels = accessibilityAtomLabels
    self.masksByChunkID = masksByChunkID
    self.artworkAtomIDs = artworkAtomIDs
  }

  public func masks(for chunk: InlineAppleAppendChunk) -> [InlineAppleSVGMask] {
    masksByChunkID[chunk.id] ?? []
  }

  public func shouldRenderArtwork(for chunk: InlineAppleAppendChunk) -> Bool {
    guard case .vector = chunk else { return true }
    guard let artworkAtomIDs else { return true }
    return artworkAtomIDs.contains(chunk.positioned.atomID)
  }
}

@MainActor
package enum InlineAppleAppendChunk {
  case text(id: String, positioned: PositionedInlineAtom, entries: [InlineTextPaintEntry])
  case vector(
    id: String,
    positioned: PositionedInlineAtom,
    path: Path,
    coveragePaint: InlineSVGCoveragePaint,
    label: String
  )
  case image(
    id: String,
    positioned: PositionedInlineAtom,
    paint: InlineImagePaintEntry,
    label: String,
    isDecorative: Bool
  )

  public var id: String {
    switch self {
    case .text(let id, _, _), .vector(let id, _, _, _, _): return id
    case .image(let id, _, _, _, _): return id
    }
  }

  public var positioned: PositionedInlineAtom {
    switch self {
    case .text(_, let positioned, _), .vector(_, let positioned, _, _, _): return positioned
    case .image(_, let positioned, _, _, _): return positioned
    }
  }

  public var paintBounds: InlineHitRect? {
    get throws {
      let localBounds: [CGRect]
      let strokeWidth: Double
      switch self {
      case .text(_, _, let entries):
        localBounds = entries.map(\.localPaintBounds)
        strokeWidth = 0
      case .vector(_, _, let path, let paint, _):
        localBounds = [path.boundingRect]
        if case .stroke(let style) = paint {
          strokeWidth = style.width
        } else {
          strokeWidth = 0
        }
      case .image(_, _, let paint, _, _):
        localBounds = [paint.localPaintBounds]
        strokeWidth = 0
      }

      let positioned = self.positioned
      let originY =
        positioned.baselineY - positioned.metrics.baselineOffset
        - positioned.metrics.ascent
      var result: InlineHitRect?
      for local in localBounds {
        let translated = local.offsetBy(
          dx: CGFloat(positioned.originX), dy: CGFloat(originY))
        guard translated.minX.isFinite, translated.minY.isFinite,
          translated.width.isFinite, translated.width >= 0,
          translated.height.isFinite, translated.height >= 0,
          translated.maxX.isFinite, translated.maxY.isFinite
        else { throw InlineLayoutError.invalidRenderPlan }
        let inflated = translated.insetBy(
          dx: CGFloat(-strokeWidth * 0.5), dy: CGFloat(-strokeWidth * 0.5))
        guard inflated.minX.isFinite, inflated.minY.isFinite,
          inflated.width.isFinite, inflated.width >= 0,
          inflated.height.isFinite, inflated.height >= 0,
          inflated.maxX.isFinite, inflated.maxY.isFinite
        else { throw InlineLayoutError.invalidRenderPlan }
        guard inflated.width > 0, inflated.height > 0 else { continue }
        let candidate = try InlineHitRect(
          minX: Double(inflated.minX), minY: Double(inflated.minY),
          width: Double(inflated.width), height: Double(inflated.height))
        result = try InlineRenderSectionRecord.union(result, candidate)
      }
      return result
    }
  }
}

@MainActor
package struct InlineAppleAppendAccessibilityEntry: Identifiable {
  public let id: String
  public let text: String
  public let isDecorative: Bool
}

@MainActor
package struct InlineAppleAppendOperationAccounting: Sendable, Hashable {
  public var geometryItemCount = 0
  public var textPathCount = 0
  public var assetPathCount = 0
  public var hitAtomCount = 0
  public var hitChunkBuildCount = 0
  public var accessibilityEntryCount = 0
}

private final class InlineAppendPreparedStorage {
  var values: [String: PreparedInlineDocument.Atom]
  init(values: [String: PreparedInlineDocument.Atom] = [:]) { self.values = values }
}

private struct InlineAppendPreparedLookup {
  let existing: InlineAppendPreparedStorage
  let appended: [String: PreparedInlineDocument.Atom]
  subscript(id: String) -> PreparedInlineDocument.Atom? {
    appended[id] ?? existing.values[id]
  }
}

private final class InlineAppendAssetStorage {
  var values: [InlineAssetKey: InlineSVGAsset]
  init(values: [InlineAssetKey: InlineSVGAsset] = [:]) { self.values = values }
}

private final class InlineAppendRevealStorage {
  var values: [String: InlineAppleAppendChunkReveal]
  init(values: [String: InlineAppleAppendChunkReveal] = [:]) { self.values = values }
}

private struct InlineAppendRevealLookup {
  let existing: InlineAppendRevealStorage
  let appended: [String: InlineAppleAppendChunkReveal]
  subscript(id: String) -> InlineAppleAppendChunkReveal? {
    appended[id] ?? existing.values[id]
  }
}

private struct InlineAppendAssetLookup {
  let existing: InlineAppendAssetStorage
  let appended: [InlineAssetKey: InlineSVGAsset]
  subscript(key: InlineAssetKey) -> InlineSVGAsset? {
    appended[key] ?? existing.values[key]
  }
}

private struct InlineAppleAppendCandidate<Provider: InlineAssetGeometryProvider> {
  let reducer: InlineAppendReducer
  let prepared: [String: PreparedInlineDocument.Atom]
  let assets: [InlineAssetKey: InlineSVGAsset]
  let reveals: [String: InlineAppleAppendChunkReveal]
  let revealDuration: Double
  let committedSections: [InlineAppleAppendSection]
  let tailSection: InlineAppleAppendSection?
  let sectionIndex: InlineRenderSectionIndex
  let accessibilityEntries: [InlineAppleAppendAccessibilityEntry]
  let assetCandidate: InlineAssetResolutionCandidate
  let imageTransaction: InlineImageRenderCache.Transaction?
  let accounting: InlineAppleAppendOperationAccounting
}

/// The single synchronous owner for Apple append projection and render
/// materialization. The reducer remains the domain-state owner; its receipts
/// are applied to a value copy while all render and cache candidates are built
/// before one notification and one atomic state commit.
@MainActor
public final class InlineAppleAppendSession<Provider: InlineAssetGeometryProvider>:
  @MainActor ObservableObject
{
  public let objectWillChange = ObservableObjectPublisher()
  package private(set) var projection: InlineAppendProjection
  public var snapshot: InlineAppendSnapshot { InlineAppendSnapshot(projection: projection) }
  public var layoutWidth: Double { projection.layoutWidth }
  public var layoutHeight: Double { projection.layoutHeight }

  private var reducer: InlineAppendReducer
  private let assets: Provider
  private let registry: InlineAssetRegistry
  private let registryLabels: [InlineAssetKey: String]
  private let hitProfile: InlineTextUnitHitProfile
  private let assetCache: InlineAssetCache?
  private let imageAssets: InlineImageAssetStore
  private let imageCache: InlineImageRenderCache?
  private let imageScale: Double
  private let preparedStorage: InlineAppendPreparedStorage
  private let assetStorage: InlineAppendAssetStorage
  private let revealStorage: InlineAppendRevealStorage
  package private(set) var revealDuration: Double
  private var committedSectionByID: [String: InlineAppleAppendSection]
  private var isPublishing = false

  package private(set) var committedSections: [InlineAppleAppendSection]
  package private(set) var tailSection: InlineAppleAppendSection?
  package private(set) var sectionIndex: InlineRenderSectionIndex
  package private(set) var accessibilityEntries: [InlineAppleAppendAccessibilityEntry]
  package private(set) var atomOrdinalByID: [String: Int]
  package private(set) var operationAccounting = InlineAppleAppendOperationAccounting()

  public init(
    reducer: InlineAppendReducer,
    assets: Provider,
    registry: InlineAssetRegistry = .empty,
    hitProfile: InlineTextUnitHitProfile = .default,
    assetCache: InlineAssetCache? = nil,
    imageAssets: InlineImageAssetStore = InlineImageAssetStore(),
    imageCache: InlineImageRenderCache? = nil,
    imageScale: Double = 1
  ) throws {
    guard imageCache?.hasActiveTransaction != true else {
      throw InlineLayoutError.invalidContinuation
    }
    self.reducer = reducer
    self.assets = assets
    self.registry = registry
    self.registryLabels = Self.makeRegistryLabels(registry)
    self.hitProfile = hitProfile
    self.assetCache = assetCache
    self.imageAssets = registry.imageStore.merged(with: imageAssets)
    self.imageCache = imageCache
    self.imageScale = imageScale
    self.preparedStorage = InlineAppendPreparedStorage()
    self.assetStorage = InlineAppendAssetStorage()
    self.revealStorage = InlineAppendRevealStorage()
    self.revealDuration = 0
    self.committedSections = []
    self.tailSection = nil
    self.sectionIndex = InlineRenderSectionIndex()
    self.accessibilityEntries = []
    self.atomOrdinalByID = [:]
    self.committedSectionByID = [:]

    let initialProjection = try InlineAppendProjection(reducer: reducer)
    let initial = try Self.makeCandidate(
      reducer: reducer,
      revision: initialProjection.revision,
      existingPrepared: preparedStorage,
      existingAssets: assetStorage,
      existingReveals: revealStorage,
      revealDuration: revealDuration,
      sectionIndex: sectionIndex,
      documentAtoms: initialProjection.documentAtoms,
      preparedAtoms: initialProjection.preparedAtoms,
      sectionLines: initialProjection.committedLines,
      tailLines: initialProjection.tailLines,
      assets: assets,
      registry: registry,
      registryLabels: self.registryLabels,
      hitProfile: hitProfile,
      assetCache: assetCache,
      imageAssets: self.imageAssets,
      imageCache: imageCache,
      imageScale: imageScale,
      previousAccounting: InlineAppleAppendOperationAccounting()
    )
    projection = initialProjection
    preparedStorage.values = initial.prepared
    assetStorage.values = initial.assets
    revealStorage.values = initial.reveals
    revealDuration = initial.revealDuration
    committedSections = initial.committedSections
    tailSection = initial.tailSection
    committedSectionByID = Dictionary(
      uniqueKeysWithValues: initial.committedSections.map { ($0.id, $0) })
    sectionIndex = initial.sectionIndex
    accessibilityEntries = initial.accessibilityEntries
    atomOrdinalByID = Dictionary(
      uniqueKeysWithValues: initialProjection.documentAtoms.enumerated().map {
        ($0.element.id, $0.offset)
      }
    )
    operationAccounting = initial.accounting
    initial.imageTransaction?.commit()
    assetCache?.publish(
      assets: initial.assetCandidate.cacheAssets,
      hits: initial.assetCandidate.cacheHits,
      misses: initial.assetCandidate.cacheMisses
    )
  }

  /// Applies one event. Exact reducer replay returns its original receipt
  /// without notification; every failure or cancellation leaves all state and
  /// cache ownership unchanged.
  @discardableResult
  public func send(
    _ event: InlineAppendEvent,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws -> InlineAppendDelta {
    guard !isPublishing else { throw InlineLayoutError.invalidContinuation }
    var candidateReducer = reducer
    let delta = try candidateReducer.apply(event, cancellation: cancellation)
    try cancellation()
    let isReplay =
      candidateReducer.nextSequence == reducer.nextSequence
      && candidateReducer.revision == reducer.revision
      && candidateReducer.isFinished == reducer.isFinished
    if isReplay { return delta }
    guard imageCache?.hasActiveTransaction != true else {
      throw InlineLayoutError.invalidContinuation
    }

    var projectionValidation = try projection.prevalidate(delta)
    let candidate = try Self.makeCandidate(
      reducer: candidateReducer,
      revision: delta.revision,
      existingPrepared: preparedStorage,
      existingAssets: assetStorage,
      existingReveals: revealStorage,
      revealDuration: revealDuration,
      sectionIndex: sectionIndex,
      documentAtoms: delta.appendedDocumentAtoms,
      preparedAtoms: delta.appendedPreparedAtoms,
      sectionLines: delta.newlyCommittedLines,
      tailLines: delta.tailLines,
      assets: assets,
      registry: registry,
      registryLabels: registryLabels,
      hitProfile: hitProfile,
      assetCache: assetCache,
      imageAssets: imageAssets,
      imageCache: imageCache,
      imageScale: imageScale,
      previousAccounting: operationAccounting,
      cancellation: cancellation
    )

    do {
      try projection.verifyValidatedApply(delta, validation: &projectionValidation)
    } catch {
      candidate.imageTransaction?.rollback()
      throw error
    }

    // Every throwing operation is complete. Publication and the assignments
    // below are the sole nonthrowing commit boundary.
    isPublishing = true
    defer { isPublishing = false }
    objectWillChange.send()
    reducer = candidate.reducer
    projection.commitValidatedAfterVerification(delta, validation: &projectionValidation)
    for atom in delta.appendedDocumentAtoms where atomOrdinalByID[atom.id] == nil {
      atomOrdinalByID[atom.id] = atomOrdinalByID.count
    }
    preparedStorage.values.merge(candidate.prepared) { _, value in value }
    assetStorage.values.merge(candidate.assets) { _, value in value }
    revealStorage.values.merge(candidate.reveals) { _, value in value }
    revealDuration = candidate.revealDuration
    committedSections.append(contentsOf: candidate.committedSections)
    for section in candidate.committedSections {
      committedSectionByID[section.id] = section
    }
    if delta.isFinal {
      tailSection = nil
    } else {
      tailSection = candidate.tailSection
    }
    sectionIndex = candidate.sectionIndex
    accessibilityEntries.append(contentsOf: candidate.accessibilityEntries)
    operationAccounting = candidate.accounting
    candidate.imageTransaction?.commit()
    assetCache?.publish(
      assets: candidate.assetCandidate.cacheAssets,
      hits: candidate.assetCandidate.cacheHits,
      misses: candidate.assetCandidate.cacheMisses
    )
    return delta
  }

  /// Builds an immutable selection/highlight/composition projection from the
  /// current append projection.  All fallible work is local: the reducer,
  /// section index, image cache, and asset cache are untouched until this
  /// method returns successfully.
  package func makeEffectsPlan(
    selection: InlineSelectionKey? = nil,
    style: InlineHighlightStyle = .defaultHighlighter,
    composition: InlineSVGCompositionPlan? = nil,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws -> InlineAppleAppendEffectsPlan {
    try cancellation()
    let renderPlan = try self.makeCurrentRenderPlan(cancellation: cancellation)
    let assets = try self.effectsAssets(for: composition, cancellation: cancellation)
    try composition?.validate(prepared: renderPlan.prepared, assets: assets)
    try cancellation()

    let highlight: InlineHighlightPlan?
    if let selection {
      highlight = try InlineHighlightPlan(
        renderPlan: renderPlan,
        selection: selection,
        style: style,
        cancellation: cancellation)
    } else {
      highlight = nil
    }
    let accessibility = try InlineAccessibilityProjection(
      prepared: renderPlan.prepared,
      hitIndex: renderPlan.hitIndex,
      selection: selection)
    let labels = self.makeEffectsAccessibilityLabels(
      prepared: renderPlan.prepared, assets: assets)
    let compositionValues = try self.makeEffectsComposition(
      composition,
      assets: assets,
      cancellation: cancellation)
    try cancellation()

    return InlineAppleAppendEffectsPlan(
      preparationRevision: projection.revision,
      hitProfile: hitProfile,
      selection: selection,
      highlight: highlight,
      composition: composition,
      accessibility: accessibility,
      accessibilityAtomLabels: labels,
      masksByChunkID: compositionValues.masks,
      artworkAtomIDs: composition == nil ? nil : compositionValues.artworkAtomIDs
    )
  }

  /// Throwing validation at every explicit renderer handoff.  A plan made for
  /// an earlier append revision cannot be consumed after a later append.
  package func validate(effects: InlineAppleAppendEffectsPlan) throws {
    guard effects.preparationRevision == projection.revision else {
      throw InlineSelectionTransitionError(
        operation: "append.effects.validate",
        targetID: effects.selection?.atomID ?? "",
        preparationRevision: projection.revision,
        cause: "effects plan belongs to a stale preparation revision")
    }
    guard effects.hitProfile == hitProfile else {
      throw InlineSelectionTransitionError(
        operation: "append.effects.validate",
        targetID: effects.selection?.atomID ?? "",
        preparationRevision: projection.revision,
        cause: "effects plan belongs to a different hit profile")
    }
    if let highlight = effects.highlight {
      guard effects.selection == highlight.selection,
        highlight.preparationRevision == projection.revision
      else {
        throw InlineSelectionTransitionError(
          operation: "append.effects.validate",
          targetID: effects.selection?.atomID ?? "",
          preparationRevision: projection.revision,
          cause: "effects highlight is not bound to the current selection/revision")
      }
    } else if effects.selection != nil {
      throw InlineSelectionTransitionError(
        operation: "append.effects.validate",
        targetID: effects.selection?.atomID ?? "",
        preparationRevision: projection.revision,
        cause: "selected effects plan is missing its highlight")
    }
  }

  /// Non-throwing body-time guard used by observed renderers.  When an append
  /// arrives after a renderer was constructed, the adapter exposes an
  /// explicit stale state instead of silently drawing old effects.
  package func isCurrent(effects: InlineAppleAppendEffectsPlan) -> Bool {
    effects.preparationRevision == projection.revision && effects.hitProfile == hitProfile
  }

  public func hitTest(at point: InlineHitPoint) -> InlineHitResult? {
    let query = sectionIndex.query(point: point)
    for record in query.sections {
      guard let section = committedSectionByID[record.id] else {
        preconditionFailure("indexed inline section was not retained")
      }
      let result = section.hitChunk.hitTest(point)
      if result != .none { return result }
    }
    if let tailSection, tailSection.record.hitBounds.map({ $0.contains(point) }) == true {
      let result = tailSection.hitChunk.hitTest(point)
      if result != .none { return result }
    }
    return nil
  }

  package func visibleSections(for viewport: InlineRenderViewport)
    -> [InlineAppleAppendSection]
  {
    let query = sectionIndex.query(viewport: viewport, kind: .paint)
    var result: [InlineAppleAppendSection] = []
    result.reserveCapacity(query.sections.count + 1)
    for record in query.sections {
      guard let section = committedSectionByID[record.id] else {
        preconditionFailure("indexed inline section was not retained")
      }
      result.append(section)
    }
    if let tailSection, let bounds = tailSection.record.paintBounds,
      viewport.intersects(bounds)
    {
      result.append(tailSection)
    }
    return result
  }

  private func makeCurrentRenderPlan(
    cancellation: @escaping InlineCancellationCheck
  ) throws -> InlineRenderPlan {
    let prepared = try makeCurrentPreparedDocument(cancellation: cancellation)
    let layout = InlineLayoutResult(
      lines: projection.committedLines + projection.tailLines,
      width: projection.layoutWidth,
      height: projection.layoutHeight,
      preparationRevision: projection.revision,
      continuation: nil)
    return try InlineRenderPlan(
      prepared: prepared,
      layout: layout,
      hitProfile: hitProfile,
      cancellation: cancellation)
  }

  private func makeCurrentPreparedDocument(
    cancellation: @escaping InlineCancellationCheck
  ) throws -> PreparedInlineDocument {
    var textUTF16Units = 0
    var graphemes = 0
    var glyphs = 0
    var runs = 0
    var imageAtoms = 0
    for atom in projection.preparedAtoms {
      try cancellation()
      switch atom {
      case .text(let text):
        let (nextText, textOverflow) = textUTF16Units.addingReportingOverflow(
          text.atom.text.utf16.count)
        let (nextGraphemes, graphemeOverflow) = graphemes.addingReportingOverflow(
          text.graphemes.count)
        guard !textOverflow, !graphemeOverflow else {
          throw InlineLayoutError.resourceLimitExceeded(
            resource: "append preparation counters", actual: Int.max, limit: Int.max - 1)
        }
        textUTF16Units = nextText
        graphemes = nextGraphemes
        for run in text.shaped.runs {
          let (nextGlyphs, glyphOverflow) = glyphs.addingReportingOverflow(run.glyphs.count)
          let (nextRuns, runOverflow) = runs.addingReportingOverflow(1)
          guard !glyphOverflow, !runOverflow else {
            throw InlineLayoutError.resourceLimitExceeded(
              resource: "append preparation counters", actual: Int.max, limit: Int.max - 1)
          }
          glyphs = nextGlyphs
          runs = nextRuns
        }
      case .vector:
        continue
      case .image:
        let (nextImages, imageOverflow) = imageAtoms.addingReportingOverflow(1)
        guard !imageOverflow else {
          throw InlineLayoutError.resourceLimitExceeded(
            resource: "append image atoms", actual: Int.max, limit: Int.max - 1)
        }
        imageAtoms = nextImages
      }
    }
    return try PreparedInlineDocument(
      document: InlineDocument(atoms: projection.documentAtoms),
      atoms: projection.preparedAtoms,
      revision: projection.revision,
      identityContext: projection.preparationIdentityContext,
      totalTextUTF16Units: textUTF16Units,
      totalGraphemes: graphemes,
      totalGlyphs: glyphs,
      totalRuns: runs,
      totalImageAtoms: imageAtoms,
      cancellation: cancellation)
  }

  private func effectsAssets(
    for composition: InlineSVGCompositionPlan?,
    cancellation: @escaping InlineCancellationCheck
  ) throws -> InlineAssetStore {
    var values = assetStorage.values
    guard let composition else { return InlineAssetStore(values: values) }
    for instance in composition.instances {
      try cancellation()
      let key = InlineAssetKey(id: instance.assetID, version: instance.assetVersion)
      guard values[key] == nil else { continue }
      if let registered = registry.records.first(where: {
        $0.id == instance.assetID && $0.version == instance.assetVersion
      })?.geometry {
        guard registered.id == instance.assetID,
          registered.version == instance.assetVersion
        else {
          throw InlineSVGCompositionError.versionMismatch(
            operation: "composition.resolve", targetID: instance.targetID,
            assetID: instance.assetID, expected: instance.assetVersion,
            actual: registered.version, preparationRevision: projection.revision)
        }
        values[key] = registered
      } else {
        do {
          let resolved = try assets.resolveGeometry(
            assetID: instance.assetID, version: instance.assetVersion)
          guard resolved.id == instance.assetID,
            resolved.version == instance.assetVersion
          else {
            throw InlineSVGCompositionError.versionMismatch(
              operation: "composition.resolve", targetID: instance.targetID,
              assetID: instance.assetID, expected: instance.assetVersion,
              actual: resolved.version, preparationRevision: projection.revision)
          }
          values[key] = resolved
        } catch let error as InlineSVGCompositionError {
          throw error
        } catch let error as InlineAssetResolutionError {
          switch error {
          case .missingAsset, .missingGeometry:
            throw InlineSVGCompositionError.missingAsset(
              operation: "composition.resolve", targetID: instance.targetID,
              assetID: instance.assetID, assetVersion: instance.assetVersion,
              preparationRevision: projection.revision)
          case .duplicateAssetID, .versionMismatch, .metricsMismatch:
            // These errors identify a corrupt or incompatible provider result;
            // treating them as an absent asset would hide the retry/fix cause.
            throw error
          }
        } catch {
          // Provider failures outside the canonical asset-resolution errors
          // (for example I/O or decoding failures) are already typed by the
          // provider. Preserve them instead of misreporting them as missing.
          throw error
        }
      }
    }
    return InlineAssetStore(values: values)
  }

  private func makeEffectsAccessibilityLabels(
    prepared: PreparedInlineDocument,
    assets: InlineAssetStore
  ) -> [String: String] {
    var labels: [String: String] = [:]
    labels.reserveCapacity(prepared.atoms.count)
    for atom in prepared.atoms {
      switch atom {
      case .text:
        continue
      case .vector(let vector):
        let key = InlineAssetKey(id: vector.atom.assetID, version: vector.atom.assetVersion)
        labels[vector.atom.id] =
          vector.atom.accessibilityLabel
          ?? registryLabels[key]
          ?? assets[key]?.accessibilityLabel
          ?? vector.atom.id
      case .image(let image):
        labels[image.atom.id] = image.atom.accessibilityLabel ?? image.atom.id
      }
    }
    return labels
  }

  private func makeEffectsComposition(
    _ composition: InlineSVGCompositionPlan?,
    assets: InlineAssetStore,
    cancellation: @escaping InlineCancellationCheck
  ) throws -> (masks: [String: [InlineAppleSVGMask]], artworkAtomIDs: Set<String>) {
    guard let composition else { return ([:], []) }
    let chunks = (committedSections + (tailSection.map { [$0] } ?? []))
      .flatMap(\.chunks)
    var masks: [String: [InlineAppleSVGMask]] = [:]
    var artworkAtomIDs = Set<String>()
    for instance in composition.instances {
      try cancellation()
      switch instance.role {
      case .artwork:
        if let sourceAtomID = instance.sourceAtomID {
          artworkAtomIDs.insert(sourceAtomID)
        }
      case .mask:
        guard let targetID = instance.targetID,
          let operation = instance.operation,
          let asset = assets[InlineAssetKey(id: instance.assetID, version: instance.assetVersion)]
        else {
          throw InlineSVGCompositionError.invalid(
            operation: "composition.publish", targetID: instance.targetID,
            assetID: instance.assetID, assetVersion: instance.assetVersion,
            preparationRevision: projection.revision,
            cause: "validated mask source was not retained")
        }
        var targetWasPositioned = false
        for chunk in chunks where chunk.positioned.atomID == targetID {
          try cancellation()
          targetWasPositioned = true
          let positioned = chunk.positioned
          let destination = CGRect(
            x: 0, y: 0, width: CGFloat(positioned.width), height: CGFloat(positioned.height))
          let localPath = InlineAppleRenderContent.makeLocalAssetPath(
            asset, commands: asset.coveragePath.commands, destination: destination)
          let localPaint = InlineAppleRenderContent.makeLocalCoveragePaint(
            asset, destination: destination)
          let maskPath = InlineAppleVectorCoveragePainter.maskPath(
            coverage: localPath, paint: localPaint)
          masks[chunk.id, default: []].append(
            InlineAppleSVGMask(
              instanceID: instance.instanceID,
              operation: operation,
              declarationOrder: instance.declarationOrder,
              path: maskPath))
        }
        guard targetWasPositioned else {
          throw InlineSVGCompositionError.invalid(
            operation: "composition.publish", targetID: targetID,
            assetID: instance.assetID, assetVersion: instance.assetVersion,
            preparationRevision: projection.revision,
            cause: "mask target has no positioned geometry")
        }
      }
    }
    for key in masks.keys {
      masks[key]?.sort {
        if $0.declarationOrder != $1.declarationOrder {
          return $0.declarationOrder < $1.declarationOrder
        }
        return $0.instanceID < $1.instanceID
      }
    }
    return (masks, artworkAtomIDs)
  }

  private static func makeCandidate(
    reducer: InlineAppendReducer,
    revision: String,
    existingPrepared: InlineAppendPreparedStorage,
    existingAssets: InlineAppendAssetStorage,
    existingReveals: InlineAppendRevealStorage,
    revealDuration: Double,
    sectionIndex: InlineRenderSectionIndex,
    documentAtoms: [InlineAtom],
    preparedAtoms: [PreparedInlineDocument.Atom],
    sectionLines: [InlineLayoutLine],
    tailLines: [InlineLayoutLine],
    assets: Provider,
    registry: InlineAssetRegistry,
    registryLabels: [InlineAssetKey: String],
    hitProfile: InlineTextUnitHitProfile,
    assetCache: InlineAssetCache?,
    imageAssets: InlineImageAssetStore,
    imageCache: InlineImageRenderCache?,
    imageScale: Double,
    previousAccounting: InlineAppleAppendOperationAccounting,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws -> InlineAppleAppendCandidate<Provider> {
    try cancellation()
    var appendedPrepared: [String: PreparedInlineDocument.Atom] = [:]
    appendedPrepared.reserveCapacity(preparedAtoms.count)
    for atom in preparedAtoms {
      let id = atomID(atom)
      guard existingPrepared.values[id] == nil,
        appendedPrepared.updateValue(atom, forKey: id) == nil
      else { throw InlineLayoutError.duplicateIdentifier(id) }
    }
    try cancellation()
    let preparedLookup = InlineAppendPreparedLookup(
      existing: existingPrepared, appended: appendedPrepared)
    try validateInlineImageAssets(
      document: InlineDocument(atoms: documentAtoms), store: imageAssets)
    let assetCandidate = try resolveAssets(
      lines: sectionLines,
      additionalLines: tailLines,
      prepared: preparedLookup,
      existing: existingAssets,
      assets: assets,
      registry: registry,
      assetCache: assetCache
    )
    try cancellation()
    let assetLookup = InlineAppendAssetLookup(
      existing: existingAssets, appended: assetCandidate.assets)

    var appendedReveals: [String: InlineAppleAppendChunkReveal] = [:]
    var nextRevealDuration = revealDuration
    for atom in preparedAtoms {
      let id = atomID(atom)
      guard existingReveals.values[id] == nil, appendedReveals[id] == nil else { continue }
      let reveal = try makeReveal(
        atom: atom,
        id: id,
        startTime: nextRevealDuration,
        assets: assetLookup
      )
      appendedReveals[id] = reveal
      nextRevealDuration = revealEndTime(reveal)
    }
    let revealLookup = InlineAppendRevealLookup(
      existing: existingReveals, appended: appendedReveals)

    let imageTransaction: InlineImageRenderCache.Transaction?
    if let imageCache {
      guard !imageCache.hasActiveTransaction else {
        throw InlineLayoutError.invalidContinuation
      }
      imageTransaction = imageCache.beginTransaction()
    } else {
      imageTransaction = nil
    }
    var shouldRollbackImageTransaction = true
    defer {
      if let imageTransaction, shouldRollbackImageTransaction {
        imageTransaction.rollback()
      }
    }
    let committed = try makeSections(
      lines: sectionLines,
      prepared: preparedLookup,
      assets: assetLookup,
      registryLabels: registryLabels,
      hitProfile: hitProfile,
      revision: revision,
      images: imageAssets,
      imageCache: imageCache,
      imageScale: imageScale,
      reveals: revealLookup
    )
    try cancellation()
    let tail = try tailLines.first.map {
      try makeSection(
        line: $0,
        prepared: preparedLookup,
        assets: assetLookup,
        registryLabels: registryLabels,
        hitProfile: hitProfile,
        revision: revision,
        images: imageAssets,
        imageCache: imageCache,
        imageScale: imageScale,
        reveals: revealLookup
      )
    }
    let candidateIndex = try sectionIndex.inserting(committed.map { $0.record })
    let accessibility = makeAccessibilityEntries(
      atoms: documentAtoms,
      registryLabels: registryLabels,
      assets: InlineAppendAssetLookup(existing: existingAssets, appended: assetCandidate.assets)
    )
    try cancellation()
    var accounting = previousAccounting
    addAccounting(&accounting, sections: committed, tail: tail)
    accounting.accessibilityEntryCount += accessibility.count
    shouldRollbackImageTransaction = false
    return InlineAppleAppendCandidate(
      reducer: reducer,
      prepared: appendedPrepared,
      assets: assetCandidate.assets,
      reveals: appendedReveals,
      revealDuration: nextRevealDuration,
      committedSections: committed,
      tailSection: tail,
      sectionIndex: candidateIndex,
      accessibilityEntries: accessibility,
      assetCandidate: assetCandidate,
      imageTransaction: imageTransaction,
      accounting: accounting
    )
  }

  private static func makeSection(
    line: InlineLayoutLine,
    prepared: InlineAppendPreparedLookup,
    assets: InlineAppendAssetLookup,
    registryLabels: [InlineAssetKey: String],
    hitProfile: InlineTextUnitHitProfile,
    revision: String,
    images: InlineImageAssetStore,
    imageCache: InlineImageRenderCache?,
    imageScale: Double,
    reveals: InlineAppendRevealLookup
  ) throws -> InlineAppleAppendSection {
    let sectionPreparedAtoms = selectedPreparedAtoms(lines: [line], prepared: prepared)
    try validateInlineRenderLine(line, preparedAtoms: sectionPreparedAtoms)
    let geometry = try makeGeometry(lines: [line], prepared: prepared)
    let textPaintEntries = try InlineTextPaintCompiler.compile(geometry: geometry)
    let assetPaths = try makeAssetPaths(geometry: geometry, assets: assets)
    let imagePaints = try InlineImagePaintCompiler.compile(
      geometry: geometry, assets: images, cache: imageCache, scale: imageScale)
    var chunks: [InlineAppleAppendChunk] = []
    var revealByChunkID: [String: InlineAppleAppendChunkReveal] = [:]
    var materialSegmentsByChunkID: [String: [InlineWritingMaterialSegment]] = [:]
    chunks.reserveCapacity(geometry.count)
    for item in geometry {
      switch item {
      case .text(let positioned, _):
        guard let entries = textPaintEntries[positioned] else {
          throw InlineLayoutError.invalidRenderPlan
        }
        let id = chunkID(for: positioned)
        guard let reveal = reveals[positioned.atomID] else {
          throw InlineLayoutError.invalidRenderPlan
        }
        chunks.append(.text(id: id, positioned: positioned, entries: entries))
        revealByChunkID[id] = reveal
      case .vector(let positioned, let prepared):
        let key = InlineAssetKey(id: prepared.atom.assetID, version: prepared.atom.assetVersion)
        guard let path = assetPaths[positioned], let asset = assets[key] else {
          throw InlineAssetResolutionError.missingGeometry(
            prepared.atom.assetID, version: prepared.atom.assetVersion)
        }
        let destination = CGRect(
          x: 0, y: 0, width: CGFloat(positioned.width), height: CGFloat(positioned.height))
        let id = chunkID(for: positioned)
        guard let reveal = reveals[positioned.atomID], case .vector(_, _, let activation) = reveal
        else {
          throw InlineLayoutError.invalidRenderPlan
        }
        let trajectoryCommands = try InlineAppleRenderContent.makeVectorRevealCommands(
          asset: asset, destination: destination)
        let materialSegments = InlineAppleRenderContent.makeWritingMaterialSegments(
          trajectoryCommands)
        let revealWithGeometry = InlineAppleAppendChunkReveal.vector(
          commands: trajectoryCommands,
          style: InlineAppleRenderContent.makeLocalTrajectoryStyle(asset, destination: destination),
          activation: activation)
        chunks.append(
          .vector(
            id: id, positioned: positioned, path: path,
            coveragePaint: InlineAppleRenderContent.makeLocalCoveragePaint(
              asset, destination: destination),
            label: prepared.atom.accessibilityLabel
              ?? registryLabels[key]
              ?? asset.accessibilityLabel
              ?? positioned.atomID
          ))
        revealByChunkID[id] = revealWithGeometry
        materialSegmentsByChunkID[id] = materialSegments
      case .image(let positioned, let prepared):
        guard let paint = imagePaints[positioned] else {
          throw InlineImageAssetError.missingImage(
            prepared.atom.assetID, version: prepared.atom.assetVersion)
        }
        let id = chunkID(for: positioned)
        guard let reveal = reveals[positioned.atomID] else {
          throw InlineLayoutError.invalidRenderPlan
        }
        chunks.append(
          .image(
            id: id, positioned: positioned, paint: paint,
            label: prepared.atom.accessibilityLabel ?? prepared.atom.id,
            isDecorative: prepared.atom.isDecorative
          ))
        revealByChunkID[id] = reveal
      }
    }
    let hitChunk = try InlineHitTestIndex.buildChunk(
      preparedAtoms: sectionPreparedAtoms, lines: [line], profile: hitProfile,
      preparationRevision: revision)
    var paintBounds: InlineHitRect?
    for chunk in chunks {
      paintBounds = try InlineRenderSectionRecord.union(paintBounds, try chunk.paintBounds)
    }
    let hitBounds = try InlineRenderSectionRecord.union(paintBounds, try hitChunk.targetBounds())
    let record = try InlineRenderSectionRecord(
      id: "section:\(line.index)", lineIndex: line.index,
      paintBounds: paintBounds, hitBounds: hitBounds)
    return InlineAppleAppendSection(
      record: record, chunks: chunks, hitChunk: hitChunk,
      revealByChunkID: revealByChunkID,
      materialSegmentsByChunkID: materialSegmentsByChunkID)
  }

  private static func makeSections(
    lines: [InlineLayoutLine],
    prepared: InlineAppendPreparedLookup,
    assets: InlineAppendAssetLookup,
    registryLabels: [InlineAssetKey: String],
    hitProfile: InlineTextUnitHitProfile,
    revision: String,
    images: InlineImageAssetStore,
    imageCache: InlineImageRenderCache?,
    imageScale: Double,
    reveals: InlineAppendRevealLookup
  ) throws -> [InlineAppleAppendSection] {
    try lines.map {
      try makeSection(
        line: $0, prepared: prepared, assets: assets,
        registryLabels: registryLabels, hitProfile: hitProfile,
        revision: revision, images: images, imageCache: imageCache,
        imageScale: imageScale, reveals: reveals)
    }
  }

  private static func makeGeometry(
    lines: [InlineLayoutLine],
    prepared: InlineAppendPreparedLookup
  ) throws -> [PreparedInlineGeometry] {
    var result: [PreparedInlineGeometry] = []
    result.reserveCapacity(lines.reduce(0) { $0 + $1.atoms.count })
    for line in lines {
      for positioned in line.atoms {
        guard let value = prepared[positioned.atomID] else {
          throw InlineLayoutError.invalidRenderPlan
        }
        switch (value, positioned.kind) {
        case (.text(let text), .text):
          result.append(.text(positioned: positioned, prepared: text))
        case (.vector(let vector), .vector):
          result.append(.vector(positioned: positioned, prepared: vector))
        case (.image(let image), .image):
          result.append(.image(positioned: positioned, prepared: image))
        default:
          throw InlineLayoutError.invalidRenderPlan
        }
      }
    }
    return result
  }

  private static func selectedPreparedAtoms(
    lines: [InlineLayoutLine], prepared: InlineAppendPreparedLookup
  ) -> [PreparedInlineDocument.Atom] {
    var result: [PreparedInlineDocument.Atom] = []
    var seen = Set<String>()
    for line in lines {
      for positioned in line.atoms where seen.insert(positioned.atomID).inserted {
        if let atom = prepared[positioned.atomID] { result.append(atom) }
      }
    }
    return result
  }

  private static func makeAssetPaths(
    geometry: [PreparedInlineGeometry], assets: InlineAppendAssetLookup
  ) throws -> [PositionedInlineAtom: Path] {
    var result: [PositionedInlineAtom: Path] = [:]
    for item in geometry {
      guard case .vector(let positioned, let prepared) = item else { continue }
      let key = InlineAssetKey(id: prepared.atom.assetID, version: prepared.atom.assetVersion)
      guard let asset = assets[key] else {
        throw InlineAssetResolutionError.missingGeometry(
          prepared.atom.assetID, version: prepared.atom.assetVersion)
      }
      result[positioned] = InlineAppleRenderContent.makeLocalAssetPath(
        asset,
        commands: asset.coveragePath.commands,
        destination: CGRect(
          x: 0, y: 0, width: CGFloat(positioned.width), height: CGFloat(positioned.height))
      )
    }
    return result
  }

  private static func resolveAssets(
    lines: [InlineLayoutLine],
    additionalLines: [InlineLayoutLine],
    prepared: InlineAppendPreparedLookup,
    existing: InlineAppendAssetStorage,
    assets: Provider,
    registry: InlineAssetRegistry,
    assetCache: InlineAssetCache?
  ) throws -> InlineAssetResolutionCandidate {
    var atoms: [InlineAtom] = []
    var seen = Set<InlineAssetKey>()
    func collect(_ line: InlineLayoutLine) {
      for positioned in line.atoms {
        guard let atom = prepared[positioned.atomID],
          case .vector(let vector) = atom
        else { continue }
        let key = InlineAssetKey(id: vector.atom.assetID, version: vector.atom.assetVersion)
        guard existing.values[key] == nil, seen.insert(key).inserted else { continue }
        atoms.append(.vector(vector.atom))
      }
    }
    for line in lines { collect(line) }
    for line in additionalLines { collect(line) }
    guard !atoms.isEmpty else {
      return InlineAssetResolutionCandidate(
        assets: [:], cacheAssets: [], cacheHits: [], cacheMisses: [])
    }
    return try prepareInlineAssets(
      document: InlineDocument(atoms: atoms), registry: registry,
      provider: assets, cache: assetCache)
  }

  private static func makeRegistryLabels(
    _ registry: InlineAssetRegistry
  ) -> [InlineAssetKey: String] {
    registry.records.reduce(into: [:]) { result, record in
      if let label = record.accessibilityLabel {
        result[InlineAssetKey(id: record.id, version: record.version)] = label
      }
    }
  }

  private static func makeAccessibilityEntries(
    atoms: [InlineAtom],
    registryLabels: [InlineAssetKey: String],
    assets: InlineAppendAssetLookup
  ) -> [InlineAppleAppendAccessibilityEntry] {
    atoms.map { atom in
      switch atom {
      case .text(let value):
        return InlineAppleAppendAccessibilityEntry(
          id: value.id, text: value.text, isDecorative: false)
      case .vector(let value):
        let key = InlineAssetKey(id: value.assetID, version: value.assetVersion)
        return InlineAppleAppendAccessibilityEntry(
          id: value.id,
          text: value.accessibilityLabel
            ?? registryLabels[key]
            ?? assets[key]?.accessibilityLabel
            ?? value.id,
          isDecorative: false)
      case .image(let value):
        return InlineAppleAppendAccessibilityEntry(
          id: value.id, text: value.accessibilityLabel ?? value.id,
          isDecorative: value.isDecorative)
      }
    }
  }

  private static func makeReveal(
    atom: PreparedInlineDocument.Atom,
    id: String,
    startTime: Double,
    assets: InlineAppendAssetLookup
  ) throws -> InlineAppleAppendChunkReveal {
    let unitDuration = 0.05
    switch atom {
    case .text(let text):
      guard !text.shaped.graphemeRanges.isEmpty else {
        throw InlineLayoutError.invalidRenderPlan
      }
      var units: [InlineRenderRevealTextUnit] = []
      let preparedUnits: [(InlineRevealUnitID, InlineRevealUnitKind, InlineSourceRange)]
      switch text.atom.style.revealMode {
      case .native:
        var nativeUnits: [(InlineRevealUnitID, InlineRevealUnitKind, InlineSourceRange)] = []
        nativeUnits.reserveCapacity(text.shaped.graphemeRanges.count)
        for (index, range) in text.shaped.graphemeRanges.enumerated() {
          nativeUnits.append(
            (
              try InlineRevealUnitID(rawValue: "\(id)-append-\(index)"), .grapheme, range
            ))
        }
        preparedUnits = nativeUnits
      case .handwriting:
        guard !text.writingUnits.isEmpty else { throw InlineLayoutError.invalidRenderPlan }
        preparedUnits = text.writingUnits.map { unit in
          let kind: InlineRevealUnitKind
          switch unit.kind {
          case .semanticStroke: kind = .semanticStroke
          case .nativeAtomic: kind = .nativeAtomic
          case .timingOnly: kind = .timingOnly
          }
          return (unit.id, kind, unit.sourceRange)
        }
      }
      units.reserveCapacity(preparedUnits.count)
      for (index, preparedUnit) in preparedUnits.enumerated() {
        let unitStart = startTime + Double(index) * unitDuration
        units.append(
          try InlineRenderRevealTextUnit(
            id: preparedUnit.0,
            kind: preparedUnit.1,
            sourceRange: preparedUnit.2,
            startTime: unitStart,
            duration: unitDuration
          ))
      }
      return .text(try InlineRenderRevealTextActivation(atomID: id, units: units))

    case .vector(let vector):
      let key = InlineAssetKey(id: vector.atom.assetID, version: vector.atom.assetVersion)
      guard let asset = assets[key] else {
        throw InlineAssetResolutionError.missingGeometry(
          vector.atom.assetID, version: vector.atom.assetVersion)
      }
      let plan = try InlinePathRevealPlanBuilder().plan(asset: asset)
      var units: [InlineRenderRevealVectorUnit] = []
      units.reserveCapacity(plan.units.count)
      var next = startTime
      for pathUnit in plan.units {
        units.append(try InlineRenderRevealVectorUnit(unit: pathUnit, startTime: next))
        next += pathUnit.duration
      }
      guard !units.isEmpty, next.isFinite else {
        throw InlineLayoutError.invalidRenderPlan
      }
      return .vector(
        commands: [:],
        style: asset.trajectoryStyle,
        activation: try InlineRenderRevealVectorActivation(
          atomID: id, assetID: vector.atom.assetID,
          assetVersion: vector.atom.assetVersion, units: units)
      )

    case .image:
      return .image(
        try InlineRenderRevealImageActivation(
          atomID: id, startTime: startTime, duration: unitDuration))
    }
  }

  private static func revealEndTime(_ reveal: InlineAppleAppendChunkReveal) -> Double {
    switch reveal {
    case .text(let activation): return activation.duration
    case .vector(_, _, let activation): return activation.duration
    case .image(let activation): return activation.startTime + activation.duration
    }
  }

  private static func addAccounting(
    _ accounting: inout InlineAppleAppendOperationAccounting,
    sections: [InlineAppleAppendSection],
    tail: InlineAppleAppendSection?
  ) {
    for section in sections + (tail.map { [$0] } ?? []) {
      accounting.geometryItemCount += section.chunks.count
      accounting.textPathCount += section.chunks.reduce(0) { count, chunk in
        if case .text(_, _, let entries) = chunk { return count + entries.count }
        return count
      }
      accounting.assetPathCount += section.chunks.reduce(0) { count, chunk in
        if case .vector = chunk { return count + 1 }
        return count
      }
      accounting.hitAtomCount += Set(section.chunks.map(\.positioned.atomID)).count
      accounting.hitChunkBuildCount += section.chunks.isEmpty ? 0 : 1
    }
  }

  private static func atomID(_ atom: PreparedInlineDocument.Atom) -> String {
    switch atom {
    case .text(let value): return value.atom.id
    case .vector(let value): return value.atom.id
    case .image(let value): return value.atom.id
    }
  }

  private static func chunkID(for positioned: PositionedInlineAtom) -> String {
    let range =
      positioned.sourceRange.map {
        "\($0.startUTF16)-\($0.endUTF16)"
      } ?? "vector"
    return "\(positioned.lineIndex):\(positioned.atomID):\(range)"
  }
}
