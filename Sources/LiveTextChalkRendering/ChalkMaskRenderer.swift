import CoreGraphics
import LiveTextEffects
import SwiftUI

/// Canonical direct painter for an authoritative LiveText alpha mask.
///
/// It shares material topology/planning/resources with the standalone SwiftUI chalk modifier.
/// No text shaping, layout, reveal timing, or hit geometry is recomputed here.
package enum ChalkMaskRenderer {
  package static func paint(
    mask: Path,
    target: WritingMaterialTarget,
    configuration: WritingChalkConfiguration,
    color: Color,
    documentOriginAtContextZero: CGPoint,
    in context: inout GraphicsContext
  ) {
    guard !mask.isEmpty else { return }
    let bounds = mask.boundingRect
    guard isFinite(bounds), isFinite(documentOriginAtContextZero) else { return }

    if configuration.grainAmount == 0,
      configuration.erosionAmount == 0,
      configuration.edgeRoughness == 0
    {
      context.fill(mask, with: .color(color), style: FillStyle(eoFill: true))
      return
    }

    let material = ChalkRenderMaterial.liveText(configuration)
    context.drawLayer { surface in
      paintEdgeDust(
        mask: mask,
        material: material,
        color: color,
        documentOriginAtContextZero: documentOriginAtContextZero,
        in: &surface
      )

      switch material.executionTopology(for: .alphaMask) {
      case .contactDabs:
        preconditionFailure("alpha-mask chalk execution cannot produce contact dabs")
      case .depositedSurface:
        paintDeposited(
          mask: mask, material: material, color: color,
          documentOriginAtContextZero: documentOriginAtContextZero, in: &surface)
      case .hatchField:
        paintHatched(
          mask: mask, target: target, material: material, color: color,
          documentOriginAtContextZero: documentOriginAtContextZero, in: &surface)
      case .smudgeResidue:
        paintSmudged(
          mask: mask, material: material, color: color,
          documentOriginAtContextZero: documentOriginAtContextZero, in: &surface)
      }

      applySubstrateTexture(
        configuration: configuration,
        bounds: bounds,
        documentOriginAtContextZero: documentOriginAtContextZero,
        in: &surface
      )
    }
  }

  private static func paintDeposited(
    mask: Path,
    material: ChalkRenderMaterial,
    color: Color,
    documentOriginAtContextZero: CGPoint,
    in context: inout GraphicsContext
  ) {
    let profile = material.surfaceProfile
    let powderClouds = ChalkSurfacePlanner.powderCloudLayers(material: material)
    if !powderClouds.isEmpty {
      context.drawLayer { cloudGroup in
        for cloud in powderClouds {
          paintPigment(
            mask: mask,
            offsetX: cloud.offsetX,
            offsetY: cloud.offsetY,
            blurRadius: cloud.blurRadius,
            opacity: cloud.opacity,
            lossPlans: [cloud.textureMask],
            color: color,
            documentOriginAtContextZero: documentOriginAtContextZero,
            in: &cloudGroup
          )
        }
        cloudGroup.blendMode = .destinationOut
        cloudGroup.fill(mask, with: .color(.white), style: FillStyle(eoFill: true))
      }
    }

    if profile.underpaintOpacity > 0 {
      paintPigment(
        mask: mask,
        blurRadius: material.style == .dryBrush ? 0.32 : 0.12,
        opacity: profile.underpaintOpacity,
        lossPlans: ChalkSurfacePlanner.lossLayers(material: material, layer: .underpaint),
        color: color,
        documentOriginAtContextZero: documentOriginAtContextZero,
        in: &context
      )
    }
    paintPigment(
      mask: mask,
      opacity: profile.faceOpacity,
      lossPlans: ChalkSurfacePlanner.lossLayers(material: material, layer: .face),
      color: color,
      documentOriginAtContextZero: documentOriginAtContextZero,
      in: &context
    )
  }

  private static func paintHatched(
    mask: Path,
    target: WritingMaterialTarget,
    material: ChalkRenderMaterial,
    color: Color,
    documentOriginAtContextZero: CGPoint,
    in context: inout GraphicsContext
  ) {
    let profile = material.surfaceProfile
    if profile.underpaintOpacity > 0 {
      paintPigment(
        mask: mask,
        opacity: profile.underpaintOpacity,
        lossPlans: ChalkSurfacePlanner.lossLayers(material: material, layer: .underpaint),
        color: color,
        documentOriginAtContextZero: documentOriginAtContextZero,
        in: &context
      )
    }

    let targetRect = CGRect(
      x: CGFloat(target.destination.x),
      y: CGFloat(target.destination.y),
      width: CGFloat(target.destination.width),
      height: CGFloat(target.destination.height)
    )
    let field =
      isFinite(targetRect) && targetRect.width > 0 && targetRect.height > 0
      ? targetRect
      : mask.boundingRect
    let segments = ChalkSurfacePlanner.hatchSegments(
      material: material,
      width: Double(field.width),
      height: Double(field.height)
    )
    guard !segments.isEmpty else { return }

    context.drawLayer { hatchLayer in
      hatchLayer.clip(to: mask, style: FillStyle(eoFill: true))
      for segment in segments {
        var path = Path()
        path.move(
          to: CGPoint(
            x: field.minX + CGFloat(segment.startX),
            y: field.minY + CGFloat(segment.startY)))
        path.addLine(
          to: CGPoint(
            x: field.minX + CGFloat(segment.endX),
            y: field.minY + CGFloat(segment.endY)))
        var stroke = hatchLayer
        stroke.opacity = min(1, max(0, segment.opacity * profile.faceOpacity))
        stroke.stroke(
          path,
          with: .color(color),
          style: StrokeStyle(
            lineWidth: CGFloat(segment.lineWidth),
            lineCap: .round,
            lineJoin: .round
          )
        )
      }
      applyLoss(
        ChalkSurfacePlanner.lossLayers(material: material, layer: .hatchField),
        bounds: field.union(mask.boundingRect),
        documentOriginAtContextZero: documentOriginAtContextZero,
        in: &hatchLayer
      )
    }
  }

  private static func paintSmudged(
    mask: Path,
    material: ChalkRenderMaterial,
    color: Color,
    documentOriginAtContextZero: CGPoint,
    in context: inout GraphicsContext
  ) {
    let profile = material.surfaceProfile
    for layer in ChalkSurfacePlanner.smudgeLayers(material: material) {
      paintPigment(
        mask: mask,
        offsetX: layer.offsetX,
        offsetY: layer.offsetY,
        blurRadius: layer.blurRadius,
        opacity: layer.opacity,
        lossPlans: layer.lossLayers,
        color: color,
        documentOriginAtContextZero: documentOriginAtContextZero,
        in: &context
      )
    }
    if profile.smudgeCoreOpacity > 0 {
      paintPigment(
        mask: mask,
        opacity: profile.smudgeCoreOpacity,
        lossPlans: ChalkSurfacePlanner.lossLayers(material: material, layer: .smudgeCore),
        color: color,
        documentOriginAtContextZero: documentOriginAtContextZero,
        in: &context
      )
    }
  }

  private static func paintEdgeDust(
    mask: Path,
    material: ChalkRenderMaterial,
    color: Color,
    documentOriginAtContextZero: CGPoint,
    in context: inout GraphicsContext
  ) {
    guard let plan = ChalkSurfacePlanner.edgeDustPlan(material: material), plan.opacity > 0 else {
      return
    }
    let first = mask.applying(
      CGAffineTransform(
        translationX: CGFloat(plan.offsetX + plan.spread),
        y: CGFloat(plan.offsetY - plan.spread * 0.48)))
    let second = mask.applying(
      CGAffineTransform(
        translationX: CGFloat(plan.offsetX - plan.spread * 0.72),
        y: CGFloat(plan.offsetY + plan.spread)))
    let blurred = mask.applying(
      CGAffineTransform(
        translationX: CGFloat(plan.offsetX),
        y: CGFloat(plan.offsetY)))
    let bounds = mask.boundingRect.union(first.boundingRect).union(second.boundingRect)
      .union(blurred.boundingRect)

    context.drawLayer { dust in
      dust.opacity = min(1, max(0, plan.opacity))
      dust.fill(first, with: .color(color), style: FillStyle(eoFill: true))
      dust.fill(second, with: .color(color), style: FillStyle(eoFill: true))
      if plan.blurRadius > 0 {
        dust.drawLayer { blurredLayer in
          blurredLayer.addFilter(.blur(radius: CGFloat(plan.blurRadius)))
          blurredLayer.fill(blurred, with: .color(color), style: FillStyle(eoFill: true))
        }
      } else {
        dust.fill(blurred, with: .color(color), style: FillStyle(eoFill: true))
      }
      dust.blendMode = .destinationOut
      dust.fill(mask, with: .color(.white), style: FillStyle(eoFill: true))
      applyTextureMask(
        plan.textureMask,
        bounds: bounds,
        documentOriginAtContextZero: documentOriginAtContextZero,
        in: &dust
      )
    }
  }

  private static func paintPigment(
    mask: Path,
    offsetX: Double = 0,
    offsetY: Double = 0,
    blurRadius: Double = 0,
    opacity: Double,
    lossPlans: [ChalkPigmentLossLayerPlan],
    color: Color,
    documentOriginAtContextZero: CGPoint,
    in context: inout GraphicsContext
  ) {
    guard opacity > 0 else { return }
    let transformed = mask.applying(
      CGAffineTransform(translationX: CGFloat(offsetX), y: CGFloat(offsetY)))
    let bounds = transformed.boundingRect
    guard isFinite(bounds) else { return }

    context.drawLayer { pigment in
      pigment.opacity = min(1, max(0, opacity))
      if blurRadius > 0 {
        pigment.drawLayer { blurred in
          blurred.addFilter(.blur(radius: CGFloat(blurRadius)))
          blurred.fill(transformed, with: .color(color), style: FillStyle(eoFill: true))
        }
      } else {
        pigment.fill(transformed, with: .color(color), style: FillStyle(eoFill: true))
      }
      applyLoss(
        lossPlans,
        bounds: bounds,
        documentOriginAtContextZero: documentOriginAtContextZero,
        in: &pigment
      )
    }
  }

  private static func applyLoss(
    _ plans: [ChalkPigmentLossLayerPlan],
    bounds: CGRect,
    documentOriginAtContextZero: CGPoint,
    in context: inout GraphicsContext
  ) {
    for plan in plans where plan.opacity > 0 {
      var loss = context
      loss.blendMode = .destinationOut
      loss.opacity = min(1, max(0, plan.opacity))
      if let threshold = plan.alphaThreshold {
        loss.addFilter(.alphaThreshold(min: threshold, color: .white))
      }
      fillTexture(
        plan,
        bounds: bounds,
        documentOriginAtContextZero: documentOriginAtContextZero,
        in: &loss
      )
      context = loss
    }
  }

  private static func applyTextureMask(
    _ plan: ChalkPigmentLossLayerPlan,
    bounds: CGRect,
    documentOriginAtContextZero: CGPoint,
    in context: inout GraphicsContext
  ) {
    var mask = context
    mask.blendMode = .destinationIn
    mask.opacity = min(1, max(0, plan.opacity))
    if let threshold = plan.alphaThreshold {
      mask.addFilter(.alphaThreshold(min: threshold, color: .white))
    }
    fillTexture(
      plan,
      bounds: bounds,
      documentOriginAtContextZero: documentOriginAtContextZero,
      in: &mask
    )
    context = mask
  }

  /// Applies the selected substrate microtexture as one bounded pigment-loss pass inside
  /// the canonical six-topology chalk renderer. The substrate never selects another renderer.
  private static func applySubstrateTexture(
    configuration: WritingChalkConfiguration,
    bounds: CGRect,
    documentOriginAtContextZero: CGPoint,
    in context: inout GraphicsContext
  ) {
    guard configuration.grainAmount > 0, isFinite(bounds) else { return }
    let substratePlan = WritingChalkSurfacePlan(configuration: configuration)
    let opacity = min(0.14, 0.035 + 0.105 * configuration.grainAmount)
    guard opacity > 0 else { return }
    let tileSize = CGFloat(substratePlan.detailTexturePointSize)
    let phase = substratePlan.phase(tileSize: Double(tileSize), pass: .face)
    let origin = CGPoint(
      x: CGFloat(phase.x) - documentOriginAtContextZero.x,
      y: CGFloat(phase.y) - documentOriginAtContextZero.y
    )
    var loss = context
    loss.blendMode = .destinationOut
    loss.opacity = opacity
    loss.fill(
      Path(bounds),
      with: .tiledImage(
        ChalkSubstrateResource.image(for: configuration.textureStyle),
        origin: origin,
        sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
        scale: tileSize / CGFloat(WritingChalkTextureResource.pixelDimension)
      )
    )
    context = loss
  }

  private static func fillTexture(
    _ plan: ChalkPigmentLossLayerPlan,
    bounds: CGRect,
    documentOriginAtContextZero: CGPoint,
    in context: inout GraphicsContext
  ) {
    guard isFinite(bounds), plan.imageScale.isFinite, plan.imageScale > 0 else { return }
    let origin = CGPoint(
      x: CGFloat(plan.phaseX) - documentOriginAtContextZero.x,
      y: CGFloat(plan.phaseY) - documentOriginAtContextZero.y
    )
    context.fill(
      Path(bounds),
      with: .tiledImage(
        ChalkRenderResources.surfaceImage(for: plan.textureStyle),
        origin: origin,
        sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
        scale: CGFloat(plan.imageScale)
      )
    )
  }

  private static func isFinite(_ point: CGPoint) -> Bool {
    point.x.isFinite && point.y.isFinite
  }

  private static func isFinite(_ rect: CGRect) -> Bool {
    rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
  }
}
