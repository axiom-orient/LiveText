import CoreGraphics
import LiveTextEffects
public import LiveTextLayout
import SwiftUI

private typealias InlineAppleTextPath = InlineTextPaintEntry

private struct InlineAppleRenderSection {
  let record: InlineRenderSectionRecord
  let geometry: [PreparedInlineGeometry]
}

/// Prebuilt target-local mask geometry. The source SVG is never painted as
/// artwork by this value; it is only consumed by the declared target
/// operation in the render adapters. `declarationOrder` is the canonical
/// deterministic declaration order retained for validation, projection, and
/// diagnostics. It is normalized into reveal-before-paint and erase-after-
/// paint phases, not a sequential cross-operation blend program.
@MainActor
package struct InlineAppleSVGMask {
  public let instanceID: String
  public let operation: InlineSVGMaskOperation
  public let declarationOrder: Int
  public let path: Path

  public init(
    instanceID: String,
    operation: InlineSVGMaskOperation,
    declarationOrder: Int,
    path: Path
  ) {
    self.instanceID = instanceID
    self.operation = operation
    self.declarationOrder = declarationOrder
    self.path = path
  }
}

/// One prebuilt trajectory command in atom-local coordinates.
///
/// The full command path is retained for completed-command assembly. The
/// mapped command and its subpath origin are retained for the current command
/// prefix. Keeping both in one immutable value makes static and append reveal
/// frames use the same command-index semantics without trimming a whole path.
@MainActor
package struct InlineAppleVectorRevealCommand {
  public let fullPath: Path
  public let start: InlinePathPoint
  public let subpathStart: InlinePathPoint
  public let command: InlinePathCommand
  public let materialSubpathID: Int
  public let materialSubpathIsClosed: Bool
  public let materialStartDistance: Double
  public let materialEndDistance: Double
  public let materialSubpathLength: Double

  fileprivate init(
    fullPath: Path,
    start: InlinePathPoint,
    subpathStart: InlinePathPoint,
    command: InlinePathCommand,
    materialSubpathID: Int,
    materialSubpathIsClosed: Bool,
    materialStartDistance: Double,
    materialEndDistance: Double,
    materialSubpathLength: Double
  ) {
    self.fullPath = fullPath
    self.start = start
    self.subpathStart = subpathStart
    self.command = command
    self.materialSubpathID = materialSubpathID
    self.materialSubpathIsClosed = materialSubpathIsClosed
    self.materialStartDistance = materialStartDistance
    self.materialEndDistance = materialEndDistance
    self.materialSubpathLength = materialSubpathLength
  }
}

/// Atom-local vector frame shared by both drawing adapters. Coverage is the
/// final visible geometry; trajectory is only the progress mask/source for a
/// partial frame.
package struct InlineAppleVectorRenderFrame {
  public let coverage: Path
  public let trajectory: Path
  public let coveragePaint: InlineSVGCoveragePaint
  public let trajectoryStyle: InlineSVGStrokeStyle
  public let isComplete: Bool

  fileprivate init(
    coverage: Path,
    trajectory: Path,
    coveragePaint: InlineSVGCoveragePaint,
    trajectoryStyle: InlineSVGStrokeStyle,
    isComplete: Bool
  ) {
    self.coverage = coverage
    self.trajectory = trajectory
    self.coveragePaint = coveragePaint
    self.trajectoryStyle = trajectoryStyle
    self.isComplete = isComplete
  }
}

/// The single coverage-paint interpretation used by static and append Apple
/// adapters. A trajectory is never included here: it is only a partial-frame
/// clip applied in front of this coverage mask.
@MainActor
package enum InlineAppleVectorCoveragePainter {
  public static func maskPath(
    coverage: Path,
    paint: InlineSVGCoveragePaint
  ) -> Path {
    switch paint {
    case .fill:
      return coverage
    case .stroke(let style):
      return coverage.strokedPath(strokeStyle(style))
    }
  }

  public static func clip(
    coverage: Path,
    paint: InlineSVGCoveragePaint,
    in context: inout GraphicsContext
  ) {
    switch paint {
    case .fill(let rule):
      context.clip(to: coverage, style: FillStyle(eoFill: rule == .evenOdd))
    case .stroke(let style):
      context.clip(to: maskPath(coverage: coverage, paint: .stroke(style)))
    }
  }

  public static func draw(
    coverage: Path,
    paint: InlineSVGCoveragePaint,
    color: Color,
    in context: inout GraphicsContext
  ) {
    switch paint {
    case .fill(let rule):
      context.fill(coverage, with: .color(color), style: FillStyle(eoFill: rule == .evenOdd))
    case .stroke(let style):
      context.stroke(coverage, with: .color(color), style: strokeStyle(style))
    }
  }

  private static func strokeStyle(_ style: InlineSVGStrokeStyle) -> StrokeStyle {
    StrokeStyle(
      lineWidth: CGFloat(style.width),
      lineCap: {
        switch style.cap {
        case .butt: return .butt
        case .round: return .round
        case .square: return .square
        }
      }(),
      lineJoin: {
        switch style.join {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
      }(),
      miterLimit: CGFloat(style.miterLimit)
    )
  }
}

/// The single renderer-neutral owner for prepared Apple drawing state.
///
/// Both drawing adapters keep only view composition and coordinate translation.
/// Asset resolution, paint compilation, local path construction, section
/// indexing, reveal validation, effect targets, and bounded caches are
/// published once by this object.
@MainActor
package final class InlineAppleRenderContent {
  private static let maximumColoredPencilTextHatches = 16_384
  private static let maximumColoredPencilConfigurations = 2
  private static let maximumWritingMaterialTextures = 4
  private static let maximumWritingStampMaskSets = 4
  private static let maximumTintedStampSets = 4

  public let plan: InlineRenderPlan
  public let preparedAssets: InlineAssetStore
  public let preparedImages: InlineImageAssetStore
  public let assetLabels: [InlineAssetKey: String]
  public let accessibilityAtomLabels: [String: String]
  public let textPaths: [PositionedInlineAtom: [InlineTextPaintEntry]]
  public let imagePaints: [PositionedInlineAtom: InlineImagePaintEntry]
  public let assetPaths: [PositionedInlineAtom: Path]
  public let writingMaterialSegments: [PositionedInlineAtom: [InlineWritingMaterialSegment]]
  public let schedule: InlineRenderRevealSchedule
  public let foregroundColor: Color
  public let compositionPlan: InlineSVGCompositionPlan?
  package let atomOrdinalByID: [String: Int]

  private let vectorCommands: [PositionedInlineAtom: [Int: InlineAppleVectorRevealCommand]]
  private let geometryByPosition: [PositionedInlineAtom: PreparedInlineGeometry]
  private let sections: [String: InlineAppleRenderSection]
  private let sectionIndex: InlineRenderSectionIndex
  private let writingMaterialTargetSet: WritingMaterialTargetSet
  private let writingMaterialTargetIndex: [PositionedInlineAtom: Int]
  private let artworkAtomIDs: Set<String>
  private let compositionMasksByPosition: [PositionedInlineAtom: [InlineAppleSVGMask]]

  private var coloredPencilVectorPlanCache:
    [ColoredPencilConfiguration: [PositionedInlineAtom: ColoredPencilPathPlan]] = [:]
  private var coloredPencilTextFillPlanCache:
    [ColoredPencilConfiguration: [PositionedInlineAtom: ColoredPencilFillPlan]] = [:]
  private var coloredPencilTextHatchAllocationCache:
    [ColoredPencilConfiguration: [PositionedInlineAtom: Int]] = [:]
  private var coloredPencilConfigurationLRU: [ColoredPencilConfiguration] = []
  public private(set) var coloredPencilPlanBuildCount = 0
  private var writingMaterialPlanCache = WritingMaterialPlanCache()
  private var writingMaterialTextureCache: [WritingMaterial: CGImage] = [:]
  private struct TintedStampKey: Hashable {
    let material: WritingMaterial
    let color: Color
  }
  private var writingStampMaskCache: [WritingMaterial: [CGImage]] = [:]
  private var tintedStampCache: [TintedStampKey: [CGImage]] = [:]

  public var coloredPencilCachedConfigurationCount: Int {
    coloredPencilConfigurationLRU.count
  }

  public var writingMaterialCachedConfigurationCount: Int {
    writingMaterialPlanCache.cachedConfigurationCount
  }

  public var writingMaterialPlanBuildCount: Int {
    writingMaterialPlanCache.buildCount
  }

  public var writingMaterialTargetCount: Int {
    writingMaterialTargetSet.targets.count
  }

  public convenience init<Provider: InlineAssetGeometryProvider>(
    plan: InlineRenderPlan,
    assets: Provider,
    registry: InlineAssetRegistry = .empty,
    schedule: InlineRenderRevealSchedule? = nil,
    foregroundColor: Color = .primary,
    assetCache: InlineAssetCache? = nil,
    imageAssets: InlineImageAssetStore = InlineImageAssetStore(),
    imageCache: InlineImageRenderCache? = nil,
    imageScale: Double = 1,
    composition: InlineSVGCompositionPlan? = nil
  ) throws {
    try self.init(
      plan: plan,
      assets: assets,
      registry: registry,
      schedule: schedule,
      foregroundColor: foregroundColor,
      assetCache: assetCache,
      imageAssets: imageAssets,
      imageCache: imageCache,
      imageScale: imageScale,
      composition: composition,
      forceMinimumOSImageRendering: false
    )
  }

  public init<Provider: InlineAssetGeometryProvider>(
    plan: InlineRenderPlan,
    assets: Provider,
    registry: InlineAssetRegistry = .empty,
    schedule: InlineRenderRevealSchedule? = nil,
    foregroundColor: Color = .primary,
    assetCache: InlineAssetCache? = nil,
    imageAssets: InlineImageAssetStore = InlineImageAssetStore(),
    imageCache: InlineImageRenderCache? = nil,
    imageScale: Double = 1,
    composition: InlineSVGCompositionPlan? = nil,
    forceMinimumOSImageRendering: Bool = false
  ) throws {
    let imageTransaction: InlineImageRenderCache.Transaction?
    if let imageCache, !imageCache.hasActiveTransaction {
      imageTransaction = imageCache.beginTransaction()
    } else {
      imageTransaction = nil
    }
    var imageTransactionCommitted = false
    defer {
      if let imageTransaction, !imageTransactionCommitted { imageTransaction.rollback() }
    }

    let assetCandidate = try prepareInlineAssets(
      document: plan.prepared.document,
      registry: registry,
      provider: assets,
      cache: assetCache
    )
    var preparedAssetValues = assetCandidate.assets
    if let composition {
      // Composition-only mask sources may be registered without becoming
      // document atoms. Resolve them before plan publication, just like atom
      // assets, and preserve the operation/target/revision on failures.
      for instance in composition.instances {
        let key = InlineAssetKey(id: instance.assetID, version: instance.assetVersion)
        guard preparedAssetValues[key] == nil else { continue }
        if let registered = registry.records.first(where: {
          $0.id == instance.assetID && $0.version == instance.assetVersion
        })?.geometry {
          guard registered.id == instance.assetID, registered.version == instance.assetVersion
          else {
            throw InlineSVGCompositionError.versionMismatch(
              operation: "composition.resolve", targetID: instance.targetID,
              assetID: instance.assetID, expected: instance.assetVersion,
              actual: registered.version, preparationRevision: plan.prepared.revision)
          }
          preparedAssetValues[key] = registered
        } else {
          do {
            let resolved = try assets.resolveGeometry(
              assetID: instance.assetID, version: instance.assetVersion)
            guard resolved.id == instance.assetID, resolved.version == instance.assetVersion else {
              throw InlineSVGCompositionError.versionMismatch(
                operation: "composition.resolve", targetID: instance.targetID,
                assetID: instance.assetID, expected: instance.assetVersion,
                actual: resolved.version, preparationRevision: plan.prepared.revision)
            }
            preparedAssetValues[key] = resolved
          } catch let error as InlineSVGCompositionError {
            throw error
          } catch let error as InlineAssetResolutionError {
            switch error {
            case .missingAsset, .missingGeometry:
              throw InlineSVGCompositionError.missingAsset(
                operation: "composition.resolve", targetID: instance.targetID,
                assetID: instance.assetID, assetVersion: instance.assetVersion,
                preparationRevision: plan.prepared.revision)
            case .duplicateAssetID, .versionMismatch, .metricsMismatch:
              throw error
            }
          } catch {
            throw error
          }
        }
      }
    }
    let preparedAssets = InlineAssetStore(values: preparedAssetValues)
    try composition?.validate(prepared: plan.prepared, assets: preparedAssets)
    let preparedImages = registry.imageStore.merged(with: imageAssets)
    try validateInlineImageAssets(document: plan.prepared.document, store: preparedImages)
    let resolvedSchedule = try Self.validatedSchedule(
      schedule, for: plan, assets: preparedAssets)
    let textPaths = try InlineTextPaintCompiler.compile(geometry: plan.geometry)
    let candidates = Self.makeWritingMaterialTargetCandidates(
      geometry: plan.geometry, textPaths: textPaths)
    let writingMaterialTargetSet = WritingMaterialTargetSet(targets: candidates.map(\.target))
    var writingMaterialTargetIndex: [PositionedInlineAtom: Int] = [:]
    writingMaterialTargetIndex.reserveCapacity(candidates.count)
    for (index, candidate) in candidates.enumerated() {
      writingMaterialTargetIndex[candidate.positioned] = index
    }
    let imagePaints: [PositionedInlineAtom: InlineImagePaintEntry]
    if forceMinimumOSImageRendering {
      imagePaints = try InlineImagePaintCompiler.compileMinimumOSForTesting(
        geometry: plan.geometry, assets: preparedImages, cache: imageCache, scale: imageScale)
    } else {
      imagePaints = try InlineImagePaintCompiler.compile(
        geometry: plan.geometry, assets: preparedImages, cache: imageCache, scale: imageScale)
    }
    let assetPaths = try Self.makeAssetPaths(geometry: plan.geometry, assets: preparedAssets)
    let vectorCommands = try Self.makeVectorCommands(
      geometry: plan.geometry, assets: preparedAssets)
    let writingMaterialSegments = Self.makeWritingMaterialSegments(vectorCommands)

    var geometryByPosition: [PositionedInlineAtom: PreparedInlineGeometry] = [:]
    var geometryByLine: [Int: [PreparedInlineGeometry]] = [:]
    geometryByPosition.reserveCapacity(plan.geometry.count)
    for item in plan.geometry {
      let positioned: PositionedInlineAtom
      switch item {
      case .text(let value, _), .vector(let value, _), .image(let value, _): positioned = value
      }
      geometryByPosition[positioned] = item
      geometryByLine[positioned.lineIndex, default: []].append(item)
    }

    var artworkAtomIDs = Set<String>()
    var compositionMasksByPosition: [PositionedInlineAtom: [InlineAppleSVGMask]] = [:]
    if let composition {
      for instance in composition.instances {
        switch instance.role {
        case .artwork:
          if let sourceAtomID = instance.sourceAtomID { artworkAtomIDs.insert(sourceAtomID) }
        case .mask:
          guard let targetID = instance.targetID,
            let operation = instance.operation,
            let asset = preparedAssets[
              InlineAssetKey(id: instance.assetID, version: instance.assetVersion)]
          else {
            throw InlineSVGCompositionError.invalid(
              operation: "composition.publish", targetID: instance.targetID,
              assetID: instance.assetID, assetVersion: instance.assetVersion,
              preparationRevision: plan.prepared.revision,
              cause: "validated mask source was not retained")
          }
          var targetWasPositioned = false
          for item in plan.geometry {
            let positioned: PositionedInlineAtom
            switch item {
            case .text(let value, _), .vector(let value, _), .image(let value, _):
              positioned = value
            }
            guard positioned.atomID == targetID else { continue }
            targetWasPositioned = true
            let destination = CGRect(
              x: 0, y: 0, width: CGFloat(positioned.width), height: CGFloat(positioned.height))
            let localPath = preparedAssetPath(
              asset, commands: asset.coveragePath.commands,
              sourceBounds: asset.coordinateBounds, destination: destination)
            let localPaint = Self.makeLocalCoveragePaint(asset, destination: destination)
            let maskPath = InlineAppleVectorCoveragePainter.maskPath(
              coverage: localPath, paint: localPaint)
            compositionMasksByPosition[positioned, default: []].append(
              InlineAppleSVGMask(
                instanceID: instance.instanceID, operation: operation,
                declarationOrder: instance.declarationOrder, path: maskPath))
          }
          guard targetWasPositioned else {
            throw InlineSVGCompositionError.invalid(
              operation: "composition.publish", targetID: targetID,
              assetID: instance.assetID, assetVersion: instance.assetVersion,
              preparationRevision: plan.prepared.revision,
              cause: "mask target has no positioned geometry")
          }
        }
      }
      for key in compositionMasksByPosition.keys {
        compositionMasksByPosition[key]?.sort {
          if $0.declarationOrder != $1.declarationOrder {
            return $0.declarationOrder < $1.declarationOrder
          }
          return $0.instanceID < $1.instanceID
        }
      }
    }

    var assetLabels: [InlineAssetKey: String] = [:]
    for record in registry.records {
      if let label = record.accessibilityLabel {
        assetLabels[InlineAssetKey(id: record.id, version: record.version)] = label
      }
    }
    for atom in plan.prepared.document.atoms {
      guard case .vector(let vector) = atom else { continue }
      let key = InlineAssetKey(id: vector.assetID, version: vector.assetVersion)
      if assetLabels[key] == nil, let label = preparedAssets[key]?.accessibilityLabel {
        assetLabels[key] = label
      }
    }
    var accessibilityAtomLabels: [String: String] = [:]
    accessibilityAtomLabels.reserveCapacity(plan.prepared.document.atoms.count)
    for atom in plan.prepared.document.atoms {
      switch atom {
      case .text:
        continue
      case .vector(let vector):
        let key = InlineAssetKey(id: vector.assetID, version: vector.assetVersion)
        accessibilityAtomLabels[vector.id] =
          vector.accessibilityLabel
          ?? assetLabels[key]
          ?? vector.id
      case .image(let image):
        accessibilityAtomLabels[image.id] = image.accessibilityLabel ?? image.id
      }
    }

    var sectionRecords: [InlineRenderSectionRecord] = []
    var sections: [String: InlineAppleRenderSection] = [:]
    sectionRecords.reserveCapacity(plan.layout.lines.count)
    sections.reserveCapacity(plan.layout.lines.count)
    for line in plan.layout.lines {
      let lineGeometry = geometryByLine[line.index] ?? []
      var paintBounds: InlineHitRect?
      for item in lineGeometry {
        paintBounds = try InlineRenderSectionRecord.union(
          paintBounds,
          try Self.paintBounds(
            for: item, textPaths: textPaths, assetPaths: assetPaths, imagePaints: imagePaints)
        )
      }
      let record = try InlineRenderSectionRecord(
        id: "section:\(line.index)", lineIndex: line.index,
        paintBounds: paintBounds, hitBounds: paintBounds)
      sectionRecords.append(record)
      sections[record.id] = InlineAppleRenderSection(record: record, geometry: lineGeometry)
    }
    let sectionIndex = try InlineRenderSectionIndex(sections: sectionRecords)

    imageTransaction?.commit()
    imageTransactionCommitted = true
    assetCache?.publish(
      assets: assetCandidate.cacheAssets,
      hits: assetCandidate.cacheHits,
      misses: assetCandidate.cacheMisses)

    self.plan = plan
    self.atomOrdinalByID = Dictionary(
      uniqueKeysWithValues: plan.prepared.document.atoms.enumerated().map {
        ($0.element.id, $0.offset)
      }
    )
    self.preparedAssets = preparedAssets
    self.preparedImages = preparedImages
    self.assetLabels = assetLabels
    self.accessibilityAtomLabels = accessibilityAtomLabels
    self.textPaths = textPaths
    self.imagePaints = imagePaints
    self.assetPaths = assetPaths
    self.vectorCommands = vectorCommands
    self.writingMaterialSegments = writingMaterialSegments
    self.geometryByPosition = geometryByPosition
    self.sections = sections
    self.sectionIndex = sectionIndex
    self.schedule = resolvedSchedule
    self.foregroundColor = foregroundColor
    self.compositionPlan = composition
    self.writingMaterialTargetSet = writingMaterialTargetSet
    self.writingMaterialTargetIndex = writingMaterialTargetIndex
    self.artworkAtomIDs = artworkAtomIDs
    self.compositionMasksByPosition = compositionMasksByPosition
  }

  /// Returns target-local mask instances in validated declaration order.
  package func compositionMasks(for positioned: PositionedInlineAtom)
    -> [InlineAppleSVGMask]
  {
    compositionMasksByPosition[positioned] ?? []
  }

  /// Builds the one semantic accessibility projection shared by both static
  /// adapters. The selection is validated against this content's hit index
  /// before an adapter can publish it.
  package func accessibilityProjection(
    selection: InlineSelectionKey?
  ) throws -> InlineAccessibilityProjection {
    try InlineAccessibilityProjection(
      prepared: plan.prepared, hitIndex: plan.hitIndex, selection: selection)
  }

  /// With an explicit composition plan, only an artwork instance may paint a
  /// vector atom. A mask-only source therefore cannot become visible by
  /// accident through the ordinary vector path.
  package func shouldRenderArtwork(for positioned: PositionedInlineAtom) -> Bool {
    compositionPlan == nil || artworkAtomIDs.contains(positioned.atomID)
  }

  public func visibleGeometry(for viewport: InlineRenderViewport) -> [PreparedInlineGeometry] {
    let query = sectionIndex.query(viewport: viewport, kind: .paint)
    var result: [PreparedInlineGeometry] = []
    result.reserveCapacity(query.sections.reduce(0) { $0 + (sections[$1.id]?.geometry.count ?? 0) })
    for record in query.sections {
      guard let section = sections[record.id] else {
        preconditionFailure("validated inline render section was not retained")
      }
      result.append(contentsOf: section.geometry)
    }
    return result
  }

  public func textCanvasBounds(for positioned: PositionedInlineAtom) -> CGRect {
    let cell = CGRect(
      x: 0, y: 0, width: CGFloat(positioned.width), height: CGFloat(positioned.height))
    return (textPaths[positioned] ?? []).reduce(cell) { $0.union($1.localPaintBounds) }
  }

  /// Returns a vector path in atom-local coordinates for every reveal phase.
  /// The caller applies the atom origin exactly once.
  public func vectorPath(
    for positioned: PositionedInlineAtom,
    frame: InlineRenderRevealFrame
  ) -> Path {
    vectorRenderFrame(for: positioned, frame: frame).trajectory
  }

  public func vectorRenderFrame(
    for positioned: PositionedInlineAtom,
    frame: InlineRenderRevealFrame
  ) -> InlineAppleVectorRenderFrame {
    guard let coverage = assetPaths[positioned],
      let item = geometryByPosition[positioned],
      case .vector(_, let prepared) = item,
      let asset = preparedAssets[
        InlineAssetKey(id: prepared.atom.assetID, version: prepared.atom.assetVersion)]
    else {
      preconditionFailure("validated vector asset was not prebuilt")
    }
    let destination = CGRect(
      x: 0, y: 0, width: CGFloat(positioned.width), height: CGFloat(positioned.height))
    let coordinateScale = inlineSVGUniformScale(
      sourceBounds: asset.coordinateBounds, destination: destination)
    let trajectoryStyle = inlineSVGScaledStrokeStyle(asset.trajectoryStyle, scale: coordinateScale)
    let coveragePaint = Self.makeLocalCoveragePaint(asset, destination: destination)
    guard let activation = frame.vectorActivation(for: positioned.atomID),
      let commands = vectorCommands[positioned]
    else { preconditionFailure("validated vector reveal activation was not retained") }
    let reveal = Self.makeVectorRevealPath(
      commands: commands, activation: activation, time: frame.time)
    return InlineAppleVectorRenderFrame(
      coverage: coverage,
      trajectory: reveal.path,
      coveragePaint: coveragePaint,
      trajectoryStyle: trajectoryStyle,
      isComplete: reveal.isComplete
    )
  }

  public func writingMaterialTarget(for positioned: PositionedInlineAtom)
    -> WritingMaterialTarget?
  {
    guard let index = writingMaterialTargetIndex[positioned],
      writingMaterialTargetSet.targets.indices.contains(index)
    else { return nil }
    return writingMaterialTargetSet.targets[index]
  }

  public func writingMaterialSegments(for positioned: PositionedInlineAtom)
    -> [InlineWritingMaterialSegment]?
  {
    writingMaterialSegments[positioned]
  }

  public func visibleWritingMaterialSegments(
    for positioned: PositionedInlineAtom,
    frame: InlineRenderRevealFrame
  ) -> [InlineWritingMaterialSegment]? {
    guard let activation = frame.vectorActivation(for: positioned.atomID) else {
      return writingMaterialSegments[positioned]
    }
    return InlineWritingMaterialSampler.visibleSegments(
      writingMaterialSegments[positioned] ?? [], activation: activation, time: frame.time)
  }

  public func tintedStamps(material: WritingMaterial, color: Color) -> [CGImage] {
    let key = TintedStampKey(material: material, color: color)
    if let cached = tintedStampCache[key] { return cached }
    let masks: [CGImage]
    if let cached = writingStampMaskCache[material] {
      masks = cached
    } else {
      let baked = InlineWritingStampFactory.stampMasks(for: material)
      if writingStampMaskCache.count >= Self.maximumWritingStampMaskSets,
        let first = writingStampMaskCache.keys.first
      {
        writingStampMaskCache.removeValue(forKey: first)
      }
      writingStampMaskCache[material] = baked
      masks = baked
    }
    let tinted = InlineWritingStampFactory.tinted(
      masks: masks,
      color: color.cgColor ?? CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    if tintedStampCache.count >= Self.maximumTintedStampSets,
      let first = tintedStampCache.keys.first
    {
      tintedStampCache.removeValue(forKey: first)
    }
    tintedStampCache[key] = tinted
    return tinted
  }

  public func writingMaterialTexture(for material: WritingMaterial) -> CGImage {
    if let cached = writingMaterialTextureCache[material] { return cached }
    let image: CGImage
    if case .chalk(let configuration) = material {
      do {
        image = try InlineWritingMaterialTextureFactory.makeChalkCoverageMask(
          for: WritingChalkSurfacePlan(configuration: configuration))
      } catch {
        preconditionFailure(String(describing: error))
      }
    } else {
      let texturePlan = WritingMaterialTexturePlan(material: material)
      guard let generated = InlineWritingMaterialTextureFactory.makeImage(from: texturePlan) else {
        preconditionFailure("procedural pigment texture could not be built")
      }
      image = generated
    }
    if writingMaterialTextureCache.count >= Self.maximumWritingMaterialTextures,
      let first = writingMaterialTextureCache.keys.first
    {
      writingMaterialTextureCache.removeValue(forKey: first)
    }
    writingMaterialTextureCache[material] = image
    return image
  }

  public func makeColoredPencilPlans(
    for configuration: ColoredPencilConfiguration,
    in viewport: InlineRenderViewport
  ) -> [PositionedInlineAtom: ColoredPencilPathPlan] {
    touchColoredPencilConfiguration(configuration)
    var plans = coloredPencilVectorPlanCache[configuration] ?? [:]
    let previousCount = plans.count
    for item in visibleGeometry(for: viewport) {
      guard case .vector(let positioned, let prepared) = item,
        plans[positioned] == nil,
        let asset = preparedAssets[
          InlineAssetKey(id: prepared.atom.assetID, version: prepared.atom.assetVersion)]
      else { continue }
      let destination = ColoredPencilRect(
        validatedX: 0, y: 0, width: positioned.width, height: positioned.height)
      plans[positioned] = ColoredPencilPathPlan(
        asset: asset, destination: destination, configuration: configuration)
    }
    coloredPencilVectorPlanCache[configuration] = plans
    if plans.count != previousCount { coloredPencilPlanBuildCount += 1 }
    return plans
  }

  public func makeColoredPencilTextFillPlans(
    for configuration: ColoredPencilConfiguration,
    in viewport: InlineRenderViewport
  ) -> [PositionedInlineAtom: ColoredPencilFillPlan] {
    touchColoredPencilConfiguration(configuration)
    var plans = coloredPencilTextFillPlanCache[configuration] ?? [:]
    let previousCount = plans.count
    let allocation = coloredPencilTextHatchAllocation(for: configuration)
    for item in visibleGeometry(for: viewport) {
      guard case .text(let positioned, _) = item,
        plans[positioned] == nil,
        textPaths[positioned]?.contains(where: {
          $0.kind == .outline || $0.kind == .semanticStroke
        }) == true
      else { continue }
      let bounds = textCanvasBounds(for: positioned)
      let destination = ColoredPencilRect(
        validatedX: Double(bounds.minX), y: Double(bounds.minY),
        width: Double(bounds.width), height: Double(bounds.height))
      plans[positioned] = ColoredPencilFillPlan(
        destination: destination, configuration: configuration,
        maximumHatches: allocation[positioned] ?? 0)
    }
    coloredPencilTextFillPlanCache[configuration] = plans
    if plans.count != previousCount { coloredPencilPlanBuildCount += 1 }
    return plans
  }

  public func makeWritingMaterialPlans(
    for material: WritingMaterial,
    in viewport: InlineRenderViewport
  ) -> [PositionedInlineAtom: WritingMaterialPlan] {
    let cachedPlans = writingMaterialPlanCache.plans(
      for: material, targetSet: writingMaterialTargetSet)
    var result: [PositionedInlineAtom: WritingMaterialPlan] = [:]
    for item in visibleGeometry(for: viewport) {
      let positioned: PositionedInlineAtom
      switch item {
      case .text(let value, _), .vector(let value, _): positioned = value
      case .image: continue
      }
      guard let index = writingMaterialTargetIndex[positioned],
        let plan = cachedPlans[index]
      else { continue }
      result[positioned] = plan
    }
    return result
  }

  package func resolvedAccessibilityLabel(
    vector: InlineVectorAtom, fallback: String
  ) -> String {
    vector.accessibilityLabel
      ?? assetLabels[InlineAssetKey(id: vector.assetID, version: vector.assetVersion)]
      ?? fallback
  }

  package static func makeLocalAssetPath(
    _ asset: InlineSVGAsset,
    commands: [InlinePathCommand],
    destination: CGRect
  ) -> Path {
    preparedAssetPath(
      asset, commands: commands, sourceBounds: asset.coordinateBounds, destination: destination)
  }

  package static func makeLocalCoveragePaint(
    _ asset: InlineSVGAsset,
    destination: CGRect
  ) -> InlineSVGCoveragePaint {
    let scale = inlineSVGUniformScale(
      sourceBounds: asset.coordinateBounds, destination: destination)
    return inlineSVGScaledCoveragePaint(asset.coveragePaint, scale: scale)
  }

  package static func makeLocalTrajectoryStyle(
    _ asset: InlineSVGAsset,
    destination: CGRect
  ) -> InlineSVGStrokeStyle {
    let scale = inlineSVGUniformScale(
      sourceBounds: asset.coordinateBounds, destination: destination)
    return inlineSVGScaledStrokeStyle(asset.trajectoryStyle, scale: scale)
  }

  private func coloredPencilTextHatchAllocation(
    for configuration: ColoredPencilConfiguration
  ) -> [PositionedInlineAtom: Int] {
    if let cached = coloredPencilTextHatchAllocationCache[configuration] { return cached }
    var candidates: [(PositionedInlineAtom, ColoredPencilRect)] = []
    for item in plan.geometry {
      guard case .text(let positioned, _) = item,
        textPaths[positioned]?.contains(where: {
          $0.kind == .outline || $0.kind == .semanticStroke
        }) == true
      else { continue }
      let bounds = textCanvasBounds(for: positioned)
      let destination = ColoredPencilRect(
        validatedX: Double(bounds.minX), y: Double(bounds.minY),
        width: Double(bounds.width), height: Double(bounds.height))
      candidates.append((positioned, destination))
    }
    let requests = candidates.map {
      ColoredPencilFillPlan.requestedHatchCount(
        destination: $0.1, configuration: configuration,
        maximumHatches: ColoredPencilPathPlan.maximumHatches)
    }
    let counts = ColoredPencilFillPlan.boundedHatchAllocations(
      requestedCounts: requests, maximumHatches: Self.maximumColoredPencilTextHatches)
    var allocation: [PositionedInlineAtom: Int] = [:]
    for (candidate, count) in zip(candidates, counts) { allocation[candidate.0] = count }
    coloredPencilTextHatchAllocationCache[configuration] = allocation
    return allocation
  }

  private func touchColoredPencilConfiguration(_ configuration: ColoredPencilConfiguration) {
    coloredPencilConfigurationLRU.removeAll { $0 == configuration }
    coloredPencilConfigurationLRU.append(configuration)
    guard coloredPencilConfigurationLRU.count > Self.maximumColoredPencilConfigurations else {
      return
    }
    let evicted = coloredPencilConfigurationLRU.removeFirst()
    coloredPencilVectorPlanCache.removeValue(forKey: evicted)
    coloredPencilTextFillPlanCache.removeValue(forKey: evicted)
    coloredPencilTextHatchAllocationCache.removeValue(forKey: evicted)
  }

  private static func makeWritingMaterialTargetCandidates(
    geometry: [PreparedInlineGeometry],
    textPaths: [PositionedInlineAtom: [InlineAppleTextPath]]
  ) -> [(positioned: PositionedInlineAtom, target: WritingMaterialTarget)] {
    var result: [(PositionedInlineAtom, WritingMaterialTarget)] = []
    for (geometryIndex, item) in geometry.enumerated() {
      let positioned: PositionedInlineAtom
      let destination: WritingMaterialRect
      switch item {
      case .text(let value, _):
        positioned = value
        guard
          textPaths[value]?.contains(where: {
            $0.kind == .outline || $0.kind == .semanticStroke
          }) == true
        else { continue }
        let cell = CGRect(
          x: 0, y: 0, width: CGFloat(value.width), height: CGFloat(value.height))
        let bounds = (textPaths[value] ?? []).reduce(cell) { $0.union($1.localPaintBounds) }
        destination = WritingMaterialRect(
          validatedX: Double(bounds.minX), y: Double(bounds.minY),
          width: Double(bounds.width), height: Double(bounds.height))
      case .vector(let value, _):
        positioned = value
        destination = WritingMaterialRect(
          validatedX: 0, y: 0, width: value.width, height: value.height)
      case .image: continue
      }
      let originY =
        positioned.baselineY - positioned.metrics.baselineOffset - positioned.metrics.ascent
      let target = WritingMaterialTarget(
        validatedTargetID:
          "\(positioned.atomID)|\(positioned.kind.rawValue)|line:\(positioned.lineIndex)|geometry:\(geometryIndex)",
        documentOriginX: positioned.originX + Double(destination.x),
        documentOriginY: originY + Double(destination.y),
        destination: destination)
      result.append((positioned, target))
    }
    return result
  }

  private static func validatedSchedule(
    _ schedule: InlineRenderRevealSchedule?,
    for plan: InlineRenderPlan,
    assets: InlineAssetStore
  ) throws -> InlineRenderRevealSchedule {
    let value =
      try schedule
      ?? InlineRenderRevealSchedule.completed(
        plan: plan, assets: assets)
    guard value.preparationRevision == plan.prepared.revision else {
      throw InlineLayoutError.invalidRenderPlan
    }
    var vectors: [String: InlineVectorAtom] = [:]
    for atom in plan.prepared.atoms {
      if case .vector(let vector) = atom { vectors[vector.atom.id] = vector.atom }
    }
    for activation in value.vectorActivations {
      guard let vector = vectors[activation.atomID],
        vector.assetID == activation.assetID,
        vector.assetVersion == activation.assetVersion,
        let asset = assets[
          InlineAssetKey(id: activation.assetID, version: activation.assetVersion)],
        activation.units.allSatisfy({ unit in
          guard asset.trajectoryPath.commands.indices.contains(unit.commandIndex) else {
            return false
          }
          if case .move = asset.trajectoryPath.commands[unit.commandIndex] { return false }
          return true
        })
      else { throw InlineLayoutError.invalidRenderPlan }
    }
    return value
  }

  private static func paintBounds(
    for item: PreparedInlineGeometry,
    textPaths: [PositionedInlineAtom: [InlineAppleTextPath]],
    assetPaths: [PositionedInlineAtom: Path],
    imagePaints: [PositionedInlineAtom: InlineImagePaintEntry]
  ) throws -> InlineHitRect? {
    let positioned: PositionedInlineAtom
    let bounds: [CGRect]
    let strokeWidth: Double
    switch item {
    case .text(let value, _):
      positioned = value
      bounds = textPaths[value]?.map(\.localPaintBounds) ?? []
      strokeWidth = 0
    case .vector(let value, _):
      positioned = value
      bounds = assetPaths[value].map { [$0.boundingRect] } ?? []
      strokeWidth = max(
        1,
        WritingStrokeGeometryPlan.maximumPossibleHalfWidth(destinationHeight: value.height) * 2
          + (WritingStrokeGeometryPlan.inkHaloBlurRadius + 1.05) * 2)
    case .image(let value, _):
      positioned = value
      bounds = imagePaints[value].map { [$0.localPaintBounds] } ?? []
      strokeWidth = 0
    }
    let originY =
      positioned.baselineY - positioned.metrics.baselineOffset - positioned.metrics.ascent
    var result: InlineHitRect?
    for localBounds in bounds {
      let translated = localBounds.offsetBy(
        dx: CGFloat(positioned.originX), dy: CGFloat(originY))
      guard translated.minX.isFinite, translated.minY.isFinite,
        translated.width.isFinite, translated.width >= 0,
        translated.height.isFinite, translated.height >= 0
      else {
        throw InlineLayoutError.invalidRenderPlan
      }
      let inflated = translated.insetBy(
        dx: CGFloat(-strokeWidth * 0.5), dy: CGFloat(-strokeWidth * 0.5))
      guard inflated.width > 0, inflated.height > 0 else { continue }
      result = try InlineRenderSectionRecord.union(
        result,
        try InlineHitRect(
          minX: Double(inflated.minX), minY: Double(inflated.minY),
          width: Double(inflated.width), height: Double(inflated.height)))
    }
    return result
  }

  private static func makeAssetPaths(
    geometry: [PreparedInlineGeometry], assets: InlineAssetStore
  ) throws -> [PositionedInlineAtom: Path] {
    var result: [PositionedInlineAtom: Path] = [:]
    for item in geometry {
      guard case .vector(let positioned, let prepared) = item,
        let asset = assets[
          InlineAssetKey(id: prepared.atom.assetID, version: prepared.atom.assetVersion)]
      else { continue }
      result[positioned] = preparedAssetPath(
        asset, commands: asset.coveragePath.commands,
        sourceBounds: asset.coordinateBounds,
        destination: CGRect(
          x: 0, y: 0, width: CGFloat(positioned.width), height: CGFloat(positioned.height)))
    }
    return result
  }

  private static func makeVectorCommands(
    geometry: [PreparedInlineGeometry], assets: InlineAssetStore
  ) throws -> [PositionedInlineAtom: [Int: InlineAppleVectorRevealCommand]] {
    var result: [PositionedInlineAtom: [Int: InlineAppleVectorRevealCommand]] = [:]
    for item in geometry {
      guard case .vector(let positioned, let prepared) = item,
        let asset = assets[
          InlineAssetKey(id: prepared.atom.assetID, version: prepared.atom.assetVersion)]
      else { continue }
      let destination = CGRect(
        x: 0, y: 0, width: CGFloat(positioned.width), height: CGFloat(positioned.height))
      result[positioned] = try makeVectorRevealCommands(asset: asset, destination: destination)
    }
    return result
  }

  package static func makeWritingMaterialSegments(
    _ commandsByPosition: [PositionedInlineAtom: [Int: InlineAppleVectorRevealCommand]]
  ) -> [PositionedInlineAtom: [InlineWritingMaterialSegment]] {
    var result: [PositionedInlineAtom: [InlineWritingMaterialSegment]] = [:]
    for (positioned, commands) in commandsByPosition {
      let segments = makeWritingMaterialSegments(commands)
      if !segments.isEmpty { result[positioned] = segments }
    }
    return result
  }

  package static func makeWritingMaterialSegments(
    _ commands: [Int: InlineAppleVectorRevealCommand]
  ) -> [InlineWritingMaterialSegment] {
    let pieces = commands.keys.sorted().compactMap { index -> InlineWritingMaterialPathPiece? in
      guard let command = commands[index] else { return nil }
      return InlineWritingMaterialPathPiece(
        path: command.fullPath.cgPath,
        subpathID: command.materialSubpathID,
        startDistance: command.materialStartDistance,
        endDistance: command.materialEndDistance,
        subpathLength: command.materialSubpathLength,
        isClosed: command.materialSubpathIsClosed,
        commandIndex: index)
    }
    return InlineWritingMaterialSampler.segments(pieces: pieces)
  }

  /// Builds a trajectory reveal path by command index. Completed commands are
  /// appended in activation order, followed by only the current command's
  /// prefix. This is the canonical rule shared by static and append frames.
  package static func makeVectorRevealPath(
    commands: [Int: InlineAppleVectorRevealCommand],
    activation: InlineRenderRevealVectorActivation,
    time: Double
  ) -> (path: Path, isComplete: Bool) {
    guard time.isFinite else { return (Path(), false) }
    if time >= activation.duration {
      var complete = Path()
      for unit in activation.units {
        if let command = commands[unit.commandIndex] { complete.addPath(command.fullPath) }
      }
      return (complete, true)
    }

    let completedCount = activation.completedCommandCount(at: time)
    var path = Path()
    for unit in activation.units.prefix(completedCount) {
      if let command = commands[unit.commandIndex] { path.addPath(command.fullPath) }
    }
    if completedCount < activation.units.count {
      let unit = activation.units[completedCount]
      let progress = min(1, max(0, (time - unit.startTime) / unit.duration))
      if progress > 0, let command = commands[unit.commandIndex] {
        path.addPath(makePartialVectorCommandPath(command: command, progress: progress))
      }
    }
    return (path, false)
  }

  /// Prebuilds the command metadata used by both static and append reveal.
  package static func makeVectorRevealCommands(
    asset: InlineSVGAsset,
    destination: CGRect
  ) throws -> [Int: InlineAppleVectorRevealCommand] {
    let metadata = try InlineWritingMaterialCommandMetadataCompiler.compile(
      commands: asset.trajectoryPath.commands)
    let scale = inlineSVGUniformScale(
      sourceBounds: asset.coordinateBounds, destination: destination)
    let scaledWidth = asset.coordinateBounds.width * scale
    let scaledHeight = asset.coordinateBounds.height * scale
    let originX =
      Double(destination.midX) - scaledWidth / 2
      - asset.coordinateBounds.minX * scale
    let originY =
      Double(destination.midY) - scaledHeight / 2
      - asset.coordinateBounds.minY * scale
    func mapPoint(_ value: InlinePathPoint) throws -> InlinePathPoint {
      // The command payload is atom-local, so the partial command can be
      // interpolated without rebuilding the asset transform at frame time.
      return try InlinePathPoint(
        x: originX + value.x * scale,
        y: originY + value.y * scale)
    }
    func mapCommand(_ command: InlinePathCommand) throws -> InlinePathCommand {
      switch command {
      case .move(let point): return .move(try mapPoint(point))
      case .line(let point): return .line(try mapPoint(point))
      case .quadratic(let control, let to):
        return .quadratic(control: try mapPoint(control), to: try mapPoint(to))
      case .cubic(let control1, let control2, let to):
        return .cubic(
          control1: try mapPoint(control1), control2: try mapPoint(control2),
          to: try mapPoint(to))
      case .close: return .close
      }
    }
    var current = try InlinePathPoint(x: 0, y: 0)
    var subpathStart = current
    var commands: [Int: InlineAppleVectorRevealCommand] = [:]
    for (index, command) in asset.trajectoryPath.commands.enumerated() {
      switch command {
      case .move(let point):
        current = point
        subpathStart = point
      case .line(let end), .quadratic(_, let end), .cubic(_, _, let end):
        let start = current
        current = end
        guard let value = metadata[index] else { continue }
        commands[index] = InlineAppleVectorRevealCommand(
          fullPath: preparedAssetPath(
            asset, commands: [.move(start), command], sourceBounds: asset.coordinateBounds,
            destination: destination),
          start: try mapPoint(start), subpathStart: try mapPoint(subpathStart),
          command: try mapCommand(command),
          materialSubpathID: value.subpathID, materialSubpathIsClosed: value.isClosed,
          materialStartDistance: value.startDistance, materialEndDistance: value.endDistance,
          materialSubpathLength: value.subpathLength)
      case .close:
        let start = current
        current = subpathStart
        guard let value = metadata[index] else { continue }
        commands[index] = InlineAppleVectorRevealCommand(
          fullPath: preparedAssetPath(
            asset, commands: [.move(start), .line(subpathStart), .close],
            sourceBounds: asset.coordinateBounds, destination: destination),
          start: try mapPoint(start), subpathStart: try mapPoint(subpathStart),
          command: .close,
          materialSubpathID: value.subpathID, materialSubpathIsClosed: value.isClosed,
          materialStartDistance: value.startDistance, materialEndDistance: value.endDistance,
          materialSubpathLength: value.subpathLength)
      }
    }
    return commands
  }

  private static func makePartialVectorCommandPath(
    command: InlineAppleVectorRevealCommand,
    progress: Double
  ) -> Path {
    func point(_ value: InlinePathPoint) -> CGPoint {
      CGPoint(x: CGFloat(value.x), y: CGFloat(value.y))
    }
    func lerp(_ a: CGPoint, _ b: CGPoint, _ f: Double) -> CGPoint {
      CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }
    let f = min(1, max(0, progress))
    guard f > 0 else { return Path() }
    let start = point(command.start)
    let subpathStart = point(command.subpathStart)
    var path = Path()
    path.move(to: start)
    switch command.command {
    case .line(let end): path.addLine(to: lerp(start, point(end), f))
    case .quadratic(let control, let end):
      let c = point(control)
      let e = point(end)
      let a = lerp(start, c, f)
      let b = lerp(c, e, f)
      path.addQuadCurve(to: lerp(a, b, f), control: a)
    case .cubic(let control1, let control2, let end):
      let c1 = point(control1)
      let c2 = point(control2)
      let e = point(end)
      let a = lerp(start, c1, f)
      let b = lerp(c1, c2, f)
      let c = lerp(c2, e, f)
      let d = lerp(a, b, f)
      let e2 = lerp(b, c, f)
      path.addCurve(to: lerp(d, e2, f), control1: a, control2: d)
    case .close:
      path.addLine(to: lerp(start, subpathStart, f))
      if f == 1 { path.closeSubpath() }
    case .move: break
    }
    return path
  }
}

private func inlineSVGUniformScale(
  sourceBounds: InlinePathBounds,
  destination: CGRect
) -> Double {
  let scale: Double
  if sourceBounds.width > 0, sourceBounds.height > 0 {
    scale = min(
      Double(destination.width) / sourceBounds.width,
      Double(destination.height) / sourceBounds.height
    )
  } else if sourceBounds.width > 0 {
    scale = Double(destination.width) / sourceBounds.width
  } else if sourceBounds.height > 0 {
    scale = Double(destination.height) / sourceBounds.height
  } else {
    preconditionFailure("validated SVG coordinate bounds have no drawable extent")
  }
  guard scale.isFinite, scale > 0 else {
    preconditionFailure("validated SVG destination has no positive uniform scale")
  }
  return scale
}

private func inlineSVGScaledStrokeStyle(
  _ style: InlineSVGStrokeStyle,
  scale: Double
) -> InlineSVGStrokeStyle {
  return InlineSVGStrokeStyle(
    validatedWidth: style.width * scale,
    cap: style.cap,
    join: style.join,
    miterLimit: style.miterLimit)
}

private func inlineSVGScaledCoveragePaint(
  _ paint: InlineSVGCoveragePaint,
  scale: Double
) -> InlineSVGCoveragePaint {
  switch paint {
  case .fill(let rule): return .fill(rule)
  case .stroke(let style): return .stroke(inlineSVGScaledStrokeStyle(style, scale: scale))
  }
}

private func preparedAssetPath(
  _ asset: InlineSVGAsset,
  commands: [InlinePathCommand],
  sourceBounds: InlinePathBounds,
  destination: CGRect
) -> Path {
  let scale = inlineSVGUniformScale(sourceBounds: sourceBounds, destination: destination)
  let scaledWidth = sourceBounds.width * scale
  let scaledHeight = sourceBounds.height * scale
  let originX = Double(destination.midX) - scaledWidth / 2 - sourceBounds.minX * scale
  let originY = Double(destination.midY) - scaledHeight / 2 - sourceBounds.minY * scale
  func mapPoint(_ value: InlinePathPoint) -> CGPoint {
    CGPoint(
      x: CGFloat(originX + value.x * scale),
      y: CGFloat(originY + value.y * scale)
    )
  }
  var path = Path()
  for command in commands {
    switch command {
    case .move(let value): path.move(to: mapPoint(value))
    case .line(let value): path.addLine(to: mapPoint(value))
    case .quadratic(let control, let value):
      path.addQuadCurve(
        to: mapPoint(value),
        control: mapPoint(control))
    case .cubic(let control1, let control2, let value):
      path.addCurve(
        to: mapPoint(value),
        control1: mapPoint(control1),
        control2: mapPoint(control2))
    case .close: path.closeSubpath()
    }
  }
  return path
}
