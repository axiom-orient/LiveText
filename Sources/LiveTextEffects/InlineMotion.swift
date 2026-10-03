import Foundation

/// Presentation-only motion vocabulary for one render pass.
///
/// These presets never alter source identity, layout, hit geometry, accessibility,
/// or reveal timing. A host owns `InlineMotionPhase` and may drive it with any
/// clock/animation system. Every built-in preset begins and settles at identity.
public enum InlineMotionStyle: String, Codable, CaseIterable, Hashable, Sendable {
  case none
  case happy
  case curious
  case surprised
  case thinking
  case excited
}

/// A validated scalar phase for presentation motion.
///
/// This is deliberately separate from `InlineRenderRevealPhase`: semantic reveal
/// and expressive motion are independent timelines even when a host chooses to
/// animate them together.
public struct InlineMotionPhase: Codable, Equatable, Hashable, Sendable {
  public let rawValue: Double

  public static let zero = InlineMotionPhase(unchecked: 0)
  public static let complete = InlineMotionPhase(unchecked: 1)

  public init(rawValue: Double) throws {
    guard rawValue.isFinite, (0...1).contains(rawValue) else {
      throw InlineMotionError.invalidPhase(rawValue)
    }
    self.rawValue = rawValue
  }

  public init(_ rawValue: Double) throws {
    try self.init(rawValue: rawValue)
  }

  private init(unchecked rawValue: Double) {
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    try self.init(rawValue: decoder.singleValueContainer().decode(Double.self))
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.singleValueContainer()
    try values.encode(rawValue)
  }
}

public enum InlineMotionError: Error, Equatable, Sendable {
  case invalidPhase(Double)
  case invalidIntensity(Double)
  case invalidStagger(Double)
  case invalidAtomCount(Int)
  case invalidAtomIndex(index: Int, count: Int)
  case invalidAtomHeight(Double)
}

/// Renderer-neutral configuration for cartoon-like presentation motion.
///
/// `intensity` is bounded to keep transforms readable and hit geometry useful
/// while still allowing obvious squash/stretch and overshoot. `stagger` is the
/// maximum fraction of the global phase reserved for document-order staggering.
public struct InlineMotionConfiguration: Codable, Equatable, Hashable, Sendable {
  public let style: InlineMotionStyle
  public let intensity: Double
  public let stagger: Double

  private enum CodingKeys: String, CodingKey { case style, intensity, stagger }

  public init(
    style: InlineMotionStyle,
    intensity: Double = 1,
    stagger: Double = 0.18
  ) throws {
    guard intensity.isFinite, (0...1).contains(intensity) else {
      throw InlineMotionError.invalidIntensity(intensity)
    }
    guard stagger.isFinite, (0...0.45).contains(stagger) else {
      throw InlineMotionError.invalidStagger(stagger)
    }
    self.style = style
    self.intensity = intensity
    self.stagger = stagger
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      style: values.decode(InlineMotionStyle.self, forKey: .style),
      intensity: values.decode(Double.self, forKey: .intensity),
      stagger: values.decode(Double.self, forKey: .stagger)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(style, forKey: .style)
    try values.encode(intensity, forKey: .intensity)
    try values.encode(stagger, forKey: .stagger)
  }

  public static let none = try! InlineMotionConfiguration(style: .none, intensity: 0, stagger: 0)
  public static let happy = try! InlineMotionConfiguration(
    style: .happy, intensity: 0.84, stagger: 0.14)
  public static let curious = try! InlineMotionConfiguration(
    style: .curious, intensity: 0.70, stagger: 0.10)
  public static let surprised = try! InlineMotionConfiguration(
    style: .surprised, intensity: 1, stagger: 0.04)
  public static let thinking = try! InlineMotionConfiguration(
    style: .thinking, intensity: 0.54, stagger: 0.20)
  public static let excited = try! InlineMotionConfiguration(
    style: .excited, intensity: 1, stagger: 0.09)
}

/// One sampled visual transform. Values are renderer-neutral and finite.
/// Translation uses points; rotation uses radians. Anchor values are normalized
/// within the logical atom cell (`0` = top/leading, `1` = bottom/trailing).
public struct InlineMotionTransform: Equatable, Hashable, Sendable {
  public let translationX: Double
  public let translationY: Double
  public let scaleX: Double
  public let scaleY: Double
  public let rotationRadians: Double
  public let anchorX: Double
  public let anchorY: Double

  public static let identity = InlineMotionTransform(
    translationX: 0,
    translationY: 0,
    scaleX: 1,
    scaleY: 1,
    rotationRadians: 0,
    anchorX: 0.5,
    anchorY: 0.5
  )

  fileprivate init(
    translationX: Double,
    translationY: Double,
    scaleX: Double,
    scaleY: Double,
    rotationRadians: Double,
    anchorX: Double,
    anchorY: Double
  ) {
    self.translationX = translationX
    self.translationY = translationY
    self.scaleX = scaleX
    self.scaleY = scaleY
    self.rotationRadians = rotationRadians
    self.anchorX = anchorX
    self.anchorY = anchorY
  }
}

extension InlineMotionConfiguration {
  /// Samples the configured motion for one atom without owning a clock or
  /// mutating renderer state.
  ///
  /// - Parameters:
  ///   - phase: Host-owned global motion phase.
  ///   - atomIndex: Stable document-order index for this render pass.
  ///   - atomCount: Number of atoms participating in the pass.
  ///   - atomHeight: Logical atom height in points, used to scale translation.
  ///   - atomID: Stable source identity used only to alternate tilt direction.
  ///   - reduceMotion: When true, all spatial motion is suppressed.
  public func sample(
    phase: InlineMotionPhase,
    atomIndex: Int,
    atomCount: Int,
    atomHeight: Double,
    atomID: String,
    reduceMotion: Bool = false
  ) throws -> InlineMotionTransform {
    guard atomCount > 0 else { throw InlineMotionError.invalidAtomCount(atomCount) }
    guard (0..<atomCount).contains(atomIndex) else {
      throw InlineMotionError.invalidAtomIndex(index: atomIndex, count: atomCount)
    }
    guard atomHeight.isFinite, atomHeight >= 0 else {
      throw InlineMotionError.invalidAtomHeight(atomHeight)
    }
    return sampleValidated(
      phase: phase,
      atomIndex: atomIndex,
      atomCount: atomCount,
      atomHeight: atomHeight,
      atomID: atomID,
      reduceMotion: reduceMotion
    )
  }

  /// Package renderer fast path for values already admitted by document/layout invariants.
  package func sampleValidated(
    phase: InlineMotionPhase,
    atomIndex: Int,
    atomCount: Int,
    atomHeight: Double,
    atomID: String,
    reduceMotion: Bool = false
  ) -> InlineMotionTransform {
    precondition(atomCount > 0, "motion atom count must be positive")
    precondition((0..<atomCount).contains(atomIndex), "motion atom ordinal must be in range")
    precondition(
      atomHeight.isFinite && atomHeight >= 0, "motion atom height must be finite and nonnegative")
    guard style != .none, intensity > 0, !reduceMotion else { return .identity }
    guard phase != .zero, phase != .complete else { return .identity }

    let height = atomHeight
    let rank = atomCount <= 1 ? 0 : Double(atomIndex) / Double(atomCount - 1)
    let delay = stagger * rank
    let denominator = 1 - delay
    precondition(denominator > 0, "validated motion stagger must leave positive local duration")
    let p = clamp((phase.rawValue - delay) / denominator)
    guard p > 0, p < 1 else { return .identity }

    let direction = stableDirection(atomID)
    let strength = intensity

    switch style {
    case .none:
      return .identity

    case .happy:
      // Anticipate down, spring upward, land with a broad squash, then settle.
      let tx = keyframed(
        p,
        points: [
          (0, 0), (0.10, -0.22), (0.32, 0.58), (0.52, 0.30), (0.68, -0.28),
          (0.83, 0.12), (1, 0),
        ])
      let ty = keyframed(
        p,
        points: [
          (0, 0), (0.10, 0.026), (0.32, -0.102), (0.52, -0.058), (0.68, 0.020),
          (0.83, -0.010), (1, 0),
        ])
      let sx = keyframed(
        p,
        points: [
          (0, 1), (0.10, 1.050), (0.32, 0.935), (0.52, 0.970), (0.68, 1.060),
          (0.83, 0.987), (1, 1),
        ])
      let sy = keyframed(
        p,
        points: [
          (0, 1), (0.10, 0.925), (0.32, 1.165), (0.52, 1.090), (0.68, 0.900),
          (0.83, 1.028), (1, 1),
        ])
      let turn = keyframed(
        p,
        points: [
          (0, 0), (0.10, -0.28), (0.32, 0.62), (0.52, 0.26), (0.68, -0.34),
          (0.83, 0.14), (1, 0),
        ])
      return makeTransform(
        x: direction * height * 0.030 * tx * strength,
        y: height * ty * strength,
        scaleX: 1 + (sx - 1) * strength,
        scaleY: 1 + (sy - 1) * strength,
        rotation: direction * degrees(4.0) * turn * strength,
        anchorY: 0.86
      )

    case .curious:
      // A small counter-lean gives the later tilt intention instead of drift.
      let lean = keyframed(
        p,
        points: [(0, 0), (0.16, -0.18), (0.48, 1.0), (0.70, 0.82), (0.86, 0.28), (1, 0)])
      let bob = keyframed(
        p,
        points: [
          (0, 0), (0.16, 0.010), (0.48, -0.026), (0.70, -0.018), (0.86, 0.004),
          (1, 0),
        ])
      let stretch = keyframed(
        p,
        points: [(0, 0), (0.16, -0.15), (0.48, 1.0), (0.70, 0.68), (0.86, 0.22), (1, 0)])
      return makeTransform(
        x: direction * height * 0.044 * lean * strength,
        y: height * bob * strength,
        scaleX: 1 - 0.012 * stretch * strength,
        scaleY: 1 + 0.042 * stretch * strength,
        rotation: direction * degrees(8.2) * lean * strength,
        anchorY: 0.74
      )

    case .surprised:
      // A short collective anticipation is followed by an explosive stretch,
      // a hard landing squash, and two rapidly diminishing rebounds.
      let sx = keyframed(
        p,
        points: [
          (0, 1), (0.12, 1.10), (0.30, 0.84), (0.52, 1.12), (0.69, 0.95),
          (0.84, 1.02), (1, 1),
        ])
      let sy = keyframed(
        p,
        points: [
          (0, 1), (0.12, 0.76), (0.30, 1.34), (0.52, 0.86), (0.69, 1.08),
          (0.84, 0.98), (1, 1),
        ])
      let ty = keyframed(
        p,
        points: [
          (0, 0), (0.12, 0.060), (0.30, -0.160), (0.52, 0.032), (0.69, -0.036),
          (0.84, 0.009), (1, 0),
        ])
      let turn = keyframed(
        p,
        points: [
          (0, 0), (0.12, 0.45), (0.30, -0.70), (0.52, 0.48), (0.69, -0.28),
          (0.84, 0.12), (1, 0),
        ])
      return makeTransform(
        x: direction * height * 0.018 * turn * strength,
        y: height * ty * strength,
        scaleX: 1 + (sx - 1) * strength,
        scaleY: 1 + (sy - 1) * strength,
        rotation: direction * degrees(4.0) * turn * strength,
        anchorY: 0.90
      )

    case .thinking:
      // Slow, deliberately irregular lean: low energy with a clear directional mood.
      let lean = keyframed(
        p,
        points: [(0, 0), (0.20, 0.16), (0.52, 1.0), (0.78, 0.84), (0.92, 0.25), (1, 0)])
      let drift = keyframed(
        p,
        points: [
          (0, 0), (0.20, -0.005), (0.52, 0.014), (0.78, -0.012), (0.92, 0.004),
          (1, 0),
        ])
      return makeTransform(
        x: direction * height * 0.034 * lean * strength,
        y: height * drift * strength,
        scaleX: 1 - 0.012 * lean * strength,
        scaleY: 1 + 0.020 * lean * strength,
        rotation: direction * degrees(5.0) * lean * strength,
        anchorY: 0.72
      )

    case .excited:
      // Two deliberate impulses read more clearly than frame-to-frame jitter:
      // compress → leap → squash → smaller leap → settle.
      let sx = keyframed(
        p,
        points: [
          (0, 1), (0.08, 1.10), (0.24, 0.90), (0.42, 1.12), (0.57, 0.95),
          (0.72, 1.06), (0.84, 0.98), (1, 1),
        ])
      let sy = keyframed(
        p,
        points: [
          (0, 1), (0.08, 0.84), (0.24, 1.24), (0.42, 0.86), (0.57, 1.15),
          (0.72, 0.92), (0.84, 1.04), (1, 1),
        ])
      let ty = keyframed(
        p,
        points: [
          (0, 0), (0.08, 0.040), (0.24, -0.120), (0.42, 0.032), (0.57, -0.076),
          (0.72, 0.016), (0.84, -0.024), (1, 0),
        ])
      let turn = keyframed(
        p,
        points: [
          (0, 0), (0.08, -0.42), (0.24, 1.0), (0.42, -0.86), (0.57, 0.66),
          (0.72, -0.42), (0.84, 0.20), (1, 0),
        ])
      return makeTransform(
        x: direction * height * 0.040 * turn * strength,
        y: height * ty * strength,
        scaleX: 1 + (sx - 1) * strength,
        scaleY: 1 + (sy - 1) * strength,
        rotation: direction * degrees(8.5) * turn * strength,
        anchorY: 0.88
      )
    }
  }

  private func makeTransform(
    x: Double,
    y: Double,
    scaleX: Double,
    scaleY: Double,
    rotation: Double,
    anchorY: Double
  ) -> InlineMotionTransform {
    precondition(
      x.isFinite && y.isFinite && scaleX.isFinite && scaleY.isFinite && rotation.isFinite,
      "motion equations must produce finite values"
    )
    precondition((0.60...1.40).contains(scaleX), "motion scaleX escaped the visual envelope")
    precondition((0.60...1.40).contains(scaleY), "motion scaleY escaped the visual envelope")
    precondition(
      (-degrees(12)...degrees(12)).contains(rotation),
      "motion rotation escaped the visual envelope"
    )
    precondition((0...1).contains(anchorY), "motion anchor must stay inside the logical atom cell")

    return InlineMotionTransform(
      translationX: x,
      translationY: y,
      scaleX: scaleX,
      scaleY: scaleY,
      rotationRadians: rotation,
      anchorX: 0.5,
      anchorY: anchorY
    )
  }
}

private func clamp(_ value: Double, lower: Double = 0, upper: Double = 1) -> Double {
  min(upper, max(lower, value))
}

private func degrees(_ value: Double) -> Double {
  value * .pi / 180
}

private func stableDirection(_ string: String) -> Double {
  // FNV-1a is sufficient here: this is a deterministic visual alternator,
  // not an identity or cryptographic authority.
  var hash: UInt64 = 14_695_981_039_346_656_037
  for byte in string.utf8 {
    hash ^= UInt64(byte)
    hash &*= 1_099_511_628_211
  }
  return hash & 1 == 0 ? -1 : 1
}

private func keyframed(_ phase: Double, points: [(Double, Double)]) -> Double {
  precondition(!points.isEmpty, "motion keyframes must not be empty")
  guard let first = points.first, let last = points.last else {
    preconditionFailure("motion keyframes must not be empty")
  }
  if phase <= first.0 { return first.1 }
  if phase >= last.0 { return last.1 }

  for index in 1..<points.count {
    let right = points[index]
    let left = points[index - 1]
    precondition(right.0 > left.0, "motion keyframe phases must be strictly increasing")
    guard phase <= right.0 else { continue }
    let raw = clamp((phase - left.0) / (right.0 - left.0))
    let eased = raw * raw * (3 - 2 * raw)
    return left.1 + (right.1 - left.1) * eased
  }
  return last.1
}
