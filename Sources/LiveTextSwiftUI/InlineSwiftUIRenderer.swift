import Combine
import CoreGraphics
public import LiveTextAppleRendering
import LiveTextEffects
public import LiveTextLayout
import SwiftUI

@inline(__always)
private func isInlineSwiftUITextPathVisible(
  _ entry: InlineTextPaintEntry,
  activation: InlineRenderRevealTextActivation?,
  time: Double
) -> Bool {
  guard let activation else { return true }
  switch entry.kind {
  case .semanticStroke:
    guard let unitID = entry.writingUnitID else { return false }
    return activation.progress(at: time, unitID: unitID) > 0
  case .outline, .coreText:
    return activation.progress(at: time, sourceRange: entry.sourceRange) > 0
  }
}

/// SwiftUI façade over the shared Apple render-content owner.
@MainActor
public final class InlineSwiftUIRenderContent {
  fileprivate let core: InlineAppleRenderContent

  fileprivate var plan: InlineRenderPlan { core.plan }
  fileprivate var preparedAssets: InlineAssetStore { core.preparedAssets }
  fileprivate var preparedImages: InlineImageAssetStore { core.preparedImages }
  fileprivate var assetLabels: [InlineAssetKey: String] { core.assetLabels }
  fileprivate var accessibilityAtomLabels: [String: String] { core.accessibilityAtomLabels }
  fileprivate var textPaths: [PositionedInlineAtom: [InlineTextPaintEntry]] { core.textPaths }
  fileprivate var imagePaints: [PositionedInlineAtom: InlineImagePaintEntry] { core.imagePaints }
  fileprivate var assetPaths: [PositionedInlineAtom: Path] { core.assetPaths }
  fileprivate var writingMaterialSegments: [PositionedInlineAtom: [InlineWritingMaterialSegment]] {
    core.writingMaterialSegments
  }
  fileprivate var schedule: InlineRenderRevealSchedule { core.schedule }
  fileprivate var foregroundColor: Color { core.foregroundColor }

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
      plan: plan, assets: assets, registry: registry, schedule: schedule,
      foregroundColor: foregroundColor, assetCache: assetCache,
      imageAssets: imageAssets, imageCache: imageCache, imageScale: imageScale,
      composition: composition,
      forceMinimumOSImageRendering: false)
  }

  package init<Provider: InlineAssetGeometryProvider>(
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
    forceMinimumOSImageRendering: Bool
  ) throws {
    self.core = try InlineAppleRenderContent(
      plan: plan, assets: assets, registry: registry, schedule: schedule,
      foregroundColor: foregroundColor, assetCache: assetCache,
      imageAssets: imageAssets, imageCache: imageCache, imageScale: imageScale,
      composition: composition,
      forceMinimumOSImageRendering: forceMinimumOSImageRendering)
  }

  package init(core: InlineAppleRenderContent) {
    self.core = core
  }

  fileprivate func visibleGeometry(for viewport: InlineRenderViewport) -> [PreparedInlineGeometry] {
    core.visibleGeometry(for: viewport)
  }
  fileprivate func textCanvasBounds(for positioned: PositionedInlineAtom) -> CGRect {
    core.textCanvasBounds(for: positioned)
  }
  fileprivate func vectorPath(
    for positioned: PositionedInlineAtom,
    frame: InlineRenderRevealFrame
  ) -> Path { core.vectorPath(for: positioned, frame: frame) }
  fileprivate func vectorRenderFrame(
    for positioned: PositionedInlineAtom,
    frame: InlineRenderRevealFrame
  ) -> InlineAppleVectorRenderFrame {
    core.vectorRenderFrame(for: positioned, frame: frame)
  }
  fileprivate func compositionMasks(for positioned: PositionedInlineAtom)
    -> [InlineAppleSVGMask]
  {
    core.compositionMasks(for: positioned)
  }
  fileprivate func shouldRenderArtwork(for positioned: PositionedInlineAtom) -> Bool {
    core.shouldRenderArtwork(for: positioned)
  }
  fileprivate func writingMaterialTarget(for positioned: PositionedInlineAtom)
    -> WritingMaterialTarget?
  { core.writingMaterialTarget(for: positioned) }
  fileprivate func tintedStamps(material: WritingMaterial, color: Color) -> [CGImage] {
    core.tintedStamps(material: material, color: color)
  }
  fileprivate func writingMaterialTexture(for material: WritingMaterial) -> CGImage {
    core.writingMaterialTexture(for: material)
  }
  fileprivate func makeColoredPencilPlans(
    for configuration: ColoredPencilConfiguration,
    in viewport: InlineRenderViewport
  ) -> [PositionedInlineAtom: ColoredPencilPathPlan] {
    core.makeColoredPencilPlans(for: configuration, in: viewport)
  }
  fileprivate func makeColoredPencilTextFillPlans(
    for configuration: ColoredPencilConfiguration,
    in viewport: InlineRenderViewport
  ) -> [PositionedInlineAtom: ColoredPencilFillPlan] {
    core.makeColoredPencilTextFillPlans(for: configuration, in: viewport)
  }
  fileprivate func makeWritingMaterialPlans(
    for material: WritingMaterial,
    in viewport: InlineRenderViewport
  ) -> [PositionedInlineAtom: WritingMaterialPlan] {
    core.makeWritingMaterialPlans(for: material, in: viewport)
  }
  fileprivate var coloredPencilPlanBuildCount: Int { core.coloredPencilPlanBuildCount }
  fileprivate var coloredPencilCachedConfigurationCount: Int {
    core.coloredPencilCachedConfigurationCount
  }
  fileprivate var writingMaterialCachedConfigurationCount: Int {
    core.writingMaterialCachedConfigurationCount
  }
  fileprivate var writingMaterialPlanBuildCount: Int { core.writingMaterialPlanBuildCount }
  fileprivate var writingMaterialTargetCount: Int { core.writingMaterialTargetCount }
  fileprivate func writingMaterialSegments(for positioned: PositionedInlineAtom)
    -> [InlineWritingMaterialSegment]?
  { core.writingMaterialSegments(for: positioned) }
  fileprivate func visibleWritingMaterialSegments(
    for positioned: PositionedInlineAtom,
    frame: InlineRenderRevealFrame
  ) -> [InlineWritingMaterialSegment]? {
    core.visibleWritingMaterialSegments(for: positioned, frame: frame)
  }
  fileprivate func resolvedAccessibilityLabel(
    vector: InlineVectorAtom, fallback: String
  ) -> String { core.resolvedAccessibilityLabel(vector: vector, fallback: fallback) }
  fileprivate var coreIdentityForTesting: ObjectIdentifier { ObjectIdentifier(core) }
}

/// SwiftUI renderer for immutable prepared content and a scalar reveal phase.
@MainActor
public struct InlineSwiftUIRenderer: View {
  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  private let content: InlineSwiftUIRenderContent
  private let phase: InlineRenderRevealPhase
  private let viewport: InlineRenderViewport
  private let coloredPencilPlans: [PositionedInlineAtom: ColoredPencilPathPlan]
  private let coloredPencilTextFillPlans: [PositionedInlineAtom: ColoredPencilFillPlan]
  private let writingMaterialPlans: [PositionedInlineAtom: WritingMaterialPlan]
  private let writingMaterial: WritingMaterial?
  private let writingMaterialTexture: CGImage?
  private let writingMaterialColor: Color?
  private let motion: InlineMotionConfiguration
  private let motionPhase: InlineMotionPhase
  private let highlight: InlineHighlightPlan?
  private let onTextUnitActivation: InlineTextUnitActivationHandler?
  private let accessibility: InlineAccessibilityProjection

  public init(
    content: InlineSwiftUIRenderContent,
    phase: InlineRenderRevealPhase = .complete,
    viewport: InlineRenderViewport,
    material: InlineRendererMaterial = .none,
    writingColor: Color? = nil,
    onTextUnitActivation: InlineTextUnitActivationHandler? = nil
  ) {
    self.init(
      content: content,
      phase: phase,
      viewport: viewport,
      material: material,
      writingColor: writingColor,
      motion: .none,
      motionPhase: .complete,
      highlight: nil,
      onTextUnitActivation: onTextUnitActivation)
  }

  /// Additive presentation-only motion. The host owns `motionPhase`; this
  /// renderer only samples the deterministic transform and never starts a clock.
  public init(
    content: InlineSwiftUIRenderContent,
    phase: InlineRenderRevealPhase = .complete,
    viewport: InlineRenderViewport,
    material: InlineRendererMaterial = .none,
    writingColor: Color? = nil,
    motion: InlineMotionConfiguration,
    motionPhase: InlineMotionPhase,
    onTextUnitActivation: InlineTextUnitActivationHandler? = nil
  ) {
    self.init(
      content: content,
      phase: phase,
      viewport: viewport,
      material: material,
      writingColor: writingColor,
      motion: motion,
      motionPhase: motionPhase,
      highlight: nil,
      onTextUnitActivation: onTextUnitActivation)
  }

  private init(
    content: InlineSwiftUIRenderContent,
    phase: InlineRenderRevealPhase,
    viewport: InlineRenderViewport,
    material: InlineRendererMaterial,
    writingColor: Color?,
    motion: InlineMotionConfiguration,
    motionPhase: InlineMotionPhase,
    highlight: InlineHighlightPlan?,
    onTextUnitActivation: InlineTextUnitActivationHandler?
  ) {
    self.content = content
    self.phase = phase
    self.viewport = viewport
    self.coloredPencilPlans =
      material.coloredPencilConfiguration.map {
        content.makeColoredPencilPlans(for: $0, in: viewport)
      } ?? [:]
    self.coloredPencilTextFillPlans =
      material.coloredPencilConfiguration.map {
        content.makeColoredPencilTextFillPlans(for: $0, in: viewport)
      } ?? [:]
    if let writingMaterial = material.writingMaterial, writingMaterial.kind != .chalk {
      self.writingMaterialPlans = content.makeWritingMaterialPlans(
        for: writingMaterial, in: viewport)
    } else {
      self.writingMaterialPlans = [:]
    }
    self.writingMaterial = material.writingMaterial
    if let writingMaterial = material.writingMaterial, writingMaterial.kind != .chalk {
      self.writingMaterialTexture = content.writingMaterialTexture(for: writingMaterial)
    } else {
      self.writingMaterialTexture = nil
    }
    self.writingMaterialColor = writingColor
    self.motion = motion
    self.motionPhase = motionPhase
    self.highlight = Self.checkedHighlight(highlight, for: content.plan)
    self.onTextUnitActivation = onTextUnitActivation
    self.accessibility = Self.checkedAccessibility(
      selection: highlight?.selection, content: content)
  }

  /// Throwing constructor for hosts that need typed rejection instead of a
  /// programmer-error trap when a retained effect plan is stale or forged.
  public init(
    validating content: InlineSwiftUIRenderContent,
    phase: InlineRenderRevealPhase = .complete,
    viewport: InlineRenderViewport,
    material: InlineRendererMaterial = .none,
    writingColor: Color? = nil,
    highlight: InlineHighlightPlan? = nil,
    onTextUnitActivation: InlineTextUnitActivationHandler? = nil
  ) throws {
    if let highlight { try highlight.validate(for: content.plan) }
    self.init(
      content: content,
      phase: phase,
      viewport: viewport,
      material: material,
      writingColor: writingColor,
      motion: .none,
      motionPhase: .complete,
      highlight: highlight,
      onTextUnitActivation: onTextUnitActivation)
  }

  /// Throwing expressive-motion constructor for hosts that also retain a
  /// validated highlight/effects plan.
  public init(
    validating content: InlineSwiftUIRenderContent,
    phase: InlineRenderRevealPhase = .complete,
    viewport: InlineRenderViewport,
    material: InlineRendererMaterial = .none,
    writingColor: Color? = nil,
    motion: InlineMotionConfiguration,
    motionPhase: InlineMotionPhase,
    highlight: InlineHighlightPlan? = nil,
    onTextUnitActivation: InlineTextUnitActivationHandler? = nil
  ) throws {
    if let highlight { try highlight.validate(for: content.plan) }
    self.init(
      content: content, phase: phase, viewport: viewport, material: material,
      writingColor: writingColor, motion: motion, motionPhase: motionPhase,
      highlight: highlight, onTextUnitActivation: onTextUnitActivation)
  }

  /// Rasterizes this configured renderer exactly once without re-running
  /// document shaping, line fitting, or a second reveal timeline.
  @MainActor
  public func rasterSnapshot(
    scale: CGFloat = 1,
    limits: InlineAppleRasterSnapshotLimits = .default
  ) throws -> InlineAppleRasterSnapshot {
    try InlineAppleRasterSnapshotter.snapshot(
      content: self,
      size: CGSize(width: viewport.width, height: viewport.height),
      scale: scale,
      limits: limits
    )
  }

  public var body: some View {
    let frame = content.schedule.sample(at: phase)
    let visibleGeometry = content.visibleGeometry(for: viewport)
    ZStack(alignment: .topLeading) {
      if let highlight {
        highlightView(highlight)
          .accessibilityHidden(true)
          .allowsHitTesting(false)
      }
      ForEach(visibleGeometry, id: \.self) { item in
        let positioned = Self.positionedValue(for: item)
        let expressive = motion.sampleValidated(
          phase: motionPhase,
          atomIndex: inlineAppleMotionOrdinal(
            atomID: positioned.atomID, in: content.core.atomOrdinalByID),
          atomCount: content.core.atomOrdinalByID.count,
          atomHeight: positioned.height,
          atomID: positioned.atomID,
          reduceMotion: accessibilityReduceMotion
        )
        atomView(item, frame: frame)
          .position(
            x: CGFloat(positioned.originX - viewport.x + positioned.width / 2),
            y: CGFloat(
              positioned.baselineY - positioned.metrics.baselineOffset
                - positioned.metrics.ascent - viewport.y + positioned.height / 2
            )
          )
          .scaleEffect(
            x: CGFloat(expressive.scaleX),
            y: CGFloat(expressive.scaleY),
            anchor: UnitPoint(x: expressive.anchorX, y: expressive.anchorY)
          )
          .rotationEffect(
            .radians(expressive.rotationRadians),
            anchor: UnitPoint(x: expressive.anchorX, y: expressive.anchorY)
          )
          .offset(
            x: CGFloat(expressive.translationX),
            y: CGFloat(expressive.translationY)
          )
      }
    }
    .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    .clipped()
    .accessibilityRepresentation {
      InlineAppleAccessibilityRepresentation(
        projection: accessibility,
        atomLabels: content.accessibilityAtomLabels,
        onTextUnitActivation: onTextUnitActivation)
    }
  }

  public func hitTest(_ point: InlineHitPoint) -> InlineHitResult {
    content.plan.hitIndex.hitTest(point)
  }

  public func hitTest(atViewportPoint point: InlineHitPoint) -> InlineHitResult {
    guard let layoutPoint = viewport.layoutPoint(fromLocal: point) else { return .none }
    return content.plan.hitIndex.hitTest(layoutPoint)
  }

  /// Performs the shared viewport hit test and emits only a word activation
  /// event. Selection ownership remains with the host callback consumer.
  @discardableResult
  public func activate(atViewportPoint point: InlineHitPoint) -> InlineHitResult {
    let result = hitTest(atViewportPoint: point)
    if case .textUnit(let word) = result { onTextUnitActivation?(word) }
    return result
  }

  internal var highlightPlanForTesting: InlineHighlightPlan? { highlight }
  internal var accessibilityProjectionForTesting: InlineAccessibilityProjection {
    accessibility
  }

  private static func checkedHighlight(
    _ highlight: InlineHighlightPlan?,
    for plan: InlineRenderPlan
  ) -> InlineHighlightPlan? {
    guard let highlight else { return nil }
    do {
      try highlight.validate(for: plan)
      return highlight
    } catch {
      preconditionFailure(String(describing: error))
    }
  }

  private static func checkedAccessibility(
    selection: InlineSelectionKey?,
    content: InlineSwiftUIRenderContent
  ) -> InlineAccessibilityProjection {
    do {
      return try content.core.accessibilityProjection(selection: selection)
    } catch {
      preconditionFailure(String(describing: error))
    }
  }

  private func highlightView(_ plan: InlineHighlightPlan) -> some View {
    ZStack(alignment: .topLeading) {
      ForEach(Array(plan.fragments.enumerated()), id: \.offset) { _, fragment in
        let rect = fragment.rect
        let x = CGFloat(rect.minX - viewport.x)
        let y = CGFloat(rect.minY - viewport.y)
        switch plan.style {
        case .highlighter(let color, let opacity, let cornerRadius):
          RoundedRectangle(cornerRadius: CGFloat(cornerRadius))
            .fill(Self.highlightColor(color).opacity(opacity))
            .frame(width: CGFloat(rect.width), height: CGFloat(rect.height))
            .position(x: x + CGFloat(rect.width) / 2, y: y + CGFloat(rect.height) / 2)
        case .underline(let color, let thickness, let offset):
          Rectangle()
            .fill(Self.highlightColor(color))
            .frame(width: CGFloat(rect.width), height: CGFloat(thickness))
            .position(
              x: x + CGFloat(rect.width) / 2,
              y: y + CGFloat(rect.height) + CGFloat(offset) + CGFloat(thickness) / 2)
        case .outline(let color, let thickness):
          RoundedRectangle(cornerRadius: 1)
            .stroke(Self.highlightColor(color), lineWidth: CGFloat(thickness))
            .frame(width: CGFloat(rect.width), height: CGFloat(rect.height))
            .position(x: x + CGFloat(rect.width) / 2, y: y + CGFloat(rect.height) / 2)
        }
      }
    }
    .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
  }

  private static func highlightColor(_ color: InlineHighlightColor) -> Color {
    Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
  }

  internal func visibleAtomIDsForTesting(in viewport: InlineRenderViewport) -> [String] {
    content.visibleGeometry(for: viewport).map { item in
      switch item {
      case .text(let positioned, _), .vector(let positioned, _):
        return positioned.atomID
      case .image(let positioned, _):
        return positioned.atomID
      }
    }
  }

  package func visibleAtomIDsForWritingTesting(in viewport: InlineRenderViewport) -> [String] {
    visibleAtomIDsForTesting(in: viewport)
  }

  internal var canonicalGeometryForTesting: [PreparedInlineGeometry] { content.plan.geometry }
  internal var renderedTextPathsForTesting: [PositionedInlineAtom: [Path]] {
    content.textPaths.mapValues { entries in
      entries.compactMap { entry in
        guard entry.kind == .outline else { return nil }
        return entry.outlinePath
      }
    }
  }
  internal var renderedTextPaintEntriesForTesting: [PositionedInlineAtom: [InlineTextPaintEntry]] {
    content.textPaths
  }
  /// Test-only projection of the semantic mask boundary. The production
  /// chalk branch passes the full entry set plus activation/time; keeping the
  /// same forwarding operation here makes that contract deterministic without
  /// requiring a raster or SwiftUI body evaluation.
  internal static func semanticMaskPathForTesting(
    _ entries: [InlineTextPaintEntry],
    activation: InlineRenderRevealTextActivation?,
    time: Double
  ) -> Path {
    InlineAppleSemanticStrokePainter.maskPath(
      entries, activation: activation, time: time)
  }
  internal func textCanvasBoundsForTesting(
    _ positioned: PositionedInlineAtom
  ) -> CGRect {
    content.textCanvasBounds(for: positioned)
  }
  /// Test-only evidence that colored-pencil geometry was compiled for the
  /// positioned vector atoms before SwiftUI body evaluation.
  internal var coloredPencilPlanCountForTesting: Int { coloredPencilPlans.count }
  internal var coloredPencilPlanBuildCountForTesting: Int {
    content.coloredPencilPlanBuildCount
  }
  internal var coloredPencilCachedConfigurationCountForTesting: Int {
    content.coloredPencilCachedConfigurationCount
  }
  internal var coloredPencilTextHatchCountForTesting: Int {
    coloredPencilTextFillPlans.values.reduce(0) { $0 + $1.hatches.count }
  }
  package var writingMaterialPlanCountForTesting: Int {
    writingMaterialPlans.count
  }
  package var writingMaterialMarkCountForTesting: Int {
    writingMaterialPlans.values.reduce(0) { $0 + $1.marks.count }
  }
  package var writingMaterialTargetCountForTesting: Int {
    content.writingMaterialTargetCount
  }
  package var writingMaterialPlansForTesting: [PositionedInlineAtom: WritingMaterialPlan] {
    writingMaterialPlans
  }
  package var writingMaterialCachedConfigurationCountForTesting: Int {
    content.writingMaterialCachedConfigurationCount
  }
  package var writingMaterialPlanBuildCountForTesting: Int {
    content.writingMaterialPlanBuildCount
  }
  internal var coloredPencilVisibleTextHatchCountsForTesting: [PositionedInlineAtom: Int] {
    let visible: Set<PositionedInlineAtom> = Set(
      content.visibleGeometry(for: viewport).compactMap { item in
        guard case .text(let positioned, _) = item else { return nil }
        return positioned
      })
    return coloredPencilTextFillPlans.reduce(into: [:]) { result, entry in
      if visible.contains(entry.key) { result[entry.key] = entry.value.hatches.count }
    }
  }
  internal func coloredPencilVisibleSampleCountForTesting(
    _ positioned: PositionedInlineAtom
  ) -> Int? {
    guard let plan = coloredPencilPlans[positioned] else { return nil }
    let frame = content.schedule.sample(at: phase)
    return plan.strokes.reduce(0) {
      $0
        + plan.visiblePoints(
          for: $1,
          activation: frame.vectorActivation(for: positioned.atomID),
          time: frame.time
        ).count
    }
  }
  internal var visibleTextPathsForTesting: [PositionedInlineAtom: [Path]] {
    let frame = content.schedule.sample(at: phase)
    var result: [PositionedInlineAtom: [Path]] = [:]
    for (positioned, entries) in content.textPaths {
      let activation = frame.textActivation(for: positioned.atomID)
      result[positioned] = entries.filter {
        isInlineSwiftUITextPathVisible($0, activation: activation, time: frame.time)
      }.compactMap { entry in
        guard entry.kind == .outline else { return nil }
        return entry.outlinePath
      }
    }
    return result
  }
  internal var visibleTextPaintEntriesForTesting: [PositionedInlineAtom: [InlineTextPaintEntry]] {
    let frame = content.schedule.sample(at: phase)
    var result: [PositionedInlineAtom: [InlineTextPaintEntry]] = [:]
    for (positioned, entries) in content.textPaths {
      let activation = frame.textActivation(for: positioned.atomID)
      result[positioned] = entries.filter {
        isInlineSwiftUITextPathVisible($0, activation: activation, time: frame.time)
      }
    }
    return result
  }
  internal var renderedAssetPathsForTesting: [PositionedInlineAtom: Path] {
    content.assetPaths
  }
  /// Test-only projection of the target-local composition inputs consumed by
  /// the SwiftUI Canvas branch. It exposes the same immutable mask values the
  /// body applies, without introducing a renderer-owned cache.
  internal var compositionMasksForTesting: [PositionedInlineAtom: [InlineAppleSVGMask]] {
    Dictionary(
      uniqueKeysWithValues: content.plan.geometry.compactMap { item in
        let positioned: PositionedInlineAtom
        switch item {
        case .text(let value, _), .vector(let value, _), .image(let value, _): positioned = value
        }
        let masks = content.compositionMasks(for: positioned)
        return masks.isEmpty ? nil : (positioned, masks)
      })
  }
  internal var visibleAssetPathsForTesting: [PositionedInlineAtom: Path] {
    let frame = content.schedule.sample(at: phase)
    var result: [PositionedInlineAtom: Path] = [:]
    for positioned in content.assetPaths.keys {
      result[positioned] = content.vectorPath(for: positioned, frame: frame)
    }
    return result
  }
  internal var contentIdentityForTesting: ObjectIdentifier { content.coreIdentityForTesting }
  internal var visibleGeometryForTesting: [PreparedInlineGeometry] {
    content.visibleGeometry(for: viewport)
  }
  internal func resolvedAccessibilityLabel(
    vector: InlineVectorAtom, fallback: String
  ) -> String {
    content.resolvedAccessibilityLabel(vector: vector, fallback: fallback)
  }

  private func atomView(
    _ item: PreparedInlineGeometry,
    frame: InlineRenderRevealFrame
  ) -> AnyView {
    switch item {
    case .text(let positioned, _):
      let paths = content.textPaths[positioned] ?? []
      let color = content.foregroundColor
      let materialColor = writingMaterialColor ?? color
      let atomID = positioned.atomID
      let activation = frame.textActivation(for: atomID)
      // Glyph outlines and Core Text paint can extend outside the logical
      // advance cell (negative bearings, italic overhang, and ascender/
      // descender paint). Keep the logical cell for placement, but give this
      // per-atom Canvas the unioned paint bounds so it cannot clip locally.
      let canvasBounds = content.textCanvasBounds(for: positioned)
      return AnyView(
        ZStack(alignment: .topLeading) {
          Canvas { context, _ in
            context.translateBy(x: -canvasBounds.minX, y: -canvasBounds.minY)
            let masks = content.compositionMasks(for: positioned).map { mask in
              Self.translatedMask(mask, by: -canvasBounds.minX, y: -canvasBounds.minY)
            }
            context.drawLayer { layer in
              InlineAppleCompositionPainter.applyRevealMasks(masks, in: &layer)
              let visibleEntries = paths.filter {
                isInlineSwiftUITextPathVisible($0, activation: activation, time: frame.time)
              }
              if let fillPlan = coloredPencilTextFillPlans[positioned] {
                Self.drawColoredPencilText(
                  fillPlan,
                  entries: visibleEntries,
                  activation: activation,
                  time: frame.time,
                  in: &layer,
                  color: color
                )
              } else if let material = writingMaterial,
                case .chalk(let configuration) = material,
                let target = content.writingMaterialTarget(for: positioned)
              {
                // Keep the complete entry set and pass the same frame sample
                // used by visibility checks. Filtering first would make the
                // painter lose the unit progress and stroke the whole semantic
                // outline for every entry that has started.
                let mask = InlineAppleSemanticStrokePainter.maskPath(
                  paths, activation: activation, time: frame.time)
                InlineWritingChalkPainter.paint(
                  mask: mask,
                  target: target,
                  configuration: configuration,
                  color: materialColor,
                  documentOriginAtContextZero: CGPoint(
                    x: CGFloat(target.documentOriginX - target.destination.x),
                    y: CGFloat(target.documentOriginY - target.destination.y)
                  ),
                  in: &layer
                )
              } else if let materialPlan = writingMaterialPlans[positioned] {
                Self.drawWritingMaterialText(
                  materialPlan,
                  entries: visibleEntries,
                  activation: activation,
                  time: frame.time,
                  in: &layer,
                  color: materialColor,
                  texture: writingMaterialTexture
                )
              }
              for entry in visibleEntries {
                switch entry.kind {
                case .outline:
                  if coloredPencilTextFillPlans[positioned] == nil,
                    writingMaterialPlans[positioned] == nil,
                    writingMaterial?.kind != .chalk,
                    let path = entry.outlinePath
                  {
                    layer.fill(path, with: .color(color))
                  }
                case .coreText:
                  entry.draw(in: &layer)
                case .semanticStroke:
                  if writingMaterial?.kind != .chalk,
                    coloredPencilTextFillPlans[positioned] == nil,
                    writingMaterialPlans[positioned] == nil
                  {
                    InlineAppleSemanticStrokePainter.draw(
                      [entry], color: materialColor,
                      activation: activation, time: frame.time, in: &layer)
                  }
                }
              }
              InlineAppleCompositionPainter.applyEraseMasks(masks, in: &layer)
            }
          }
          .frame(width: canvasBounds.width, height: canvasBounds.height)
          .offset(x: canvasBounds.minX, y: canvasBounds.minY)
        }
        .frame(
          width: positioned.width,
          height: positioned.height,
          alignment: .topLeading
        )
      )
    case .vector(let positioned, let prepared):
      guard content.shouldRenderArtwork(for: positioned) else {
        return AnyView(EmptyView())
      }
      let vector = prepared.atom
      let fullPath = content.assetPaths[positioned]
      let color = content.foregroundColor
      let pencilPlan = coloredPencilPlans[positioned]
      let materialPlan = writingMaterialPlans[positioned]
      let materialColor = writingMaterialColor ?? color
      let logicalCell = CGRect(
        x: 0, y: 0, width: CGFloat(positioned.width), height: CGFloat(positioned.height))
      let vectorPaintExpansion: CGFloat =
        writingMaterial.map { material in
          let geometryExpansion = WritingStrokeGeometryPlan.conservativeMaximumHalfWidth(
            for: material, destinationHeight: positioned.height)
          let chalkExpansion: Double
          if case .chalk(let configuration) = material {
            chalkExpansion = WritingChalkSurfacePlan(configuration: configuration).paintOutset
          } else {
            chalkExpansion = 0
          }
          let haloExpansion =
            material.kind == .ink
            ? WritingStrokeGeometryPlan.inkHaloBlurRadius + 1.05 : 0
          return CGFloat(max(geometryExpansion, chalkExpansion) + haloExpansion)
        } ?? 0
      let canvasBounds = logicalCell.insetBy(
        dx: -vectorPaintExpansion, dy: -vectorPaintExpansion)
      let viewportOrigin = CGPoint(
        x: CGFloat(positioned.originX - viewport.x),
        y: CGFloat(
          positioned.baselineY - positioned.metrics.baselineOffset
            - positioned.metrics.ascent - viewport.y
        )
      )
      let rawCanvasOrigin = CGPoint(
        x: viewportOrigin.x + canvasBounds.minX,
        y: viewportOrigin.y + canvasBounds.minY
      )
      let pixelCorrection = Self.devicePixelAlignmentCorrection(
        for: rawCanvasOrigin,
        scale: displayScale
      )
      return AnyView(
        ZStack(alignment: .topLeading) {
          Canvas { context, _ in
            // The expanded Canvas is a separate raster surface from the
            // document Canvas. Align its frame origin to the display grid,
            // then compensate the local translation so path coordinates keep
            // their exact viewport-global position.
            context.translateBy(
              x: -canvasBounds.minX - pixelCorrection.width,
              y: -canvasBounds.minY - pixelCorrection.height
            )
            guard fullPath != nil else {
              preconditionFailure("validated vector path was not prebuilt")
            }
            let masks = content.compositionMasks(for: positioned).map { mask in
              Self.translatedMask(
                mask,
                by: -canvasBounds.minX - pixelCorrection.width,
                y: -canvasBounds.minY - pixelCorrection.height)
            }
            context.drawLayer { layer in
              InlineAppleCompositionPainter.applyRevealMasks(masks, in: &layer)
              let vectorFrame = content.vectorRenderFrame(for: positioned, frame: frame)
              let trajectoryMask =
                vectorFrame.trajectory.isEmpty
                ? Path()
                : vectorFrame.trajectory.strokedPath(
                  Self.inlineStrokeStyle(vectorFrame.trajectoryStyle))
              if let materialPlan, let material = writingMaterial {
                // Writing materials own their variable-width ribbon and its
                // reveal terminal. Clipping that ribbon to the source SVG
                // coverage/trajectory would reduce it back to a one-pixel
                // centerline and erase the pressure taper.
                Self.drawWritingMaterialVector(
                  materialPlan, material: material, path: vectorFrame.trajectory,
                  in: &layer, color: materialColor, texture: writingMaterialTexture,
                  materialSegments: content.visibleWritingMaterialSegments(
                    for: positioned, frame: frame),
                  stampImages: content.tintedStamps(material: material, color: materialColor))
              } else {
                layer.drawLayer { paintLayer in
                  if !vectorFrame.isComplete {
                    guard !trajectoryMask.isEmpty else { return }
                    paintLayer.clip(to: trajectoryMask)
                  }
                  Self.clipInlineVectorCoverage(vectorFrame, in: &paintLayer)
                  if let pencilPlan {
                    Self.drawColoredPencil(
                      pencilPlan, in: &paintLayer,
                      activation: frame.vectorActivation(for: positioned.atomID),
                      time: frame.time, color: color)
                  } else if let material = writingMaterial,
                    case .chalk(let configuration) = material,
                    let target = content.writingMaterialTarget(for: positioned)
                  {
                    InlineWritingChalkPainter.paint(
                      mask: vectorFrame.isComplete
                        ? InlineAppleVectorCoveragePainter.maskPath(
                          coverage: vectorFrame.coverage, paint: vectorFrame.coveragePaint)
                        : trajectoryMask, target: target,
                      configuration: configuration, color: materialColor,
                      documentOriginAtContextZero: CGPoint(
                        x: CGFloat(target.documentOriginX - target.destination.x),
                        y: CGFloat(target.documentOriginY - target.destination.y)),
                      in: &paintLayer)
                  } else {
                    Self.drawInlineVectorCoverage(vectorFrame, in: &paintLayer, color: color)
                  }
                }
              }
              InlineAppleCompositionPainter.applyEraseMasks(masks, in: &layer)
            }
          }
          .frame(width: canvasBounds.width, height: canvasBounds.height)
          .offset(
            x: canvasBounds.minX + pixelCorrection.width,
            y: canvasBounds.minY + pixelCorrection.height
          )
        }
        .frame(width: positioned.width, height: positioned.height, alignment: .topLeading)
        .accessibilityLabel(
          content.resolvedAccessibilityLabel(vector: vector, fallback: positioned.atomID))
      )
    case .image(let positioned, let prepared):
      guard let paint = content.imagePaints[positioned] else {
        preconditionFailure("validated inline image paint was not prebuilt")
      }
      let image = prepared.atom
      let logicalCell = CGRect(
        x: 0,
        y: 0,
        width: CGFloat(positioned.width),
        height: CGFloat(positioned.height)
      )
      // A per-atom Canvas has its own rendering bounds. Adaptive paint can
      // protrude above/below or to either side of the typographic cell, so
      // expand that Canvas while retaining a logical-cell wrapper for layout
      // placement and accessibility semantics.
      let canvasBounds = logicalCell.union(paint.localPaintBounds)
      return AnyView(
        ZStack(alignment: .topLeading) {
          Canvas { context, _ in
            guard frame.imageIsVisible(atomID: image.id) else { return }
            context.translateBy(x: -canvasBounds.minX, y: -canvasBounds.minY)
            let masks = content.compositionMasks(for: positioned).map { mask in
              Self.translatedMask(mask, by: -canvasBounds.minX, y: -canvasBounds.minY)
            }
            context.drawLayer { layer in
              InlineAppleCompositionPainter.applyRevealMasks(masks, in: &layer)
              paint.draw(in: &layer)
              InlineAppleCompositionPainter.applyEraseMasks(masks, in: &layer)
            }
          }
          .frame(width: canvasBounds.width, height: canvasBounds.height)
          .offset(x: canvasBounds.minX, y: canvasBounds.minY)
        }
        .frame(
          width: positioned.width,
          height: positioned.height,
          alignment: .topLeading
        )
        .accessibilityHidden(image.isDecorative)
        .accessibilityLabel(image.accessibilityLabel ?? image.id)
      )
    }
  }

  /// Returns the correction that moves a child Canvas origin onto the nearest
  /// display pixel without moving the document/path origin seen by users.
  /// Invalid scales and coordinates leave the layout untouched.
  internal static func devicePixelAlignmentCorrection(
    for rawOrigin: CGPoint,
    scale: CGFloat
  ) -> CGSize {
    guard scale.isFinite, scale > 0,
      rawOrigin.x.isFinite, rawOrigin.y.isFinite
    else { return .zero }
    let alignedX = (rawOrigin.x * scale).rounded() / scale
    let alignedY = (rawOrigin.y * scale).rounded() / scale
    return CGSize(
      width: alignedX - rawOrigin.x,
      height: alignedY - rawOrigin.y
    )
  }

  private static func inlineStrokeStyle(_ style: InlineSVGStrokeStyle) -> StrokeStyle {
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

  private static func translatedMask(
    _ mask: InlineAppleSVGMask,
    by x: CGFloat,
    y: CGFloat
  ) -> InlineAppleSVGMask {
    InlineAppleSVGMask(
      instanceID: mask.instanceID,
      operation: mask.operation,
      declarationOrder: mask.declarationOrder,
      path: mask.path.applying(CGAffineTransform(translationX: x, y: y)))
  }

  private static func clipInlineVectorCoverage(
    _ frame: InlineAppleVectorRenderFrame,
    in context: inout GraphicsContext
  ) {
    InlineAppleVectorCoveragePainter.clip(
      coverage: frame.coverage, paint: frame.coveragePaint, in: &context)
  }

  private static func drawInlineVectorCoverage(
    _ frame: InlineAppleVectorRenderFrame,
    in context: inout GraphicsContext,
    color: Color
  ) {
    InlineAppleVectorCoveragePainter.draw(
      coverage: frame.coverage, paint: frame.coveragePaint, color: color, in: &context)
  }

  private static func drawWritingMaterialText(
    _ plan: WritingMaterialPlan,
    entries: [InlineTextPaintEntry],
    activation: InlineRenderRevealTextActivation?,
    time: Double,
    in context: inout GraphicsContext,
    color: Color,
    texture: CGImage?
  ) {
    let mask = InlineAppleSemanticStrokePainter.maskPath(
      entries, activation: activation, time: time)
    guard !mask.isEmpty else { return }
    guard !plan.marks.isEmpty else {
      context.fill(
        mask,
        with: .color(color.opacity(plan.baseOpacity)),
        style: FillStyle(eoFill: true)
      )
      return
    }

    // Material owns the complete surface composition. The base face is
    // intentionally incomplete so the plan's marks remain visible at body
    // text scale rather than disappearing beneath an opaque glyph.
    if plan.kind == .ink {
      context.drawLayer { layer in
        layer.addFilter(.blur(radius: CGFloat(WritingStrokeGeometryPlan.inkHaloBlurRadius)))
        layer.stroke(
          mask,
          with: .color(color.opacity(0.34)),
          style: StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round)
        )
      }
    }
    context.drawLayer { layer in
      layer.clip(to: mask, style: FillStyle(eoFill: true))
      layer.fill(
        mask,
        with: .color(color.opacity(max(0.20, min(0.92, plan.baseOpacity)))),
        style: FillStyle(eoFill: true)
      )
      if let texture {
        Self.drawWritingMaterialTexture(
          texture,
          plan: plan,
          in: &layer,
          bounds: mask.boundingRect
        )
      }
      Self.drawWritingMaterialMarks(plan, in: &layer, color: color)
      if plan.kind == .ink {
        layer.stroke(
          mask,
          with: .color(color.opacity(0.82)),
          style: StrokeStyle(lineWidth: 0.95, lineCap: .round, lineJoin: .round)
        )
      } else if plan.kind == .pen {
        layer.stroke(
          mask,
          with: .color(color.opacity(0.42)),
          style: StrokeStyle(lineWidth: 0.32, lineCap: .round, lineJoin: .round)
        )
      }
    }
  }

  private static func drawWritingMaterialVector(
    _ plan: WritingMaterialPlan,
    material: WritingMaterial?,
    path: Path,
    in context: inout GraphicsContext,
    color: Color,
    texture: CGImage?,
    materialSegments: [InlineWritingMaterialSegment]? = nil,
    stampImages: [CGImage] = []
  ) {
    guard !path.isEmpty else { return }
    guard let material else {
      context.stroke(path, with: .color(color.opacity(plan.baseOpacity)), lineWidth: 1)
      return
    }
    if plan.kind == .knockout {
      // Facade capability: this adapter composites each atom in its own
      // layer, so the punch erases this atom's layer only — the stroke
      // leaves a transparent channel rather than cutting sibling content.
      // The Canvas facade performs the full document punch.
      let geometries = InlineAppleWritingMaterialGeometry.make(
        segments: materialSegments ?? [],
        material: material,
        destinationHeight: plan.destination.height
      )
      var punch = context
      punch.blendMode = .destinationOut
      for geometry in geometries {
        punch.fill(Self.writingGeometryPath(geometry.body), with: .color(.white))
      }
      context = punch
      context.blendMode = .normal
      return
    }
    if plan.marks.isEmpty {
      context.stroke(path, with: .color(color.opacity(plan.baseOpacity)), lineWidth: 1)
      return
    }
    let geometries = InlineAppleWritingMaterialGeometry.make(
      segments: materialSegments ?? [],
      material: material,
      destinationHeight: plan.destination.height
    )
    guard !geometries.isEmpty else {
      // An empty plan is the explicit nonthrowing result for malformed or
      // overflowing centerline geometry. Do not turn that failure into a
      // visually successful but unbounded fallback stroke.
      return
    }
    var body = Path()
    var coverage = Path()
    for geometry in geometries {
      let bodyPath = Self.writingGeometryPath(geometry.body)
      body.addPath(bodyPath)
      coverage.addPath(bodyPath)
    }
    guard !body.isEmpty else { return }
    if plan.kind == .ink {
      context.drawLayer { layer in
        layer.addFilter(.blur(radius: CGFloat(WritingStrokeGeometryPlan.inkHaloBlurRadius)))
        layer.stroke(
          coverage,
          with: .color(color.opacity(0.34)),
          style: StrokeStyle(lineWidth: 2.10, lineCap: .round, lineJoin: .round)
        )
      }
    }
    context.drawLayer { layer in
      // The shared geometry is already a variable-width filled outline.
      // Adapters only fill it and clip the material surface to that outline.
      // Media grain must bite across the boundary: clip the whole material
      // layer to the coverage dilated by the edge budget, not the bare
      // polygon, so erosion stamps carve the outer contour into crumbles.
      // The stamp bite needs headroom past the boundary, but the face,
      // texture, and marks must stay inside the polygon or they read as
      // stroke pixels and widen the visible silhouette.
      layer.drawLayer { surface in
        surface.clip(to: coverage)
        Self.drawMaterialSurface(
          plan, body: body, coverage: coverage, geometries: geometries,
          color: color, stampImages: stampImages, texture: texture, in: &surface
        )
      }
      if !stampImages.isEmpty {
        for geometry in geometries {
          InlineWritingStampPainter.draw(geometry.stamps, images: stampImages, in: &layer)
        }
      }
      if plan.kind == .ink {
        // Wet edge: ink pools darker along the boundary; the band scales
        // with the stroke instead of staying a fixed hairline.
        layer.stroke(
          coverage,
          with: .color(color.opacity(0.80)),
          style: StrokeStyle(
            lineWidth: CGFloat(min(2.2, max(0.5, plan.destination.height * 0.03))),
            lineCap: .round,
            lineJoin: .round
          )
        )
      }
    }
    Self.drawWritingGeometryDetails(geometries, in: &context, color: color)
  }

  /// The tight-clipped material face: ribbon body, second pass overlay,
  /// document-anchored texture tile, and low-weight surface marks.
  private static func drawMaterialSurface(
    _ plan: WritingMaterialPlan,
    body: Path,
    coverage: Path,
    geometries: [WritingStrokeGeometry],
    color: Color,
    stampImages: [CGImage],
    texture: CGImage?,
    in context: inout GraphicsContext
  ) {
    let bodyAlpha = max(0.20, min(0.92, plan.baseOpacity))
    // Non-zero winding: a self-crossing ribbon has winding 2 at the
    // crossing, and even-odd would punch it into a transparent hole.
    // Vector ribbons carry no counters, so non-zero is always safe.
    context.fill(
      body,
      with: .color(color.opacity(bodyAlpha)),
      style: FillStyle(eoFill: false)
    )
    if plan.kind == .marker {
      // Wet edge (NPAR 2017 edge darkening): real marker film pools a
      // darker ring inside the stroke boundary.
      context.stroke(
        coverage,
        with: .color(color.opacity(min(0.92, bodyAlpha * 1.18))),
        style: StrokeStyle(
          lineWidth: CGFloat(min(2.2, max(0.5, plan.destination.height * 0.028))),
          lineCap: .round,
          lineJoin: .round
        )
      )
    }
    if let texture {
      // Per-stroke alignment: the tile grid rotates to each subpath's
      // dominant travel direction (see the Canvas adapter note).
      for geometry in geometries {
        let origin = geometry.body.first
        context.drawLayer { tex in
          if let origin {
            tex.translateBy(x: origin.x, y: origin.y)
            tex.rotate(by: .radians(geometry.dominantAngle))
            tex.translateBy(x: -origin.x, y: -origin.y)
          }
          var bounds = coverage.boundingRect
          let inflate = hypot(bounds.width, bounds.height) / 2
          bounds = bounds.insetBy(dx: -inflate, dy: -inflate)
          Self.drawWritingMaterialTexture(
            texture,
            plan: plan,
            in: &tex,
            bounds: bounds
          )
        }
      }
    }
    // The ribbon body now carries the stroke; marks only add surface
    // grain, so their weight drops for vector strokes.
    let markIntensity: Double
    let markDotScale: Double
    switch plan.kind {
    case .chalk:
      preconditionFailure("chalk surface is not a generic material plan")
    case .brush:
      markIntensity = 0.45
      markDotScale = 0.35
    case .pen:
      markIntensity = 0.7
      markDotScale = 0.5
    case .ink:
      markIntensity = 0.45
      markDotScale = 0.35
    case .marker:
      markIntensity = 0.5
      markDotScale = 0.3
    case .knockout:
      markIntensity = 0
      markDotScale = 0
    }
    let effectiveIntensity = stampImages.isEmpty ? markIntensity : markIntensity * 0.55
    Self.drawWritingMaterialMarks(
      plan,
      in: &context,
      color: color,
      intensity: effectiveIntensity,
      dotScale: markDotScale
    )
  }

  private static func writingGeometryPath(_ points: [WritingPlanPoint]) -> Path {
    guard let first = points.first else { return Path() }
    var path = Path()
    path.move(to: CGPoint(x: first.x, y: first.y))
    for point in points.dropFirst() {
      path.addLine(to: CGPoint(x: point.x, y: point.y))
    }
    path.closeSubpath()
    return path
  }

  private static func drawWritingGeometryDetails(
    _ geometries: [WritingStrokeGeometry],
    in context: inout GraphicsContext,
    color: Color
  ) {
    for geometry in geometries {
      for bristle in geometry.bristles {
        context.blendMode = bristle.isErosion ? .destinationOut : .normal
        for run in bristle.runs where run.count > 1 {
          var path = Path()
          path.move(to: CGPoint(x: run[0].x, y: run[0].y))
          for point in run.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
          }
          context.stroke(
            path,
            with: .color(color.opacity(min(0.9, max(0, bristle.opacity)))),
            style: StrokeStyle(
              lineWidth: CGFloat(max(0.18, bristle.width)),
              lineCap: .butt,
              lineJoin: .round
            )
          )
        }
      }
      context.blendMode = .normal
      for splat in geometry.splatters {
        let radius = CGFloat(max(0.35, splat.radius))
        context.fill(
          Path(
            ellipseIn: CGRect(
              x: splat.x - radius,
              y: splat.y - radius,
              width: radius * 2,
              height: radius * 2
            )),
          with: .color(color.opacity(min(0.84, max(0, splat.opacity))))
        )
      }
    }
    context.blendMode = .normal
  }

  /// Repeats one small deterministic tile over the actual path mask.  The
  /// image is shared per material configuration; only the clipped draw calls
  /// are target-local.  The phase is calculated in document coordinates so a
  /// viewport change cannot make a glyph's grain swim.
  private static func drawWritingMaterialTexture(
    _ texture: CGImage,
    plan: WritingMaterialPlan,
    in context: inout GraphicsContext,
    bounds: CGRect
  ) {
    guard !bounds.isEmpty else { return }
    let tileSize: CGFloat = CGFloat(WritingMaterialTexturePlan.defaultPointSize)
    guard tileSize.isFinite, tileSize > 0 else { return }
    let destinationX = CGFloat(plan.destination.x)
    let destinationY = CGFloat(plan.destination.y)
    let documentX = CGFloat(plan.documentOriginX)
    let documentY = CGFloat(plan.documentOriginY)
    let globalMinX = documentX + bounds.minX - destinationX
    let globalMinY = documentY + bounds.minY - destinationY
    let gridX = floor(globalMinX / tileSize) * tileSize
    let gridY = floor(globalMinY / tileSize) * tileSize
    let firstX = destinationX + (gridX - documentX) - tileSize
    let firstY = destinationY + (gridY - documentY) - tileSize
    let image = Image(decorative: texture, scale: 2)
    let opacity: Double
    switch plan.kind {
    case .chalk:
      preconditionFailure("chalk surface texture is not a generic material plan")
    case .brush: opacity = 0.56
    case .pen: opacity = 0.20
    case .ink: opacity = 0.48
    case .marker: opacity = 0.18
    case .knockout: opacity = 0
    }
    context.blendMode = .multiply
    context.opacity = opacity
    var y = firstY
    while y < bounds.maxY + tileSize {
      var x = firstX
      while x < bounds.maxX + tileSize {
        context.draw(
          image,
          in: CGRect(x: x, y: y, width: tileSize, height: tileSize)
        )
        x += tileSize
      }
      y += tileSize
    }
    context.opacity = 1
    context.blendMode = .normal
  }

  private static func drawWritingMaterialMarks(
    _ plan: WritingMaterialPlan,
    in context: inout GraphicsContext,
    color: Color,
    intensity: Double = 1,
    dotScale: Double = 1
  ) {
    for mark in plan.marks {
      let start = CGPoint(x: mark.x, y: mark.y)
      let markOpacity = mark.opacity * intensity
      let markWidth = mark.width * dotScale
      switch plan.kind {
      case .marker:
        context.blendMode = .normal
        var fleck = Path()
        fleck.move(to: start)
        fleck.addLine(
          to: CGPoint(
            x: mark.x + mark.dx * mark.length,
            y: mark.y + mark.dy * mark.length
          ))
        context.stroke(
          fleck,
          with: .color(color.opacity(min(0.5, markOpacity))),
          style: StrokeStyle(lineWidth: CGFloat(max(0.3, markWidth)), lineCap: .round)
        )
      case .knockout:
        break
      case .chalk:
        preconditionFailure("chalk surface marks are not generated")
      case .brush:
        context.blendMode = mark.isErosion ? .destinationOut : .normal
        let end = CGPoint(
          x: mark.x + mark.dx * mark.length,
          y: mark.y + mark.dy * mark.length
        )
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(
          path,
          with: .color(color.opacity(min(0.92, markOpacity * 0.92))),
          style: StrokeStyle(
            lineWidth: CGFloat(max(0.55, markWidth * (mark.isErosion ? 0.72 : 0.86))),
            lineCap: .butt,
            lineJoin: .round
          )
        )
        let directionLength = max(0.001, hypot(end.x - start.x, end.y - start.y))
        let normal = CGPoint(
          x: -(end.y - start.y) / directionLength,
          y: (end.x - start.x) / directionLength
        )
        for lane in [-1.0, 0.0, 1.0] {
          let offset = lane * CGFloat(0.42 + mark.secondarySize * 0.46)
          var bristle = Path()
          bristle.move(
            to: CGPoint(
              x: start.x + normal.x * offset,
              y: start.y + normal.y * offset
            ))
          bristle.addLine(
            to: CGPoint(
              x: end.x + normal.x * offset * 0.55,
              y: end.y + normal.y * offset * 0.55
            ))
          context.stroke(
            bristle,
            with: .color(color.opacity(min(0.72, markOpacity * (lane == 0 ? 0.62 : 0.48)))),
            style: StrokeStyle(
              lineWidth: CGFloat(max(0.18, markWidth * (lane == 0 ? 0.20 : 0.13))),
              lineCap: .butt,
              lineJoin: .round
            )
          )
        }
      case .pen:
        context.blendMode = .normal
        var nib = Path()
        nib.move(to: start)
        nib.addLine(
          to: CGPoint(
            x: mark.x + mark.dx * mark.length,
            y: mark.y + mark.dy * mark.length
          ))
        context.stroke(
          nib,
          with: .color(color.opacity(min(0.96, markOpacity * 0.88))),
          style: StrokeStyle(
            lineWidth: CGFloat(max(0.38, markWidth * 0.76)),
            lineCap: .round,
            lineJoin: .round
          )
        )
        let dotRadius = CGFloat(max(0.18, markWidth * 0.34))
        context.fill(
          Path(
            ellipseIn: CGRect(
              x: start.x - dotRadius,
              y: start.y - dotRadius,
              width: dotRadius * 2,
              height: dotRadius * 2
            )),
          with: .color(color.opacity(min(0.88, markOpacity * 0.58)))
        )
      case .ink:
        context.blendMode = .normal
        var path = Path()
        path.move(to: start)
        let end = CGPoint(
          x: mark.x + mark.dx * mark.length,
          y: mark.y + mark.dy * mark.length
        )
        path.addQuadCurve(
          to: end,
          control: CGPoint(
            x: (start.x + end.x) * 0.5 + mark.secondaryX * mark.length * 0.45,
            y: (start.y + end.y) * 0.5 + mark.secondaryY * mark.length * 0.45
          )
        )
        context.stroke(
          path,
          with: .color(color.opacity(min(0.92, markOpacity * 0.72))),
          style: StrokeStyle(
            lineWidth: CGFloat(max(0.72, markWidth * 0.82)),
            lineCap: .round,
            lineJoin: .round
          )
        )
        let radius = max(0.42, markWidth * (0.78 + mark.secondarySize * 0.64))
        context.fill(
          Path(
            ellipseIn: CGRect(
              x: end.x - radius, y: end.y - radius,
              width: radius * 2, height: radius * 2
            )),
          with: .color(color.opacity(min(0.84, markOpacity * 0.70)))
        )
      }
    }
    context.blendMode = .normal
  }

  private static func drawColoredPencil(
    _ plan: ColoredPencilPathPlan,
    in context: inout GraphicsContext,
    activation: InlineRenderRevealVectorActivation?,
    time: Double,
    color: Color
  ) {
    Self.drawColoredPencilHatches(
      plan,
      in: &context,
      activation: activation,
      time: time,
      color: color
    )
    for stroke in plan.strokes {
      let points = plan.visiblePoints(
        for: stroke,
        activation: activation,
        time: time
      )
      guard points.count > 1 else { continue }
      let centerline = Self.makeCenterlinePath(points)
      // Display-size vectors need a pencil body that scales with the glyph,
      // not the fixed 1pt body contract kept in the plan.
      let bodyScale = max(1.78, plan.destination.height * 0.30)
      if stroke.isClosed {
        context.stroke(
          centerline,
          with: .color(color),
          style: StrokeStyle(
            // Closed contours carry even-odd counters that must stay
            // unpainted, so they keep the plan's own body width.
            lineWidth: CGFloat(stroke.bodyWidth * 1.18),
            lineCap: .butt,
            lineJoin: .round
          )
        )
      } else {
        // Keep the public plan's 1pt body contract, but give the actual
        // rasterized ribbon enough area to survive 2x/3x antialiasing. The
        // sampled widths still taper to the terminal tip.
        let outline = Self.makeOpenOutlinePath(points, widthScale: bodyScale)
        context.fill(outline, with: .color(color), style: FillStyle(eoFill: true))
      }
      for fiber in stroke.fibers {
        let fiberPoints = Self.offsetFiber(points, by: fiber.offset * bodyScale * 0.5)
        guard fiberPoints.count > 1 else { continue }
        context.stroke(
          Self.makeCenterlinePath(fiberPoints),
          with: .color(color.opacity(fiber.opacity)),
          style: StrokeStyle(
            lineWidth: CGFloat(max(0.08, stroke.bodyWidth * fiber.widthScale)),
            lineCap: .round,
            lineJoin: .round
          )
        )
      }
    }
  }

  private static func drawColoredPencilText(
    _ plan: ColoredPencilFillPlan,
    entries: [InlineTextPaintEntry],
    activation: InlineRenderRevealTextActivation?,
    time: Double,
    in context: inout GraphicsContext,
    color: Color
  ) {
    let mask = InlineAppleSemanticStrokePainter.maskPath(
      entries, activation: activation, time: time)
    guard !mask.isEmpty else { return }
    guard !plan.hatches.isEmpty else {
      context.fill(mask, with: .color(color), style: FillStyle(eoFill: true))
      return
    }
    context.drawLayer { layer in
      layer.clip(to: mask, style: FillStyle(eoFill: true))
      // Keep the base face in the isolated layer. A destination-out tooth
      // mark must subtract the face as well as the deposits; drawing the face
      // before this layer would leave the apparent pencil surface opaque.
      // A pencil does not cover paper like an opaque vector fill.  Keep a
      // translucent pigment bed and make the directional deposition field the
      // dominant signal, otherwise body-sized glyphs read as ordinary text.
      layer.fill(mask, with: .color(color.opacity(0.16)), style: FillStyle(eoFill: true))
      layer.stroke(
        mask,
        with: .color(color.opacity(0.28)),
        style: StrokeStyle(lineWidth: 0.28, lineCap: .round, lineJoin: .round)
      )
      var hatchPath = Path()
      var grainPath = Path()
      var opacityTotal = 0.0
      for hatch in plan.hatches {
        hatchPath.addPath(Self.makeOpenOutlinePath(hatch.points))
        grainPath.addPath(Self.makeCenterlinePath(hatch.points))
        opacityTotal += hatch.opacity
      }
      layer.fill(
        hatchPath,
        with: .color(
          color.opacity(
            min(
              0.92,
              opacityTotal / Double(max(1, plan.hatches.count)) * 1.65
            ))),
        style: FillStyle(eoFill: true)
      )
      layer.stroke(
        grainPath,
        with: .color(color.opacity(0.52 + 0.36 * plan.configuration.fiberAmount)),
        style: StrokeStyle(lineWidth: 0.68, lineCap: .round, lineJoin: .round)
      )
      Self.drawColoredPencilFiberField(
        in: &layer,
        bounds: mask.boundingRect,
        configuration: plan.configuration,
        color: color
      )
      if plan.configuration.paperTooth > 0 {
        layer.blendMode = .destinationOut
        let gapOpacity = 0.80 + 0.18 * plan.configuration.paperTooth
        let gapRadius = CGFloat(0.62 + 0.95 * plan.configuration.paperTooth)
        for (index, hatch) in plan.hatches.enumerated() where index.isMultiple(of: 2) {
          for pointIndex in [1, 4, 6] where pointIndex < hatch.points.count {
            let point = hatch.points[pointIndex]
            let radius = max(0.12, gapRadius * CGFloat(1 - point.width * 0.18))
            layer.fill(
              Path(
                ellipseIn: CGRect(
                  x: point.x - radius,
                  y: point.y - radius,
                  width: radius * 2,
                  height: radius * 2
                )),
              with: .color(.white.opacity(gapOpacity))
            )
          }
        }
        layer.blendMode = .normal
      }
    }
  }

  /// Dense, directional paper-tooth strokes are what make a filled glyph
  /// read as pencil pigment rather than a solid vector face.  They are drawn
  /// across the target bounds and clipped by the actual glyph mask above, so
  /// narrow counters and separate glyphs receive the same material without
  /// any per-glyph random allocation.
  private static func drawColoredPencilFiberField(
    in context: inout GraphicsContext,
    bounds: CGRect,
    configuration: ColoredPencilConfiguration,
    color: Color
  ) {
    guard !bounds.isEmpty else { return }
    let spacing = CGFloat(max(0.92, 1.72 - 0.72 * configuration.paperTooth))
    let overscan = max(bounds.width, bounds.height) + bounds.height * 1.6
    let count = min(192, max(1, Int(ceil((bounds.height + overscan) / spacing))))
    let phase = Double(configuration.seed & 0xFFFF) / Double(0xFFFF)
    var fibers = Path()
    for index in 0..<count {
      let fraction = Double(index) / Double(max(1, count - 1))
      let y = bounds.minY - bounds.height * 0.8 + CGFloat(fraction) * (bounds.height * 2.6)
      let wobble =
        CGFloat(sin(Double(index) * 2.137 + phase * 6.283))
        * CGFloat(0.16 + 0.46 * configuration.jitterAmount)
      let slope = CGFloat(0.08 + 0.10 * sin(Double(index) * 0.71 + phase))
      fibers.move(to: CGPoint(x: bounds.minX - bounds.height, y: y + wobble))
      fibers.addLine(
        to: CGPoint(
          x: bounds.maxX + bounds.height,
          y: y + wobble + (bounds.width + bounds.height * 2) * slope
        ))
    }
    context.stroke(
      fibers,
      with: .color(color.opacity(0.34 + 0.34 * configuration.fiberAmount)),
      style: StrokeStyle(lineWidth: 0.34, lineCap: .round, lineJoin: .round)
    )
  }

  private static func drawColoredPencilHatches(
    _ plan: ColoredPencilPathPlan,
    in context: inout GraphicsContext,
    activation: InlineRenderRevealVectorActivation?,
    time: Double,
    color: Color
  ) {
    let visibleCount = plan.visibleHatchCount(activation: activation, time: time)
    guard visibleCount > 0 else { return }
    let mask = Self.makeClosedFillPath(plan.strokes)
    context.drawLayer { layer in
      layer.clip(to: mask, style: FillStyle(eoFill: true))
      var hatchPath = Path()
      var grainPath = Path()
      var opacityTotal = 0.0
      let visibleHatches = Array(plan.hatches.prefix(visibleCount))
      for hatch in visibleHatches {
        hatchPath.addPath(Self.makeOpenOutlinePath(hatch.points))
        grainPath.addPath(Self.makeCenterlinePath(hatch.points))
        opacityTotal += hatch.opacity
      }
      let opacity = opacityTotal / Double(max(1, visibleHatches.count))
      layer.fill(
        hatchPath,
        with: .color(color.opacity(min(0.92, opacity * 1.65))),
        style: FillStyle(eoFill: true)
      )
      layer.stroke(
        grainPath,
        with: .color(color.opacity(0.38 + 0.38 * plan.configuration.fiberAmount)),
        style: StrokeStyle(lineWidth: 0.38, lineCap: .round, lineJoin: .round)
      )
      if plan.configuration.paperTooth > 0 {
        layer.blendMode = .destinationOut
        let gapOpacity = 0.80 + 0.18 * plan.configuration.paperTooth
        let gapRadius = CGFloat(0.62 + 0.95 * plan.configuration.paperTooth)
        for (index, hatch) in visibleHatches.enumerated() where index.isMultiple(of: 2) {
          for pointIndex in [1, 4, 6] where pointIndex < hatch.points.count {
            let point = hatch.points[pointIndex]
            let radius = max(0.12, gapRadius * CGFloat(1 - point.width * 0.18))
            layer.fill(
              Path(
                ellipseIn: CGRect(
                  x: point.x - radius,
                  y: point.y - radius,
                  width: radius * 2,
                  height: radius * 2
                )),
              with: .color(.white.opacity(gapOpacity))
            )
          }
        }
        layer.blendMode = .normal
      }
    }
  }

  private static func makeClosedFillPath(
    _ strokes: [ColoredPencilStrokePlan]
  ) -> Path {
    var path = Path()
    for stroke in strokes where stroke.isClosed {
      guard let first = stroke.points.first else { continue }
      path.move(to: CGPoint(x: first.x, y: first.y))
      for point in stroke.points.dropFirst() {
        path.addLine(to: CGPoint(x: point.x, y: point.y))
      }
      path.closeSubpath()
    }
    return path
  }

  private static func makeCenterlinePath(_ points: [ColoredPencilPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: CGPoint(x: first.x, y: first.y))
    for point in points.dropFirst() {
      path.addLine(to: CGPoint(x: point.x, y: point.y))
    }
    return path
  }

  private static func makeOpenOutlinePath(
    _ points: [ColoredPencilPoint],
    widthScale: Double = 1
  ) -> Path {
    guard points.count > 1 else { return Path() }
    var left: [CGPoint] = []
    var right: [CGPoint] = []
    left.reserveCapacity(points.count)
    right.reserveCapacity(points.count)
    for index in points.indices {
      let previous = points[index == points.startIndex ? index : points.index(before: index)]
      let next = points[
        index == points.index(before: points.endIndex) ? index : points.index(after: index)]
      let dx = next.x - previous.x
      let dy = next.y - previous.y
      let length = hypot(dx, dy)
      let normalX = length > 0 ? -dy / length : 0
      let normalY = length > 0 ? dx / length : 1
      let radius = points[index].width * widthScale * 0.5
      left.append(
        CGPoint(x: points[index].x + normalX * radius, y: points[index].y + normalY * radius))
      right.append(
        CGPoint(x: points[index].x - normalX * radius, y: points[index].y - normalY * radius))
    }
    var path = Path()
    path.move(to: left[0])
    for point in left.dropFirst() { path.addLine(to: point) }
    for point in right.reversed() { path.addLine(to: point) }
    path.closeSubpath()
    return path
  }

  private static func offsetFiber(
    _ points: [ColoredPencilPoint],
    by offset: Double
  ) -> [ColoredPencilPoint] {
    guard points.count > 1 else { return points }
    return points.indices.map { index in
      let previous = points[index == points.startIndex ? index : points.index(before: index)]
      let next = points[
        index == points.index(before: points.endIndex) ? index : points.index(after: index)]
      let dx = next.x - previous.x
      let dy = next.y - previous.y
      let length = hypot(dx, dy)
      let normalX = length > 0 ? -dy / length : 0
      let normalY = length > 0 ? dx / length : 1
      return ColoredPencilPoint(
        validatedX: points[index].x + normalX * offset,
        y: points[index].y + normalY * offset,
        width: max(0.08, points[index].width))
    }
  }

  private static func positionedValue(
    for item: PreparedInlineGeometry
  ) -> PositionedInlineAtom {
    switch item {
    case .text(let positioned, _), .vector(let positioned, _): return positioned
    case .image(let positioned, _): return positioned
    }
  }
}

// MARK: - Incremental append renderer

/// SwiftUI append renderer.  The body consumes immutable chunks owned by the
/// shared append session and contains no preparation or state transition.
@MainActor
public struct InlineSwiftUIAppendRenderer<Provider: InlineAssetGeometryProvider>: View {
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @ObservedObject private var session: InlineAppleAppendSession<Provider>
  private let viewport: InlineRenderViewport
  private let phase: InlineRenderRevealPhase
  private let material: InlineRendererMaterial
  private let materialResources: InlineAppleAppendMaterialResources
  private let color: Color
  private let motion: InlineMotionConfiguration
  private let motionPhase: InlineMotionPhase
  private let effects: InlineAppleAppendEffectsPlan?
  private let onTextUnitActivation: InlineTextUnitActivationHandler?

  public init(
    session: InlineAppleAppendSession<Provider>,
    viewport: InlineRenderViewport,
    phase: InlineRenderRevealPhase = .complete,
    material: InlineRendererMaterial = .none,
    color: Color = .primary,
    onTextUnitActivation: InlineTextUnitActivationHandler? = nil
  ) throws {
    self.init(
      session: session, viewport: viewport, phase: phase,
      material: material, color: color,
      materialResources: try InlineAppleAppendPainter.materialResources(for: material),
      motion: .none, motionPhase: .complete,
      effects: nil, onTextUnitActivation: onTextUnitActivation)
  }

  /// Append renderer with presentation-only expressive motion. The append
  /// reducer/session remain the sole state and publication authority.
  public init(
    session: InlineAppleAppendSession<Provider>,
    viewport: InlineRenderViewport,
    phase: InlineRenderRevealPhase = .complete,
    material: InlineRendererMaterial = .none,
    color: Color = .primary,
    motion: InlineMotionConfiguration,
    motionPhase: InlineMotionPhase,
    onTextUnitActivation: InlineTextUnitActivationHandler? = nil
  ) throws {
    self.init(
      session: session, viewport: viewport, phase: phase,
      material: material, color: color,
      materialResources: try InlineAppleAppendPainter.materialResources(for: material),
      motion: motion, motionPhase: motionPhase,
      effects: nil, onTextUnitActivation: onTextUnitActivation)
  }

  /// Throwing append effects handoff. The effects plan is package-internal because append
  /// section payloads are already adapter-internal; callers use this one
  /// canonical path rather than passing independent highlight/mask values.
  package init(
    session: InlineAppleAppendSession<Provider>,
    viewport: InlineRenderViewport,
    phase: InlineRenderRevealPhase = .complete,
    material: InlineRendererMaterial = .none,
    color: Color = .primary,
    effects: InlineAppleAppendEffectsPlan,
    onTextUnitActivation: InlineTextUnitActivationHandler? = nil
  ) throws {
    try session.validate(effects: effects)
    self.init(
      session: session, viewport: viewport, phase: phase,
      material: material, color: color,
      materialResources: try InlineAppleAppendPainter.materialResources(for: material),
      motion: .none, motionPhase: .complete,
      effects: effects, onTextUnitActivation: onTextUnitActivation)
  }

  /// Explicit throwing handoff for hosts retaining an append effects plan.
  /// The session revision is checked before the renderer can be observed.
  package init(
    validating session: InlineAppleAppendSession<Provider>,
    viewport: InlineRenderViewport,
    phase: InlineRenderRevealPhase = .complete,
    material: InlineRendererMaterial = .none,
    color: Color = .primary,
    effects: InlineAppleAppendEffectsPlan,
    onTextUnitActivation: InlineTextUnitActivationHandler? = nil
  ) throws {
    try self.init(
      session: session, viewport: viewport, phase: phase,
      material: material, color: color, effects: effects,
      onTextUnitActivation: onTextUnitActivation)
  }

  private init(
    session: InlineAppleAppendSession<Provider>,
    viewport: InlineRenderViewport,
    phase: InlineRenderRevealPhase,
    material: InlineRendererMaterial,
    color: Color,
    materialResources: InlineAppleAppendMaterialResources,
    motion: InlineMotionConfiguration,
    motionPhase: InlineMotionPhase,
    effects: InlineAppleAppendEffectsPlan?,
    onTextUnitActivation: InlineTextUnitActivationHandler?
  ) {
    self._session = ObservedObject(wrappedValue: session)
    self.viewport = viewport
    self.phase = phase
    self.material = material
    self.color = color
    self.materialResources = materialResources
    self.motion = motion
    self.motionPhase = motionPhase
    self.effects = effects
    self.onTextUnitActivation = onTextUnitActivation
  }

  public var body: some View {
    let visibleSections = session.visibleSections(for: viewport)
    Group {
      if let effects, !session.isCurrent(effects: effects) {
        Text("Append effects are stale")
          .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
      } else {
        Canvas { context, _ in
          if let effects, let highlight = effects.highlight {
            InlineAppleAppendPainter.drawHighlight(highlight, viewport: viewport, in: &context)
          }
          context.translateBy(x: -viewport.x, y: -viewport.y)
          for section in visibleSections {
            for chunk in section.chunks {
              guard let reveal = section.revealByChunkID[chunk.id] else {
                preconditionFailure("validated append reveal payload was not retained")
              }
              let positioned = chunk.positioned
              let expressive = motion.sampleValidated(
                phase: motionPhase,
                atomIndex: inlineAppleMotionOrdinal(
                  atomID: positioned.atomID, in: session.atomOrdinalByID),
                atomCount: session.atomOrdinalByID.count,
                atomHeight: positioned.height,
                atomID: positioned.atomID,
                reduceMotion: accessibilityReduceMotion
              )
              var chunkContext = context
              inlineAppleApplyMotion(expressive, positioned: positioned, in: &chunkContext)
              let originY =
                positioned.baselineY - positioned.metrics.baselineOffset
                - positioned.metrics.ascent
              chunkContext.translateBy(x: positioned.originX, y: originY)
              InlineAppleAppendPainter.draw(
                chunk: chunk,
                reveal: reveal,
                totalDuration: session.revealDuration,
                phase: phase,
                material: material,
                resources: materialResources,
                color: color,
                materialSegments: section.materialSegmentsByChunkID[chunk.id],
                effects: effects,
                in: &chunkContext)
            }
          }
        }
      }
    }
    .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    .clipped()
    .accessibilityRepresentation {
      if let effects, session.isCurrent(effects: effects) {
        InlineAppleAccessibilityRepresentation(
          projection: effects.accessibility,
          atomLabels: effects.accessibilityAtomLabels,
          onTextUnitActivation: onTextUnitActivation)
      } else if effects != nil {
        Text("Append effects are stale")
      } else {
        InlineSwiftUIAppendAccessibilityView(session: session)
      }
    }
  }

  public func hitTest(at layoutPoint: InlineHitPoint) -> InlineHitResult? {
    session.hitTest(at: layoutPoint)
  }

  public func hitTest(atViewportPoint point: InlineHitPoint) -> InlineHitResult {
    guard let layoutPoint = viewport.layoutPoint(fromLocal: point) else { return .none }
    return session.hitTest(at: layoutPoint) ?? .none
  }

  /// Performs the shared viewport hit test and emits only a word activation.
  /// Selection ownership remains with the host callback consumer.
  @discardableResult
  public func activate(atViewportPoint point: InlineHitPoint) -> InlineHitResult {
    let result = hitTest(atViewportPoint: point)
    if case .textUnit(let word) = result { onTextUnitActivation?(word) }
    return result
  }

  package var effectsPlanForTesting: InlineAppleAppendEffectsPlan? { effects }

}

private struct InlineSwiftUIAppendAccessibilityView<Provider: InlineAssetGeometryProvider>: View {
  let session: InlineAppleAppendSession<Provider>

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(session.accessibilityEntries) { entry in
        Text(entry.text).accessibilityHidden(entry.isDecorative)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
