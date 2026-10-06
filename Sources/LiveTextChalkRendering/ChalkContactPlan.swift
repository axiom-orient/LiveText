import Foundation
import LiveTextEffects

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

/// Numerical/resource constants, not user settings or frame state.
enum ChalkContactPolicy {
  static let maximumDabsPerStroke = 8_192
  static let tipVariantCount = 4
  static let minimumSpacing = 0.22
  static let minimumWidth = 0.35
  static let minimumDustRadius = 0.10
  static let dustSeedSalt: UInt64 = 0x4455_5354_504C_414E
  static let boardSeedSalt: UInt64 = 0x424F_4152_4454_4F4F
  static let scatterMemory = 0.82
  static let radiusMemory = 0.86
  static let depositionMemory = 0.80
  static let endpointContactLengths = 1.5
  static let minimumEndpointAdhesion = 0.68
}

/// A stroke receives board tooth here OR after composition, never both.
enum ChalkBoardInteraction: Sendable {
  case perContact(maximumLoss: Double)
  case postComposite(maximumLoss: Double)
}

struct ChalkBrushProfile: Sendable {
  // Keep the previously accepted path-length budget independent of the
  // denser material sampling used for fineLine.
  let admissionSpacingRadiusFraction: Double
  let spacingRadiusFraction: Double
  let axialAspect: Double
  let transverseScale: Double
  let overlapCoverage: Double
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

  func postCompositeToothLoss(configuration: WritingChalkConfiguration) -> Double {
    guard case .postComposite(let maximumLoss) = boardInteraction else { return 0 }
    // Keep a legible pigment core. Grain and erosion change coverage, not RGB.
    let exposure = 0.65 * configuration.grainAmount + 0.35 * configuration.erosionAmount
    return min(1, max(0, maximumLoss * exposure))
  }
}

extension ChalkRenderStyle {
  var contactBrushProfile: ChalkBrushProfile? {
    switch self {
    case .fineLine:
      return ChalkBrushProfile(
        admissionSpacingRadiusFraction: 0.78,
        spacingRadiusFraction: 0.55, axialAspect: 1.28, transverseScale: 1.12,
        overlapCoverage: 1,
        finalOpacity: 0.998, pressureGamma: 0.90,
        boardInteraction: .postComposite(maximumLoss: 0.48),
        scatterNormalFraction: 0.055, directionResponse: 0.54,
        radiusJitter: 0.11, depositionJitter: 0.20, microJitter: 0.045,
        dustRate: 0.22, dustOpacity: 0.42, dustSpread: 0.68, dustRadiusScale: 1.65)
    case .dryBrush:
      return ChalkBrushProfile(
        admissionSpacingRadiusFraction: 0.96,
        spacingRadiusFraction: 0.96, axialAspect: 2.40, transverseScale: 1.78,
        // The four bundled dry tips occupy ~28% of their alpha rectangles.
        // Counting every empty brush slot as pigment made the field too faint.
        overlapCoverage: 0.28,
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

struct ChalkBrushDab: Hashable, Sendable {
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

struct ChalkDustParticle: Hashable, Sendable {
  let centerX: Double
  let centerY: Double
  let radius: Double
  let angle: Double
  let opacity: Double
  let arcFraction: Double
  let variant: Int
}

struct ChalkContactSupportPlan: Hashable, Sendable {
  let boardImageScale: Double
  let boardPhaseX: Double
  let boardPhaseY: Double
  let postCompositeToothLoss: Double
  let substrateImageScale: Double
  let substratePhaseX: Double
  let substratePhaseY: Double
  let substrateLoss: Double
}

struct ChalkBrushStrokePlan: Hashable, Sendable {
  let strokeID: String
  let dabs: [ChalkBrushDab]
  let dust: [ChalkDustParticle]

  func dabs(for visibility: ChalkContactVisibility) -> ArraySlice<ChalkBrushDab> {
    // A semantic dot is visible throughout its active interval, matching
    // the exact-path adapter. It is not an arc-length sample at either end.
    if dabs.count == 1 {
      switch visibility {
      case .hidden: return dabs[0..<0]
      case .full: return dabs[...]
      case .prefix(let value):
        return value.isFinite && value > 0 ? dabs[...] : dabs[0..<0]
      case .suffix(let value):
        return value.isFinite && value < 1 ? dabs[...] : dabs[0..<0]
      }
    }
    return visible(dabs, visibility: visibility, fraction: \.arcFraction)
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
    case .prefix(let limit):
      guard limit.isFinite, limit > 0 else { return elements[0..<0] }
      guard limit < 1 else { return elements[...] }
      var low = 0, high = elements.count
      while low < high {
        let middle = low + (high - low) / 2
        if elements[middle][keyPath: fraction] <= limit { low = middle + 1 } else { high = middle }
      }
      return elements[..<low]
    case .suffix(let limit):
      guard limit.isFinite, limit < 1 else { return elements[0..<0] }
      guard limit > 0 else { return elements[...] }
      var low = 0, high = elements.count
      while low < high {
        let middle = low + (high - low) / 2
        if elements[middle][keyPath: fraction] < limit { low = middle + 1 } else { high = middle }
      }
      return elements[low...]
    }
  }
}

/// Immutable preparation output. The renderer has no random or planning state.
package struct ChalkPreparedContactPlan: Sendable {
  package static let maximumDabsPerStroke = ChalkContactPolicy.maximumDabsPerStroke

  let material: ChalkRenderMaterial
  let support: ChalkContactSupportPlan
  let strokes: [ChalkBrushStrokePlan]

  package static func prepare(
    strokes: [ChalkRenderStrokeGeometry],
    material: ChalkRenderMaterial
  ) throws -> ChalkPreparedContactPlan {
    guard material.executionTopology(for: .strokeGeometry) == .contactDabs,
      let profile = material.style.contactBrushProfile
    else {
      throw ChalkRenderError.invalidStroke("material does not support contact geometry")
    }
    let imageScale = profile.boardImageScale(grainScale: material.configuration.grainScale)
    let phase = ChalkSurfacePlanner.texturePhase(
      seed: material.configuration.seed,
      tileSize: ChalkSurfacePlanner.texturePixelSize * imageScale,
      salt: ChalkContactPolicy.boardSeedSalt)
    let surface = WritingChalkSurfacePlan(configuration: material.configuration)
    let substratePhase = surface.phase(tileSize: surface.detailTexturePointSize, pass: .face)
    return ChalkPreparedContactPlan(
      material: material,
      support: ChalkContactSupportPlan(
        boardImageScale: imageScale, boardPhaseX: phase.x, boardPhaseY: phase.y,
        postCompositeToothLoss: profile.postCompositeToothLoss(configuration: material.configuration),
        substrateImageScale: surface.detailTexturePointSize / Double(WritingChalkTextureResource.pixelDimension),
        substratePhaseX: substratePhase.x, substratePhaseY: substratePhase.y,
        substrateLoss: surface.detailGrainCutoutOpacity),
      strokes: try strokes.map { try plan(stroke: $0, material: material, profile: profile) })
  }

  private static func plan(
    stroke: ChalkRenderStrokeGeometry,
    material: ChalkRenderMaterial,
    profile: ChalkBrushProfile
  ) throws -> ChalkBrushStrokePlan {
    guard !stroke.id.isEmpty, !stroke.points.isEmpty else {
      throw ChalkRenderError.invalidStroke(stroke.id)
    }
    var points: [ChalkRenderStrokePoint] = []
    // Consecutive coincident samples have no travel; the latest pressure wins.
    for point in stroke.points {
      guard point.x.isFinite, point.y.isFinite, point.width.isFinite, point.width > 0 else {
        throw ChalkRenderError.invalidStroke(stroke.id)
      }
      if let previous = points.last, previous.x == point.x, previous.y == point.y {
        points[points.count - 1] = point
      } else {
        points.append(point)
      }
    }
    let seed = ChalkStableHash.value(seed: material.configuration.seed, string: stroke.id)
    var random = ChalkSplitMix64(state: seed)
    var dustRandom = ChalkSplitMix64(state: seed ^ ChalkContactPolicy.dustSeedSalt)
    let variant = Int(random.nextUInt64() % UInt64(ChalkContactPolicy.tipVariantCount))
    let mirror = (random.nextUInt64() & 1) == 1
    let tipSkew = random.nextSignedUnit() * 0.075

    guard points.count > 1 else {
      let point = points[0]
      let height = max(0.5, point.width) * profile.transverseScale
      let width = height * profile.axialAspect
      guard height.isFinite, width.isFinite else { throw ChalkRenderError.invalidStroke(stroke.id) }
      return ChalkBrushStrokePlan(
        strokeID: stroke.id,
        dabs: [ChalkBrushDab(
          centerX: point.x, centerY: point.y, angle: tipSkew,
          width: width, height: height, opacity: profile.finalOpacity,
          toothLoss: profile.contactToothLoss(
            configuration: material.configuration, normalizedPressure: 0.5),
          arcFraction: 1, variant: variant, mirrorX: mirror)],
        dust: [])
    }

    var cumulative = [Double](repeating: 0, count: points.count)
    var meanWidth = 0.0
    for index in 1..<points.count {
      let a = points[index - 1], b = points[index]
      let length = hypot(b.x - a.x, b.y - a.y)
      let total = cumulative[index - 1] + length
      guard length.isFinite, length > 0, total.isFinite, total > cumulative[index - 1] else {
        throw ChalkRenderError.invalidStroke(stroke.id)
      }
      cumulative[index] = total
      let weight = length / total
      let segmentWidth = a.width * 0.5 + b.width * 0.5
      meanWidth = meanWidth * (1 - weight) + segmentWidth * weight
    }
    let finalDistance = cumulative[cumulative.count - 1]
    guard meanWidth.isFinite, meanWidth > 0 else { throw ChalkRenderError.invalidStroke(stroke.id) }
    // Admission uses the original point-mean width and original spacing.
    // Check the floating-point estimate before converting it to an integer.
    let pointMeanWidth = stroke.points.reduce(0.0) { $0 + $1.width / Double(stroke.points.count) }
    guard pointMeanWidth.isFinite, pointMeanWidth > 0 else {
      throw ChalkRenderError.invalidStroke(stroke.id)
    }
    let admissionSpacing = max(ChalkContactPolicy.minimumSpacing,
      pointMeanWidth * 0.5 * profile.admissionSpacingRadiusFraction)
    let maximumIntervals = maximumDabsPerStroke - 1
    let admittedIntervals = ceil(finalDistance / admissionSpacing)
    guard admittedIntervals.isFinite, admittedIntervals <= Double(maximumIntervals) else {
      throw ChalkRenderError.resourceLimitExceeded(
        resource: "chalk contact dabs", actual: maximumDabsPerStroke + 1, limit: maximumDabsPerStroke)
    }
    // Use one bounded, uniform arc grid. Denser pigment deposition consumes
    // the available budget rather than rejecting an historically valid path.
    let desiredSpacing = max(ChalkContactPolicy.minimumSpacing,
      meanWidth * 0.5 * profile.spacingRadiusFraction)
    let intervals = Int(min(Double(maximumIntervals), max(1, ceil(finalDistance / desiredSpacing))))
    let spacing = finalDistance / Double(intervals)
    var dabs: [ChalkBrushDab] = []
    dabs.reserveCapacity(intervals + 1)
    var dust: [ChalkDustParticle] = []
    var sampleIndex = 1
    var filteredAngle: Double?
    var filteredScatter = 0.0
    var filteredRadiusNoise = 0.0
    var filteredDepositionNoise = 0.0

    for dabIndex in 0...intervals {
      let distance = dabIndex == intervals ? finalDistance
        : finalDistance * (Double(dabIndex) / Double(intervals))
      while sampleIndex < points.count - 1, cumulative[sampleIndex] < distance { sampleIndex += 1 }
      let previous = points[sampleIndex - 1], next = points[sampleIndex]
      let span = cumulative[sampleIndex] - cumulative[sampleIndex - 1]
      let local = min(1, max(0, (distance - cumulative[sampleIndex - 1]) / span))
      let x = previous.x * (1 - local) + next.x * local
      let y = previous.y * (1 - local) + next.y * local
      let sourceWidth = previous.width * (1 - local) + next.width * local
      // Apply pressure to a dimensionless ratio, not to a width measured in pt.
      let relativeWidth = sourceWidth / meanWidth
      let pressureWidth = max(ChalkContactPolicy.minimumWidth, meanWidth * pow(relativeWidth, profile.pressureGamma))
      let relativePressure = min(1.30, max(0.55, relativeWidth))
      let pressure = min(1, max(0, (relativePressure - 0.55) / 0.75))
      guard x.isFinite, y.isFinite, pressureWidth.isFinite else {
        throw ChalkRenderError.invalidStroke(stroke.id)
      }
      let rawAngle = atan2(next.y - previous.y, next.x - previous.x) + tipSkew
      let angle: Double
      if let current = filteredAngle {
        let delta = atan2(sin(rawAngle - current), cos(rawAngle - current))
        angle = current + delta * profile.directionResponse
      } else {
        angle = rawAngle
      }
      filteredAngle = angle
      filteredScatter = filteredScatter * ChalkContactPolicy.scatterMemory
        + random.nextSignedUnit() * (1 - ChalkContactPolicy.scatterMemory)
      filteredRadiusNoise = filteredRadiusNoise * ChalkContactPolicy.radiusMemory
        + random.nextSignedUnit() * (1 - ChalkContactPolicy.radiusMemory)
      filteredDepositionNoise = filteredDepositionNoise * ChalkContactPolicy.depositionMemory
        + random.nextSignedUnit() * (1 - ChalkContactPolicy.depositionMemory)
      let normalX = -sin(angle), normalY = cos(angle)
      let scatter = pressureWidth * (
        profile.scatterNormalFraction * filteredScatter + profile.microJitter * random.nextSignedUnit())
      let radiusScale = max(0.62, 1 + profile.radiusJitter * filteredRadiusNoise
        + profile.microJitter * 0.75 * random.nextSignedUnit())
      let depositionScale = max(0.18, 1 - profile.depositionJitter * 0.5
        + profile.depositionJitter * 0.5 * filteredDepositionNoise)
      let height = pressureWidth * profile.transverseScale * radiusScale
      let width = height * profile.axialAspect
      let overlap = max(1, width * profile.overlapCoverage / spacing)
      let rampLength = max(1, meanWidth * ChalkContactPolicy.endpointContactLengths)
      let edgeDistance = min(distance, finalDistance - distance)
      let t = min(1, max(0, edgeDistance / rampLength))
      let smooth = t * t * (3 - 2 * t)
      let envelope = ChalkContactPolicy.minimumEndpointAdhesion
        + (1 - ChalkContactPolicy.minimumEndpointAdhesion) * smooth
      let adhesion = (0.62 + 0.38 * pressure) * depositionScale * envelope
      // Coverage is composited multiplicatively: density/overlap is the
      // quantity to modulate, rather than multiplying already-linear alpha.
      let opacity = 1 - pow(1 - profile.finalOpacity, adhesion / overlap)
      let fraction = distance / finalDistance
      let centerX = x + normalX * scatter, centerY = y + normalY * scatter
      guard centerX.isFinite, centerY.isFinite, width.isFinite, height.isFinite,
        opacity.isFinite, width > 0, height > 0
      else { throw ChalkRenderError.invalidStroke(stroke.id) }
      dabs.append(ChalkBrushDab(
        centerX: centerX, centerY: centerY, angle: angle,
        width: width, height: height, opacity: opacity,
        toothLoss: profile.contactToothLoss(configuration: material.configuration, normalizedPressure: pressure),
        arcFraction: fraction, variant: variant, mirrorX: mirror))

      if material.configuration.edgeRoughness > 0, dustRandom.nextUnit() < profile.dustRate {
        let side: Double = dustRandom.nextUnit() < 0.5 ? -1 : 1
        let spread = pressureWidth * profile.dustSpread * (0.48 + dustRandom.nextUnit() * 0.62)
        let along = pressureWidth * dustRandom.nextSignedUnit() * 0.36
        let dustX = x + cos(angle) * along + normalX * spread * side
        let dustY = y + sin(angle) * along + normalY * spread * side
        let radius = max(ChalkContactPolicy.minimumDustRadius,
          pressureWidth * profile.dustRadiusScale * (0.015 + dustRandom.nextUnit() * 0.045))
        guard dustX.isFinite, dustY.isFinite, radius.isFinite else {
          throw ChalkRenderError.invalidStroke(stroke.id)
        }
        dust.append(ChalkDustParticle(
          centerX: dustX, centerY: dustY, radius: radius, angle: angle,
          opacity: profile.dustOpacity * (0.55 + dustRandom.nextUnit() * 0.45),
          arcFraction: fraction,
          variant: Int(dustRandom.nextUInt64() % UInt64(ChalkContactPolicy.tipVariantCount))))
      }
    }
    return ChalkBrushStrokePlan(strokeID: stroke.id, dabs: dabs, dust: dust)
  }
}
