import LiveTextCanvas
import LiveTextEffects
import LiveTextLayout
import SwiftUI

/// Canvas counterpart of `LiveTextWritingRenderer`.
///
/// The underlying immutable render content and hit index are unchanged.
/// Every writing configuration is passed to `InlineCanvasRenderer`, which
/// consumes the same deterministic material plan as the SwiftUI adapter;
/// text, images, accessibility, and hit testing therefore retain their
/// existing semantics.
@MainActor
public struct LiveTextCanvasWritingRenderer: View {
  private let base: InlineCanvasRenderer

  public init(
    content: InlineCanvasRenderContent,
    phase: InlineRenderRevealPhase = .complete,
    viewport: InlineRenderViewport,
    configuration: InlineWritingConfiguration = .default
  ) {
    self.base = InlineCanvasRenderer(
      content: content,
      phase: phase,
      viewport: viewport,
      material: configuration.effect,
      writingColor: configuration.color.map {
        Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha)
      }
    )
  }

  /// Canvas counterpart of the expressive writing renderer.
  public init(
    content: InlineCanvasRenderContent,
    phase: InlineRenderRevealPhase = .complete,
    viewport: InlineRenderViewport,
    configuration: InlineWritingConfiguration = .default,
    motion: InlineMotionConfiguration,
    motionPhase: InlineMotionPhase
  ) {
    self.base = InlineCanvasRenderer(
      content: content,
      phase: phase,
      viewport: viewport,
      material: configuration.effect,
      writingColor: configuration.color.map {
        Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha)
      },
      motion: motion,
      motionPhase: motionPhase
    )
  }

  public var body: some View { base }

  public func hitTest(_ point: InlineHitPoint) -> InlineHitResult {
    base.hitTest(point)
  }

  public func hitTest(atViewportPoint point: InlineHitPoint) -> InlineHitResult {
    base.hitTest(atViewportPoint: point)
  }
}
