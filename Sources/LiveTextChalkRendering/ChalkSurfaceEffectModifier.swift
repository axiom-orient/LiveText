import LiveTextEffects
import SwiftUI

private struct ChalkTextureLayer: View {
  let plan: ChalkPigmentLossLayerPlan

  var body: some View {
    Canvas { context, size in
      context.opacity = min(1, max(0, plan.opacity))
      if let alphaThreshold = plan.alphaThreshold {
        context.addFilter(.alphaThreshold(min: alphaThreshold, color: .white))
      }
      context.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .tiledImage(
          ChalkRenderResources.surfaceImage(for: plan.textureStyle),
          origin: CGPoint(x: CGFloat(plan.phaseX), y: CGFloat(plan.phaseY)),
          sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
          scale: CGFloat(plan.imageScale)
        )
      )
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct ChalkSubstrateLayer: View {
  let configuration: WritingChalkConfiguration

  var body: some View {
    let surface = WritingChalkSurfacePlan(configuration: configuration)
    let tileSize = CGFloat(surface.detailTexturePointSize)
    let phase = surface.phase(tileSize: Double(tileSize), pass: .face)
    Canvas { context, size in
      context.opacity = min(0.14, 0.035 + 0.105 * configuration.grainAmount)
      context.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .tiledImage(
          ChalkSubstrateResource.image(for: configuration.textureStyle),
          origin: CGPoint(x: CGFloat(phase.x), y: CGFloat(phase.y)),
          sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
          scale: tileSize / CGFloat(WritingChalkTextureResource.pixelDimension)
        )
      )
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct ChalkPigmentMask: View {
  let plans: [ChalkPigmentLossLayerPlan]

  var body: some View {
    ZStack {
      Color.white
      ForEach(Array(plans.enumerated()), id: \.offset) { _, plan in
        ChalkTextureLayer(plan: plan).blendMode(.destinationOut)
      }
    }
    .compositingGroup()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct ChalkHatchField: View {
  let material: ChalkRenderMaterial

  var body: some View {
    Canvas { context, size in
      let segments = ChalkSurfacePlanner.hatchSegments(
        material: material,
        width: Double(size.width),
        height: Double(size.height)
      )
      for segment in segments {
        var path = Path()
        path.move(to: CGPoint(x: CGFloat(segment.startX), y: CGFloat(segment.startY)))
        path.addLine(to: CGPoint(x: CGFloat(segment.endX), y: CGFloat(segment.endY)))
        var segmentContext = context
        segmentContext.opacity = segment.opacity
        segmentContext.stroke(
          path,
          with: .color(.white),
          style: StrokeStyle(
            lineWidth: CGFloat(segment.lineWidth),
            lineCap: .round,
            lineJoin: .round
          )
        )
      }
    }
    .mask {
      ChalkPigmentMask(
        plans: ChalkSurfacePlanner.lossLayers(material: material, layer: .hatchField)
      )
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct ChalkDepositedFace<Content: View>: View {
  let content: Content
  let material: ChalkRenderMaterial

  var body: some View {
    let profile = material.surfaceProfile
    let powderCloud = ChalkSurfacePlanner.powderCloudLayers(material: material)
    ZStack {
      if !powderCloud.isEmpty {
        ZStack {
          ForEach(Array(powderCloud.enumerated()), id: \.offset) { _, layer in
            content
              .blur(radius: CGFloat(layer.blurRadius))
              .offset(x: CGFloat(layer.offsetX), y: CGFloat(layer.offsetY))
              .opacity(layer.opacity)
              .mask { ChalkTextureLayer(plan: layer.textureMask) }
          }
        }
        .overlay { content.blendMode(.destinationOut) }
        .compositingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
      if profile.underpaintOpacity > 0 {
        content
          .blur(radius: material.style == .dryBrush ? 0.32 : 0.12)
          .opacity(profile.underpaintOpacity)
          .mask {
            ChalkPigmentMask(
              plans: ChalkSurfacePlanner.lossLayers(material: material, layer: .underpaint)
            )
          }
      }
      content
        .opacity(profile.faceOpacity)
        .mask {
          ChalkPigmentMask(
            plans: ChalkSurfacePlanner.lossLayers(material: material, layer: .face)
          )
        }
    }
    .compositingGroup()
  }
}

private struct ChalkHatchedFace<Content: View>: View {
  let content: Content
  let material: ChalkRenderMaterial

  var body: some View {
    let profile = material.surfaceProfile
    ZStack {
      content
        .opacity(profile.underpaintOpacity)
        .mask {
          ChalkPigmentMask(
            plans: ChalkSurfacePlanner.lossLayers(material: material, layer: .underpaint)
          )
        }
      content
        .opacity(profile.faceOpacity)
        .mask { ChalkHatchField(material: material) }
    }
    .compositingGroup()
  }
}

private struct ChalkSmudgedFace<Content: View>: View {
  let content: Content
  let material: ChalkRenderMaterial

  var body: some View {
    let profile = material.surfaceProfile
    let layers = ChalkSurfacePlanner.smudgeLayers(material: material)
    ZStack {
      ForEach(Array(layers.enumerated()), id: \.offset) { _, layer in
        content
          .blur(radius: CGFloat(layer.blurRadius))
          .offset(x: CGFloat(layer.offsetX), y: CGFloat(layer.offsetY))
          .opacity(layer.opacity)
          .mask { ChalkPigmentMask(plans: layer.lossLayers) }
      }
      content
        .opacity(profile.smudgeCoreOpacity)
        .mask {
          ChalkPigmentMask(
            plans: ChalkSurfacePlanner.lossLayers(material: material, layer: .smudgeCore)
          )
        }
    }
    .compositingGroup()
  }
}

private struct ChalkTextureComposition<Content: View>: View {
  let content: Content
  let material: ChalkRenderMaterial
  let color: Color?

  @ViewBuilder
  private var tintedContent: some View {
    if let color {
      // Pigment composite, not a multiply: the caller color replaces content
      // RGB while preserving content alpha, matching the Canvas painter path
      // which tints white masks with the same pigment. colorMultiply cannot
      // tint dark content (black × color = black).
      ZStack {
        content
        color.blendMode(.sourceAtop)
      }
      .compositingGroup()
    } else {
      content
    }
  }

  @ViewBuilder
  private var materialFace: some View {
    switch material.executionTopology(for: .alphaMask) {
    case .contactDabs:
      preconditionFailure("Alpha-mask material execution cannot produce physical contact dabs")
    case .depositedSurface:
      ChalkDepositedFace(content: tintedContent, material: material)
    case .hatchField:
      ChalkHatchedFace(content: tintedContent, material: material)
    case .smudgeResidue:
      ChalkSmudgedFace(content: tintedContent, material: material)
    }
  }

  @ViewBuilder
  private var edgeDust: some View {
    if let plan = ChalkSurfacePlanner.edgeDustPlan(material: material) {
      ZStack {
        tintedContent.offset(
          x: CGFloat(plan.offsetX + plan.spread),
          y: CGFloat(plan.offsetY - plan.spread * 0.48)
        )
        tintedContent.offset(
          x: CGFloat(plan.offsetX - plan.spread * 0.72),
          y: CGFloat(plan.offsetY + plan.spread)
        )
        tintedContent
          .blur(radius: CGFloat(plan.blurRadius))
          .offset(x: CGFloat(plan.offsetX), y: CGFloat(plan.offsetY))
      }
      .overlay { tintedContent.blendMode(.destinationOut) }
      .compositingGroup()
      .opacity(plan.opacity)
      .mask { ChalkTextureLayer(plan: plan.textureMask) }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  var body: some View {
    ZStack {
      edgeDust
      materialFace
      if material.configuration.grainAmount > 0 {
        ChalkSubstrateLayer(configuration: material.configuration)
          .blendMode(.destinationOut)
      }
    }
    .compositingGroup()
  }
}

/// Package-internal arbitrary-view adapter. LiveText's own renderers do not use
/// this path; they paint directly into their existing GraphicsContext.
package struct ChalkRenderSurfaceModifier: ViewModifier {
  package let material: ChalkRenderMaterial
  package let color: Color?

  package init(material: ChalkRenderMaterial, color: Color? = nil) {
    self.material = material
    self.color = color
  }

  @ViewBuilder
  package func body(content: Content) -> some View {
    let configuration = material.configuration
    if configuration.grainAmount == 0,
      configuration.erosionAmount == 0,
      configuration.edgeRoughness == 0
    {
      if let color {
        ZStack {
          content
          color.blendMode(.sourceAtop)
        }
        .compositingGroup()
      } else {
        content
      }
    } else {
      ChalkTextureComposition(content: content, material: material, color: color)
    }
  }
}
