import LiveTextAppleRendering
import LiveTextCanvas
import LiveTextEffects
import LiveTextLayout
import LiveTextSwiftUI
import SwiftUI

/// The smallest layout contract needed to turn an `InlineDocument` into
/// renderer-ready LiveText content.
///
/// This configuration intentionally contains layout inputs only. Clocks,
/// reveal progress, material selection, and motion remain presentation-owned
/// values supplied to a renderer after the scene is prepared.
public struct InlineLiveTextLayoutConfiguration: Sendable, Hashable {
  public let width: Double
  public let leading: Double
  public let revision: UInt64
  public let oversizedVectorPolicy: InlineOversizedVectorPolicy
  public let magazineStyle: InlineMagazineStyle

  public init(
    width: Double,
    leading: Double = 0,
    revision: UInt64 = 0,
    oversizedVectorPolicy: InlineOversizedVectorPolicy = .reject,
    magazineStyle: InlineMagazineStyle = .standard
  ) throws {
    guard width.isFinite, width >= 0 else {
      throw InlineLayoutError.invalidWidth(width)
    }
    guard leading.isFinite, leading >= 0 else {
      throw InlineLayoutError.invalidMetric(name: "leading", value: leading)
    }
    self.width = width
    self.leading = leading
    self.revision = revision
    self.oversizedVectorPolicy = oversizedVectorPolicy
    self.magazineStyle = magazineStyle
  }
}

/// Prepared, laid-out, and renderer-projected LiveText content.
///
/// `InlineLiveTextScene` removes the repeated preparation → layout → render
/// wiring from common SwiftUI callers while retaining each intermediate value
/// for advanced consumers. The scene is immutable: changing width or document
/// content creates a new scene, while changing phase, material, or motion
/// only creates a new renderer projection.
@MainActor
public struct InlineLiveTextScene<Provider: InlineAssetGeometryProvider> {
  public let document: InlineDocument
  public let prepared: PreparedInlineDocument
  public let layout: InlineLayoutResult
  public let plan: InlineRenderPlan
  public let viewport: InlineRenderViewport
  public let schedule: InlineRenderRevealSchedule
  public let swiftUIContent: InlineSwiftUIRenderContent
  public let canvasContent: InlineCanvasRenderContent

  public var animationDuration: Double { schedule.duration }

  public init(
    document: InlineDocument,
    assets: Provider,
    registry: InlineAssetRegistry = .empty,
    configuration: InlineLiveTextLayoutConfiguration,
    preparation: InlinePreparation? = nil,
    foregroundColor: Color = .primary,
    composition: InlineSVGCompositionPlan? = nil
  ) throws {
    let resolvedPreparation = preparation ?? InlinePreparation()
    let prepared = try resolvedPreparation.prepare(document: document)
    let engine = try InlineLayoutEngine(
      leading: configuration.leading,
      oversizedVectorPolicy: configuration.oversizedVectorPolicy)
    let flow = try InlineFlowRegion(
      rect: try InlineFlowRect(
        x: 0,
        y: 0,
        width: configuration.width,
        height: Double.greatestFiniteMagnitude
      ),
      revision: configuration.revision,
      magazineStyle: configuration.magazineStyle
    )
    let layout = try engine.layout(prepared: prepared, flow: flow)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)

    // Resolve the provider before publishing any renderer content. This keeps
    // missing vector geometry a typed construction failure instead of a
    // placeholder success.
    let resolvedAssets = try resolveInlineAssets(
      document: document,
      registry: registry,
      provider: assets)
    let schedule = try InlineRenderRevealSchedule(
      plan: plan,
      assets: resolvedAssets)
    let viewport = try InlineRenderViewport(
      x: 0,
      y: 0,
      width: max(1, layout.width),
      height: max(1, layout.height)
    )
    let swiftUIContent = try InlineSwiftUIRenderContent(
      plan: plan,
      assets: assets,
      registry: registry,
      schedule: schedule,
      foregroundColor: foregroundColor,
      composition: composition)
    let canvasContent = try InlineCanvasRenderContent(
      plan: plan,
      assets: assets,
      registry: registry,
      schedule: schedule,
      foregroundColor: foregroundColor,
      composition: composition)

    self.document = document
    self.prepared = prepared
    self.layout = layout
    self.plan = plan
    self.viewport = viewport
    self.schedule = schedule
    self.swiftUIContent = swiftUIContent
    self.canvasContent = canvasContent
  }

  /// Validates and returns a renderer phase for a UI binding or animation
  /// driver. Invalid external progress is rejected instead of silently
  /// clamped.
  public func phase(for progress: Double) throws -> InlineRenderRevealPhase {
    try InlineRenderRevealPhase(rawValue: progress)
  }

  public func renderer(
    phase: InlineRenderRevealPhase = .complete,
    material: InlineRendererMaterial = .none,
    writingColor: Color? = nil,
    onTextUnitActivation: InlineTextUnitActivationHandler? = nil
  ) -> InlineSwiftUIRenderer {
    InlineSwiftUIRenderer(
      content: swiftUIContent,
      phase: phase,
      viewport: viewport,
      material: material,
      writingColor: writingColor,
      onTextUnitActivation: onTextUnitActivation)
  }

  public func writingRenderer(
    phase: InlineRenderRevealPhase = .complete,
    configuration: InlineWritingConfiguration = .default
  ) -> LiveTextWritingRenderer {
    LiveTextWritingRenderer(
      content: swiftUIContent,
      phase: phase,
      viewport: viewport,
      configuration: configuration)
  }

  public func canvasRenderer(
    phase: InlineRenderRevealPhase = .complete,
    material: InlineRendererMaterial = .none,
    writingColor: Color? = nil
  ) -> InlineCanvasRenderer {
    InlineCanvasRenderer(
      content: canvasContent,
      phase: phase,
      viewport: viewport,
      material: material,
      writingColor: writingColor)
  }
}
