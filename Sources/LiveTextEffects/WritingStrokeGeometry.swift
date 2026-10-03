import Foundation

/// Renderer-neutral variable-width stroke geometry for writing materials.
///
/// The pipeline follows the same shape as the MIT-licensed perfect-freehand
/// outline model (© Steve Ruiz): a sampled centerline receives a per-sample
/// radius from a pressure/thinning model, taper strengths shrink the radius
/// near both ends, and angle-based normal offsets produce the two outline
/// rails that adapters fill as one closed polygon — never a stroked line.
/// rough.js-style seeded edge displacement (© Preet Shihn) and the stochastic
/// dry-brush bristle runs described in the virtual-hairy-brush literature
/// (Xu, Tang, Lau, Pan, Eurographics 2002) are layered on top of the same
/// deterministic seed, so every adapter and every frame observes identical
/// geometry for identical inputs.
///
/// All coordinates are target-local points. No SwiftUI/Core Graphics values
/// appear here; adapters translate the loops into their own path types.
public enum WritingStrokeGeometryPlan {}

/// One sampled centerline point of an open or closed subpath.
public struct WritingStrokeSample: Hashable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// A filled-polygon point emitted by the stroke geometry plan.
public struct WritingPlanPoint: Hashable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// One dry-brush bristle: parallel centerline-offset runs whose gaps grow
/// with speed and dryness. `isErosion` bristles remove pigment instead of
/// depositing it.
public struct WritingBristle: Hashable, Sendable {
  public let runs: [[WritingPlanPoint]]
  public let width: Double
  public let opacity: Double
  public let isErosion: Bool
}

/// A small pigment droplet deposited near a stroke terminal.
public struct WritingSplat: Hashable, Sendable {
  public let x: Double
  public let y: Double
  public let radius: Double
  public let opacity: Double
}

/// How a stroke terminates. Real media ends differently per material:
/// chalk snaps off, markers stop square, ink brushes round or press out.
public enum WritingStrokeEndCap: Hashable, Sendable {
  /// Semicircular cap (ink brush exits).
  case round
  /// Straight cut across the stroke (chalk snap, marker stop).
  case cut
  /// Straight cut with a forward-tilted face (挫筆 angled stop).
  case angled
}

/// A knot-based stroke width profile (Inkscape PowerStroke semantics in
/// reduced form): (position, scale) knots along the stroke length with
/// smoothstep interpolation between them. Applied multiplicatively on top
/// of the material's pressure-driven radius.
public struct WritingWidthProfile: Hashable, Sendable, Codable {
  public struct Knot: Hashable, Sendable, Codable {
    /// Position along the stroke length, 0 (entry) to 1 (exit).
    public let position: Double
    /// Multiplier on the material's nominal radius.
    public let scale: Double

    public init(position: Double, scale: Double) {
      self.position = min(1, max(0, position.isFinite ? position : 0))
      self.scale = max(0.02, min(3, scale.isFinite ? scale : 1))
    }

    private enum CodingKeys: String, CodingKey { case position, scale }

    public init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      let position = try values.decode(Double.self, forKey: .position)
      let scale = try values.decode(Double.self, forKey: .scale)
      let canonical = Self(position: position, scale: scale)
      guard canonical.position == position, canonical.scale == scale else {
        throw DecodingError.dataCorruptedError(
          forKey: canonical.position != position ? .position : .scale,
          in: values,
          debugDescription: "width-profile knot must already satisfy canonical bounds"
        )
      }
      self = canonical
    }
  }

  public let knots: [Knot]

  public init(knots: [Knot]) {
    self.knots = knots.sorted { $0.position < $1.position }
  }

  private enum CodingKeys: String, CodingKey { case knots }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let knots = try values.decode([Knot].self, forKey: .knots)
    guard zip(knots, knots.dropFirst()).allSatisfy({ $0.position <= $1.position }) else {
      throw DecodingError.dataCorruptedError(
        forKey: .knots, in: values,
        debugDescription: "width-profile knots must be stored in nondecreasing position order"
      )
    }
    self.knots = knots
  }

  /// Nib character: a slight belly with a lighter exit stroke.
  public static let nib = WritingWidthProfile(knots: [
    Knot(position: 0, scale: 1),
    Knot(position: 0.4, scale: 1.06),
    Knot(position: 1, scale: 0.9),
  ])

  /// Multiplicative width scale at arclength fraction `u`.
  public func scale(at u: Double) -> Double {
    let u = min(1, max(0, u.isFinite ? u : 0))
    guard let first = knots.first else { return 1 }
    if u <= first.position { return first.scale }
    for index in 1..<knots.count {
      let b = knots[index]
      if u <= b.position {
        let a = knots[index - 1]
        let span = max(b.position - a.position, 1e-9)
        let t = (u - a.position) / span
        let smooth = t * t * (3 - 2 * t)
        return a.scale + (b.scale - a.scale) * smooth
      }
    }
    return knots[knots.count - 1].scale
  }
}

/// One deterministic media deposit scheduled along a stroke's arc length.
///
/// The plan owns placement (the universal dab-spacing model: intervals
/// proportional to the local stroke width) and every random transform, so
/// both adapters observe identical deposits and a reveal prefix never
/// changes while it extends. Adapters translate the placement into cached
/// stamp images — placement is domain state, drawing is an effect.
public struct WritingStrokeStamp: Hashable, Sendable {
  public let x: Double
  public let y: Double
  /// Direction of travel at the deposit, in radians.
  public let angle: Double
  /// Desired drawn diameter in points. The stamp art itself carries the
  /// elongated, grain-baked shape inside this square.
  public let diameter: Double
  /// Per-stamp flow alpha before material-level opacity.
  public let alpha: Double
  /// Stable selector in 0..<1; the adapter maps it onto its sheet variants.
  public let variant: Double
  /// Mirror the stamp horizontally so tips never read as one repeated print.
  public let flip: Bool
  /// Erosion stamps remove pigment (dry-brush gaps) instead of depositing.
  public let isErosion: Bool

  public init(
    x: Double, y: Double, angle: Double, diameter: Double, alpha: Double,
    variant: Double, flip: Bool, isErosion: Bool
  ) {
    self.x = x
    self.y = y
    self.angle = angle
    self.diameter = diameter
    self.alpha = alpha
    self.variant = variant
    self.flip = flip
    self.isErosion = isErosion
  }
}

/// The complete deterministic geometry for one visible stroke interval.
public struct WritingStrokeGeometry: Hashable, Sendable {
  /// Closed body outline. Adapters fill this exact polygon and never stroke
  /// the body centerline, keeping rasterization identical across backends.
  public let body: [WritingPlanPoint]
  public let bristles: [WritingBristle]
  public let splatters: [WritingSplat]
  public let stamps: [WritingStrokeStamp]
  /// Dominant travel direction (radians) of the visible interval. Media
  /// texture aligns to it so directional grain follows the stroke instead
  /// of the page axes.
  public let dominantAngle: Double
  /// Largest half-width used anywhere in the geometry. Adapters size their
  /// clip masks from this value.
  public let maximumHalfWidth: Double

  public static func empty(maximumHalfWidth: Double = 1) -> WritingStrokeGeometry {
    WritingStrokeGeometry(
      body: [], bristles: [], splatters: [], stamps: [],
      dominantAngle: 0, maximumHalfWidth: maximumHalfWidth)
  }
}

extension WritingStrokeGeometryPlan {
  /// Hard upper bounds for one geometry result.  The limits are applied
  /// before any curve math so malformed or adversarial paths cannot turn a
  /// render frame into an unbounded allocation.
  public static let maximumSamples = 16_384
  public static let maximumBristles = 2_048
  public static let maximumSplatters = 2_048
  public static let maximumStamps = 2_048
  /// One shared halo radius keeps ink edge treatment identical in both
  /// SwiftUI and Canvas adapters.
  public static let inkHaloBlurRadius = 1.35

  /// Conservative bound for every valid public material configuration at a
  /// destination height. Section culling happens before a concrete material
  /// is selected, so this worst-case value must include body, edge, overlay,
  /// bristles, and terminal splatters for all four material families.
  public static func maximumPossibleHalfWidth(destinationHeight: Double) -> Double {
    // `faceWidth(for:destinationHeight:)` intentionally uses a one-point
    // minimum for degenerate but valid destinations. Keep the culling bound
    // on that same contract; returning zero for height == 0 would let a
    // valid material stroke disappear at a section edge.
    guard destinationHeight.isFinite else { return 0 }
    let height = max(1, destinationHeight)

    // Chalk is a surface applied to the source mask. It contributes only a
    // one-point source stroke and a bounded dust halo; it never owns a ribbon.
    let chalk = min(1.5, max(0.5, height * 0.02))

    let brushFace = min(36, max(2.8, height * 0.46))
    let brush = Self.maximumHalfWidth(
      faceWidth: brushFace,
      edgeAmplitude: (0.30 + 64 * 0.06) * 1.55,
      hasBristles: true,
      hasSplatters: false)

    let penFace = min(11, max(1.2, height * 0.20))
    let pen = Self.maximumHalfWidth(
      faceWidth: penFace,
      edgeAmplitude: 0.12,
      hasBristles: false,
      hasSplatters: false)

    let inkFace = min(30, max(2.2, height * 0.36))
    let ink = Self.maximumHalfWidth(
      faceWidth: inkFace,
      edgeAmplitude: (0.25 + 0.5) * 1.45,
      hasBristles: true,
      hasSplatters: true)

    let markerFace = min(34, max(2.6, height * 0.52))
    let marker = Self.maximumHalfWidth(
      faceWidth: markerFace,
      edgeAmplitude: 0.10 + 0.30,
      hasBristles: false,
      hasSplatters: false)

    let knockoutFace = min(30, max(2.2, height * 0.38))
    let knockout = Self.maximumHalfWidth(
      faceWidth: knockoutFace,
      edgeAmplitude: 0.35 + 1.1,
      hasBristles: false,
      hasSplatters: false)

    return max(chalk, max(brush, max(pen, max(ink, max(marker, knockout)))))
  }

  /// Returns a conservative local paint expansion for a material at one
  /// destination height. This is the same bound used by generated geometry
  /// and includes the widest possible body, overlay, bristles, and splatters
  /// for that material. Adapters use it to size their vector paint surface
  /// before the frame closure runs.
  public static func conservativeMaximumHalfWidth(
    for material: WritingMaterial,
    destinationHeight: Double
  ) -> Double {
    // Match `faceWidth` for zero-height destinations. The public rectangle
    // contract permits height == 0, while material geometry still has the
    // one-point minimum face used by the renderer.
    guard destinationHeight.isFinite else { return 0 }
    if case .chalk = material {
      // Chalk geometry is intentionally not materialized by the writing
      // stroke planner. Its adapter path is the source centerline stroked at
      // one point and textured by WritingChalkSurfacePlan.
      return 0.5
    }
    let face = Self.faceWidth(for: material, destinationHeight: destinationHeight)
    let model = Self.widthModel(
      for: material,
      faceWidth: face,
      length: max(face, 1),
      destinationHeight: destinationHeight
    )
    return Self.maximumHalfWidth(
      faceWidth: face,
      edgeAmplitude: model.edgeAmplitude * (1 + model.edgeTear),
      hasBristles: model.bristleCount > 0,
      hasSplatters: model.splatCount > 0
    )
  }

  // MARK: Public entry point

  /// Builds deterministic stroke geometry for the visible samples of one
  /// subpath. The same samples, material, and salt always produce the same
  /// geometry, so reveal frames cannot make a finished stroke wiggle.
  /// When a reveal adapter has source arclength metadata, `sourceDistances`
  /// keeps pressure/taper coordinates continuous across command fragments;
  /// `visibleLength` is the current visible terminal distance and defaults to
  /// the last source distance.
  public static func geometry(
    samples: [WritingStrokeSample],
    isClosed: Bool,
    material: WritingMaterial,
    destinationHeight: Double,
    seedSalt: UInt64,
    sourceDistances: [Double]? = nil,
    visibleLength: Double? = nil
  ) -> WritingStrokeGeometry {
    // This API is intentionally non-throwing because it is called from a
    // frame renderer.  Invalid/non-finite input has one explicit outcome:
    // an empty geometry with no clip extent.  In particular, do not feed
    // non-finite values into `hypot` or a floating-point-to-Int conversion.
    guard destinationHeight.isFinite,
      samples.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
    else {
      return .empty(maximumHalfWidth: 0)
    }

    guard sourceDistances == nil || sourceDistances?.count == samples.count,
      sourceDistances == nil || sourceDistances!.allSatisfy(\.isFinite),
      sourceDistances == nil || Self.isNondecreasing(sourceDistances!),
      sourceDistances == nil || (sourceDistances!.first ?? 0) >= 0,
      sourceDistances != nil || visibleLength == nil,
      visibleLength == nil || visibleLength!.isFinite,
      visibleLength == nil || visibleLength! >= 0
    else {
      return .empty(maximumHalfWidth: 0)
    }

    var samples = Self.boundedSamples(samples)
    let boundedSourceDistances: [Double]?
    if let sourceDistances {
      let values = Self.boundedDistances(sourceDistances)
      guard values.count == samples.count else {
        return .empty(maximumHalfWidth: 0)
      }
      boundedSourceDistances = values
    } else {
      boundedSourceDistances = nil
    }
    guard samples.count > 1 else {
      // Degenerate stroke: a single dot sized from the material face.
      let size = Self.faceWidth(for: material, destinationHeight: destinationHeight)
      if let first = samples.first {
        let radius = max(0.4, size * 0.5)
        let geometry = WritingStrokeGeometry(
          body: Self.circle(
            center: WritingPlanPoint(x: first.x, y: first.y), radius: radius, segments: 13),
          bristles: [], splatters: [], stamps: [], dominantAngle: 0,
          maximumHalfWidth: radius)
        return Self.hasFiniteGeometry(geometry) ? geometry : .empty(maximumHalfWidth: 0)
      }
      return .empty()
    }

    var physicalDistances: [Double] = Array(repeating: 0, count: samples.count)
    var physicalTotal = 0.0
    for index in 1..<samples.count {
      guard let distance = Self.safeDistance(samples[index - 1], samples[index]) else {
        return .empty(maximumHalfWidth: 0)
      }
      let nextTotal = physicalTotal + distance
      guard nextTotal.isFinite else {
        return .empty(maximumHalfWidth: 0)
      }
      physicalTotal = nextTotal
      physicalDistances[index] = physicalTotal
    }
    var distances: [Double]
    let total: Double
    if let boundedSourceDistances {
      distances = boundedSourceDistances
      total = visibleLength ?? boundedSourceDistances.last ?? 0
      guard total.isFinite, total >= boundedSourceDistances.last ?? 0 else {
        return .empty(maximumHalfWidth: 0)
      }
    } else {
      guard visibleLength == nil else {
        return .empty(maximumHalfWidth: 0)
      }
      distances = physicalDistances
      total = physicalTotal
    }
    guard total > 0 else {
      let first = samples[0]
      let radius = max(0.4, Self.faceWidth(for: material, destinationHeight: destinationHeight) * 0.5)
      let geometry = WritingStrokeGeometry(
        body: Self.circle(center: WritingPlanPoint(x: first.x, y: first.y), radius: radius, segments: 13),
        bristles: [], splatters: [], stamps: [], dominantAngle: 0,
        maximumHalfWidth: radius)
      return Self.hasFiniteGeometry(geometry) ? geometry : .empty(maximumHalfWidth: 0)
    }

    let face = Self.faceWidth(for: material, destinationHeight: destinationHeight)
    // Sparse polylines put every sample inside the two end-taper zones (a
    // straight SVG segment can be exactly two points) and collapse the
    // ribbon to the minimum radius. Insert interior samples so width and
    // pressure exist along the whole stroke. The step depends only on the
    // material face, not on total path length, so extending a reveal cannot
    // re-space an already visible prefix.
    let maximumStep = max(1.3, min(6, face / 8))
    if total > maximumStep {
      let resampled = Self.resampled(
        samples: samples, distances: distances,
        maximumStep: maximumStep, limit: Self.maximumSamples)
      samples = resampled.0
      distances = resampled.1
    }

    let seed = material.seed ^ seedSalt &* 0x9E37_79B9_7F4A_7C15
    var random = WritingStrokeRandom(seed: seed)
    var model = Self.widthModel(
      for: material, faceWidth: face, length: total, destinationHeight: destinationHeight)

    // Ink exit character (筆觸): one seeded archetype per stroke so
    // calligraphy strokes end with varied, repeatable tails — a needle
    // point, a pressed blunt stop, a frayed dry tail, or an angled cut.
    var endCapStyle = model.endCap
    var tailFray = false
    if model.exitVariety {
      var exitRandom = WritingStrokeRandom(seed: seed ^ 0x7EC7_1111)
      let roll = exitRandom.nextUnit()
      if roll < 0.35 {
        model.endTaper = min(total * 0.30, face * 2.8)
      } else if roll < 0.60 {
        // 頓筆 pressed stop: the dewdrop foot stays rounded and full.
        model.endTaper = min(total * 0.08, face * 0.45)
      } else if roll < 0.85 {
        model.endTaper = min(total * 0.22, face * 1.8)
        tailFray = true
      } else {
        model.endTaper = min(total * 0.10, face * 0.6)
        endCapStyle = .angled
      }
      if tailFray {
        model.bristleGap = min(0.85, model.bristleGap * 1.8)
        model.bristleErosion = min(0.6, model.bristleErosion * 1.5)
        model.splatCount = max(model.splatCount, 2)
      }
    }

    // Pressure: perfect-freehand-style velocity simulation over the sample
    // spacing (dense flattened samples mean the stroke is turning or
    // slowing, so pigment thickens there), blended with low-frequency
    // tremor, then smoothed so the ribbon stays free of angular kinks.
    var pressure: [Double] = []
    pressure.reserveCapacity(samples.count)
    var simulated = 0.5
    for index in 0..<samples.count {
      let step = index == 0 ? distances[min(1, distances.count - 1)] : distances[index] - distances[index - 1]
      let speed = min(1, max(0, step) / max(face, 1))
      let slowness = min(1, 1 - speed)
      simulated = min(1, simulated + (slowness - simulated) * speed * 0.275)
      let tremor = Self.valueNoise(
        phase: distances[index] * model.tremorFrequency, seed: seed, salt: 0x1E3)
      pressure.append(min(1, max(0, simulated + (tremor - 0.5) * 2 * model.tremor)))
    }
    pressure = Self.smooth(pressure, passes: 3)

    // Radius per sample with taper strengths.
    var radii: [Double] = (0..<samples.count).map { index in
      let eased = sin((0.5 - model.thinning * (0.5 - pressure[index])) * .pi / 2)
      var radius = face * 0.5 * eased
      if !isClosed {
        let startDistance = distances[index]
        if model.startTaper > 0, startDistance < model.startTaper {
          let t = startDistance / model.startTaper
          radius *= t * (2 - t)
        }
        let remaining = total - distances[index]
        if model.endTaper > 0, remaining < model.endTaper {
          // Smoothstep depth mirrors the reveal terminal-taper contract, so
          // the visible tail thins decisively instead of lingering wide.
          let t = max(0, remaining / model.endTaper)
          let smooth = t * t * (3 - 2 * t)
          radius *= max(0.02, 1 - (1 - smooth) * 0.92)
        }
      }
      if let profile = model.widthProfile {
        radius *= profile.scale(at: distances[index] / max(total, 1e-9))
      }
      return max(0.22, radius)
    }

    // Outline rails with angle-based offsets. Preserve every canonical sample
    // so command-boundary source distances remain available to reveal frames.
    var left: [WritingPlanPoint] = []
    var right: [WritingPlanPoint] = []
    left.reserveCapacity(samples.count)
    right.reserveCapacity(samples.count)
    let edge = model.edgeAmplitude

    // Per-sample edge bite at three scales, coupled to the shared grain
    // field so the boundary crumble continues the interior tooth. The
    // combined amplitude stays inside ±edge; tears add a bounded outward
    // jag. Computed once per sample so closed subpaths can blend the seam
    // (index 0 and the last index are the same physical point).
    // Ink reservoir (libmypaint-style): pigment depletes with travel,
    // weighted by the local width and pressure. Depleted regions erode
    // harder and deposit less — the quantitative basis of 飛白 drying.
    let inkLoad: [Double]? = model.inkDepletionRate > 0
      ? {
        var load = 1.0
        var loads: [Double] = []
        loads.reserveCapacity(samples.count)
        for index in 0..<samples.count {
          if index > 0 {
            let step = distances[index] - distances[index - 1]
            let widthRatio = radii[index] / max(face * 0.5, 0.5)
            load -= model.inkDepletionRate * step * widthRatio
              * (0.4 + 0.6 * pressure[index])
          }
          loads.append(max(0, min(1, load)))
        }
        return loads
      }()
      : nil

    func edgeBite(index: Int, sign: Double) -> Double {
      let distance = distances[index]
      let railSalt: UInt64 = sign > 0 ? 0x5A1 : 0xA17
      var displacement = edge * (0.42 * (
        (Self.valueNoise(
          phase: distance * model.edgeFrequency * 0.35, seed: seed, salt: railSalt) - 0.5)
          + (Self.valueNoise(
            phase: distance * model.edgeFrequency * 0.85, seed: seed, salt: railSalt ^ 0x9D2) - 0.5) * 0.6
          + (Self.valueNoise(
            phase: distance * model.edgeFrequency * 2.1, seed: seed, salt: railSalt ^ 0x3B7) - 0.5) * 0.4
      ) * 2 + 0.58 * ((Self.grain(
        x: samples[index].x, y: samples[index].y, seed: seed) - 0.5) * 2))
      if model.edgeTear > 0 {
        let tear = Self.valueNoise(
          phase: distance * model.edgeFrequency * 0.5, seed: seed, salt: railSalt ^ 0x7E3)
        if tear > 0.72 {
          displacement += edge * model.edgeTear * ((tear - 0.72) / 0.28)
        }
      }
      // The bite scales with the local width: a tail thinning to nothing has
      // no crumble, which also keeps the absolute terminal-taper contract.
      return displacement * min(1, radii[index] / max(face * 0.5, 0.5))
    }

    if isClosed, samples.count > 2 {
      // Seam blending (Inkscape lpe-powerstroke closes the width loop the
      // same way): the duplicated seam point is one physical location, so
      // its width and both rails' bites must agree between the walk-in and
      // walk-out pass, or the contour shows a step there.
      let seamRadius = (radii[0] + radii[radii.count - 1]) * 0.5
      radii[0] = seamRadius
      radii[radii.count - 1] = seamRadius
    }

    func offsetRail(
      _ index: Int, sign: Double, into rail: inout [WritingPlanPoint]
    ) {
      let previous = samples[max(0, index - 1)]
      let next = samples[min(samples.count - 1, index + 1)]
      let direction = Self.tangent(
        at: index,
        samples: samples,
        preferredStart: previous,
        preferredEnd: next)
      let length = direction.length
      let normalX = -direction.y / max(length, 1e-9)
      let normalY = direction.x / max(length, 1e-9)
      var displacement = edgeBite(index: index, sign: sign)
      if isClosed, (index == 0 || index == samples.count - 1) {
        // Seam points reuse the walk-out bite on the walk-in pass so both
        // rails close without a dislocation step.
        displacement = edgeBite(index: 0, sign: sign)
      }
      let offset = radii[index] + displacement
      rail.append(WritingPlanPoint(
        x: samples[index].x + normalX * sign * offset,
        y: samples[index].y + normalY * sign * offset))
    }

    // Signed turn angle per sample; caps have none.
    let turns: [Double] = (0..<samples.count).map { index in
      guard index > 0, index < samples.count - 1 else { return 0 }
      let a = samples[index - 1]
      let b = samples[index]
      let c = samples[index + 1]
      let v1x = b.x - a.x, v1y = b.y - a.y
      let v2x = c.x - b.x, v2y = c.y - b.y
      let l1 = max(hypot(v1x, v1y), 1e-9)
      let l2 = max(hypot(v2x, v2y), 1e-9)
      let cross = (v1x * v2y - v1y * v2x) / (l1 * l2)
      let dot = min(1, max(-1, (v1x * v2x + v1y * v2y) / (l1 * l2)))
      return atan2(cross, dot)
    }

    /// Outer join at a cusp: a short arc around the corner vertex keeps the
    /// outline convex instead of leaving a bevel flat (Inkscape rounds the
    /// same corner with a minimal-eccentricity ellipse; our dense samples
    /// make a circular fan equivalent at this scale).
    func appendOuterJoin(
      _ index: Int, sign: Double, turn: Double, into rail: inout [WritingPlanPoint]
    ) {
      let center = samples[index]
      let previous = samples[index - 1]
      let next = samples[index + 1]
      func unit(_ a: WritingStrokeSample, _ b: WritingStrokeSample) -> (Double, Double) {
        let dx = b.x - a.x, dy = b.y - a.y
        let l = max(hypot(dx, dy), 1e-9)
        return (dx / l, dy / l)
      }
      let d1 = unit(previous, center)
      let d2 = unit(center, next)
      // Rail offset directions for the incoming and outgoing tangents.
      let n1 = (-d1.1 * sign, d1.0 * sign)
      let n2 = (-d2.1 * sign, d2.0 * sign)
      let a1 = atan2(n1.1, n1.0)
      var a2 = atan2(n2.1, n2.0)
      // Shortest sweep: on the outer rail the short arc between the two
      // rail normals always bulges away from the turn center, which is the
      // convex corner fill we want. (An outward-sign heuristic here is
      // unstable at exact 90-degree turns.)
      while a2 - a1 > .pi { a2 -= 2 * .pi }
      while a2 - a1 < -.pi { a2 += 2 * .pi }
      let radius = radii[index] + edgeBite(index: index, sign: sign)
      let steps = max(2, Int(abs(a2 - a1) / (.pi / 12)))
      for step in 1...steps {
        let angle = a1 + (a2 - a1) * Double(step) / Double(steps)
        rail.append(WritingPlanPoint(
          x: center.x + cos(angle) * radius,
          y: center.y + sin(angle) * radius))
      }
    }

    for index in 0..<samples.count {
      let turn = turns[index]
      // Outer side: positive turn bends toward the left rail's outside.
      let outerSign: Double = turn > 0 ? -1 : 1
      if abs(turn) > 1.31 {
        if outerSign < 0 {
          appendOuterJoin(index, sign: -1, turn: turn, into: &left)
          offsetRail(index, sign: 1, into: &right)
        } else {
          offsetRail(index, sign: -1, into: &left)
          appendOuterJoin(index, sign: 1, turn: turn, into: &right)
        }
      } else {
        offsetRail(index, sign: -1, into: &left)
        offsetRail(index, sign: 1, into: &right)
      }
    }

    var body: [WritingPlanPoint] = left
    if isClosed {
      body.append(contentsOf: right.reversed())
    } else {
      // Walk the left rail forward, cap the tip per the material's end
      // style, walk the right rail back, then cap the entry and close.
      switch endCapStyle {
      case .round:
        body.append(contentsOf: Self.endCap(
          center: samples[samples.count - 1],
          radius: radii[radii.count - 1],
          side: left[left.count - 1],
          forward: Self.endDirection(samples),
          segments: 9))
      case .cut:
        break
      case .angled:
        // Tilted stop face: the cut plane leans into the travel direction.
        let tip = samples[samples.count - 1]
        let direction = Self.endDirection(samples)
        body.append(WritingPlanPoint(
          x: tip.x + direction.x * radii[radii.count - 1] * 0.55,
          y: tip.y + direction.y * radii[radii.count - 1] * 0.55))
      }
      body.append(contentsOf: right.reversed())
      body.append(contentsOf: Self.endCap(
        center: samples[0],
        radius: radii[0],
        side: right[0],
        forward: Self.startDirection(samples),
        segments: 7))
    }

    // Marker entry streaks: the dry tip deposits uneven width-wise stripes
    // before ink flow stabilizes, then the film turns solid.
    var bristles: [WritingBristle] = []
    if model.entryStreakCount > 0, !isClosed, samples.count > 2 {
      var streakRandom = WritingStrokeRandom(seed: seed ^ 0x57EA_1E5)
      let zone = face * 1.2
      for _ in 0..<model.entryStreakCount {
        let lateral = (streakRandom.nextUnit() - 0.5) * 1.5
        let startDistance = streakRandom.nextUnit() * zone * 0.35
        let streakLength = zone * (0.45 + streakRandom.nextUnit() * 0.85)
        var run: [WritingPlanPoint] = []
        for index in 0..<samples.count where distances[index] >= startDistance {
          guard distances[index] <= startDistance + streakLength else { break }
          let previous = samples[max(0, index - 1)]
          let next = samples[min(samples.count - 1, index + 1)]
          let dx = next.x - previous.x
          let dy = next.y - previous.y
          let length = max(hypot(dx, dy), 1e-9)
          let normalX = -dy / length
          let normalY = dx / length
          run.append(WritingPlanPoint(
            x: samples[index].x + normalX * lateral * radii[index] * 0.5,
            y: samples[index].y + normalY * lateral * radii[index] * 0.5))
        }
        guard run.count > 1 else { continue }
        bristles.append(WritingBristle(
          runs: [run],
          width: max(0.24, face * (0.03 + streakRandom.nextUnit() * 0.05)),
          opacity: 0.18 + streakRandom.nextUnit() * 0.34,
          isErosion: streakRandom.nextUnit() < 0.45))
      }
    }
    if model.bristleCount > 0 {
      let bristleCount = min(Self.maximumBristles, model.bristleCount)
      bristles.reserveCapacity(bristleCount)
      for bristleIndex in 0..<bristleCount {
        // Per-bristle RNG: a reveal prefix changes the sample count, so a
        // shared stream would shift every later bristle's shape mid-write.
        var bristleRandom = WritingStrokeRandom(
          seed: seed ^ 0xB21_5711 ^ UInt64(truncatingIfNeeded: bristleIndex &+ 1)
            &* 0x9E37_79B9_7F4A_7C15)
        let baseLateral = -0.82
          + 1.64 * (Double(bristleIndex) + bristleRandom.nextUnit() * 0.7)
          / Double(bristleCount)
        // The bristle wanders across the ribbon (two harmonics) and drifts
        // outward toward the tail, replacing the parallel-rail look.
        // Periods stay far above the sample spacing; a period near the
        // sample step aliases into angular zigzags when rasterized.
        let wanderAmplitude = 0.10 + bristleRandom.nextUnit() * 0.14
        let wanderFrequency = 0.10 + bristleRandom.nextUnit() * 0.12
        let fineAmplitude = 0.03 + bristleRandom.nextUnit() * 0.03
        let fineFrequency = 0.5 + bristleRandom.nextUnit() * 0.4
        let phase1 = bristleRandom.nextUnit() * 2 * .pi
        let phase2 = bristleRandom.nextUnit() * 2 * .pi
        let runs = Self.bristleRuns(
          samples: samples, radii: radii, distances: distances, total: total,
          baseLateral: baseLateral,
          wanderAmplitude: wanderAmplitude,
          wanderFrequency: wanderFrequency,
          fineAmplitude: fineAmplitude,
          fineFrequency: fineFrequency,
          phase1: phase1,
          phase2: phase2,
          runProbability: model.bristleRun,
          gapProbability: model.bristleGap,
          inkLoad: inkLoad,
          random: &bristleRandom)
        guard !runs.isEmpty else { continue }
        bristles.append(WritingBristle(
          runs: runs,
          width: max(0.24, face * (0.018 + bristleRandom.nextUnit() * 0.045)),
          opacity: model.bristleOpacity * (0.45 + bristleRandom.nextUnit() * 0.55),
          isErosion: bristleRandom.nextUnit() < model.bristleErosion))
      }
    }

    var splatters: [WritingSplat] = []
    if model.splatCount > 0, !isClosed, samples.count > 2 {
      let end = samples[samples.count - 1]
      let direction = Self.endDirection(samples)
      let splatCount = min(Self.maximumSplatters, model.splatCount)
      for _ in 0..<splatCount {
        let along = (0.2 + random.nextUnit() * 0.9) * face
        let across = (random.nextUnit() - 0.5) * 1.6 * face
        splatters.append(WritingSplat(
          x: end.x + direction.x * along - direction.y * across,
          y: end.y + direction.y * along + direction.x * across,
          radius: max(0.3, face * (0.04 + random.nextUnit() * 0.09)),
          opacity: 0.3 + random.nextUnit() * 0.45))
      }
    }

    // Media stamps: deposits scheduled along arc length at intervals
    // proportional to the local stroke width. Every stamp draws its own
    // parameters from a per-stamp seeded RNG, so an already visible prefix
    // is bit-stable while a reveal extends.
    var stamps: [WritingStrokeStamp] = []
    if model.stampSpacing > 0, face >= model.stampMinimumFace, samples.count > 1 {
      stamps.reserveCapacity(min(Self.maximumStamps, 128))
      var index = 0
      var nextStampAt = distances[0] + model.stampSpacing * max(1.4, radii[0] * 2)
      var stampIndex = 0
      while index < samples.count - 1, stampIndex < Self.maximumStamps {
        let span = distances[index + 1] - distances[index]
        guard span > 0, span.isFinite else {
          index += 1
          continue
        }
        if distances[index + 1] < nextStampAt {
          index += 1
          continue
        }
        let t = min(1, max(0, (nextStampAt - distances[index]) / span))
        let a = samples[index]
        let b = samples[index + 1]
        let x = a.x + (b.x - a.x) * t
        let y = a.y + (b.y - a.y) * t
        let radius = radii[index] + (radii[index + 1] - radii[index]) * t
        let pressureHere = pressure[index] + (pressure[index + 1] - pressure[index]) * t
        let directionLength = max(hypot(b.x - a.x, b.y - a.y), 1e-9)
        let directionX = (b.x - a.x) / directionLength
        let directionY = (b.y - a.y) / directionLength
        let baseAngle = atan2(directionY, directionX)
        let normalX = -directionY
        let normalY = directionX

        // Per-stamp deterministic parameters.
        var stampRandom = WritingStrokeRandom(
          seed: seed ^ 0x57A1_0000 ^ UInt64(truncatingIfNeeded: stampIndex &+ 1)
            &* 0x9E37_79B9_7F4A_7C15)
        let jitterAngle = (stampRandom.nextUnit() - 0.5) * 2 * model.stampRotation
        let lateral = (stampRandom.nextUnit() - 0.5) * 2 * model.stampScatter * max(radius, 0.5)
        let along = (stampRandom.nextUnit() - 0.5) * model.stampScatter * max(radius, 0.5)
        let flip = stampRandom.nextUnit() < 0.5
        let scaleJitter = 0.88 + stampRandom.nextUnit() * 0.26
        let variant = stampRandom.nextUnit()

        // Deposits thin out inside the terminal tapers with the same ratio
        // the ribbon radius shrinks, so tips keep their crumbled look.
        let taperFade = min(1, radius / max(face * 0.5, 0.5))
        let load = inkLoad?[min(index, (inkLoad?.count ?? 1) - 1)] ?? 1
        // Erosion bites harder as the brush runs dry; deposits fade.
        let loadFactor = model.stampIsErosion
          ? min(1.4, 0.6 + (1 - load) * 0.8)
          : 0.4 + 0.6 * load
        let alpha = min(
          1,
          model.stampFlow * (0.70 + 0.30 * pressureHere) * max(0.06, taperFade)
            * loadFactor)
        stamps.append(WritingStrokeStamp(
          x: x + normalX * lateral + directionX * along,
          y: y + normalY * lateral + directionY * along,
          angle: baseAngle + jitterAngle,
          diameter: max(1.6, radius * 2 * scaleJitter),
          alpha: alpha,
          variant: variant,
          flip: flip,
          isErosion: model.stampIsErosion))
        nextStampAt += model.stampSpacing * max(1.4, radius * 2)
        stampIndex += 1
      }
    }

    let maximumHalfWidth = Self.maximumHalfWidth(
      faceWidth: face,
      edgeAmplitude: edge * (1 + model.edgeTear),
      hasBristles: !bristles.isEmpty,
      hasSplatters: !splatters.isEmpty
    )

    // Dominant travel direction: the chord of the visible interval.
    let firstSample = samples[0]
    let lastSample = samples[samples.count - 1]
    let chord = hypot(lastSample.x - firstSample.x, lastSample.y - firstSample.y)
    let dominantAngle = chord > 1
      ? atan2(lastSample.y - firstSample.y, lastSample.x - firstSample.x)
      : 0

    let geometry = WritingStrokeGeometry(
      body: body,
      bristles: bristles,
      splatters: splatters,
      stamps: stamps,
      dominantAngle: dominantAngle,
      maximumHalfWidth: maximumHalfWidth)
    // Finite source coordinates can still overflow when a rail, overlay,
    // bristle, or splatter offset is added near Double's boundary.  Return
    // the same explicit nonthrowing failure as invalid input instead of
    // handing an adapter a partially infinite path.
    return Self.hasFiniteGeometry(geometry) ? geometry : .empty(maximumHalfWidth: 0)
  }

  // MARK: Input and extent guards

  /// Linearly inserts interior samples so no consecutive pair spans more
  /// than `maximumStep` in distance coordinate. Distances interpolate with
  /// the points, keeping source-arclength metadata monotone.
  private static func resampled(
    samples: [WritingStrokeSample],
    distances: [Double],
    maximumStep: Double,
    limit: Int
  ) -> ([WritingStrokeSample], [Double]) {
    guard samples.count == distances.count, samples.count > 1 else {
      return (samples, distances)
    }
    var outSamples: [WritingStrokeSample] = []
    var outDistances: [Double] = []
    outSamples.reserveCapacity(samples.count * 2)
    outDistances.reserveCapacity(samples.count * 2)
    outSamples.append(samples[0])
    outDistances.append(distances[0])
    for index in 1..<samples.count {
      let a = samples[index - 1]
      let b = samples[index]
      let distanceA = distances[index - 1]
      let distanceB = distances[index]
      let span = distanceB - distanceA
      // Reserve one slot for every original point still ahead, including the
      // current interval's terminal. A greedy insertion pass that only
      // reserves `b` can consume the cap in an early long segment and erase
      // the final source endpoint from an otherwise valid stroke.
      let remainingOriginalPoints = samples.count - index
      let availableInterior = max(
        0,
        limit - outSamples.count - remainingOriginalPoints
      )
      let interior = span > maximumStep && availableInterior > 0
        ? Self.boundedInteger(span / maximumStep, upperBound: availableInterior)
        : 0
      if interior > 0 {
        for step in 1...interior {
          let t = Double(step) / Double(interior + 1)
          let sample = WritingStrokeSample(
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t)
          let sampleDistance = distanceA + span * t
          guard sample.x.isFinite, sample.y.isFinite, sampleDistance.isFinite else {
            return (outSamples, outDistances)
          }
          outSamples.append(sample)
          outDistances.append(sampleDistance)
          if outSamples.count >= limit {
            return (outSamples, outDistances)
          }
        }
      }
      outSamples.append(b)
      outDistances.append(distanceB)
      // The reservation above keeps the terminal source point available. The
      // guard is defensive for a future caller that supplies a smaller limit.
      if outSamples.count >= limit, index < samples.count - 1 {
        return (outSamples, outDistances)
      }
    }
    return (outSamples, outDistances)
  }

  private static func boundedSamples(_ samples: [WritingStrokeSample]) -> [WritingStrokeSample] {
    guard samples.count > maximumSamples else { return samples }
    // Preserve both ends of a bounded canonical plan. The material sampler
    // can emit one segment per command, which is `maximumSamples + 1` points;
    // dropping only the tail would silently erase the final reveal command.
    return Self.boundedIndices(count: samples.count).map { samples[$0] }
  }

  private static func boundedInteger(_ value: Double, upperBound: Int) -> Int {
    guard upperBound > 0, value.isFinite, value > 0 else { return 0 }
    let roundedDown = value.rounded(.down)
    guard roundedDown >= 1 else { return 0 }
    if roundedDown >= Double(upperBound) { return upperBound }
    // `roundedDown < upperBound <= maximumSamples`; the conversion is
    // bounded before it reaches Swift's trapping integer initializer.
    return Int(roundedDown)
  }

  private static func boundedInteger(
    _ value: Double,
    lowerBound: Int,
    upperBound: Int
  ) -> Int {
    guard upperBound >= lowerBound, value.isFinite else { return lowerBound }
    let roundedDown = value.rounded(.down)
    guard roundedDown.isFinite else { return lowerBound }
    if roundedDown <= Double(lowerBound) { return lowerBound }
    if roundedDown >= Double(upperBound) { return upperBound }
    // `lowerBound <= roundedDown < upperBound <= maximumBristles` for all
    // material model call sites.
    return Int(roundedDown)
  }

  private static func boundedDistances(_ values: [Double]) -> [Double] {
    guard values.count > maximumSamples else { return values }
    return Self.boundedIndices(count: values.count).map { values[$0] }
  }

  private static func boundedIndices(count: Int) -> [Int] {
    guard count > maximumSamples else { return Array(0..<count) }
    guard maximumSamples > 1 else { return [0] }
    var result: [Int] = []
    result.reserveCapacity(maximumSamples)
    let denominator = maximumSamples - 1
    for index in 0..<maximumSamples {
      let (numerator, overflow) = index.multipliedReportingOverflow(by: count - 1)
      if overflow {
        // This is unreachable for normal arrays but is an explicit finite
        // fallback if an adversarial collection count would overflow an
        // index product. Keep the first bounded prefix and the terminal.
        result = Array(0..<(maximumSamples - 1))
        result.append(count - 1)
        return result
      }
      result.append(numerator / denominator)
    }
    return result
  }

  private static func isNondecreasing(_ values: [Double]) -> Bool {
    guard let first = values.first else { return true }
    var previous = first
    for value in values.dropFirst() {
      guard value >= previous else { return false }
      previous = value
    }
    return true
  }

  private static func safeDistance(
    _ first: WritingStrokeSample,
    _ second: WritingStrokeSample
  ) -> Double? {
    let dx = second.x - first.x
    let dy = second.y - first.y
    guard dx.isFinite, dy.isFinite else { return nil }
    let distance = hypot(dx, dy)
    return distance.isFinite ? distance : nil
  }

  private static func tangent(
    at index: Int,
    samples: [WritingStrokeSample],
    preferredStart: WritingStrokeSample,
    preferredEnd: WritingStrokeSample
  ) -> (x: Double, y: Double, length: Double) {
    let preferredDX = preferredEnd.x - preferredStart.x
    let preferredDY = preferredEnd.y - preferredStart.y
    let preferredLength = hypot(preferredDX, preferredDY)
    if preferredDX.isFinite, preferredDY.isFinite, preferredLength.isFinite,
      preferredLength > 1e-12
    {
      return (preferredDX, preferredDY, preferredLength)
    }
    if index > 0 {
      let previous = samples[index - 1]
      let dx = samples[index].x - previous.x
      let dy = samples[index].y - previous.y
      let length = hypot(dx, dy)
      if dx.isFinite, dy.isFinite, length.isFinite, length > 1e-12 {
        return (dx, dy, length)
      }
    }
    if index + 1 < samples.count {
      let next = samples[index + 1]
      let dx = next.x - samples[index].x
      let dy = next.y - samples[index].y
      let length = hypot(dx, dy)
      if dx.isFinite, dy.isFinite, length.isFinite, length > 1e-12 {
        return (dx, dy, length)
      }
    }
    return (1, 0, 1)
  }

  private static func maximumHalfWidth(
    faceWidth: Double,
    edgeAmplitude: Double,
    hasBristles: Bool,
    hasSplatters: Bool
  ) -> Double {
    // The bound is derived from the complete generated ranges, not from a
    // sampled point scan (which would be quadratic for a long stroke).  It
    // covers the continuous rail interpolation, cap arc, and every random
    // range used by the material model.  Each edge range is applied once.
    let bodyBound = (faceWidth * 0.5) + abs(edgeAmplitude) + 0.4
    // Bristles wander across the ribbon (two harmonics) and splay toward
    // the tail (up to 1.35x): worst-case lateral is (0.9 + 0.26) * 1.35
    // radii plus half a bristle width.
    let bristleBound = faceWidth * 0.5 * 1.60 + faceWidth * 0.035
    let splatterBound = hypot(faceWidth * 2.0, faceWidth * 1.2)
      + faceWidth * 0.17
    var extent = bodyBound
    if hasBristles { extent = max(extent, bristleBound) }
    if hasSplatters { extent = max(extent, splatterBound) }
    return extent.isFinite ? max(0, extent) : 0
  }

  private static func hasFiniteGeometry(_ geometry: WritingStrokeGeometry) -> Bool {
    guard geometry.maximumHalfWidth.isFinite, geometry.maximumHalfWidth >= 0 else {
      return false
    }
    guard geometry.body.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
      return false
    }
    guard geometry.bristles.allSatisfy({ bristle in
      bristle.width.isFinite && bristle.width >= 0
        && bristle.opacity.isFinite
        && bristle.runs.allSatisfy { run in
          run.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }
    }) else {
      return false
    }
    return geometry.splatters.allSatisfy { splat in
      splat.x.isFinite && splat.y.isFinite
        && splat.radius.isFinite && splat.radius >= 0
        && splat.opacity.isFinite
    }
  }

  // MARK: Per-material models

  struct WidthModel {
    var thinning: Double
    // Media stamp schedule (see WritingStrokeStamp). spacing is a fraction
    // of the local stroke diameter; zero disables stamping for the material.
    var stampSpacing: Double
    var stampFlow: Double
    var stampScatter: Double
    var stampRotation: Double
    var stampMinimumFace: Double
    var stampIsErosion: Bool
    var smoothing: Double
    var tremor: Double
    var tremorFrequency: Double
    var startTaper: Double
    var endTaper: Double
    var edgeAmplitude: Double
    var edgeFrequency: Double
    /// Outward dry-edge tear budget (brush/ink 飛白), as a fraction of the
    /// edge amplitude; zero for chalk/pen.
    var edgeTear: Double
    var endCap: WritingStrokeEndCap
    /// Ink-style per-stroke exit characters (needle/pressed/frayed/angled).
    var exitVariety: Bool
    /// Entry dry streaks: width-wise stripes the dry tip deposits before
    /// ink flow stabilizes (flat-marker reference behavior).
    var entryStreakCount: Int
    /// Ink reservoir depletion per point of travel, scaled by the local
    /// width ratio and pressure (0 disables — chalk/pen/marker never dry).
    var inkDepletionRate: Double
    /// Optional knot-based width profile multiplied into the radius.
    var widthProfile: WritingWidthProfile?
    var bristleCount: Int
    var bristleRun: Double
    var bristleGap: Double
    var bristleOpacity: Double
    var bristleErosion: Double
    var splatCount: Int
  }

  /// Face width in points for geometry-changing materials. Chalk deliberately
  /// stays out of this model because its source stroke remains one point wide.
  static func faceWidth(for material: WritingMaterial, destinationHeight: Double) -> Double {
    let height = max(1, destinationHeight)
    switch material {
    case .chalk:
      return 1
    case .brush(let configuration):
      let weight = 0.34 + configuration.coverage * 0.12
      return min(36, max(2.8, height * weight))
    case .pen(let configuration):
      let weight = 0.14 + min(0.06, configuration.dotScale * 0.03)
      return min(11, max(1.2, height * weight))
    case .ink(let configuration):
      let weight = 0.28 + configuration.pooling * 0.08
      return min(30, max(2.2, height * weight))
    case .marker(let configuration):
      let weight = 0.42 + configuration.coverage * 0.10
      return min(34, max(2.6, height * weight))
    case .knockout:
      return min(30, max(2.2, height * 0.38))
    }
  }

  static func widthModel(
    for material: WritingMaterial,
    faceWidth face: Double,
    length: Double,
    destinationHeight: Double
  ) -> WidthModel {
    switch material {
    case .chalk:
      // Chalk never uses this geometry-changing model. Keep a bounded
      // one-point outline for callers that inspect the generic planner; the
      // render adapters use the source mask plus WritingChalkSurfacePlan.
      return WidthModel(
        thinning: 0,
        stampSpacing: 0,
        stampFlow: 0,
        stampScatter: 0,
        stampRotation: 0,
        stampMinimumFace: .greatestFiniteMagnitude,
        stampIsErosion: false,
        smoothing: 0,
        tremor: 0,
        tremorFrequency: 0,
        startTaper: 0,
        endTaper: 0,
        edgeAmplitude: 0,
        edgeFrequency: 0,
        edgeTear: 0,
        endCap: .cut,
        exitVariety: false,
        entryStreakCount: 0,
        inkDepletionRate: 0,
        widthProfile: nil,
        bristleCount: 0,
        bristleRun: 0,
        bristleGap: 0,
        bristleOpacity: 0,
        bristleErosion: 0,
        splatCount: 0)
    case .brush(let configuration):
      // Brush pen: strong thinning, blunt entry, tapered exit, and dry
      // bristle streaks that thin out as coverage drops.
      let dryness = 1 - configuration.coverage
      return WidthModel(
        thinning: 0.55,
        stampSpacing: 0.11,
        stampFlow: 0.42,
        stampScatter: 0.05,
        stampRotation: 0.30,
        stampMinimumFace: 5.0,
        stampIsErosion: true,
        smoothing: 0.62,
        tremor: 0.12,
        tremorFrequency: 0.42,
        startTaper: min(length * 0.2, face * 0.9),
        endTaper: min(length * 0.34, face * 2.3),
        edgeAmplitude: 0.30 + configuration.streakScale * 0.06,
        edgeFrequency: 0.55,
        edgeTear: 0.55,
        endCap: .round,
        exitVariety: false,
        entryStreakCount: 0,
        inkDepletionRate: 0.006,
        widthProfile: nil,
        bristleCount: Self.boundedInteger(face / 1.4, lowerBound: 5, upperBound: 12),
        bristleRun: 0.5 + configuration.coverage * 0.35,
        bristleGap: 0.16 + dryness * 0.5,
        bristleOpacity: 0.22 + configuration.coverage * 0.22,
        bristleErosion: 0.22 + dryness * 0.35,
        splatCount: 0)
    case .pen:
      // Ballpoint/nib: steady width, hard edges, almost no texture.
      return WidthModel(
        thinning: 0.22,
        stampSpacing: 0,
        stampFlow: 0,
        stampScatter: 0,
        stampRotation: 0,
        stampMinimumFace: .greatestFiniteMagnitude,
        stampIsErosion: false,
        smoothing: 0.66,
        tremor: 0.07,
        tremorFrequency: 0.8,
        startTaper: min(length * 0.08, face * 0.6),
        endTaper: min(length * 0.12, face * 0.9),
        edgeAmplitude: 0.12,
        edgeFrequency: 1.1,
        edgeTear: 0,
        endCap: .round,
        exitVariety: false,
        entryStreakCount: 0,
        inkDepletionRate: 0,
        widthProfile: .nib,
        bristleCount: 0,
        bristleRun: 0,
        bristleGap: 0,
        bristleOpacity: 0,
        bristleErosion: 0,
        splatCount: 0)
    case .ink(let configuration):
      // Ink brush: pronounced pressure response, double taper, occasional
      // dry streaks, and pooling droplets near the exit.
      return WidthModel(
        thinning: 0.68,
        stampSpacing: 0.13,
        stampFlow: 0.28,
        stampScatter: 0.06,
        stampRotation: 0.45,
        stampMinimumFace: 5.0,
        stampIsErosion: true,
        smoothing: 0.6,
        tremor: 0.14,
        tremorFrequency: 0.38,
        startTaper: min(length * 0.18, face * 1.2),
        endTaper: min(length * 0.38, face * 2.6),
        edgeAmplitude: 0.25 + configuration.bleed * 0.5,
        edgeFrequency: 0.6,
        edgeTear: 0.45,
        endCap: .round,
        exitVariety: true,
        entryStreakCount: 0,
        inkDepletionRate: 0.009,
        widthProfile: nil,
        bristleCount: Self.boundedInteger(face / 1.8, lowerBound: 4, upperBound: 9),
        bristleRun: 0.48 + configuration.coverage * 0.32,
        bristleGap: 0.14 + (1 - configuration.coverage) * 0.4,
        bristleOpacity: 0.20 + configuration.coverage * 0.22,
        bristleErosion: 0.18 + (1 - configuration.coverage) * 0.3,
        splatCount: configuration.pooling > 0.05
          ? Self.boundedInteger(2 + configuration.pooling * 4, lowerBound: 0, upperBound: 6)
          : 0)
    case .marker(let configuration):
      // Flat marker film: constant width, squared stops, no media texture —
      // the only character is a hair of edge bleed.
      return WidthModel(
        thinning: 0,
        stampSpacing: 0,
        stampFlow: 0,
        stampScatter: 0,
        stampRotation: 0,
        stampMinimumFace: .greatestFiniteMagnitude,
        stampIsErosion: false,
        smoothing: 0.6,
        tremor: 0.05,
        tremorFrequency: 0.5,
        startTaper: 0,
        endTaper: 0,
        edgeAmplitude: 0.10 + configuration.bleed * 0.30,
        edgeFrequency: 0.9,
        edgeTear: 0,
        endCap: .cut,
        exitVariety: false,
        entryStreakCount: Self.boundedInteger(
          3 + configuration.bleed * 6, lowerBound: 3, upperBound: 9),
        inkDepletionRate: 0,
        widthProfile: nil,
        bristleCount: 0,
        bristleRun: 0,
        bristleGap: 0,
        bristleOpacity: 0,
        bristleErosion: 0,
        splatCount: 0)
    case .knockout(let configuration):
      // The punch shape reads best with a quiet organic edge: the shared
      // grain coupling gives it a torn-stencil silhouette.
      return WidthModel(
        thinning: 0,
        stampSpacing: 0,
        stampFlow: 0,
        stampScatter: 0,
        stampRotation: 0,
        stampMinimumFace: .greatestFiniteMagnitude,
        stampIsErosion: false,
        smoothing: 0.6,
        tremor: 0.08,
        tremorFrequency: 0.5,
        startTaper: 0,
        endTaper: 0,
        edgeAmplitude: 0.35 + configuration.edgeSoftness * 1.1,
        edgeFrequency: 0.9,
        edgeTear: 0,
        endCap: .cut,
        exitVariety: false,
        entryStreakCount: 0,
        inkDepletionRate: 0,
        widthProfile: nil,
        bristleCount: 0,
        bristleRun: 0,
        bristleGap: 0,
        bristleOpacity: 0,
        bristleErosion: 0,
        splatCount: 0)
    }
  }

  // MARK: Geometry helpers

  /// Smoothed direction leaving the first sample (used by the entry cap).
  private static func startDirection(_ samples: [WritingStrokeSample]) -> (x: Double, y: Double) {
    let end = samples[min(2, samples.count - 1)]
    let direction = Self.tangent(
      at: 0,
      samples: samples,
      preferredStart: samples[0],
      preferredEnd: end)
    return (-direction.x / direction.length, -direction.y / direction.length)
  }

  /// Smoothed direction arriving at the final sample.
  private static func endDirection(_ samples: [WritingStrokeSample]) -> (x: Double, y: Double) {
    let start = samples[max(0, samples.count - 3)]
    let direction = Self.tangent(
      at: samples.count - 1,
      samples: samples,
      preferredStart: start,
      preferredEnd: samples[samples.count - 1])
    return (direction.x / direction.length, direction.y / direction.length)
  }

  /// Emits a half-round cap that continues the outline from `side` around
  /// `center` toward the mirror rail point, bulging in the `forward`
  /// direction of travel.
  private static func endCap(
    center: WritingStrokeSample,
    radius: Double,
    side: WritingPlanPoint,
    forward: (x: Double, y: Double),
    segments: Int
  ) -> [WritingPlanPoint] {
    guard radius > 0.24 else { return [] }
    let startAngle = atan2(side.y - center.y, side.x - center.x)
    // Pick the half-turn whose midpoint leaves the stroke in the direction
    // of travel, so the cap rounds the tip instead of cutting across it.
    let midPositive = startAngle + .pi / 2
    let midNegative = startAngle - .pi / 2
    let positiveForward = cos(midPositive) * forward.x + sin(midPositive) * forward.y
    let negativeForward = cos(midNegative) * forward.x + sin(midNegative) * forward.y
    let sweep = positiveForward >= negativeForward ? Double.pi : -Double.pi
    var points: [WritingPlanPoint] = []
    points.reserveCapacity(segments - 1)
    for step in 1..<(segments - 1) {
      let t = Double(step) / Double(segments - 1)
      let angle = startAngle + sweep * t
      points.append(WritingPlanPoint(
        x: center.x + cos(angle) * radius,
        y: center.y + sin(angle) * radius))
    }
    return points
  }

  private static func circle(
    center: WritingPlanPoint, radius: Double, segments: Int
  ) -> [WritingPlanPoint] {
    (0..<segments).map { step in
      let angle = Double(step) / Double(segments) * 2 * .pi
      return WritingPlanPoint(
        x: center.x + cos(angle) * radius,
        y: center.y + sin(angle) * radius)
    }
  }

  private static func smooth(_ values: [Double], passes: Int) -> [Double] {
    var current = values
    for _ in 0..<passes {
      guard current.count > 2 else { return current }
      var next = current
      for index in 1..<(current.count - 1) {
        next[index] = (current[index - 1] + current[index] * 2 + current[index + 1]) * 0.25
      }
      current = next
    }
    return current
  }

  /// Walks the centerline depositing stochastic bristle runs with gaps; the
  /// gap probability rises with distance so tails fray first.
  private static func bristleRuns(
    samples: [WritingStrokeSample],
    radii: [Double],
    distances: [Double],
    total: Double,
    baseLateral: Double,
    wanderAmplitude: Double,
    wanderFrequency: Double,
    fineAmplitude: Double,
    fineFrequency: Double,
    phase1: Double,
    phase2: Double,
    runProbability: Double,
    gapProbability: Double,
    inkLoad: [Double]?,
    random: inout WritingStrokeRandom
  ) -> [[WritingPlanPoint]] {
    guard samples.count > 1 else { return [] }
    var runs: [[WritingPlanPoint]] = []
    var current: [WritingPlanPoint] = []
    var depositing = random.nextUnit() < runProbability
    for index in 0..<samples.count {
      if depositing {
        // Two harmonics wander across the ribbon and drift toward the tail,
        // so bristles splay instead of tracing parallel centerline rails.
        // The splay is gated by the local width ratio: at a tapered terminal
        // the bristles converge with the ribbon instead of masking it.
        let progress = distances[index] / max(total, 1e-9)
        let bodyHalf = radii.max() ?? 1
        let radiusRatio = min(1, radii[index] / max(bodyHalf, 1e-9))
        let wander = wanderAmplitude * sin(distances[index] * wanderFrequency + phase1)
          + fineAmplitude * sin(distances[index] * fineFrequency + phase2)
        let lateral = (baseLateral + wander) * (1 + progress * 0.22 * radiusRatio) * radii[index]
        let previous = samples[max(0, index - 1)]
        let next = samples[min(samples.count - 1, index + 1)]
        let direction = Self.tangent(
          at: index,
          samples: samples,
          preferredStart: previous,
          preferredEnd: next)
        let normalX = -direction.y / max(direction.length, 1e-9)
        let normalY = direction.x / max(direction.length, 1e-9)
        current.append(WritingPlanPoint(
          x: samples[index].x + normalX * lateral,
          y: samples[index].y + normalY * lateral))
      }
      let progress = distances[index] / max(total, 1e-9)
      // Gap chance grows toward the tail, producing 飛白-style fraying.
      // Gap chance grows toward the tail, and harder wherever the reservoir
      // has run down — the quantitative 飛白 drying model.
      let dryness = 1 - (inkLoad?[index] ?? 1)
      let gapChance = gapProbability * (0.45 + progress * 1.1) * (1 + dryness * 1.5)
      if depositing, random.nextUnit() < gapChance * 0.55 {
        if current.count > 1 { runs.append(current) }
        current = []
        depositing = false
      } else if !depositing, random.nextUnit() < runProbability * 0.35 {
        depositing = true
      }
    }
    if current.count > 1 { runs.append(current) }
    return runs
  }

  /// The deterministic 2-D media grain field shared by rail displacement
  /// and stamp baking. Sampling the same field at a rail point and inside
  /// the stamp sheets makes the crumbled boundary a continuation of the
  /// interior tooth instead of an independent outline wiggle.
  public static func grain(x: Double, y: Double, seed: UInt64) -> Double {
    var amplitude = 1.0
    var total = 0.0
    var norm = 0.0
    var cell = 6.0
    for octave in 0..<3 {
      total += amplitude * grainOctave(x: x / cell, y: y / cell, seed: seed ^ UInt64(octave * 7919))
      norm += amplitude
      amplitude *= 0.55
      cell *= 0.5
    }
    return total / norm
  }

  private static func grainOctave(x: Double, y: Double, seed: UInt64) -> Double {
    let ix = x.rounded(.down)
    let iy = y.rounded(.down)
    let fx = x - ix
    let fy = y - iy
    let sx = fx * fx * (3 - 2 * fx)
    let sy = fy * fy * (3 - 2 * fy)
    let a = grainLattice(Int(ix), Int(iy), seed)
    let b = grainLattice(Int(ix) + 1, Int(iy), seed)
    let c = grainLattice(Int(ix), Int(iy) + 1, seed)
    let d = grainLattice(Int(ix) + 1, Int(iy) + 1, seed)
    return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy
  }

  private static func grainLattice(_ x: Int, _ y: Int, _ seed: UInt64) -> Double {
    var value = seed
    value ^= UInt64(bitPattern: Int64(x)) &* 0xBF58_476D_1CE4_E5B9
    value ^= UInt64(bitPattern: Int64(y)) &* 0x94D0_49BB_1331_11EB
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    value ^= value >> 31
    return Double(value >> 11) / Double(UInt64.max >> 11)
  }

  /// Deterministic 1-D value noise in [0, 1] with two octaves.
  static func valueNoise(phase: Double, seed: UInt64, salt: UInt64) -> Double {
    // A finite path can still produce an overflowing phase when its length
    // is close to `Double.greatestFiniteMagnitude`.  Clamp that phase before
    // interpolation and hash indexing; never convert an arbitrary Double to
    // Int64 because Swift traps on an out-of-range conversion.
    let base: Double
    if phase.isNaN {
      base = 0
    } else if phase == .infinity {
      base = Double.greatestFiniteMagnitude
    } else if phase == -.infinity {
      base = -Double.greatestFiniteMagnitude
    } else {
      base = phase
    }
    let integer = base.rounded(.down)
    let fraction = base - integer
    let smoothT = fraction * fraction * (3 - 2 * fraction)
    let a = hashValue(seed: seed, salt: salt, index: hashIndex(integer))
    let b = hashValue(seed: seed, salt: salt, index: hashIndex(integer + 1))
    let fine = hashValue(seed: seed, salt: salt ^ 0xF1, index: hashIndex(base * 8))
    return (a + (b - a) * smoothT) * 0.82 + fine * 0.18
  }

  private static func hashIndex(_ value: Double) -> UInt64 {
    // `Double(Int64.max)` rounds to 2^63, so use the exact representable
    // boundary rather than relying on a potentially trapping conversion.
    let signedLimit = 9_223_372_036_854_775_808.0
    guard value.isFinite else {
      return value.sign == .minus ? UInt64(bitPattern: Int64.min) : UInt64.max
    }
    if value >= signedLimit { return UInt64.max }
    if value <= -signedLimit { return UInt64(bitPattern: Int64.min) }
    return UInt64(bitPattern: Int64(value))
  }

  private static func hashValue(seed: UInt64, salt: UInt64, index: UInt64) -> Double {
    var value = seed ^ salt &* 0x9E37_79B9_7F4A_7C15 ^ index &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 30)) &* 0x94D0_49BB_1331_11EB
    value = (value ^ (value >> 27)) &* 0x9E37_79B9_7F4A_7C15
    value ^= value >> 31
    return Double(value >> 11) / Double(UInt64.max >> 11)
  }
}

/// Small deterministic PRNG (SplitMix64) shared by the stroke plan.
private struct WritingStrokeRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed == 0 ? 0x853C_49E6_748F_EA9B : seed
  }

  mutating func nextUnit() -> Double {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    value ^= value >> 31
    return Double(value >> 11) / Double(UInt64.max >> 11)
  }
}
