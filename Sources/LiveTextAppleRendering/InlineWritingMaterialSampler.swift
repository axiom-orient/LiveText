import CoreGraphics
import Foundation
import LiveTextLayout

/// Source-distance metadata for one drawable SVG path command.
///
/// This is renderer-neutral package-internal API so SwiftUI and Canvas consume one compiler
/// result without carrying adapter-specific metadata types.
package struct InlineWritingMaterialCommandMetadata: Equatable, Sendable {
  public let subpathID: Int
  public let isClosed: Bool
  public let startDistance: Double
  public let endDistance: Double
  public let subpathLength: Double

  public init(
    subpathID: Int,
    isClosed: Bool,
    startDistance: Double,
    endDistance: Double,
    subpathLength: Double
  ) {
    self.subpathID = subpathID
    self.isClosed = isClosed
    self.startDistance = startDistance
    self.endDistance = endDistance
    self.subpathLength = subpathLength
  }
}

/// Explicit failures from command metadata compilation.
package enum InlineWritingMaterialCommandMetadataError:
  Error, Equatable, Sendable, LocalizedError
{
  case invalidCommandState(commandIndex: Int)
  case nonFinitePoint(commandIndex: Int)
  case distanceOverflow(commandIndex: Int)

  public var errorDescription: String? {
    switch self {
    case .invalidCommandState(let commandIndex):
      return "Inline writing material command has no active subpath: \(commandIndex)."
    case .nonFinitePoint(let commandIndex):
      return "Inline writing material command produced a non-finite point: \(commandIndex)."
    case .distanceOverflow(let commandIndex):
      return "Inline writing material command distance overflowed: \(commandIndex)."
    }
  }
}

/// Compiles source-distance metadata once for both drawing adapters.
///
/// Quadratic and cubic samples intentionally retain the existing 8/10-point
/// flattening counts. De Casteljau interpolation keeps each finite sample
/// bounded even when the Bernstein power-basis expression would overflow.
/// Distances are checked at every segment and cumulative addition; unsupported
/// overflow is thrown before an adapter can publish partial metadata.
package enum InlineWritingMaterialCommandMetadataCompiler {
  private struct Point {
    let x: Double
    let y: Double
  }

  private struct RawMetadata {
    let subpathID: Int
    let startDistance: Double
    let length: Double
  }

  public static func compile(
    commands: [InlinePathCommand]
  ) throws -> [Int: InlineWritingMaterialCommandMetadata] {
    var raw: [Int: RawMetadata] = [:]
    var totals: [Int: Double] = [:]
    var closed: Set<Int> = []
    var current: Point?
    var subpathStart: Point?
    var subpathID = -1

    func record(index: Int, length: Double) throws {
      guard subpathID >= 0, current != nil, subpathStart != nil else {
        throw InlineWritingMaterialCommandMetadataError.invalidCommandState(
          commandIndex: index)
      }
      guard length.isFinite, length >= 0 else {
        throw InlineWritingMaterialCommandMetadataError.distanceOverflow(
          commandIndex: index)
      }
      let startDistance = totals[subpathID, default: 0]
      guard startDistance.isFinite, startDistance >= 0 else {
        throw InlineWritingMaterialCommandMetadataError.distanceOverflow(
          commandIndex: index)
      }
      let endDistance = try checkedAdd(
        startDistance, length, commandIndex: index)
      raw[index] = RawMetadata(
        subpathID: subpathID,
        startDistance: startDistance,
        length: length)
      totals[subpathID] = endDistance
    }

    for (index, command) in commands.enumerated() {
      switch command {
      case .move(let point):
        let scalar = Point(x: point.x, y: point.y)
        guard scalar.x.isFinite, scalar.y.isFinite else {
          throw InlineWritingMaterialCommandMetadataError.nonFinitePoint(
            commandIndex: index)
        }
        subpathID += 1
        current = scalar
        subpathStart = scalar
        totals[subpathID] = 0
      case .line(let end):
        guard let currentPoint = current else {
          throw InlineWritingMaterialCommandMetadataError.invalidCommandState(
            commandIndex: index)
        }
        let length = try checkedDistance(
          from: currentPoint,
          to: Point(x: end.x, y: end.y),
          commandIndex: index)
        try record(index: index, length: length)
        current = Point(x: end.x, y: end.y)
      case .quadratic(let control, let end):
        guard let currentPoint = current else {
          throw InlineWritingMaterialCommandMetadataError.invalidCommandState(
            commandIndex: index)
        }
        let length = try quadraticLength(
          from: currentPoint,
          control: Point(x: control.x, y: control.y),
          to: Point(x: end.x, y: end.y),
          commandIndex: index)
        try record(index: index, length: length)
        current = Point(x: end.x, y: end.y)
      case .cubic(let control1, let control2, let end):
        guard let currentPoint = current else {
          throw InlineWritingMaterialCommandMetadataError.invalidCommandState(
            commandIndex: index)
        }
        let length = try cubicLength(
          from: currentPoint,
          control1: Point(x: control1.x, y: control1.y),
          control2: Point(x: control2.x, y: control2.y),
          to: Point(x: end.x, y: end.y),
          commandIndex: index)
        try record(index: index, length: length)
        current = Point(x: end.x, y: end.y)
      case .close:
        guard let currentPoint = current, let subpathStart else {
          throw InlineWritingMaterialCommandMetadataError.invalidCommandState(
            commandIndex: index)
        }
        let length = try checkedDistance(
          from: currentPoint, to: subpathStart, commandIndex: index)
        try record(index: index, length: length)
        closed.insert(subpathID)
        current = subpathStart
      }
    }

    var result: [Int: InlineWritingMaterialCommandMetadata] = [:]
    result.reserveCapacity(raw.count)
    for (index, value) in raw {
      guard let total = totals[value.subpathID], total.isFinite else {
        throw InlineWritingMaterialCommandMetadataError.distanceOverflow(
          commandIndex: index)
      }
      let endDistance = try checkedAdd(
        value.startDistance, value.length, commandIndex: index)
      result[index] = InlineWritingMaterialCommandMetadata(
        subpathID: value.subpathID,
        isClosed: closed.contains(value.subpathID),
        startDistance: value.startDistance,
        endDistance: endDistance,
        subpathLength: total)
    }
    return result
  }

  private static func checkedAdd(
    _ lhs: Double,
    _ rhs: Double,
    commandIndex: Int
  ) throws -> Double {
    let result = lhs + rhs
    guard lhs.isFinite, rhs.isFinite, result.isFinite, result >= 0 else {
      throw InlineWritingMaterialCommandMetadataError.distanceOverflow(
        commandIndex: commandIndex)
    }
    return result
  }

  private static func checkedDistance(
    from start: Point,
    to end: Point,
    commandIndex: Int
  ) throws -> Double {
    let dx = end.x - start.x
    let dy = end.y - start.y
    guard dx.isFinite, dy.isFinite else {
      throw InlineWritingMaterialCommandMetadataError.distanceOverflow(
        commandIndex: commandIndex)
    }
    let length = hypot(dx, dy)
    guard length.isFinite else {
      throw InlineWritingMaterialCommandMetadataError.distanceOverflow(
        commandIndex: commandIndex)
    }
    return length
  }

  private static func lerp(_ lhs: Double, _ rhs: Double, t: Double) -> Double? {
    guard lhs.isFinite, rhs.isFinite, t.isFinite, t >= 0, t <= 1 else { return nil }
    if lhs == rhs { return lhs }
    let result: Double
    // The difference of same-sign finite values is representable. For
    // opposite signs, weighted terms avoid the potentially overflowing
    // subtraction in rhs - lhs.
    if (lhs >= 0 && rhs >= 0) || (lhs <= 0 && rhs <= 0) {
      result = lhs + (rhs - lhs) * t
    } else {
      result = lhs * (1 - t) + rhs * t
    }
    return result.isFinite ? result : nil
  }

  private static func checkedLerp(
    _ lhs: Double,
    _ rhs: Double,
    t: Double,
    commandIndex: Int
  ) throws -> Double {
    guard let result = lerp(lhs, rhs, t: t) else {
      throw InlineWritingMaterialCommandMetadataError.nonFinitePoint(
        commandIndex: commandIndex)
    }
    return result
  }

  private static func quadraticPoint(
    from start: Point,
    control: Point,
    to end: Point,
    t: Double,
    commandIndex: Int
  ) throws -> Point {
    let firstX = try checkedLerp(start.x, control.x, t: t, commandIndex: commandIndex)
    let secondX = try checkedLerp(control.x, end.x, t: t, commandIndex: commandIndex)
    let firstY = try checkedLerp(start.y, control.y, t: t, commandIndex: commandIndex)
    let secondY = try checkedLerp(control.y, end.y, t: t, commandIndex: commandIndex)
    return Point(
      x: try checkedLerp(firstX, secondX, t: t, commandIndex: commandIndex),
      y: try checkedLerp(firstY, secondY, t: t, commandIndex: commandIndex))
  }

  private static func cubicPoint(
    from start: Point,
    control1: Point,
    control2: Point,
    to end: Point,
    t: Double,
    commandIndex: Int
  ) throws -> Point {
    let firstX = try checkedLerp(start.x, control1.x, t: t, commandIndex: commandIndex)
    let secondX = try checkedLerp(control1.x, control2.x, t: t, commandIndex: commandIndex)
    let thirdX = try checkedLerp(control2.x, end.x, t: t, commandIndex: commandIndex)
    let firstY = try checkedLerp(start.y, control1.y, t: t, commandIndex: commandIndex)
    let secondY = try checkedLerp(control1.y, control2.y, t: t, commandIndex: commandIndex)
    let thirdY = try checkedLerp(control2.y, end.y, t: t, commandIndex: commandIndex)
    let fourthX = try checkedLerp(firstX, secondX, t: t, commandIndex: commandIndex)
    let fifthX = try checkedLerp(secondX, thirdX, t: t, commandIndex: commandIndex)
    let fourthY = try checkedLerp(firstY, secondY, t: t, commandIndex: commandIndex)
    let fifthY = try checkedLerp(secondY, thirdY, t: t, commandIndex: commandIndex)
    return Point(
      x: try checkedLerp(fourthX, fifthX, t: t, commandIndex: commandIndex),
      y: try checkedLerp(fourthY, fifthY, t: t, commandIndex: commandIndex))
  }

  private static func quadraticLength(
    from start: Point,
    control: Point,
    to end: Point,
    commandIndex: Int
  ) throws -> Double {
    var previous = start
    var length = 0.0
    for step in 1...8 {
      let point = try quadraticPoint(
        from: start,
        control: control,
        to: end,
        t: Double(step) / 8,
        commandIndex: commandIndex)
      length = try checkedAdd(
        length,
        try checkedDistance(from: previous, to: point, commandIndex: commandIndex),
        commandIndex: commandIndex)
      previous = point
    }
    return length
  }

  private static func cubicLength(
    from start: Point,
    control1: Point,
    control2: Point,
    to end: Point,
    commandIndex: Int
  ) throws -> Double {
    var previous = start
    var length = 0.0
    for step in 1...10 {
      let point = try cubicPoint(
        from: start,
        control1: control1,
        control2: control2,
        to: end,
        t: Double(step) / 10,
        commandIndex: commandIndex)
      length = try checkedAdd(
        length,
        try checkedDistance(from: previous, to: point, commandIndex: commandIndex),
        commandIndex: commandIndex)
      previous = point
    }
    return length
  }
}

/// A command-sized centerline fragment with the source subpath arclength it
/// came from.  The path is already in the adapter's target coordinate space;
/// this type only carries immutable metadata across the SwiftUI/Canvas
/// boundary.
package struct InlineWritingMaterialPathPiece {
  public let path: CGPath
  public let subpathID: Int
  public let startDistance: Double
  public let endDistance: Double
  public let subpathLength: Double
  public let isClosed: Bool
  public let commandIndex: Int

  public init(
    path: CGPath,
    subpathID: Int,
    startDistance: Double,
    endDistance: Double,
    subpathLength: Double,
    isClosed: Bool,
    commandIndex: Int
  ) {
    self.path = path
    self.subpathID = subpathID
    self.startDistance = startDistance
    self.endDistance = endDistance
    self.subpathLength = subpathLength
    self.isClosed = isClosed
    self.commandIndex = commandIndex
  }
}

/// One bounded, source-distance-aware line segment emitted by the common
/// sampler.  Both drawing adapters feed this exact representation into the
/// renderer-neutral writing geometry plan.
package struct InlineWritingMaterialSegment {
  public let start: CGPoint
  public let end: CGPoint
  public let startDistance: Double
  public let endDistance: Double
  public let subpathLength: Double
  public let subpathID: Int
  public let isClosed: Bool
  public let commandIndex: Int

  public init(
    start: CGPoint,
    end: CGPoint,
    startDistance: Double,
    endDistance: Double,
    subpathLength: Double,
    subpathID: Int,
    isClosed: Bool,
    commandIndex: Int
  ) {
    self.start = start
    self.end = end
    self.startDistance = startDistance
    self.endDistance = endDistance
    self.subpathLength = subpathLength
    self.subpathID = subpathID
    self.isClosed = isClosed
    self.commandIndex = commandIndex
  }
}

/// Bounded Core Graphics flattening shared by the SwiftUI and Canvas
/// adapters.  Sampling is capped while each CGPath element is flattened; no
/// unbounded intermediate segment array is created and no second 8x expansion
/// is performed by an adapter.  The collector keeps the source-distance
/// metadata supplied by the immutable command preparation step, so taper and
/// pressure do not restart at reveal command boundaries.
package enum InlineWritingMaterialSampler {
  public static let maximumSegments = 16_384

  /// Builds a bounded, immutable plan for the supplied command pieces.
  ///
  /// Move-only and zero-length pieces are ignored. If the number of remaining
  /// drawable pieces is greater than the requested cap, an empty array is an
  /// explicit unsupported-input result: the sampler never returns a partial
  /// plan that silently removes reveal commands. Every accepted drawable
  /// piece receives at least one segment, and any remaining budget is divided
  /// by measured piece length. Segments never cross a command boundary.
  public static func segments(
    pieces: [InlineWritingMaterialPathPiece],
    maximumSegments requestedMaximum: Int = Self.maximumSegments
  ) -> [InlineWritingMaterialSegment] {
    let maximum = max(1, min(Self.maximumSegments, requestedMaximum))
    return Self.canonicalSegments(pieces: pieces, maximum: maximum)
  }

  private struct MeasuredPiece {
    let piece: InlineWritingMaterialPathPiece
    let start: CGPoint
    let end: CGPoint
    /// A closed command-only path can contain a forward edge followed by the
    /// synthetic close edge back to its start. In that case the flattened
    /// first/last endpoints are equal even though the piece is drawable. Keep
    /// the first real edge as a one-segment fallback so reservation cannot
    /// erase the command.
    let fallbackStart: CGPoint
    let fallbackEnd: CGPoint
    let length: Double
    let flattenedCount: Int
  }

  /// Creates one immutable, whole-asset command-preserving sampling plan.
  /// The first pass only measures each command with the fixed 8/10-point
  /// flattening used by the renderers. The second pass emits at least one
  /// segment for every valid command and allocates remaining samples by
  /// measured command length. No segment is allowed to cross commands and no
  /// 8x/10x flattened asset is retained.
  private static func canonicalSegments(
    pieces: [InlineWritingMaterialPathPiece],
    maximum: Int
  ) -> [InlineWritingMaterialSegment] {
    var measuredPieces: [MeasuredPiece] = []
    measuredPieces.reserveCapacity(min(pieces.count, maximum))
    for piece in pieces {
      guard let measured = Self.measure(piece: piece) else { continue }
      // Do not retain an unbounded measured-piece array just to discover that
      // the mandatory one-segment-per-piece reservation cannot fit. Once the
      // cap is exceeded the result is an explicit unsupported-input failure,
      // so no later piece can affect that result.
      guard measuredPieces.count < maximum else { return [] }
      measuredPieces.append(measured)
    }
    guard !measuredPieces.isEmpty else { return [] }
    // Reserve one segment for every drawable piece before allocating any
    // extra samples. A command cap cannot preserve reveal semantics if this
    // mandatory reservation does not fit, so return an explicit failure
    // rather than dropping a prefix or crossing command boundaries.
    guard measuredPieces.count <= maximum else { return [] }

    let minimums = Array(repeating: 1, count: measuredPieces.count)
    let capacities = measuredPieces.map { max(0, $0.flattenedCount - 1) }
    let extras = Self.proportionalAllocation(
      weights: measuredPieces.map(\.length),
      capacities: capacities,
      total: maximum - measuredPieces.count)
    var result: [InlineWritingMaterialSegment] = []
    result.reserveCapacity(maximum)
    for (index, piece) in measuredPieces.enumerated() {
      let budget = minimums[index] + extras[index]
      guard Self.append(
        piece: piece,
        segmentCount: budget,
        to: &result,
        maximum: maximum
      ) else {
        // A measured drawable piece must contribute at least one segment. If
        // a later finite-coordinate check makes that impossible, preserve the
        // same explicit-failure semantics as an over-cap input rather than
        // returning a silently truncated prefix.
        return []
      }
    }
    return result
  }

  private static func measure(
    piece: InlineWritingMaterialPathPiece
  ) -> MeasuredPiece? {
    guard piece.commandIndex >= 0,
      piece.startDistance.isFinite,
      piece.endDistance.isFinite,
      piece.subpathLength.isFinite,
      piece.startDistance >= 0,
      piece.endDistance >= piece.startDistance,
      piece.subpathLength >= piece.endDistance
    else { return nil }

    var first: CGPoint?
    var last: CGPoint?
    var fallbackStart: CGPoint?
    var fallbackEnd: CGPoint?
    var length = 0.0
    var count = 0
    var valid = true
    Self.forEachFlattenedSegment(in: piece.path) { start, end in
      guard valid,
        start.x.isFinite, start.y.isFinite,
        end.x.isFinite, end.y.isFinite
      else {
        valid = false
        return
      }
      let dx = Double(end.x) - Double(start.x)
      let dy = Double(end.y) - Double(start.y)
      guard dx.isFinite, dy.isFinite else {
        valid = false
        return
      }
      let segmentLength = hypot(dx, dy)
      guard segmentLength.isFinite else {
        valid = false
        return
      }
      guard segmentLength > 0 else { return }
      let nextLength = length + segmentLength
      guard nextLength.isFinite else {
        valid = false
        return
      }
      if first == nil { first = start }
      if fallbackStart == nil {
        fallbackStart = start
        fallbackEnd = end
      }
      last = end
      length = nextLength
      count += 1
    }
    guard valid, let first, let last, count > 0, length > 0 else { return nil }
    return MeasuredPiece(
      piece: piece,
      start: first,
      end: last,
      fallbackStart: fallbackStart ?? first,
      fallbackEnd: fallbackEnd ?? last,
      length: length,
      flattenedCount: count)
  }

  private static func proportionalAllocation(
    weights: [Double],
    capacities: [Int],
    total: Int
  ) -> [Int] {
    guard weights.count == capacities.count, total > 0 else {
      return Array(repeating: 0, count: capacities.count)
    }
    let totalWeight = weights.reduce(0, +)
    guard totalWeight.isFinite, totalWeight > 0 else {
      var fallback = Array(repeating: 0, count: capacities.count)
      var remaining = total
      for index in fallback.indices where remaining > 0 {
        let amount = min(capacities[index], remaining)
        fallback[index] = amount
        remaining -= amount
      }
      return fallback
    }

    var result = Array(repeating: 0, count: capacities.count)
    var remainders = Array(repeating: 0.0, count: capacities.count)
    var assigned = 0
    for index in result.indices {
      let capacity = max(0, capacities[index])
      guard capacity > 0 else { continue }
      let share = Double(total) * max(0, weights[index]) / totalWeight
      let base = Self.safeFloor(share, upperBound: min(capacity, total))
      result[index] = base
      assigned += base
      remainders[index] = max(0, share - Double(base))
    }

    var remaining = max(0, total - assigned)
    // Largest-remainder allocation is deterministic once the candidates are
    // sorted by remainder and then by source index. The previous implementation
    // rescanned every candidate for every remaining unit, which made a large
    // multi-subpath asset O(n * remaining). One sort plus two linear passes
    // keeps this bounded at O(n log n), while retaining the same tie-break and
    // capacity behavior.
    let order = result.indices
      .filter { index in
        result[index] < capacities[index] && remainders[index].isFinite
      }
      .sorted { left, right in
        if remainders[left] == remainders[right] { return left < right }
        return remainders[left] > remainders[right]
      }
    for index in order where remaining > 0 {
      result[index] += 1
      remaining -= 1
    }
    // If a capacity clipped a large proportional share, there can still be
    // more units than candidates. All remainders are now exhausted; fill the
    // remaining capacity in source-index order without another scan per unit.
    if remaining > 0 {
      for index in result.indices where remaining > 0 {
        let capacity = max(0, capacities[index])
        let available = capacity - result[index]
        guard available > 0 else { continue }
        let amount = min(available, remaining)
        result[index] += amount
        remaining -= amount
      }
    }
    return result
  }

  private static func safeFloor(_ value: Double, upperBound: Int) -> Int {
    guard upperBound > 0, value.isFinite, value > 0 else { return 0 }
    let floored = value.rounded(.down)
    guard floored >= 1 else { return 0 }
    if floored >= Double(upperBound) { return upperBound }
    // `floored < upperBound <= maximumSegments`, so this conversion is
    // proven finite and representable rather than relying on a trap-prone
    // conversion from arbitrary input.
    return Int(floored)
  }

  private static func append(
    piece: MeasuredPiece,
    segmentCount: Int,
    to result: inout [InlineWritingMaterialSegment],
    maximum: Int
  ) -> Bool {
    guard segmentCount > 0, result.count < maximum,
      let points = Self.samplePoints(piece: piece, segmentCount: segmentCount)
    else { return false }
    let sourceSpan = piece.piece.endDistance - piece.piece.startDistance
    guard sourceSpan.isFinite, sourceSpan >= 0 else { return false }
    var appended = false
    for index in 0..<min(segmentCount, points.count - 1) {
      guard result.count < maximum else { return false }
      let start = points[index]
      let end = points[index + 1]
      guard start != end else { continue }
      let lower = Double(index) / Double(segmentCount)
      let upper = Double(index + 1) / Double(segmentCount)
      let startDistance = Self.sourceDistance(piece.piece, fraction: lower)
      let endDistance = Self.sourceDistance(piece.piece, fraction: upper)
      guard startDistance.isFinite, endDistance.isFinite else { return false }
      result.append(InlineWritingMaterialSegment(
        start: start,
        end: end,
        startDistance: startDistance,
        endDistance: endDistance,
        subpathLength: piece.piece.subpathLength,
        subpathID: piece.piece.subpathID,
        isClosed: piece.piece.isClosed,
        commandIndex: piece.piece.commandIndex))
      appended = true
    }
    return appended
  }

  private static func samplePoints(
    piece: MeasuredPiece,
    segmentCount: Int
  ) -> [CGPoint]? {
    guard segmentCount > 0 else { return nil }
    if segmentCount == 1 {
      if piece.start == piece.end {
        return [piece.fallbackStart, piece.fallbackEnd]
      }
      return [piece.start, piece.end]
    }
    var points = Array(repeating: piece.start, count: segmentCount + 1)
    points[segmentCount] = piece.end
    var targetIndex = 1
    var travelled = 0.0
    var valid = true
    Self.forEachFlattenedSegment(in: piece.piece.path) { start, end in
      guard valid, targetIndex < segmentCount else { return }
      let dx = Double(end.x) - Double(start.x)
      let dy = Double(end.y) - Double(start.y)
      guard dx.isFinite, dy.isFinite else { valid = false; return }
      let length = hypot(dx, dy)
      guard length.isFinite else { valid = false; return }
      guard length > 0 else { return }
      let segmentEnd = travelled + length
      guard segmentEnd.isFinite else { valid = false; return }
      while targetIndex < segmentCount {
        let target = piece.length * Double(targetIndex) / Double(segmentCount)
        guard target.isFinite else { valid = false; return }
        guard target <= segmentEnd else { break }
        let fraction = max(0, min(1, (target - travelled) / length))
        points[targetIndex] = CGPoint(
          x: start.x + (end.x - start.x) * CGFloat(fraction),
          y: start.y + (end.y - start.y) * CGFloat(fraction))
        targetIndex += 1
      }
      travelled = segmentEnd
    }
    guard valid, targetIndex == segmentCount,
      points.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
    else { return nil }
    return points
  }

  private static func sourceDistance(
    _ piece: InlineWritingMaterialPathPiece,
    fraction: Double
  ) -> Double {
    if fraction <= 0 { return piece.startDistance }
    if fraction >= 1 { return piece.endDistance }
    let span = piece.endDistance - piece.startDistance
    guard span.isFinite else { return piece.startDistance }
    let value = piece.startDistance + span * fraction
    guard value.isFinite else { return piece.endDistance }
    return min(piece.endDistance, max(piece.startDistance, value))
  }

  private static func forEachFlattenedSegment(
    in path: CGPath,
    body: (CGPoint, CGPoint) -> Void
  ) {
    var current: CGPoint?
    var subpathStart: CGPoint?
    path.applyWithBlock { elementPointer in
      let element = elementPointer.pointee
      switch element.type {
      case .moveToPoint:
        current = element.points[0]
        subpathStart = current
      case .addLineToPoint:
        guard let start = current else { return }
        let end = element.points[0]
        body(start, end)
        current = end
      case .addQuadCurveToPoint:
        guard let start = current else { return }
        let control = element.points[0]
        let end = element.points[1]
        var previous = start
        for step in 1...8 {
          let t = CGFloat(step) / 8
          let inverse = 1 - t
          let point = CGPoint(
            x: inverse * inverse * start.x
              + 2 * inverse * t * control.x + t * t * end.x,
            y: inverse * inverse * start.y
              + 2 * inverse * t * control.y + t * t * end.y)
          body(previous, point)
          previous = point
        }
        current = end
      case .addCurveToPoint:
        guard let start = current else { return }
        let control1 = element.points[0]
        let control2 = element.points[1]
        let end = element.points[2]
        var previous = start
        for step in 1...10 {
          let t = CGFloat(step) / 10
          let inverse = 1 - t
          let point = CGPoint(
            x: inverse * inverse * inverse * start.x
              + 3 * inverse * inverse * t * control1.x
              + 3 * inverse * t * t * control2.x
              + t * t * t * end.x,
            y: inverse * inverse * inverse * start.y
              + 3 * inverse * inverse * t * control1.y
              + 3 * inverse * t * t * control2.y
              + t * t * t * end.y)
          body(previous, point)
          previous = point
        }
        current = end
      case .closeSubpath:
        guard let start = current, let subpathStart else { return }
        body(start, subpathStart)
        current = subpathStart
      @unknown default:
        break
      }
    }
  }

  /// Returns a reveal prefix from an immutable full-path segment plan. The
  /// operation only scans the already bounded segment array and interpolates
  /// one moving terminal; it never re-flattens a CGPath on a frame.
  public static func visibleSegments(
    _ segments: [InlineWritingMaterialSegment],
    activation: InlineRenderRevealVectorActivation?,
    time: Double
  ) -> [InlineWritingMaterialSegment] {
    guard let activation else { return segments }
    var visible: [InlineWritingMaterialSegment] = []
    visible.reserveCapacity(segments.count)
    // Segments are emitted in command order. Resolve activation once per
    // command, then clip the active command against one absolute source
    // distance. Applying the command fraction independently to every
    // flattened segment would reveal the tail of a cubic before its head and
    // would create gaps between consecutive segments.
    var commandStart = 0
    while commandStart < segments.count {
      let commandIndex = segments[commandStart].commandIndex
      var commandEnd = commandStart + 1
      while commandEnd < segments.count,
        segments[commandEnd].commandIndex == commandIndex
      {
        commandEnd += 1
      }
      let progress = activation.progress(at: time, commandIndex: commandIndex)
      guard progress > 0 else {
        commandStart = commandEnd
        continue
      }
      if progress >= 1 {
        visible.append(contentsOf: segments[commandStart..<commandEnd])
        commandStart = commandEnd
        continue
      }

      let first = segments[commandStart]
      let last = segments[commandEnd - 1]
      let commandLower = first.startDistance
      let commandUpper = last.endDistance
      let commandSpan = commandUpper - commandLower
      guard commandSpan > 0, commandSpan.isFinite else {
        commandStart = commandEnd
        continue
      }
      let terminal = commandLower + commandSpan * progress
      guard terminal > commandLower, terminal.isFinite else {
        commandStart = commandEnd
        continue
      }
      for segment in segments[commandStart..<commandEnd] {
        guard segment.startDistance < terminal else { break }
        guard segment.endDistance > segment.startDistance,
          segment.endDistance.isFinite
        else { continue }
        if segment.endDistance <= terminal {
          visible.append(segment)
          continue
        }
        let span = segment.endDistance - segment.startDistance
        let fraction = (terminal - segment.startDistance) / span
        guard fraction > 0, fraction.isFinite else { continue }
        let end = CGPoint(
          x: segment.start.x + (segment.end.x - segment.start.x) * fraction,
          y: segment.start.y + (segment.end.y - segment.start.y) * fraction
        )
        visible.append(
          InlineWritingMaterialSegment(
            start: segment.start,
            end: end,
            startDistance: segment.startDistance,
            endDistance: terminal,
            subpathLength: segment.subpathLength,
            subpathID: segment.subpathID,
            isClosed: segment.isClosed,
            commandIndex: segment.commandIndex
          )
        )
        break
      }
      commandStart = commandEnd
    }
    return visible
  }

}
