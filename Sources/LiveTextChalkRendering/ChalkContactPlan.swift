import CoreGraphics
import Foundation
import LiveTextEffects
import SwiftUI

package struct ChalkRenderStrokePoint: Hashable, Sendable {
  package let x: Double
  package let y: Double
  package let width: Double

  package init(x: Double, y: Double, width: Double) {
    self.x = x
    self.y = y
    self.width = width
  }
}

package struct ChalkRenderStrokeGeometry: Hashable, Sendable {
  package let id: String
  package let points: [ChalkRenderStrokePoint]

  package init(id: String, points: [ChalkRenderStrokePoint]) {
    self.id = id
    self.points = points
  }
}

package enum ChalkContactVisibility: Hashable, Sendable {
  case hidden
  case full
  case prefix(Double)
  case suffix(Double)
}

package enum ChalkRenderError: Error, Equatable, Sendable {
  case invalidStroke(String)
  case resourceLimitExceeded(resource: String, actual: Int, limit: Int)
}

private enum ChalkBoardInteraction: Sendable {
  case perContact(maximumLoss: Double)
  case postComposite(loss: Double)
}

private struct ChalkBrushProfile: Sendable {
  let tipResourcePrefix: String
  let tipVariantCount: Int
  let spacingRadiusFraction: Double
  let axialAspect: Double
  let transverseScale: Double
  let finalOpacity: Double
  let pressureGamma: Double
  let boardInteraction: ChalkBoardInteraction
  let scatterNormalFraction: Double
  let directionResponse: Double
  let radiusJitter: Double
  let depositionJitter: Double
  let microJitter: Double
  let dustRate: Double
  let dustOpacity: Double
  let dustSpread: Double
  let dustRadiusScale: Double

  func boardImageScale(grainScale: Double) -> Double {
    max(0.35, min(1.80, grainScale / 3.5))
  }

  func contactToothLoss(
    configuration: WritingChalkConfiguration,
    normalizedPressure: Double
  ) -> Double {
    guard case .perContact(let maximumLoss) = boardInteraction else { return 0 }
    let pressure = min(1, max(0, normalizedPressure))
    let pressureExposure = 1.0 - 0.72 * pressure
    let textureStrength = 0.34 + 0.66 * configuration.grainAmount
    let erosionStrength = 0.58 + 0.42 * configuration.erosionAmount
    return min(0.92, max(0, maximumLoss * pressureExposure * textureStrength * erosionStrength))
  }

  var postCompositeToothLoss: Double {
    guard case .postComposite(let loss) = boardInteraction else { return 0 }
    return min(1, max(0, loss))
  }
}

extension ChalkRenderStyle {
  fileprivate var contactBrushProfile: ChalkBrushProfile? {
    switch self {
    case .fineLine:
      return ChalkBrushProfile(
        tipResourcePrefix: "chalk-tip-fine-line", tipVariantCount: 4,
        spacingRadiusFraction: 0.78, axialAspect: 1.28, transverseScale: 1.12,
        finalOpacity: 0.998, pressureGamma: 0.90,
        boardInteraction: .postComposite(loss: 0.28),
        scatterNormalFraction: 0.055, directionResponse: 0.54,
        radiusJitter: 0.11, depositionJitter: 0.20, microJitter: 0.045,
        dustRate: 0.22, dustOpacity: 0.42, dustSpread: 0.68, dustRadiusScale: 1.65)
    case .dryBrush:
      return ChalkBrushProfile(
        tipResourcePrefix: "chalk-tip-dry-brush", tipVariantCount: 4,
        spacingRadiusFraction: 0.96, axialAspect: 2.40, transverseScale: 1.78,
        finalOpacity: 0.94, pressureGamma: 1.02,
        boardInteraction: .perContact(maximumLoss: 0.62),
        scatterNormalFraction: 0.250, directionResponse: 0.38,
        radiusJitter: 0.340, depositionJitter: 0.58, microJitter: 0.195,
        dustRate: 0.48, dustOpacity: 0.38, dustSpread: 1.96, dustRadiusScale: 2.90)
    case .powderFill, .diagonalHatch, .crossHatch, .smudged:
      return nil
    }
  }
}

private struct ChalkBrushDab: Hashable, Sendable {
  let centerX: Double
  let centerY: Double
  let angle: Double
  let width: Double
  let height: Double
  let opacity: Double
  let toothLoss: Double
  let arcFraction: Double
  let variant: Int
  let mirrorX: Bool
}

private struct ChalkDustParticle: Hashable, Sendable {
  let centerX: Double
  let centerY: Double
  let radius: Double
  let opacity: Double
  let arcFraction: Double
}

private struct ChalkContactSupportPlan: Hashable, Sendable {
  let boardImageScale: Double
  let boardPhaseX: Double
  let boardPhaseY: Double
  let postCompositeToothLoss: Double
}

private struct ChalkBrushStrokePlan: Hashable, Sendable {
  let strokeID: String
  let dabs: [ChalkBrushDab]
  let dust: [ChalkDustParticle]

  func dabs(for visibility: ChalkContactVisibility) -> ArraySlice<ChalkBrushDab> {
    visible(dabs, visibility: visibility, fraction: \.arcFraction)
  }

  func dust(for visibility: ChalkContactVisibility) -> ArraySlice<ChalkDustParticle> {
    visible(dust, visibility: visibility, fraction: \.arcFraction)
  }

  private func visible<Element>(
    _ elements: [Element],
    visibility: ChalkContactVisibility,
    fraction: KeyPath<Element, Double>
  ) -> ArraySlice<Element> {
    switch visibility {
    case .hidden:
      return elements[0..<0]
    case .full:
      return elements[...]
    case .prefix(let value):
      let limit = min(1, max(0, value))
      var low = 0, high = elements.count
      while low < high {
        let middle = (low + high) / 2
        if elements[middle][keyPath: fraction] <= limit { low = middle + 1 } else { high = middle }
      }
      return elements[..<low]
    case .suffix(let value):
      let limit = min(1, max(0, value))
      var low = 0, high = elements.count
      while low < high {
        let middle = (low + high) / 2
        if elements[middle][keyPath: fraction] < limit { low = middle + 1 } else { high = middle }
      }
      return elements[low...]
    }
  }
}

package struct ChalkPreparedContactPlan: Sendable {
  package static let maximumDabsPerStroke = 8_192

  fileprivate let material: ChalkRenderMaterial
  fileprivate let support: ChalkContactSupportPlan
  fileprivate let strokes: [ChalkBrushStrokePlan]

  package static func prepare(
    strokes: [ChalkRenderStrokeGeometry],
    material: ChalkRenderMaterial
  ) throws -> ChalkPreparedContactPlan {
    guard material.executionTopology(for: .strokeGeometry) == .contactDabs,
      let profile = material.style.contactBrushProfile
    else {
      throw ChalkRenderError.invalidStroke("material does not support contact geometry")
    }
    let boardImageScale = profile.boardImageScale(grainScale: material.configuration.grainScale)
    let boardTileSize = ChalkSurfacePlanner.texturePixelSize * boardImageScale
    let phase = ChalkSurfacePlanner.texturePhase(
      seed: material.configuration.seed,
      tileSize: boardTileSize,
      salt: 0x424F_4152_4454_4F4F)
    let support = ChalkContactSupportPlan(
      boardImageScale: boardImageScale,
      boardPhaseX: phase.x, boardPhaseY: phase.y,
      postCompositeToothLoss: profile.postCompositeToothLoss)
    return ChalkPreparedContactPlan(
      material: material,
      support: support,
      strokes: try strokes.enumerated().map { index, stroke in
        try plan(stroke: stroke, material: material, profile: profile, strokeIndex: index)
      })
  }

  private static func plan(
    stroke: ChalkRenderStrokeGeometry,
    material: ChalkRenderMaterial,
    profile: ChalkBrushProfile,
    strokeIndex: Int
  ) throws -> ChalkBrushStrokePlan {
    guard !stroke.id.isEmpty, !stroke.points.isEmpty,
      stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.width > 0 })
    else { throw ChalkRenderError.invalidStroke(stroke.id) }

    if stroke.points.count == 1 {
      let point = stroke.points[0]
      let radius = max(0.25, point.width * 0.5)
      return ChalkBrushStrokePlan(
        strokeID: stroke.id,
        dabs: [ChalkBrushDab(
          centerX: point.x, centerY: point.y, angle: 0,
          width: radius * 2 * profile.transverseScale * profile.axialAspect,
          height: radius * 2 * profile.transverseScale,
          opacity: profile.finalOpacity,
          toothLoss: profile.contactToothLoss(
            configuration: material.configuration, normalizedPressure: 0.5),
          arcFraction: 1, variant: 0, mirrorX: false)],
        dust: [])
    }

    var cumulative = [Double](repeating: 0, count: stroke.points.count)
    for index in 1..<stroke.points.count {
      let a = stroke.points[index - 1], b = stroke.points[index]
      cumulative[index] = cumulative[index - 1] + hypot(b.x - a.x, b.y - a.y)
    }
    guard let finalDistance = cumulative.last, finalDistance > 0 else {
      return ChalkBrushStrokePlan(strokeID: stroke.id, dabs: [], dust: [])
    }

    let meanWidth = stroke.points.reduce(0.0) { $0 + $1.width } / Double(stroke.points.count)
    var spacing = max(0.22, meanWidth * 0.5 * profile.spacingRadiusFraction)
    let estimatedCount = Int(ceil(finalDistance / spacing)) + 1
    guard estimatedCount <= maximumDabsPerStroke else {
      throw ChalkRenderError.resourceLimitExceeded(
        resource: "chalk contact dabs", actual: estimatedCount, limit: maximumDabsPerStroke)
    }
    let count = max(2, estimatedCount)
    spacing = finalDistance / Double(count - 1)
    let overlap = max(1.0, (meanWidth * profile.transverseScale * profile.axialAspect) / max(spacing, 0.001))
    let linearizedOpacity = 1 - pow(1 - profile.finalOpacity, 1 / overlap)

    let baseSeed = ChalkStableHash.value(
      seed: material.configuration.seed ^ UInt64(strokeIndex), string: stroke.id)
    var random = ChalkSplitMix64(state: baseSeed)
    let baseVariant = Int(random.nextUInt64() % UInt64(profile.tipVariantCount))
    let baseMirror = (random.nextUInt64() & 1) == 1
    let tipSkew = random.nextSignedUnit() * 0.075
    var dabs: [ChalkBrushDab] = []
    var dust: [ChalkDustParticle] = []
    dabs.reserveCapacity(count)

    var sampleIndex = 1
    var filteredAngle: Double?
    var filteredScatter = 0.0
    var filteredRadiusNoise = 0.0
    var filteredDepositionNoise = 0.0

    for dabIndex in 0..<count {
      let distance = min(finalDistance, Double(dabIndex) * spacing)
      while sampleIndex < cumulative.count - 1, cumulative[sampleIndex] < distance { sampleIndex += 1 }
      let previousIndex = max(0, sampleIndex - 1)
      let nextIndex = min(stroke.points.count - 1, sampleIndex)
      let previous = stroke.points[previousIndex], next = stroke.points[nextIndex]
      let span = cumulative[nextIndex] - cumulative[previousIndex]
      let local = span > 0 ? (distance - cumulative[previousIndex]) / span : 0
      let x = previous.x + (next.x - previous.x) * local
      let y = previous.y + (next.y - previous.y) * local
      let sourceWidth = previous.width + (next.width - previous.width) * local
      let pressureWidth = max(0.35, pow(max(0.05, sourceWidth), profile.pressureGamma))
      let relativePressure = min(1.30, max(0.55, sourceWidth / max(meanWidth, 0.001)))
      let normalizedPressure = min(1, max(0, (relativePressure - 0.55) / 0.75))
      let pressureAdhesion = 0.62 + 0.38 * normalizedPressure
      let toothLoss = profile.contactToothLoss(
        configuration: material.configuration, normalizedPressure: normalizedPressure)

      let dx = next.x - previous.x, dy = next.y - previous.y
      let rawAngle = atan2(dy, dx) + tipSkew
      let angle: Double
      if let current = filteredAngle {
        var delta = rawAngle - current
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        angle = current + delta * min(1, max(0.05, profile.directionResponse))
      } else {
        angle = rawAngle
      }
      filteredAngle = angle
      filteredScatter = filteredScatter * 0.82 + random.nextSignedUnit() * 0.18
      filteredRadiusNoise = filteredRadiusNoise * 0.86 + random.nextSignedUnit() * 0.14
      filteredDepositionNoise = filteredDepositionNoise * 0.80 + random.nextSignedUnit() * 0.20
      let normalX = -sin(angle), normalY = cos(angle)
      let scatter = pressureWidth * (
        profile.scatterNormalFraction * filteredScatter + profile.microJitter * random.nextSignedUnit())
      let radiusScale = max(0.62, 1 + profile.radiusJitter * filteredRadiusNoise + profile.microJitter * 0.75 * random.nextSignedUnit())
      let depositionScale = max(0.18, 1 - profile.depositionJitter * 0.5 + profile.depositionJitter * 0.5 * filteredDepositionNoise)
      let contactHeight = pressureWidth * profile.transverseScale * radiusScale
      let fraction = finalDistance > 0 ? distance / finalDistance : 1
      let endEnvelope = 0.66 + 0.34 * sin(.pi * fraction)
      dabs.append(ChalkBrushDab(
        centerX: x + normalX * scatter, centerY: y + normalY * scatter,
        angle: angle, width: contactHeight * profile.axialAspect, height: contactHeight,
        opacity: min(1, max(0.01, linearizedOpacity * endEnvelope * pressureAdhesion * depositionScale)),
        toothLoss: toothLoss, arcFraction: fraction,
        variant: baseVariant, mirrorX: baseMirror))

      if random.nextUnit() < profile.dustRate {
        let side: Double = random.nextUnit() < 0.5 ? -1 : 1
        let spread = pressureWidth * profile.dustSpread * (0.48 + random.nextUnit() * 0.62)
        let along = pressureWidth * random.nextSignedUnit() * 0.36
        dust.append(ChalkDustParticle(
          centerX: x + cos(angle) * along + normalX * spread * side,
          centerY: y + sin(angle) * along + normalY * spread * side,
          radius: max(0.16, pressureWidth * profile.dustRadiusScale * (0.015 + random.nextUnit() * 0.045)),
          opacity: profile.dustOpacity * (0.55 + random.nextUnit() * 0.45),
          arcFraction: fraction))
      }
    }
    return ChalkBrushStrokePlan(strokeID: stroke.id, dabs: dabs, dust: dust)
  }
}

package enum ChalkContactRenderer {
  package static func paint(
    plan: ChalkPreparedContactPlan,
    visibility: [ChalkContactVisibility],
    color: Color,
    documentOriginAtContextZero: CGPoint,
    clipBounds: CGRect,
    in context: inout GraphicsContext
  ) {
    guard visibility.count == plan.strokes.count,
      clipBounds.width.isFinite, clipBounds.height.isFinite
    else { return }

    let profile = plan.material.style.contactBrushProfile!
    let resolvedTips = (0..<profile.tipVariantCount).map {
      context.resolve(ChalkRenderResources.tipImage(style: plan.material.style, variant: $0))
    }
    let support = plan.support
    let localBoardOrigin = CGPoint(
      x: CGFloat(support.boardPhaseX) - documentOriginAtContextZero.x,
      y: CGFloat(support.boardPhaseY) - documentOriginAtContextZero.y)

    context.drawLayer { pigment in
      for (index, stroke) in plan.strokes.enumerated() {
        for dab in stroke.dabs(for: visibility[index]) {
          pigment.drawLayer { contact in
            var resolved = resolvedTips[dab.variant]
            resolved.shading = .color(color)
            var local = contact
            local.opacity = min(1, dab.opacity * (0.64 + 0.36 * plan.material.configuration.grainAmount))
            local.translateBy(x: CGFloat(dab.centerX), y: CGFloat(dab.centerY))
            local.rotate(by: .radians(dab.angle))
            if dab.mirrorX { local.scaleBy(x: -1, y: 1) }
            local.draw(
              resolved,
              in: CGRect(
                x: CGFloat(-dab.width * 0.5), y: CGFloat(-dab.height * 0.5),
                width: CGFloat(dab.width), height: CGFloat(dab.height)
              )
            )
            if dab.toothLoss > 0 {
              contact.blendMode = .destinationOut
              contact.opacity = min(1, max(0, dab.toothLoss))
              contact.fill(
                Path(clipBounds),
                with: .tiledImage(
                  ChalkRenderResources.boardToothImage,
                  origin: localBoardOrigin,
                  sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                  scale: CGFloat(support.boardImageScale)))
            }
          }
        }
      }
      if support.postCompositeToothLoss > 0 {
        var boardLoss = pigment
        boardLoss.blendMode = .destinationOut
        boardLoss.opacity = support.postCompositeToothLoss
        boardLoss.fill(
          Path(clipBounds),
          with: .tiledImage(
            ChalkRenderResources.boardToothImage,
            origin: localBoardOrigin,
            sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            scale: CGFloat(support.boardImageScale)))
        pigment = boardLoss
      }
    }

    let dustStrength = plan.material.configuration.edgeRoughness
    guard dustStrength > 0 else { return }
    for (index, stroke) in plan.strokes.enumerated() {
      for particle in stroke.dust(for: visibility[index]) {
        let radius = CGFloat(max(0.35, particle.radius))
        var dust = context
        dust.opacity = min(0.34, particle.opacity * dustStrength)
        dust.fill(
          Path(ellipseIn: CGRect(
            x: CGFloat(particle.centerX) - radius, y: CGFloat(particle.centerY) - radius,
            width: radius * 2, height: radius * 2)),
          with: .color(color))
      }
    }
  }
}
