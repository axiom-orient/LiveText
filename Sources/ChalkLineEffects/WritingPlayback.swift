import Foundation

enum ChalkWritingStrokeSlice: Equatable {
  case prefix(Double)
  case suffix(Double)
}

extension ChalkWritingAnimation {
  func strokeSlice(
    at progress: Double,
    duration: Double,
    timing: WritingStrokeTiming,
    motion: ChalkWritingMotionStyle = .uniform,
    seed: UInt64 = 0
  ) -> ChalkWritingStrokeSlice {
    let clampedProgress = min(1, max(0, progress))
    switch self {
    case .write:
      let fraction = WritingPlayback.strokeFraction(
        at: clampedProgress * duration,
        timing: timing,
        motion: motion,
        seed: seed
      )
      return .prefix(fraction)
    case .eraseForward:
      let fraction = WritingPlayback.strokeFraction(
        at: clampedProgress * duration,
        timing: timing,
        motion: motion,
        seed: seed
      )
      return .suffix(fraction)
    case .eraseReverse:
      let fraction = WritingPlayback.strokeFraction(
        at: (1 - clampedProgress) * duration,
        timing: timing,
        motion: motion,
        seed: seed
      )
      return .prefix(fraction)
    }
  }
}

/// Deterministic playback and contact styling shared by every writing renderer.
///
/// The timing curve models a smooth pen-down stroke; it does not claim to
/// reconstruct the trajectory of any particular writer.
public enum WritingPlayback {
  /// Maps a timeline time to the arc-length fraction visible for one stroke.
  public static func strokeFraction(
    at time: Double,
    timing: WritingStrokeTiming,
    motion: ChalkWritingMotionStyle = .uniform,
    seed: UInt64 = 0
  ) -> Double {
    guard time.isFinite else { return 0 }
    if time <= timing.startTime { return 0 }
    if time >= timing.endTime { return 1 }
    let linear = (time - timing.startTime) / (timing.endTime - timing.startTime)
    guard motion == .varied else { return minimumJerkFraction(linear) }
    return variedFraction(
      linear,
      seed: seed,
      glyphIndex: timing.glyphIndex,
      strokeID: timing.strokeID
    )
  }

  static func variedFraction(
    _ fraction: Double,
    seed: UInt64,
    glyphIndex: Int,
    strokeID: String
  ) -> Double {
    let value = min(1, max(0, fraction))
    // This function runs once per active stroke on every animation frame.
    // Keep the seed derivation numeric so it does not allocate an interpolated
    // String or a temporary exponent array in the Canvas hot path.
    let glyphHash = deterministicHash(seed: seed, glyphIndex: glyphIndex)
    let strokeHash = deterministicHash(seed: glyphHash, strokeID: strokeID)
    let speedAdjusted: Double
    switch glyphHash % 3 {
    case 0:
      speedAdjusted = pow(value, 1.30)
    case 1:
      speedAdjusted = pow(value, 0.78)
    default:
      speedAdjusted = value
    }
    switch strokeHash % 4 {
    case 0:  // slow -> fast
      return speedAdjusted * speedAdjusted
    case 1:  // fast -> slow
      return 1 - pow(1 - speedAdjusted, 2)
    case 2:  // slow -> fast -> slow
      return speedAdjusted < 0.5
        ? 2 * speedAdjusted * speedAdjusted
        : 1 - pow(-2 * speedAdjusted + 2, 2) / 2
    default:
      return minimumJerkFraction(speedAdjusted)
    }
  }

  /// A fifth-order minimum-jerk progression with zero velocity and
  /// acceleration at pen-down and pen-up.
  public static func minimumJerkFraction(_ fraction: Double) -> Double {
    let value = min(1, max(0, fraction))
    return value * value * value * (10 - 15 * value + 6 * value * value)
  }

  /// Applies a small deterministic contact-width variation without changing
  /// the authored stroke geometry or order.
  public static func naturalizedPoints(
    _ points: [WritingPoint],
    strokeID: String
  ) throws -> [WritingPoint] {
    guard !points.isEmpty else { return [] }
    let denominator = Double(max(1, points.count - 1))
    return try points.enumerated().map { index, point in
      let fraction = Double(index) / denominator
      let contact = 0.80 + 0.20 * sin(.pi * fraction)
      let variation = 1 + (deterministicSignedUnit(strokeID: strokeID, index: index) * 0.045)
      return try WritingPoint(x: point.x, y: point.y, width: point.width * contact * variation)
    }
  }

  /// Adds a restrained, deterministic writing character to a logical stroke.
  ///
  /// The original semantic catalog remains the authority for glyph shape and
  /// stroke order. This renderer-facing helper preserves its endpoints, adds a
  /// gentle bend to otherwise ruler-straight strokes, and varies contact width
  /// along the stroke. It deliberately avoids high-frequency jitter: that
  /// reads as a damaged line rather than natural motor movement.
  public static func naturalizedStroke(_ stroke: WritingStroke) throws -> WritingStroke {
    let source = stroke.points
    guard source.count > 1 else {
      return try WritingStroke(
        id: stroke.id, points: try naturalizedPoints(source, strokeID: stroke.id))
    }

    let expanded = try addGentleMidpoints(to: source, strokeID: stroke.id)
    let denominator = Double(max(1, expanded.count - 1))
    let phase = deterministicSignedUnit(strokeID: stroke.id, index: 0) * .pi
    let averageWidth = expanded.map(\.width).reduce(0, +) / Double(expanded.count)

    let styled = try expanded.enumerated().map { index, point in
      let fraction = Double(index) / denominator
      guard index > 0, index < expanded.count - 1 else {
        return try WritingPoint(
          x: point.x, y: point.y,
          width: taperedWidth(point, fraction, strokeID: stroke.id, index: index))
      }

      let previous = expanded[index - 1]
      let next = expanded[index + 1]
      let directionX = next.x - previous.x
      let directionY = next.y - previous.y
      let length = hypot(directionX, directionY)
      let normalX = length > 0 ? -directionY / length : 0
      let normalY = length > 0 ? directionX / length : 0
      let envelope = sin(.pi * fraction)
      let bend = averageWidth * 0.11 * envelope * sin(.pi * fraction + phase)

      return try WritingPoint(
        x: point.x + normalX * bend,
        y: point.y + normalY * bend,
        width: taperedWidth(point, fraction, strokeID: stroke.id, index: index)
      )
    }
    return try WritingStroke(id: stroke.id, points: styled)
  }

  private static func addGentleMidpoints(
    to points: [WritingPoint],
    strokeID: String
  ) throws -> [WritingPoint] {
    guard points.count <= 3 else { return points }
    var result: [WritingPoint] = []
    result.reserveCapacity(points.count * 2)

    for (index, pair) in zip(points.indices, points.dropFirst()) {
      let first = points[index]
      let second = pair
      if result.isEmpty { result.append(first) }
      let directionX = second.x - first.x
      let directionY = second.y - first.y
      let length = hypot(directionX, directionY)
      let normalX = length > 0 ? -directionY / length : 0
      let normalY = length > 0 ? directionX / length : 0
      let bend = length * 0.018 * deterministicSignedUnit(strokeID: strokeID, index: index + 1)
      let midpoint = try WritingPoint(
        x: (first.x + second.x) * 0.5 + normalX * bend,
        y: (first.y + second.y) * 0.5 + normalY * bend,
        width: (first.width + second.width) * 0.5)
      result.append(midpoint)
      result.append(second)
    }
    return result
  }

  private static func taperedWidth(
    _ point: WritingPoint,
    _ fraction: Double,
    strokeID: String,
    index: Int
  ) -> Double {
    let contact = 0.80 + 0.20 * sin(.pi * fraction)
    let variation = 1 + (deterministicSignedUnit(strokeID: strokeID, index: index) * 0.045)
    return point.width * contact * variation
  }

  private static func deterministicSignedUnit(strokeID: String, index: Int) -> Double {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in strokeID.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    hash ^= UInt64(index &* 2_654_435_761)
    return Double(Int(hash & 0xFFFF) - 32_768) / 32_768
  }

  private static func deterministicHash(seed: UInt64, glyphIndex: Int) -> UInt64 {
    var hash = seed ^ 14_695_981_039_346_656_037
    hash ^= UInt64(bitPattern: Int64(glyphIndex))
    hash &*= 1_099_511_628_211
    return hash
  }

  private static func deterministicHash(seed: UInt64, strokeID: String) -> UInt64 {
    var hash = seed ^ 14_695_981_039_346_656_037
    for byte in strokeID.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return hash
  }
}
