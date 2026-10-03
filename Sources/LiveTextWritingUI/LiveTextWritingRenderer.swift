import LiveTextEffects
import LiveTextLayout
import LiveTextSwiftUI
import SwiftUI

@MainActor
public struct LiveTextWritingRenderer: View {
  private let base: InlineSwiftUIRenderer
  public init(
    content: InlineSwiftUIRenderContent,
    phase: InlineRenderRevealPhase = .complete,
    viewport: InlineRenderViewport,
    configuration: InlineWritingConfiguration = .default,
  ) {
    self.base = InlineSwiftUIRenderer(
      content: content,
      phase: phase,
      viewport: viewport,
      material: configuration.effect,
      writingColor: configuration.color.map {
        Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha)
      }
    )
  }

  /// Writing renderer with presentation-only expressive motion. `motionPhase`
  /// is host-owned and independent of handwriting reveal progress.
  public init(
    content: InlineSwiftUIRenderContent,
    phase: InlineRenderRevealPhase = .complete,
    viewport: InlineRenderViewport,
    configuration: InlineWritingConfiguration = .default,
    motion: InlineMotionConfiguration,
    motionPhase: InlineMotionPhase
  ) {
    self.base = InlineSwiftUIRenderer(
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
  public func hitTest(_ point: InlineHitPoint) -> InlineHitResult { base.hitTest(point) }
}
