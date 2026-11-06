import ChalkLineEffects
import CoreGraphics
import Foundation
import ImageIO
import LiveTextApple
import LiveTextSVG
import LiveTextWritingUI
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Geometry resolution stays boring on purpose: every SVG source is prepared
/// before a renderer is mounted, and renderers only receive an immutable
/// provider plus an immutable registry.
struct SampleGeometryProvider: InlineAssetGeometryProvider, Sendable {
  let geometries: [InlineAssetKey: InlineSVGAsset]

  func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
    let key = InlineAssetKey(id: assetID, version: version)
    guard let asset = geometries[key] else {
      throw InlineAssetResolutionError.missingGeometry(assetID, version: version)
    }
    return asset
  }
}

/// Every sample flow shares one catalog: an inline image, a filled vector
/// mask, and an open-stroke spark. Every asset goes through the same public
/// adapters a product would use.
struct SampleAssetCatalog {
  let provider: SampleGeometryProvider
  let registry: InlineAssetRegistry
  let thumbnail: InlineEncodedImageAsset
  let thumbnailImage: UIImage
  let spark: InlineSVGAsset
  let leaf: InlineSVGAsset
}

enum SampleAssetError: Error, LocalizedError {
  case emptyThumbnail
  case thumbnailColorSpaceUnavailable
  case thumbnailRasterizationFailed
  case thumbnailEncodingFailed
  case invalidThumbnail
  case emptySVGSource(String)

  var errorDescription: String? {
    switch self {
    case .emptyThumbnail: return "The thumbnail PNG encoder returned no bytes."
    case .thumbnailColorSpaceUnavailable:
      return "The named sRGB color space could not be created."
    case .thumbnailRasterizationFailed:
      return "The thumbnail bitmap context could not be created."
    case .thumbnailEncodingFailed:
      return "The thumbnail PNG destination could not be finalized."
    case .invalidThumbnail:
      return "The generated thumbnail PNG could not be decoded."
    case .emptySVGSource(let id): return "The SVG adapter produced no asset for '\(id)'."
    }
  }
}

enum SampleSetupValidationError: Error, LocalizedError {
  case missingCapability(String)

  var errorDescription: String? {
    switch self {
    case .missingCapability(let capability):
      return "The sample did not prepare its required '\(capability)' capability."
    }
  }
}

/// Host-owned placement state for the two external controls in the compose
/// host composition. The reducer is pure; rebuilding a bundle is the effect
/// that publishes the next immutable layout/render input.
enum SampleCompositionPosition: String, CaseIterable, Identifiable {
  case upperRight
  case lowerLeft

  var id: String { rawValue }

  var title: String {
    switch self {
    case .upperRight: return "upper right"
    case .lowerLeft: return "lower left"
    }
  }

  func applying(_ event: SampleCompositionPositionEvent) -> SampleCompositionPosition {
    switch event {
    case .toggle:
      return self == .upperRight ? .lowerLeft : .upperRight
    case .set(let position):
      return position
    }
  }
}

enum SampleCompositionPositionEvent {
  case toggle
  case set(SampleCompositionPosition)
}

enum SampleCompositionLayoutMode: String, CaseIterable, Identifiable {
  case inline
  case magazine

  var id: String { rawValue }

  var title: String {
    switch self {
    case .inline: return "Inline"
    case .magazine: return "Magazine"
    }
  }
}

enum SampleMagazineLayout {
  static let viewportWidth: Double = 276
  static let mediaWidth: Double = 72
  static let mediaHeight: Double = 128
  static let mediaGap: Double = 8
  static let minimumTextWidth: Double = 104
}

enum SampleSVGMode: String, CaseIterable, Identifiable {
  case artwork
  case mask
  case combined

  var id: String { rawValue }

  var title: String {
    switch self {
    case .artwork: return "Artwork"
    case .mask: return "Erase mask"
    case .combined: return "Combined"
    }
  }
}

struct SampleCompositionPlacement {
  let photo: InlineFlowRect
  let button: InlineFlowRect
}

/// One prepared document plus everything both static renderers need to draw
/// it: one immutable plan, one reveal schedule, one viewport, one content
/// value per adapter sharing the same geometry.
@MainActor
struct SampleRenderBundle {
  let swiftUI: InlineSwiftUIRenderContent
  let canvas: InlineCanvasRenderContent
  let plan: InlineRenderPlan
  let layout: InlineLayoutResult
  let schedule: InlineRenderRevealSchedule
  let viewport: InlineRenderViewport
  let documentText: String
  let composition: InlineSVGCompositionPlan?
  let photoExclusion: InlineFlowRect?
  let buttonExclusion: InlineFlowRect?
  let magazineMinimumXMedia: InlineFlowRect?
  let magazineMaximumXMedia: InlineFlowRect?
  let thumbnail: UIImage?
  let demoTextUnit: InlineTextUnitHit
}

@MainActor
@Observable
final class SampleModel {
  /// Each item is already one complete semantic atom. The append reducer never
  /// receives partial UTF-8 or partial graphemes.
  static let streamAtoms: [String?] = [
    "LiveText prepares", "text, images,", "and vectors once",
    "and lays them out", "with one immutable result.",
    "그리디 줄바꿈은", "폭을 알 때만", "다시 계산됩니다.",
    nil,
    "A stream commits lines", "and replaces only", "the mutable tail.",
  ]

  private(set) var compositionBundle: SampleRenderBundle?
  private(set) var magazineCompositionBundle: SampleRenderBundle?
  private(set) var writingBundle: SampleRenderBundle?
  private(set) var svgBundles: [SampleSVGMode: SampleRenderBundle] = [:]
  private(set) var setupError: String?
  private(set) var compositionPosition: SampleCompositionPosition = .upperRight
  private(set) var stream: SampleStream?

  /// Reused for width-only relayout. Preparation remains authoritative.
  private var preparedCatalog: SampleAssetCatalog?
  private var preparedWritingFace: ChalkInlineWritingFace?

  init() {
    setup()
  }

  /// Builds every feature before publishing any of them. A failed attempt
  /// leaves no partial sample state and can be repeated from the error view.
  func retrySetup() {
    setup()
  }

  private func setup() {
    do {
      let (catalog, writingFace) = try preparedInputs()
      let compositionDocument = try Self.makeCompositionDocument(
        catalog: catalog, writingFaceID: writingFace.id)
      let composition = try Self.makeBundle(
        document: compositionDocument,
        catalog: catalog,
        width: SampleMagazineLayout.viewportWidth,
        foregroundColor: .white,
        mode: .composition(position: compositionPosition, layoutMode: .inline),
        writingFace: writingFace)
      let magazineComposition = try Self.makeBundle(
        document: compositionDocument,
        catalog: catalog,
        width: SampleMagazineLayout.viewportWidth,
        foregroundColor: .white,
        mode: .composition(position: compositionPosition, layoutMode: .magazine),
        writingFace: writingFace)
      let writing = try Self.makeWritingBundle(
        document: try Self.makeWritingDocument(writingFaceID: writingFace.id),
        catalog: catalog,
        writingFace: writingFace)
      let svgDocument = try Self.makeSVGDocument(
        catalog: catalog, writingFaceID: writingFace.id)
      var svg: [SampleSVGMode: SampleRenderBundle] = [:]
      for mode in SampleSVGMode.allCases {
        svg[mode] = try Self.makeBundle(
          document: svgDocument,
          catalog: catalog,
          width: 320,
          foregroundColor: .white,
          mode: .svg(mode),
          writingFace: writingFace)
      }
      let stream = try Self.makeStream(catalog: catalog)
      try Self.validate(
        composition: composition,
        magazineComposition: magazineComposition,
        writing: writing,
        svg: svg,
        stream: stream)

      compositionBundle = composition
      magazineCompositionBundle = magazineComposition
      writingBundle = writing
      svgBundles = svg
      preparedCatalog = catalog
      preparedWritingFace = writingFace
      self.stream = stream
      setupError = nil
    } catch {
      compositionBundle = nil
      magazineCompositionBundle = nil
      writingBundle = nil
      svgBundles = [:]
      preparedCatalog = nil
      preparedWritingFace = nil
      stream = nil
      setupError = Self.errorMessage(for: error)
    }
  }

  /// Reflows the already-prepared handwriting document for a new viewport width.
  ///
  /// Preparation and reveal identity stay authoritative and width-independent. Only layout,
  /// render projection, and viewport are rebuilt. This is the canonical resize path used by
  /// responsive rendering while animation progress continues unchanged.
  @MainActor
  func reflowWritingBundle(width: Double) throws -> SampleRenderBundle {
    guard width.isFinite, width >= 80 else {
      throw InlineLayoutError.invalidMetric(name: "sample writing width", value: width)
    }
    guard let base = writingBundle, let catalog = preparedCatalog else {
      throw SampleSetupValidationError.missingCapability("responsive-writing-source")
    }

    let prepared = base.plan.prepared
    let flow = try InlineFlowRegion(
      rect: try InlineFlowRect(x: 0, y: 0, width: width, height: 520),
      revision: width.bitPattern
    )
    let layout = try InlineLayoutEngine(leading: 5).layout(prepared: prepared, flow: flow)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
    guard let demoTextUnit = Self.firstTextUnitHit(in: plan) else {
      throw SampleSetupValidationError.missingCapability("selection")
    }

    let foregroundColor = Color(red: 0.98, green: 0.96, blue: 0.90)
    return SampleRenderBundle(
      swiftUI: try InlineSwiftUIRenderContent(
        plan: plan, assets: catalog.provider, registry: catalog.registry,
        schedule: base.schedule, foregroundColor: foregroundColor),
      canvas: try InlineCanvasRenderContent(
        plan: plan, assets: catalog.provider, registry: catalog.registry,
        schedule: base.schedule, foregroundColor: foregroundColor),
      plan: plan,
      layout: layout,
      schedule: base.schedule,
      viewport: viewport,
      documentText: base.documentText,
      composition: nil,
      photoExclusion: nil,
      buttonExclusion: nil,
      magazineMinimumXMedia: nil,
      magazineMaximumXMedia: nil,
      thumbnail: nil,
      demoTextUnit: demoTextUnit
    )
  }

  // MARK: Stream (append session)

  /// The append page owns exactly one session at a time. The reducer owns
  /// domain append state; the session coordinates Apple projection publishing.
  @MainActor
  final class SampleStream: ObservableObject {
    let streamID: UUID
    let session: InlineAppleAppendSession<SampleGeometryProvider>
    @Published private(set) var pending: [InlineAtom]
    @Published private(set) var isFinished = false
    @Published private(set) var lastError: String?

    init(
      streamID: UUID,
      session: InlineAppleAppendSession<SampleGeometryProvider>,
      pending: [InlineAtom]
    ) {
      self.streamID = streamID
      self.session = session
      self.pending = pending
    }

    var headline: String {
      let snapshot = session.snapshot
      let revision = String(snapshot.revision.prefix(8))
      return
        "seq \(snapshot.nextSequence) · rev \(revision) · lines \(snapshot.committedLineCount) + tail \(snapshot.tailLineCount)"
    }

    /// Sends the next sealed atom, or `finish` once the queue is drained.
    /// A typed failure is reported and leaves the session state unchanged.
    func sendNext() {
      guard !isFinished else { return }
      do {
        let event: InlineAppendEvent
        if let atom = pending.first {
          event = .append(
            InlineAppendBatch(
              streamID: streamID,
              sequence: session.snapshot.nextSequence,
              baseRevision: session.snapshot.revision,
              atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: atom)]))
        } else {
          event = .finish(
            streamID: streamID,
            sequence: session.snapshot.nextSequence,
            baseRevision: session.snapshot.revision)
        }
        _ = try session.send(event)
        if pending.isEmpty {
          isFinished = true
        } else {
          pending.removeFirst()
        }
        lastError = nil
      } catch {
        lastError = String(describing: error)
      }
    }

    func reportReplayError(_ error: Error) {
      lastError = String(describing: error)
    }
  }

  func restartStream() {
    do {
      let (catalog, _) = try preparedInputs()
      let candidate = try Self.makeStream(catalog: catalog)
      guard let compositionBundle, let magazineCompositionBundle, let writingBundle else {
        throw SampleSetupValidationError.missingCapability("prepared-bundles")
      }
      try Self.validate(
        composition: compositionBundle,
        magazineComposition: magazineCompositionBundle,
        writing: writingBundle,
        svg: svgBundles,
        stream: candidate)
      stream = candidate
      setupError = nil
    } catch {
      setupError = "stream.restart: \(Self.errorMessage(for: error))"
    }
  }

  /// Applies a host event and publishes a complete replacement bundle only
  /// after preparation, layout, composition, and both adapter contents have
  /// succeeded. A failed rebuild leaves the current position and bundle
  /// untouched and preserves the operation/cause in `setupError`.
  func applyCompositionPosition(_ event: SampleCompositionPositionEvent) {
    let nextPosition = compositionPosition.applying(event)
    do {
      let (catalog, writingFace) = try preparedInputs()
      let document = try Self.makeCompositionDocument(
        catalog: catalog, writingFaceID: writingFace.id)
      let nextBundle = try Self.makeBundle(
        document: document,
        catalog: catalog,
        width: SampleMagazineLayout.viewportWidth,
        foregroundColor: .white,
        mode: .composition(position: nextPosition, layoutMode: .inline),
        writingFace: writingFace)
      let nextMagazineBundle = try Self.makeBundle(
        document: document,
        catalog: catalog,
        width: SampleMagazineLayout.viewportWidth,
        foregroundColor: .white,
        mode: .composition(position: nextPosition, layoutMode: .magazine),
        writingFace: writingFace)
      guard let writingBundle, let stream else {
        throw SampleSetupValidationError.missingCapability("prepared-bundles")
      }
      try Self.validate(
        composition: nextBundle,
        magazineComposition: nextMagazineBundle,
        writing: writingBundle,
        svg: svgBundles,
        stream: stream)
      compositionBundle = nextBundle
      magazineCompositionBundle = nextMagazineBundle
      compositionPosition = nextPosition
      preparedCatalog = catalog
      setupError = nil
    } catch {
      setupError =
        "composition.rebuild position=\(nextPosition.rawValue): \(Self.errorMessage(for: error))"
    }
  }

  func toggleCompositionPosition() {
    applyCompositionPosition(.toggle)
  }

  func compositionBundle(for layoutMode: SampleCompositionLayoutMode) -> SampleRenderBundle? {
    switch layoutMode {
    case .inline: return compositionBundle
    case .magazine: return magazineCompositionBundle
    }
  }

  func svgBundle(for mode: SampleSVGMode) -> SampleRenderBundle? {
    svgBundles[mode]
  }

  private static func validate(
    composition: SampleRenderBundle,
    magazineComposition: SampleRenderBundle,
    writing: SampleRenderBundle,
    svg: [SampleSVGMode: SampleRenderBundle],
    stream: SampleStream
  ) throws {
    let bundles =
      [composition, magazineComposition, writing]
      + SampleSVGMode.allCases.compactMap { svg[$0] }
    guard bundles.allSatisfy({ !$0.layout.lines.isEmpty && !$0.plan.geometry.isEmpty }) else {
      throw SampleSetupValidationError.missingCapability("layout")
    }
    guard composition.plan.prepared.totalImageAtoms > 0,
      composition.photoExclusion != nil,
      composition.buttonExclusion != nil
    else {
      throw SampleSetupValidationError.missingCapability("mixed-inline-flow")
    }
    guard magazineComposition.magazineMinimumXMedia != nil,
      magazineComposition.magazineMaximumXMedia != nil,
      magazineComposition.layout.lines.count > 1
    else {
      throw SampleSetupValidationError.missingCapability("magazine-flow")
    }
    guard writing.plan.prepared.atoms.contains(where: { atom in
      guard case .text(let text) = atom else { return false }
      return text.writingUnits.contains { unit in
        if case .semanticStroke = unit.kind { return true }
        return false
      }
    }) else {
      throw SampleSetupValidationError.missingCapability("handwriting")
    }
    guard svg[.artwork]?.composition?.instances.map(\.role) == [.artwork],
      svg[.mask]?.composition?.instances.first?.role == .mask,
      Set(svg[.combined]?.composition?.instances.map(\.role) ?? []) == Set([.artwork, .mask])
    else {
      throw SampleSetupValidationError.missingCapability("svg-composition")
    }
    guard !stream.pending.isEmpty else {
      throw SampleSetupValidationError.missingCapability("append-stream")
    }
    for bundle in bundles {
      _ = try InlineSwiftUIRenderer(
        validating: bundle.swiftUI, phase: .complete, viewport: bundle.viewport)
      _ = try InlineCanvasRenderer(
        validating: bundle.canvas, phase: .complete, viewport: bundle.viewport)
    }
  }

  private static func firstTextUnitHit(in plan: InlineRenderPlan) -> InlineTextUnitHit? {
    for line in plan.layout.lines {
      for positioned in line.atoms where positioned.kind == .text && positioned.width > 0 {
        let y =
          positioned.baselineY - positioned.metrics.baselineOffset
          - positioned.metrics.ascent + positioned.height / 2
        var x = positioned.originX + 0.5
        while x < positioned.originX + positioned.width {
          guard let point = try? InlineHitPoint(x: x, y: y) else { break }
          if case .textUnit(let unit) = plan.hitIndex.hitTest(point) { return unit }
          x += 2
        }
      }
    }
    return nil
  }

  private static func errorMessage(for error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
      return description
    }
    return String(describing: error)
  }

  // MARK: Document and bundle construction

  private enum SampleBundleMode {
    case writing
    case composition(position: SampleCompositionPosition, layoutMode: SampleCompositionLayoutMode)
    case svg(SampleSVGMode)
  }

  private static func makeCompositionDocument(
    catalog: SampleAssetCatalog,
    writingFaceID: String
  ) throws -> InlineDocument {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 20),
      tracking: 0.1,
      revealMode: .handwriting(faceID: writingFaceID))
    let emojiStyle = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "AppleColorEmoji", pointSize: 22))
    return try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "intro", text: "한글 LiveText: ", style: style)),
      .image(
        InlineImageAtom(
          id: "thumbnail", asset: catalog.thumbnail, presentation: .thumbnail,
          accessibilityLabel: "A small mountain thumbnail")),
      .text(InlineTextAtom(id: "middle", text: " color stays native ", style: style)),
      .text(InlineTextAtom(id: "emoji", text: "✨", style: emojiStyle)),
      .text(InlineTextAtom(id: "vector-lead", text: " plus SVG ", style: style)),
      .vector(InlineVectorAtom(id: "spark", asset: catalog.spark)),
      .text(InlineTextAtom(id: "outro", text: " artwork, all in view.", style: style)),
    ])
  }

  private static func makeWritingDocument(
    writingFaceID: String
  ) throws -> InlineDocument {
    let writingStyle = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 31),
      tracking: 0.2,
      revealMode: .handwriting(faceID: writingFaceID))
    // CoreText keeps the precomposed syllable intact. The surrounding copy
    // remains stroke-animated, while this known mixed-vowel syllable avoids
    // showing its ㅎ/ㅚ/ㄱ composition as separate marks in the sample.
    let nativeKoreanStyle = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 31),
      tracking: 0.2)
    return try InlineDocument(atoms: [
      .text(InlineTextAtom(
        id: "writing-message-prefix", text: SampleCopy.writingKoreanPrefix, style: writingStyle)),
      .text(InlineTextAtom(
        id: "writing-message-glyph", text: SampleCopy.writingKoreanGlyph, style: nativeKoreanStyle)),
      .text(InlineTextAtom(
        id: "writing-message-suffix",
        text: SampleCopy.writingKoreanSuffix + "\n",
        style: writingStyle)),
      .text(InlineTextAtom(
        id: "writing-message-english",
        text: SampleCopy.writingEnglishMessage,
        style: writingStyle)),
    ])
  }

  private static func makeSVGDocument(
    catalog: SampleAssetCatalog,
    writingFaceID: String
  ) throws -> InlineDocument {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 26),
      tracking: 0.15,
      revealMode: .handwriting(faceID: writingFaceID))
    return try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "intro", text: "SVG 글씨 ", style: style)),
      .image(
        InlineImageAtom(
          id: "thumbnail",
          asset: catalog.thumbnail,
          presentation: .thumbnail,
          accessibilityLabel: "Color image used as an erase-mask target")),
      .text(InlineTextAtom(id: "vector-lead", text: " artwork ", style: style)),
      .vector(InlineVectorAtom(id: "spark", asset: catalog.spark)),
      .text(InlineTextAtom(id: "outro", text: "를 쓰며 사진을 지웁니다.", style: style)),
    ])
  }

  private static func makeBundle(
    document: InlineDocument,
    catalog: SampleAssetCatalog,
    width: Double,
    foregroundColor: Color,
    mode: SampleBundleMode,
    writingFace: ChalkInlineWritingFace
  ) throws -> SampleRenderBundle {
    let writingFaces = try InlineWritingFaceStore(faces: [writingFace])
    let prepared = try InlinePreparation(writingFaceStore: writingFaces).prepare(document: document)
    let engine = try InlineLayoutEngine(leading: 5)
    let placement: SampleCompositionPlacement?
    let magazineStyle: InlineMagazineStyle?
    switch mode {
    case .composition(let position, .inline):
      placement = try compositionPlacement(position: position, width: width)
      magazineStyle = nil
    case .composition(_, .magazine):
      placement = nil
      magazineStyle = try sampleMagazineStyle(width: width)
    case .writing, .svg:
      placement = nil
      magazineStyle = nil
    }
    let exclusions: [InlineFlowExclusion]
    if let placement {
      exclusions = [
        try InlineFlowExclusion(
          id: "photo-exclusion",
          rect: placement.photo,
          insets: try InlineFlowInsets(top: 3, leading: 3, bottom: 3, trailing: 3)),
        try InlineFlowExclusion(
          id: "button-exclusion",
          rect: placement.button),
      ]
    } else {
      exclusions = []
    }
    let flowRect = try InlineFlowRect(x: 0, y: 0, width: width, height: 520)
    let flow: InlineFlowRegion
    if let magazineStyle {
      flow = try InlineFlowRegion(
        rect: flowRect,
        exclusions: exclusions,
        revision: 1,
        layoutStyle: .magazine(magazineStyle))
    } else {
      flow = try InlineFlowRegion(
        rect: flowRect,
        exclusions: exclusions,
        revision: 1)
    }
    let layout = try engine.layout(prepared: prepared, flow: flow)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let composition = try compositionPlan(
      mode: mode, prepared: prepared, catalog: catalog)
    let textPlan = try InlineRevealPlanBuilder(secondsPerUnit: 0.035)
      .textPlan(prepared: prepared)
    let imagePlan = try InlineRevealPlanBuilder(secondsPerUnit: 0.08)
      .imagePlan(prepared: prepared)
    var vectorPlans: [String: InlinePathRevealPlan] = [:]
    for atom in document.atoms {
      guard case .vector(let vector) = atom else { continue }
      let key = InlineAssetKey(id: vector.assetID, version: vector.assetVersion)
      guard let asset = catalog.provider.geometries[key] else { continue }
      vectorPlans[vector.id] = try InlinePathRevealPlanBuilder(secondsPerUnit: 0.055)
        .plan(asset: asset)
    }
    let schedule = try InlineRenderRevealSchedule(
      plan: plan,
      assets: InlineAssetStore(values: catalog.provider.geometries),
      textPlan: textPlan,
      vectorPlans: vectorPlans,
      imagePlan: imagePlan)
    let viewport = try InlineRenderViewport(
      x: 0, y: 0, width: max(1, layout.width), height: max(1, layout.height))
    let documentText = document.atoms.reduce(into: "") { text, atom in
      if case .text(let value) = atom { text += value.text }
    }
    guard let demoTextUnit = firstTextUnitHit(in: plan) else {
      throw SampleSetupValidationError.missingCapability("selection")
    }
    return SampleRenderBundle(
      swiftUI: try InlineSwiftUIRenderContent(
        plan: plan, assets: catalog.provider, registry: catalog.registry,
        schedule: schedule, foregroundColor: foregroundColor,
        composition: composition),
      canvas: try InlineCanvasRenderContent(
        plan: plan, assets: catalog.provider, registry: catalog.registry,
        schedule: schedule, foregroundColor: foregroundColor,
        composition: composition),
      plan: plan,
      layout: layout,
      schedule: schedule,
      viewport: viewport,
      documentText: documentText,
      composition: composition,
      photoExclusion: placement?.photo,
      buttonExclusion: placement?.button,
      magazineMinimumXMedia: magazineStyle?.minimumXMedia.first?.rect,
      magazineMaximumXMedia: magazineStyle?.maximumXMedia.first?.rect,
      thumbnail: (placement == nil && magazineStyle == nil) ? nil : catalog.thumbnailImage,
      demoTextUnit: demoTextUnit)
  }

  private func preparedInputs() throws -> (SampleAssetCatalog, ChalkInlineWritingFace) {
    if let preparedCatalog, let preparedWritingFace {
      return (preparedCatalog, preparedWritingFace)
    }
    let catalog = try Self.makeCatalog()
    let writingFace = try ChalkInlineWritingFace()
    preparedCatalog = catalog
    preparedWritingFace = writingFace
    return (catalog, writingFace)
  }

  /// Uses the high-level public scene API so the sample also exercises the
  /// shortest supported consumer path. The mixed-flow cases below stay on the
  /// explicit assembly path because they intentionally demonstrate exclusions,
  /// magazine layout, and custom reveal plans.
  private static func makeWritingBundle(
    document: InlineDocument,
    catalog: SampleAssetCatalog,
    writingFace: ChalkInlineWritingFace
  ) throws -> SampleRenderBundle {
    let writingFaces = try InlineWritingFaceStore(faces: [writingFace])
    let scene = try InlineLiveTextScene(
      document: document,
      assets: catalog.provider,
      configuration: try InlineLiveTextLayoutConfiguration(
        width: 320,
        leading: 5,
        revision: 1),
      preparation: InlinePreparation(writingFaceStore: writingFaces),
      foregroundColor: .white)
    guard let demoTextUnit = firstTextUnitHit(in: scene.plan) else {
      throw SampleSetupValidationError.missingCapability("selection")
    }
    let documentText = document.atoms.reduce(into: "") { text, atom in
      if case .text(let value) = atom { text += value.text }
    }
    return SampleRenderBundle(
      swiftUI: scene.swiftUIContent,
      canvas: scene.canvasContent,
      plan: scene.plan,
      layout: scene.layout,
      schedule: scene.schedule,
      viewport: scene.viewport,
      documentText: documentText,
      composition: nil,
      photoExclusion: nil,
      buttonExclusion: nil,
      magazineMinimumXMedia: nil,
      magazineMaximumXMedia: nil,
      thumbnail: nil,
      demoTextUnit: demoTextUnit)
  }

  private static func compositionPlan(
    mode: SampleBundleMode,
    prepared: PreparedInlineDocument,
    catalog: SampleAssetCatalog
  ) throws -> InlineSVGCompositionPlan? {
    let svgMode: SampleSVGMode
    switch mode {
    case .writing, .composition:
      return nil
    case .svg(let mode):
      svgMode = mode
    }

    var instances: [InlineSVGCompositionInstance] = []
    if svgMode == .artwork || svgMode == .combined {
      instances.append(
        try InlineSVGCompositionInstance(
          instanceID: "spark-artwork",
          assetID: catalog.spark.id,
          assetVersion: catalog.spark.version,
          sourceAtomID: "spark",
          role: .artwork,
          declarationOrder: 0))
    }
    if svgMode == .mask || svgMode == .combined {
      instances.append(
        try InlineSVGCompositionInstance(
          instanceID: "leaf-mask",
          assetID: catalog.leaf.id,
          assetVersion: catalog.leaf.version,
          role: .mask,
          targetID: "thumbnail",
          operation: .erase,
          declarationOrder: instances.count))
    }
    return try InlineSVGCompositionPlan(
      preparationRevision: prepared.revision,
      instances: instances)
  }

  private static func sampleMagazineStyle(width: Double) throws -> InlineMagazineStyle {
    let requiredWidth =
      SampleMagazineLayout.mediaWidth * 2
      + SampleMagazineLayout.mediaGap * 2
      + SampleMagazineLayout.minimumTextWidth
    guard width >= requiredWidth else {
      throw InlineLayoutError.invalidFlowRegion(
        "sample magazine width is too small for its media, gaps, and text")
    }
    let minimumX = try InlineMagazineMedia(
      id: "thumbnail",
      rect: InlineFlowRect(
        x: 0, y: 0,
        width: SampleMagazineLayout.mediaWidth,
        height: SampleMagazineLayout.mediaHeight))
    let maximumX = try InlineMagazineMedia(
      id: "artwork",
      rect: InlineFlowRect(
        x: width - SampleMagazineLayout.mediaWidth, y: 0,
        width: SampleMagazineLayout.mediaWidth,
        height: SampleMagazineLayout.mediaHeight))
    return try InlineMagazineStyle(
      minimumXMedia: [minimumX],
      maximumXMedia: [maximumX],
      mediaGap: SampleMagazineLayout.mediaGap,
      minimumTextWidth: SampleMagazineLayout.minimumTextWidth)
  }

  private static func compositionPlacement(
    position: SampleCompositionPosition,
    width: Double
  ) throws -> SampleCompositionPlacement {
    guard width >= 120 else {
      throw InlineLayoutError.invalidFlowRegion(
        "composition width is too small for its controls")
    }
    switch position {
    case .upperRight:
      return SampleCompositionPlacement(
        photo: try InlineFlowRect(x: width - 82, y: 0, width: 74, height: 70),
        button: try InlineFlowRect(x: 8, y: 84, width: 92, height: 32))
    case .lowerLeft:
      return SampleCompositionPlacement(
        photo: try InlineFlowRect(x: 8, y: 70, width: 74, height: 70),
        button: try InlineFlowRect(x: width - 100, y: 0, width: 92, height: 32))
    }
  }

  private static func makeStream(catalog: SampleAssetCatalog) throws -> SampleStream {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 14))
    var atoms: [InlineAtom] = []
    var textIndex = 0
    for piece in streamAtoms {
      if let piece {
        textIndex += 1
        atoms.append(
          try .text(
            InlineTextAtom(
              id: "stream-\(textIndex)", text: piece, style: style)))
      } else {
        atoms.append(try .vector(InlineVectorAtom(id: "stream-leaf", asset: catalog.leaf)))
      }
    }
    let streamID = UUID()
    let reducer = try InlineAppendReducer(
      streamID: streamID,
      preparation: InlinePreparation(),
      engine: try InlineLayoutEngine(leading: 3),
      width: 244)
    let session = try InlineAppleAppendSession<SampleGeometryProvider>(
      reducer: reducer, assets: catalog.provider, registry: catalog.registry)
    return SampleStream(streamID: streamID, session: session, pending: atoms)
  }

  // MARK: Asset catalog

  private static func makeCatalog() throws -> SampleAssetCatalog {
    let spark = try makeSVGAsset(
      id: "spark",
      width: 26, height: 26,
      path: "M13 0 L16.2 9.8 L26 13 L16.2 16.2 L13 26 L9.8 16.2 L0 13 L9.8 9.8 Z",
      metrics: try InlineMetrics(advance: 26, ascent: 26, descent: 0),
      label: "SVG spark")
    let leaf = try makeSVGAsset(
      id: "leaf",
      width: 22, height: 26,
      path: "M11 0 C18 6 20 12 19 17 C18 22 14 25 11 26 C8 25 4 22 3 17 C2 12 4 6 11 0 Z",
      metrics: try InlineMetrics(advance: 22, ascent: 26, descent: 0),
      label: "SVG leaf")
    let thumbnail = try makeThumbnailAsset()
    guard let thumbnailImage = UIImage(data: thumbnail.encodedBytes) else {
      throw SampleAssetError.invalidThumbnail
    }
    return SampleAssetCatalog(
      provider: SampleGeometryProvider(geometries: [
        InlineAssetKey(id: spark.id, version: spark.version): spark,
        InlineAssetKey(id: leaf.id, version: leaf.version): leaf,
      ]),
      registry: try InlineAssetRegistry(records: [
        InlineAssetRecord(asset: spark),
        InlineAssetRecord(asset: leaf),
        InlineAssetRecord(image: thumbnail),
      ]),
      thumbnail: thumbnail,
      thumbnailImage: thumbnailImage,
      spark: spark,
      leaf: leaf)
  }

  private static func makeSVGAsset(
    id: String,
    width: Double,
    height: Double,
    path: String,
    metrics: InlineMetrics,
    label: String
  ) throws -> InlineSVGAsset {
    let source = """
      <svg width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
        <path id="\(id)" d="\(path)" stroke="black" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
      """
    let document = try LiveTextSVGInlineAdapter.convert(
      source: source,
      id: try InlineAssetID(rawValue: id),
      metrics: metrics,
      version: 1,
      accessibilityLabel: label)
    return document.asset
  }

  private static func makeThumbnailAsset() throws -> InlineEncodedImageAsset {
    let logicalSize = CGSize(width: 60, height: 40)
    let scale = CGFloat(2)
    let pixelWidth = Int(logicalSize.width * scale)
    let pixelHeight = Int(logicalSize.height * scale)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw SampleAssetError.thumbnailColorSpaceUnavailable
    }
    let bitmapInfo =
      CGImageAlphaInfo.premultipliedLast.rawValue
      | CGBitmapInfo.byteOrder32Big.rawValue
    guard
      let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: pixelWidth * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      )
    else {
      throw SampleAssetError.thumbnailRasterizationFailed
    }

    // Keep the sample artwork in logical points while the backing pixels stay
    // fixed at 120x80. The explicit transform matches UIKit's top-left
    // drawing coordinates without consulting device scale or screen state.
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(x: scale, y: -scale)
    context.setFillColor(UIColor(red: 0.09, green: 0.12, blue: 0.22, alpha: 1).cgColor)
    context.fill(CGRect(origin: .zero, size: logicalSize))
    context.setFillColor(UIColor(red: 0.98, green: 0.72, blue: 0.30, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: 40, y: 5, width: 12, height: 12))
    let back = CGMutablePath()
    back.move(to: CGPoint(x: 0, y: 32))
    back.addLine(to: CGPoint(x: 19, y: 14))
    back.addLine(to: CGPoint(x: 36, y: 32))
    back.closeSubpath()
    context.setFillColor(UIColor(red: 0.24, green: 0.58, blue: 0.72, alpha: 1).cgColor)
    context.addPath(back)
    context.fillPath()
    let front = CGMutablePath()
    front.move(to: CGPoint(x: 19, y: 32))
    front.addLine(to: CGPoint(x: 40, y: 18))
    front.addLine(to: CGPoint(x: 60, y: 32))
    front.closeSubpath()
    context.setFillColor(UIColor(red: 0.34, green: 0.78, blue: 0.58, alpha: 1).cgColor)
    context.addPath(front)
    context.fillPath()

    guard let image = context.makeImage() else {
      throw SampleAssetError.thumbnailRasterizationFailed
    }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      throw SampleAssetError.thumbnailEncodingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw SampleAssetError.thumbnailEncodingFailed
    }
    let data = output as Data
    guard !data.isEmpty else { throw SampleAssetError.emptyThumbnail }
    let reference = try InlineImageReference(
      assetID: try InlineAssetID(rawValue: "thumbnail"),
      version: 1,
      data: data)
    return try InlineEncodedImageAsset(
      reference: reference,
      metrics: try InlineMetrics(
        advance: Double(logicalSize.width), ascent: Double(logicalSize.height), descent: 0),
      encoding: .png,
      encodedBytes: data,
      pixelWidth: Int(logicalSize.width * scale),
      pixelHeight: Int(logicalSize.height * scale))
  }
}
