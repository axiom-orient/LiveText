#if os(iOS)
import SwiftUI

@MainActor
public struct DustView: View {
  private let source: DustSource
  private let progress: CGFloat
  private let preset: DustPreset
  private let configuration: DustConfiguration
  private let transition: DustTransition
  private let layoutPolicy: DustLayoutPolicy
  private let onFailure: (@MainActor (DustRenderingError) -> Void)?
  private let onPresented: (@MainActor () -> Void)?

  public init(
    source: DustSource,
    progress: CGFloat,
    preset: DustPreset = .softDust,
    configuration: DustConfiguration = .default,
    transition: DustTransition = .disintegrate,
    layoutPolicy: DustLayoutPolicy = .sourceBounds,
    onFailure: (@MainActor (DustRenderingError) -> Void)? = nil,
    onPresented: (@MainActor () -> Void)? = nil
  ) {
    self.source = source
    self.progress = progress.isFinite ? min(max(progress, 0), 1) : 0
    self.preset = preset
    self.configuration = configuration
    self.transition = transition
    self.layoutPolicy = layoutPolicy
    self.onFailure = onFailure
    self.onPresented = onPresented
  }

  public var body: some View {
    let profile = DustMotionProfile.resolve(preset: preset, configuration: configuration)
    let maximumGrid = DustParticleGridPlanner.makeGrid(
      textureWidth: source.raster.alphaMask.width,
      textureHeight: source.raster.alphaMask.height,
      requestedCellSize: max(Float(configuration.particleSize * source.raster.scale), 1),
      maximumCount: configuration.maximumParticleCount
    )
    let maximumParticleExtent =
      CGFloat(maximumGrid.cellSize) / max(source.raster.scale, 1)
      * sqrt(2) / 2
    let padding = profile.renderPadding(particleExtent: maximumParticleExtent)
    let effectWidth = source.size.width + padding * 2
    let effectHeight = source.size.height + padding * 2

    let metalSurface = DustMetalView(
      raster: source.raster,
      progress: Float(progress),
      preset: preset,
      configuration: configuration,
      transition: transition,
      onFailure: onFailure,
      onPresented: onPresented
    )
    .frame(width: effectWidth, height: effectHeight)
    .allowsHitTesting(false)
    .accessibilityHidden(true)

    let content = Group {
      switch layoutPolicy {
      case .sourceBounds:
        Color.clear
          .frame(width: source.size.width, height: source.size.height)
          .overlay { metalSurface }
      case .effectBounds:
        metalSurface
          .frame(width: effectWidth, height: effectHeight)
      }
    }

    if let label = source.semanticLabel, !label.isEmpty {
      content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    } else {
      content
    }
  }
}
#endif
