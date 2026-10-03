import Foundation
import LiveTextEffects

/// Internal spelling for the public renderer-neutral chalk style authority.
/// There is intentionally no second chalk-style enum in the Apple renderer.
package typealias ChalkRenderStyle = WritingChalkStyle

package struct ChalkRenderMaterial: Hashable, Sendable {
  package let style: ChalkRenderStyle
  package let configuration: WritingChalkConfiguration

  package init(style: ChalkRenderStyle, configuration: WritingChalkConfiguration) {
    self.style = style
    self.configuration = configuration
  }

  package static func liveText(_ configuration: WritingChalkConfiguration) -> ChalkRenderMaterial {
    ChalkRenderMaterial(style: configuration.style, configuration: configuration)
  }
}

package enum ChalkRenderSourceKind: Hashable, Sendable {
  case strokeGeometry
  case alphaMask
}

package enum ChalkRenderExecutionTopology: Hashable, Sendable {
  case contactDabs
  case depositedSurface
  case hatchField
  case smudgeResidue
}

private enum ChalkRenderGeometryRole {
  case contactStroke
  case depositedFill
  case hatchField
  case smudgeResidue
}

extension ChalkRenderMaterial {
  private var geometryRole: ChalkRenderGeometryRole {
    switch style {
    case .fineLine, .dryBrush: return .contactStroke
    case .powderFill: return .depositedFill
    case .diagonalHatch, .crossHatch: return .hatchField
    case .smudged: return .smudgeResidue
    }
  }

  package func executionTopology(
    for source: ChalkRenderSourceKind
  ) -> ChalkRenderExecutionTopology {
    switch geometryRole {
    case .contactStroke:
      return source == .strokeGeometry ? .contactDabs : .depositedSurface
    case .depositedFill:
      return .depositedSurface
    case .hatchField:
      return .hatchField
    case .smudgeResidue:
      return .smudgeResidue
    }
  }
}

struct ChalkSplitMix64: Sendable {
  private(set) var state: UInt64

  mutating func nextUInt64() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }

  mutating func nextUnit() -> Double {
    Double(nextUInt64() >> 11) / Double(UInt64.max >> 11)
  }

  mutating func nextSignedUnit() -> Double { nextUnit() * 2 - 1 }
}

enum ChalkStableHash {
  static func value(seed: UInt64, string: String) -> UInt64 {
    var hash = seed ^ 14_695_981_039_346_656_037
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return hash
  }

  static func value(seed: UInt64, index: Int) -> UInt64 {
    var hash = seed ^ UInt64(bitPattern: Int64(index))
    hash ^= hash >> 30
    hash &*= 0xBF58_476D_1CE4_E5B9
    hash ^= hash >> 27
    hash &*= 0x94D0_49BB_1331_11EB
    return hash ^ (hash >> 31)
  }
}

struct ChalkRenderTextureProfile: Sendable {
  let tileScale: Double
  let edgeGain: Double
}

extension ChalkRenderStyle {
  var textureProfile: ChalkRenderTextureProfile {
    switch self {
    case .fineLine:
      return ChalkRenderTextureProfile(tileScale: 0.52, edgeGain: 1.00)
    case .dryBrush:
      return ChalkRenderTextureProfile(tileScale: 0.68, edgeGain: 1.18)
    case .powderFill:
      return ChalkRenderTextureProfile(tileScale: 0.56, edgeGain: 1.00)
    case .diagonalHatch:
      return ChalkRenderTextureProfile(tileScale: 0.56, edgeGain: 0.92)
    case .crossHatch:
      return ChalkRenderTextureProfile(tileScale: 0.56, edgeGain: 0.96)
    case .smudged:
      return ChalkRenderTextureProfile(tileScale: 0.76, edgeGain: 0.58)
    }
  }
}

struct ChalkHatchFamilyProfile: Sendable {
  let angle: Double
  let spacing: Double
  let normalOrigin: Double
  let lineWidth: Double
  let runLength: Double
  let gapLength: Double
  let normalWobble: Double
  let opacity: Double
}

struct ChalkSurfaceProfile: Sendable {
  let faceOpacity: Double
  let underpaintOpacity: Double
  let topologyOpacity: Double
  let microOpacity: Double
  let hatchFamilies: [ChalkHatchFamilyProfile]
  let smudgeCoreOpacity: Double
}

extension ChalkRenderMaterial {
  var surfaceProfile: ChalkSurfaceProfile {
    let c = configuration
    let scale = max(0.62, min(1.85, c.grainScale / 3.5))
    let grain = c.grainAmount
    let erosion = c.erosionAmount

    switch style {
    case .fineLine:
      return ChalkSurfaceProfile(
        faceOpacity: 0.96,
        underpaintOpacity: 0.018 + 0.020 * grain,
        topologyOpacity: min(0.88, 0.68 + 0.48 * erosion),
        microOpacity: min(0.72, 0.36 + 0.38 * grain),
        hatchFamilies: [], smudgeCoreOpacity: 0)
    case .dryBrush:
      return ChalkSurfaceProfile(
        faceOpacity: 0.88,
        underpaintOpacity: 0.020 + 0.035 * grain,
        topologyOpacity: min(1, 0.82 + 0.18 * erosion),
        microOpacity: min(0.88, 0.28 + 0.52 * grain),
        hatchFamilies: [], smudgeCoreOpacity: 0)
    case .powderFill:
      return ChalkSurfaceProfile(
        faceOpacity: 0.98,
        underpaintOpacity: 0.105 + 0.060 * grain,
        topologyOpacity: min(0.78, 0.52 + 0.24 * erosion),
        microOpacity: min(0.74, 0.22 + 0.38 * grain),
        hatchFamilies: [], smudgeCoreOpacity: 0)
    case .diagonalHatch:
      return ChalkSurfaceProfile(
        faceOpacity: 1.0,
        underpaintOpacity: 0.020 + 0.025 * grain,
        topologyOpacity: min(0.52, 0.16 + 0.28 * erosion),
        microOpacity: min(0.48, 0.12 + 0.24 * grain),
        hatchFamilies: [
          ChalkHatchFamilyProfile(
            angle: -.pi * 0.188_888_888_9,
            spacing: max(2.8, 5.10 * scale),
            normalOrigin: 1.25,
            lineWidth: max(3.60, (4.45 + 1.20 * grain) * sqrt(scale)),
            runLength: max(24, (42 - 3 * erosion) * scale),
            gapLength: max(0.40, (0.55 + 0.95 * erosion) * scale),
            normalWobble: (0.48 + 1.05 * c.edgeRoughness) * sqrt(scale),
            opacity: min(1, 0.90 + 0.10 * grain))
        ], smudgeCoreOpacity: 0)
    case .crossHatch:
      let primarySpacing = max(2.6, 3.95 * scale)
      let secondarySpacing = max(2.8, 5.20 * scale)
      let width = max(2.10, (2.70 + 0.70 * grain) * sqrt(scale))
      let run = max(14, (30 - 4 * erosion) * scale)
      let gap = max(0.50, (0.72 + 1.50 * erosion) * scale)
      let wobble = (0.22 + 0.56 * c.edgeRoughness) * sqrt(scale)
      let opacity = min(1, 0.86 + 0.12 * grain)
      return ChalkSurfaceProfile(
        faceOpacity: 0.98,
        underpaintOpacity: 0.018 + 0.020 * grain,
        topologyOpacity: min(0.52, 0.16 + 0.28 * erosion),
        microOpacity: min(0.48, 0.12 + 0.24 * grain),
        hatchFamilies: [
          ChalkHatchFamilyProfile(
            angle: -.pi * 0.133_333_333_3, spacing: primarySpacing, normalOrigin: 1.0,
            lineWidth: width, runLength: run, gapLength: gap,
            normalWobble: wobble, opacity: opacity),
          ChalkHatchFamilyProfile(
            angle: .pi * 0.20, spacing: secondarySpacing, normalOrigin: 4.0,
            lineWidth: width * 0.96, runLength: run * 0.92, gapLength: gap * 1.08,
            normalWobble: wobble, opacity: opacity * 0.94),
        ], smudgeCoreOpacity: 0)
    case .smudged:
      return ChalkSurfaceProfile(
        faceOpacity: 0.70,
        underpaintOpacity: 0.055 + 0.055 * grain,
        topologyOpacity: min(0.96, 0.66 + 0.28 * erosion),
        microOpacity: min(0.76, 0.26 + 0.46 * grain),
        hatchFamilies: [], smudgeCoreOpacity: min(0.42, 0.24 + 0.20 * grain))
    }
  }
}

struct ChalkHatchSegment: Sendable {
  let startX: Double
  let startY: Double
  let endX: Double
  let endY: Double
  let lineWidth: Double
  let opacity: Double
}

struct ChalkSmudgeLayerPlan: Sendable {
  let offsetX: Double
  let offsetY: Double
  let blurRadius: Double
  let opacity: Double
  let lossLayers: [ChalkPigmentLossLayerPlan]
}

struct ChalkPowderCloudLayerPlan: Sendable {
  let offsetX: Double
  let offsetY: Double
  let blurRadius: Double
  let opacity: Double
  let textureMask: ChalkPigmentLossLayerPlan
}

struct ChalkEdgeDustPlan: Sendable {
  let offsetX: Double
  let offsetY: Double
  let spread: Double
  let blurRadius: Double
  let opacity: Double
  let textureMask: ChalkPigmentLossLayerPlan
}

enum ChalkSurfacePigmentLayer {
  case face
  case underpaint
  case hatchField
  case powderCloud(Int)
  case smudge(Int)
  case smudgeCore
}

struct ChalkPigmentLossLayerPlan: Sendable {
  let textureStyle: ChalkRenderStyle
  let opacity: Double
  let imageScale: Double
  let phaseX: Double
  let phaseY: Double
  let alphaThreshold: Double?
}

enum ChalkSurfacePlanner {
  static let texturePixelSize = 256.0
  static let maximumHatchSegments = 16_384

  static func texturePhase(seed: UInt64, tileSize: Double, salt: UInt64 = 0) -> (
    x: Double, y: Double
  ) {
    guard tileSize.isFinite, tileSize > 0 else { return (0, 0) }
    var generator = ChalkSplitMix64(state: seed ^ salt)
    return (generator.nextUnit() * tileSize, generator.nextUnit() * tileSize)
  }

  static func topologyLossPlan(material: ChalkRenderMaterial, salt: UInt64 = 0)
    -> ChalkPigmentLossLayerPlan?
  {
    let c = material.configuration
    let profile = material.surfaceProfile
    guard c.erosionAmount > 0, profile.topologyOpacity > 0 else { return nil }
    let topologyStyle: ChalkRenderStyle =
      material.style == .diagonalHatch || material.style == .crossHatch
      ? .powderFill : material.style
    return pigmentLossPlan(
      material: material, textureStyle: topologyStyle,
      opacity: min(1, profile.topologyOpacity), salt: 0x544F_504F_4C4F_4759 ^ salt,
      alphaThreshold: topologyAlphaThreshold(material: material))
  }

  private static func topologyAlphaThreshold(material: ChalkRenderMaterial) -> Double? {
    let roughness = material.configuration.edgeRoughness
    switch material.style {
    case .fineLine: return max(0.035, 0.052 - 0.018 * roughness)
    case .dryBrush: return max(0.070, 0.125 - 0.055 * roughness)
    case .powderFill: return max(0.040, 0.065 - 0.035 * roughness)
    case .diagonalHatch, .crossHatch: return max(0.045, 0.070 - 0.030 * roughness)
    case .smudged: return nil
    }
  }

  static func microLossPlan(material: ChalkRenderMaterial, salt: UInt64 = 0)
    -> ChalkPigmentLossLayerPlan?
  {
    let c = material.configuration
    let profile = material.surfaceProfile
    guard c.grainAmount > 0, profile.microOpacity > 0 else { return nil }
    return pigmentLossPlan(
      material: material, textureStyle: .fineLine,
      opacity: min(1, profile.microOpacity), salt: 0x4D49_4352_4F50_4954 ^ salt,
      alphaThreshold: nil)
  }

  private static func pigmentLossPlan(
    material: ChalkRenderMaterial,
    textureStyle: ChalkRenderStyle,
    opacity: Double,
    salt: UInt64,
    alphaThreshold: Double?
  ) -> ChalkPigmentLossLayerPlan {
    let p = textureStyle.textureProfile
    let c = material.configuration
    let imageScale = max(0.22, min(1.35, c.grainScale / 6.0 * p.tileScale))
    let tileSize = texturePixelSize * imageScale
    let phase = texturePhase(seed: c.seed, tileSize: tileSize, salt: salt)
    return ChalkPigmentLossLayerPlan(
      textureStyle: textureStyle, opacity: opacity, imageScale: imageScale,
      phaseX: phase.x, phaseY: phase.y, alphaThreshold: alphaThreshold)
  }

  static func lossLayers(material: ChalkRenderMaterial, layer: ChalkSurfacePigmentLayer)
    -> [ChalkPigmentLossLayerPlan]
  {
    let salt: UInt64
    switch layer {
    case .face: salt = 0
    case .underpaint: salt = 0x554E_4445_5250_4149
    case .hatchField: salt = 0x4841_5443_484D_4153
    case .powderCloud(let index): salt = 0x504F_5744_4552_0000 ^ UInt64(index)
    case .smudge(let index): salt = 0x534D_5544_4745_0000 ^ UInt64(index)
    case .smudgeCore: salt = 0x534D_5544_4745_434F
    }
    return [
      topologyLossPlan(material: material, salt: salt),
      microLossPlan(material: material, salt: salt),
    ].compactMap { $0 }
  }

  static func powderCloudLayers(material: ChalkRenderMaterial) -> [ChalkPowderCloudLayerPlan] {
    guard material.style == .powderFill else { return [] }
    let c = material.configuration
    let scale = max(0.64, min(1.85, c.grainScale / 3.5))
    let roughness = c.edgeRoughness
    var random = ChalkSplitMix64(state: c.seed ^ 0x504F_5744_4552_434C)
    let count = 5
    return (0..<count).map { index in
      let fraction = Double(index + 1) / Double(count)
      let angle = .pi * (0.34 + 0.32 * random.nextUnit())
      let distance = (2.8 + fraction * (8.0 + 8.0 * roughness)) * sqrt(scale)
      let lateral = random.nextSignedUnit() * (1.2 + 3.6 * roughness) * sqrt(scale)
      let tangentX = cos(angle)
      let tangentY = sin(angle)
      let normalX = -tangentY
      let normalY = tangentX
      let envelope = pow(1 - fraction * 0.42, 1.12)
      return ChalkPowderCloudLayerPlan(
        offsetX: tangentX * distance + normalX * lateral,
        offsetY: tangentY * distance + normalY * lateral,
        blurRadius: (0.08 + fraction * (0.22 + 0.36 * roughness)) * scale,
        opacity: min(0.42, (0.16 + 0.28 * c.grainAmount) * envelope),
        textureMask: pigmentLossPlan(
          material: material, textureStyle: .powderFill, opacity: 1,
          salt: 0x504F_5744_434C_0000 ^ UInt64(index),
          alphaThreshold: max(0.055, 0.105 - 0.045 * roughness)))
    }
  }

  static func edgeDustPlan(material: ChalkRenderMaterial) -> ChalkEdgeDustPlan? {
    let c = material.configuration
    guard c.edgeRoughness > 0 else { return nil }
    let p = material.style.textureProfile
    let gain: (spread: Double, opacity: Double, blur: Double)
    switch material.style {
    case .fineLine: gain = (0.72, 0.72, 0.72)
    case .dryBrush: gain = (1.55, 1.34, 1.18)
    case .powderFill: gain = (2.35, 1.60, 1.34)
    case .diagonalHatch: gain = (0.92, 0.78, 0.86)
    case .crossHatch: gain = (1.08, 0.88, 0.92)
    case .smudged: gain = (2.05, 1.16, 1.55)
    }
    let displacement = texturePhase(
      seed: c.seed, tileSize: 3.2 * c.edgeRoughness * gain.spread,
      salt: 0x4544_4745_4455_5354)
    let offsetX = displacement.x - 1.6 * c.edgeRoughness * gain.spread
    let offsetY = displacement.y - 1.6 * c.edgeRoughness * gain.spread
    return ChalkEdgeDustPlan(
      offsetX: offsetX, offsetY: offsetY,
      spread: (0.45 + 2.0 * c.edgeRoughness) * gain.spread,
      blurRadius: (0.15 + 0.55 * c.edgeRoughness) * gain.blur,
      opacity: min(0.90, (0.08 + 0.46 * c.edgeRoughness) * p.edgeGain * gain.opacity),
      textureMask: pigmentLossPlan(
        material: material, textureStyle: .powderFill, opacity: 1,
        salt: 0x4544_4745_4D41_534B,
        alphaThreshold: 0.10 + 0.12 * (1 - c.edgeRoughness)))
  }

  static func hatchSegments(
    material: ChalkRenderMaterial,
    width: Double,
    height: Double,
    maximumSegments: Int = maximumHatchSegments
  ) -> [ChalkHatchSegment] {
    let families = material.surfaceProfile.hatchFamilies
    guard !families.isEmpty, width.isFinite, height.isFinite, width > 0, height > 0,
      maximumSegments > 0
    else { return [] }
    let centerX = width * 0.5
    let centerY = height * 0.5
    let corners = [
      (-centerX, -centerY), (centerX, -centerY), (-centerX, centerY), (centerX, centerY),
    ]
    var estimates: [Double] = []
    for family in families {
      let tx = cos(family.angle)
      let ty = sin(family.angle)
      let nx = -ty
      let ny = tx
      let tv = corners.map { $0.0 * tx + $0.1 * ty }
      let nv = corners.map { $0.0 * nx + $0.1 * ny }
      let tangentSpan = (tv.max() ?? 0) - (tv.min() ?? 0)
      let normalSpan = (nv.max() ?? 0) - (nv.min() ?? 0)
      estimates.append(
        max(1, normalSpan / max(0.001, family.spacing) + 3)
          * max(1, tangentSpan / max(0.001, family.runLength + family.gapLength) + 2))
    }
    let estimatedTotal = max(1, estimates.reduce(0, +))
    let densityScale = max(1, sqrt(estimatedTotal / Double(maximumSegments)))
    var segments: [ChalkHatchSegment] = []
    segments.reserveCapacity(min(maximumSegments, Int(ceil(estimatedTotal / densityScale))))

    for (familyIndex, source) in families.enumerated() {
      let family = ChalkHatchFamilyProfile(
        angle: source.angle, spacing: source.spacing * densityScale,
        normalOrigin: source.normalOrigin * densityScale,
        lineWidth: source.lineWidth * sqrt(densityScale),
        runLength: source.runLength * densityScale, gapLength: source.gapLength * densityScale,
        normalWobble: source.normalWobble * sqrt(densityScale), opacity: source.opacity)
      let tx = cos(family.angle)
      let ty = sin(family.angle)
      let nx = -ty
      let ny = tx
      let tv = corners.map { $0.0 * tx + $0.1 * ty }
      let nv = corners.map { $0.0 * nx + $0.1 * ny }
      let minT = (tv.min() ?? 0) - family.runLength
      let maxT = (tv.max() ?? 0) + family.runLength
      let minN = (nv.min() ?? 0) - family.spacing
      let maxN = (nv.max() ?? 0) + family.spacing
      var phaseRandom = ChalkSplitMix64(
        state: material.configuration.seed ^ 0x4841_5443_4850_4841 ^ UInt64(familyIndex &* 0x9E37))
      let phase = (phaseRandom.nextUnit() * family.spacing + family.normalOrigin)
        .truncatingRemainder(dividingBy: family.spacing)
      let firstLine = Int(floor((minN - phase) / family.spacing))
      let lastLine = Int(ceil((maxN - phase) / family.spacing))
      for lineIndex in firstLine...lastLine {
        if segments.count >= maximumSegments { return segments }
        let lineSeed = ChalkStableHash.value(
          seed: material.configuration.seed ^ 0x4841_5443_484C_494E
            ^ UInt64(familyIndex &* 0x1_0001),
          index: lineIndex)
        var random = ChalkSplitMix64(state: lineSeed)
        let baseNormal = Double(lineIndex) * family.spacing + phase
        var tangent = minT - random.nextUnit() * (family.runLength + family.gapLength)
        var previousWobble = random.nextSignedUnit() * family.normalWobble
        while tangent < maxT {
          if segments.count >= maximumSegments { return segments }
          let run = family.runLength * (0.68 + 0.62 * random.nextUnit())
          let gap = family.gapLength * (0.28 + 1.44 * random.nextUnit())
          let startT = tangent + family.gapLength * 0.12 * random.nextSignedUnit()
          let endT = min(maxT, startT + run)
          let nextWobble =
            previousWobble * 0.58 + random.nextSignedUnit() * family.normalWobble * 0.42
          if endT > minT {
            segments.append(
              ChalkHatchSegment(
                startX: centerX + tx * startT + nx * (baseNormal + previousWobble),
                startY: centerY + ty * startT + ny * (baseNormal + previousWobble),
                endX: centerX + tx * endT + nx * (baseNormal + nextWobble),
                endY: centerY + ty * endT + ny * (baseNormal + nextWobble),
                lineWidth: max(0.5, family.lineWidth * (0.78 + 0.44 * random.nextUnit())),
                opacity: min(1, max(0.05, family.opacity * (0.72 + 0.28 * random.nextUnit())))))
          }
          previousWobble = nextWobble
          tangent = endT + gap
        }
      }
    }
    return segments
  }

  static func smudgeLayers(material: ChalkRenderMaterial) -> [ChalkSmudgeLayerPlan] {
    guard material.style == .smudged else { return [] }
    let c = material.configuration
    let profile = material.surfaceProfile
    let scale = max(0.64, min(1.85, c.grainScale / 3.5))
    var random = ChalkSplitMix64(state: c.seed ^ 0x534D_5544_4745_4C59)
    let baseAngle = random.nextSignedUnit() * 0.18
    let travel = (10.0 + 31.0 * c.edgeRoughness + 9.0 * c.erosionAmount) * sqrt(scale)
    let layerCount = 12
    return (0..<layerCount).map { index in
      let fraction = Double(index) / Double(layerCount - 1)
      let signedFraction = fraction * 1.14 - 0.12
      let angle = baseAngle + random.nextSignedUnit() * (0.05 + 0.24 * c.edgeRoughness)
      let tx = cos(angle)
      let ty = sin(angle)
      let nx = -ty
      let ny = tx
      let normalScatter = random.nextSignedUnit() * (0.7 + 4.2 * c.edgeRoughness) * sqrt(scale)
      let envelope = pow(1 - fraction * 0.46, 1.08)
      return ChalkSmudgeLayerPlan(
        offsetX: tx * travel * signedFraction + nx * normalScatter,
        offsetY: ty * travel * signedFraction + ny * normalScatter,
        blurRadius: (0.18 + fraction * (1.22 + 1.10 * c.erosionAmount)) * scale,
        opacity: min(0.31, profile.smudgeCoreOpacity * 0.95 * envelope),
        lossLayers: lossLayers(material: material, layer: .smudge(index)))
    }
  }
}
