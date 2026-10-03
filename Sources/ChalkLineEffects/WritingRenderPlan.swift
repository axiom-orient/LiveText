import SwiftUI

/// Renderer-owned geometry prepared once for a mounted writing view.
///
/// The semantic scene and its timeline are public value contracts. This plan
/// is deliberately internal: it keeps the expensive renderer work (contact
/// naturalization, arc-length metadata, and complete Bezier paths) out of the
/// Canvas frame closure without changing the public preparation model.
struct ChalkWritingRenderPlan {
  struct Stroke {
    let timing: WritingStrokeTiming
    let points: [WritingPoint]
    let cumulativeLengths: [Double]
    let length: Double
    let averageWidth: Double
    let fullSegments: [WritingCubicSegment]
    let fullPath: Path?

    func prefix(upTo fraction: Double) throws -> [WritingPoint] {
      let clamped = min(1, max(0, fraction))
      if clamped <= 0 { return [] }
      if clamped >= 1 || points.count == 1 { return points }

      if length <= 0 {
        return [points[0]]
      }

      let target = clamped * length
      var result = [points[0]]
      result.reserveCapacity(points.count)
      for index in 0..<(points.count - 1) {
        let segmentEnd = cumulativeLengths[index + 1]
        let segmentLength = segmentEnd - cumulativeLengths[index]
        if segmentEnd < target {
          result.append(points[index + 1])
          continue
        }
        if segmentLength > 0 {
          let segmentStart = cumulativeLengths[index]
          let segmentFraction = (target - segmentStart) / segmentLength
          result.append(
            try points[index].interpolated(to: points[index + 1], fraction: segmentFraction))
        }
        break
      }
      return result
    }

    func path(upTo fraction: Double) throws -> Path? {
      let clamped = min(1, max(0, fraction))
      guard clamped > 0, points.count > 1 else { return nil }
      if clamped >= 1 { return fullPath }
      guard length > 0 else { return nil }

      let target = clamped * length
      var activeIndex: Int?
      var activeFraction: Double?
      for index in 0..<(points.count - 1) {
        let segmentEnd = cumulativeLengths[index + 1]
        guard segmentEnd >= target else { continue }
        let segmentLength = segmentEnd - cumulativeLengths[index]
        if segmentLength > 0 {
          activeFraction = (target - cumulativeLengths[index]) / segmentLength
          activeIndex = index
        }
        break
      }

      guard
        let activeIndex,
        let activeFraction,
        activeIndex < fullSegments.count
      else { return nil }

      var path = Path()
      let first = fullSegments[0].start
      path.move(to: CGPoint(x: first.x, y: first.y))
      for index in 0..<activeIndex {
        Self.add(fullSegments[index], to: &path)
      }
      let segment = fullSegments[activeIndex]
      if activeFraction >= 1 {
        Self.add(segment, to: &path)
      } else {
        let split = try Self.split(segment, at: activeFraction)
        Self.add(split.prefix, to: &path)
      }
      return path
    }

    func suffix(from fraction: Double) throws -> [WritingPoint] {
      let clamped = min(1, max(0, fraction))
      if clamped <= 0 { return points }
      if clamped >= 1 { return [] }
      if points.count == 1 || length <= 0 { return [points[0]] }

      let target = clamped * length
      var result: [WritingPoint] = []
      result.reserveCapacity(points.count)
      for index in 0..<(points.count - 1) {
        let segmentStart = cumulativeLengths[index]
        let segmentEnd = cumulativeLengths[index + 1]
        let segmentLength = segmentEnd - segmentStart
        guard segmentEnd >= target else { continue }
        if segmentLength > 0 {
          let segmentFraction = (target - segmentStart) / segmentLength
          if segmentFraction < 1 {
            result.append(
              try points[index].interpolated(to: points[index + 1], fraction: segmentFraction)
            )
          }
        }
        result.append(contentsOf: points[(index + 1)...])
        break
      }
      return result
    }

    func path(from fraction: Double) throws -> Path? {
      let clamped = min(1, max(0, fraction))
      guard clamped < 1, points.count > 1, length > 0 else {
        return clamped <= 0 ? fullPath : nil
      }

      let target = clamped * length
      var activeIndex: Int?
      var activeFraction: Double?
      for index in 0..<(points.count - 1) {
        let segmentEnd = cumulativeLengths[index + 1]
        guard segmentEnd >= target else { continue }
        let segmentLength = segmentEnd - cumulativeLengths[index]
        if segmentLength > 0 {
          activeFraction = (target - cumulativeLengths[index]) / segmentLength
          activeIndex = index
        }
        break
      }

      guard
        let activeIndex,
        let activeFraction,
        activeIndex < fullSegments.count
      else { return nil }

      var path = Path()
      if activeFraction < 1 {
        let split = try Self.split(fullSegments[activeIndex], at: activeFraction)
        let first = split.suffix.start
        path.move(to: CGPoint(x: first.x, y: first.y))
        Self.add(split.suffix, to: &path)
        if activeIndex + 1 < fullSegments.count {
          for index in (activeIndex + 1)..<fullSegments.count {
            Self.add(fullSegments[index], to: &path)
          }
        }
        return path
      }

      guard activeIndex + 1 < fullSegments.count else { return nil }
      let first = fullSegments[activeIndex + 1].start
      path.move(to: CGPoint(x: first.x, y: first.y))
      for index in (activeIndex + 1)..<fullSegments.count {
        Self.add(fullSegments[index], to: &path)
      }
      return path
    }

    func rendersAsDot(at fraction: Double) -> Bool {
      points.count == 1 || length <= 0
    }
  }

  let sceneSize: WritingSize
  let duration: Double
  let strokes: [Stroke]

  init(preparation: ChalkWritingPreparation) throws {
    try self.init(scene: preparation.scene, timeline: preparation.timeline)
  }

  init(scene: StrokeWritingScene, timeline: WritingTimeline) throws {
    // Keep direct render-plan construction safe even when it bypasses
    // ChalkWritingPreparation's Codable boundary.
    try validateChalkWritingTimelineOwnership(scene: scene, timeline: timeline)

    var strokesByID: [String: WritingStroke] = [:]
    strokesByID.reserveCapacity(timeline.strokes.count)
    // Walk the owned glyph storage directly. `scene.strokes` is a convenient
    // public flattened view, but materializing it here would add a second
    // temporary array before the dictionary is built.
    for glyph in scene.glyphs {
      for stroke in glyph.strokes {
        strokesByID[stroke.id] = stroke
      }
    }

    var plannedStrokes: [Stroke] = []
    plannedStrokes.reserveCapacity(timeline.strokes.count)
    for timing in timeline.strokes {
      guard let sourceStroke = strokesByID[timing.strokeID] else {
        throw WritingCoreError.invalidTimeline
      }
      let naturalized = try WritingPlayback.naturalizedStroke(sourceStroke)
      plannedStrokes.append(
        try Stroke(
          timing: timing,
          stroke: naturalized
        )
      )
    }

    guard plannedStrokes.count == timeline.strokes.count else {
      throw WritingCoreError.invalidTimeline
    }

    self.sceneSize = scene.size
    self.duration = timeline.duration
    self.strokes = plannedStrokes
  }
}

extension ChalkWritingRenderPlan.Stroke {
  init(timing: WritingStrokeTiming, stroke: WritingStroke) throws {
    let points = stroke.points
    var cumulativeLengths = [Double](repeating: 0, count: points.count)
    if points.count > 1 {
      for index in 0..<(points.count - 1) {
        let dx = points[index + 1].x - points[index].x
        let dy = points[index + 1].y - points[index].y
        cumulativeLengths[index + 1] = cumulativeLengths[index] + hypot(dx, dy)
      }
    }

    self.timing = timing
    self.points = points
    self.cumulativeLengths = cumulativeLengths
    self.length = cumulativeLengths.last ?? 0
    self.averageWidth = points.reduce(0) { $0 + $1.width } / Double(points.count)
    self.fullSegments = points.count > 1 ? try WritingBezierPath.segments(for: points) : []
    self.fullPath = try Self.makePath(for: points, segments: fullSegments)
  }

  fileprivate static func makePath(
    for points: [WritingPoint],
    segments providedSegments: [WritingCubicSegment]? = nil
  ) throws -> Path? {
    guard points.count > 1 else { return nil }
    let segments = try providedSegments ?? WritingBezierPath.segments(for: points)
    var path = Path()
    path.move(to: CGPoint(x: points[0].x, y: points[0].y))
    for segment in segments {
      path.addCurve(
        to: CGPoint(x: segment.end.x, y: segment.end.y),
        control1: CGPoint(x: segment.control1.x, y: segment.control1.y),
        control2: CGPoint(x: segment.control2.x, y: segment.control2.y)
      )
    }
    return path
  }

  private static func add(_ segment: WritingCubicSegment, to path: inout Path) {
    path.addCurve(
      to: CGPoint(x: segment.end.x, y: segment.end.y),
      control1: CGPoint(x: segment.control1.x, y: segment.control1.y),
      control2: CGPoint(x: segment.control2.x, y: segment.control2.y)
    )
  }

  private static func split(
    _ segment: WritingCubicSegment,
    at fraction: Double
  ) throws -> (prefix: WritingCubicSegment, suffix: WritingCubicSegment) {
    let t = min(1, max(0, fraction))
    let start = try WritingCoordinate(x: segment.start.x, y: segment.start.y)
    let end = try WritingCoordinate(x: segment.end.x, y: segment.end.y)

    func interpolate(_ first: WritingCoordinate, _ second: WritingCoordinate) throws
      -> WritingCoordinate
    {
      try WritingCoordinate(
        x: first.x + (second.x - first.x) * t,
        y: first.y + (second.y - first.y) * t
      )
    }

    let first = try interpolate(start, segment.control1)
    let second = try interpolate(segment.control1, segment.control2)
    let third = try interpolate(segment.control2, end)
    let fourth = try interpolate(first, second)
    let fifth = try interpolate(second, third)
    let splitCoordinate = try interpolate(fourth, fifth)
    let splitPoint = try WritingPoint(
      x: splitCoordinate.x,
      y: splitCoordinate.y,
      width: segment.start.width + (segment.end.width - segment.start.width) * t
    )

    return (
      prefix: WritingCubicSegment(
        start: segment.start,
        control1: first,
        control2: fourth,
        end: splitPoint
      ),
      suffix: WritingCubicSegment(
        start: splitPoint,
        control1: fifth,
        control2: third,
        end: segment.end
      )
    )
  }
}

/// Pure playback state used by the SwiftUI timeline and deterministic tests.
/// The clock is expressed as a `Double` so tests do not depend on wall time.
struct ChalkWritingPlaybackState: Equatable, Sendable {
  let duration: Double
  private(set) var startedAt: Double
  private(set) var isPaused: Bool

  init(duration: Double, startedAt: Double = 0) {
    self.duration = duration
    self.startedAt = startedAt
    self.isPaused = false
  }

  func progress(at time: Double) -> Double {
    guard time.isFinite else { return 0 }
    guard duration.isFinite, duration > 0 else { return 1 }
    let elapsed = max(0, time - startedAt)
    return min(1, elapsed / duration)
  }

  mutating func markComplete(at time: Double) {
    if progress(at: time) >= 1 {
      isPaused = true
    }
  }

  mutating func reset(at time: Double) {
    startedAt = time
    isPaused = false
  }
}
