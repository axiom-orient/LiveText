import CoreGraphics
import LiveTextEffects
import SwiftUI

/// Apple effect boundary: consumes immutable deposits; never resamples a path.
package enum ChalkContactRenderer {
  package static func paint(
    plan: ChalkPreparedContactPlan,
    visibility: [ChalkContactVisibility],
    color: Color,
    documentOriginAtContextZero: CGPoint,
    clipBounds: CGRect,
    in context: inout GraphicsContext
  ) {
    precondition(visibility.count == plan.strokes.count, "Chalk visibility must match prepared strokes")
    guard clipBounds.minX.isFinite, clipBounds.minY.isFinite,
      clipBounds.width.isFinite, clipBounds.height.isFinite,
      clipBounds.width > 0, clipBounds.height > 0,
      documentOriginAtContextZero.x.isFinite, documentOriginAtContextZero.y.isFinite
    else { return }
    var output = context
    output.clip(to: Path(clipBounds))
    let tips = (0..<ChalkContactPolicy.tipVariantCount).map { variant in
      var image = output.resolve(ChalkRenderResources.tipImage(style: plan.material.style, variant: variant))
      image.shading = .color(color)
      return image
    }
    let support = plan.support
    let boardOrigin = CGPoint(
      x: CGFloat(support.boardPhaseX) - documentOriginAtContextZero.x,
      y: CGFloat(support.boardPhaseY) - documentOriginAtContextZero.y)
    let clipPath = Path(clipBounds)
    let boardShading = output.resolve(.tiledImage(
      ChalkRenderResources.boardToothImage, origin: boardOrigin,
      sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
      scale: CGFloat(support.boardImageScale)))

    output.drawLayer { pigment in
      for (index, stroke) in plan.strokes.enumerated() {
        for dab in stroke.dabs(for: visibility[index]) {
          if dab.toothLoss > 0 {
            pigment.drawLayer { contact in
              draw(dab: dab, image: tips[dab.variant], in: &contact)
              removeBoardTooth(
                opacity: dab.toothLoss, mask: clipPath, shading: boardShading, in: &contact)
            }
          } else {
            // fineLine needs only one layer for the whole pigment field, not
            // one offscreen layer for every (potentially thousands of) dab.
            draw(dab: dab, image: tips[dab.variant], in: &pigment)
          }
        }
      }
      if support.postCompositeToothLoss > 0 {
        removeBoardTooth(
          opacity: support.postCompositeToothLoss, mask: clipPath, shading: boardShading, in: &pigment)
      }
      if support.substrateLoss > 0 {
        var substrate = pigment
        substrate.blendMode = .destinationOut
        substrate.opacity = support.substrateLoss
        substrate.fill(Path(clipBounds), with: .tiledImage(
          ChalkSubstrateResource.image(for: plan.material.configuration.textureStyle),
          origin: CGPoint(
            x: CGFloat(support.substratePhaseX) - documentOriginAtContextZero.x,
            y: CGFloat(support.substratePhaseY) - documentOriginAtContextZero.y),
          sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
          scale: CGFloat(support.substrateImageScale)))
      }
    }

    let dustStrength = plan.material.configuration.edgeRoughness
    guard dustStrength > 0 else { return }
    for (index, stroke) in plan.strokes.enumerated() {
      for particle in stroke.dust(for: visibility[index]) {
        var dust = output
        dust.opacity *= min(0.34, particle.opacity * dustStrength)
        dust.translateBy(x: CGFloat(particle.centerX), y: CGFloat(particle.centerY))
        dust.rotate(by: .radians(particle.angle))
        // Reuse pigment alpha, rather than opaque circles or blurred halos.
        // Retain subpixel grains: a 0.35pt radius floor made them look like beads.
        let radius = CGFloat(particle.radius)
        dust.draw(tips[particle.variant], in: CGRect(
          x: -radius * 1.25, y: -radius,
          width: radius * 2.5, height: radius * 2))
      }
    }
  }

  private static func draw(
    dab: ChalkBrushDab,
    image: GraphicsContext.ResolvedImage,
    in context: inout GraphicsContext
  ) {
    var local = context
    local.opacity *= dab.opacity
    local.translateBy(x: CGFloat(dab.centerX), y: CGFloat(dab.centerY))
    local.rotate(by: .radians(dab.angle))
    if dab.mirrorX { local.scaleBy(x: -1, y: 1) }
    local.draw(image, in: CGRect(
      x: CGFloat(-dab.width * 0.5), y: CGFloat(-dab.height * 0.5),
      width: CGFloat(dab.width), height: CGFloat(dab.height)))
  }

  private static func removeBoardTooth(
    opacity: Double,
    mask: Path,
    shading: GraphicsContext.Shading,
    in context: inout GraphicsContext
  ) {
    var loss = context
    loss.blendMode = .destinationOut
    loss.opacity = opacity
    loss.fill(mask, with: shading)
  }
}
