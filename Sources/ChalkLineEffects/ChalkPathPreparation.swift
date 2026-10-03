import SwiftUI

/// Validated exact vector data and its deterministic playback timeline.
public struct ChalkPathPreparation: Codable, Equatable, Sendable {
  public let scene: ChalkPathScene
  public let timeline: WritingTimeline

  /// Internal metric data is built once and reused by every frame of a view.
  /// It is deliberately not part of the serialized public contract.
  let geometry: [ChalkPathGeometry]

  /// Full paths are materialized once during preparation and reused by every
  /// mounted view. This render cache is omitted from Codable and Equatable.
  let renderPlan: ChalkPathRenderPlan

  public init(
    scene: ChalkPathScene,
    timing: WritingTimingOptions = .default
  ) throws {
    let geometry = try scene.strokes.map { try ChalkPathGeometry(stroke: $0) }
    let timeline = try WritingTimelinePlanner.makePathTimeline(
      strokeIDsAndLengths: geometry.map { ($0.id, $0.length) },
      options: timing
    )
    let renderPlan = try ChalkPathRenderPlan(
      scene: scene, timeline: timeline, geometry: geometry
    )
    self.scene = scene
    self.timeline = timeline
    self.geometry = geometry
    self.renderPlan = renderPlan
  }

  public var duration: Double { timeline.duration }

  public static func prepare(
    scene: ChalkPathScene,
    timing: WritingTimingOptions = .default
  ) throws -> ChalkPathPreparation {
    try ChalkPathPreparation(scene: scene, timing: timing)
  }

  private enum CodingKeys: String, CodingKey { case scene, timeline }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let scene = try container.decode(ChalkPathScene.self, forKey: .scene)
    let timeline = try container.decode(WritingTimeline.self, forKey: .timeline)
    let geometry = try scene.strokes.map { try ChalkPathGeometry(stroke: $0) }
    guard timeline.strokes.count == geometry.count,
      timeline.strokes.map(\.strokeID) == scene.strokes.map(\.id)
    else {
      throw ChalkPathError.invalidPath("path preparation timeline does not match scene")
    }
    try Self.validateTimeline(timeline, scene: scene)
    let renderPlan = try ChalkPathRenderPlan(
      scene: scene, timeline: timeline, geometry: geometry
    )
    self.scene = scene
    self.timeline = timeline
    self.geometry = geometry
    self.renderPlan = renderPlan
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(scene, forKey: .scene)
    try container.encode(timeline, forKey: .timeline)
  }

  public static func == (lhs: ChalkPathPreparation, rhs: ChalkPathPreparation) -> Bool {
    lhs.scene == rhs.scene && lhs.timeline == rhs.timeline
  }

  private static func validateTimeline(
    _ timeline: WritingTimeline,
    scene: ChalkPathScene
  ) throws {
    guard timeline.strokes.count == scene.strokes.count,
      timeline.strokes.map(\.strokeID) == scene.strokes.map(\.id),
      timeline.strokes.allSatisfy({ $0.endTime <= timeline.duration })
    else {
      throw ChalkPathError.invalidPath("path preparation timeline does not match scene")
    }
    for (index, timing) in timeline.strokes.enumerated() {
      guard timing.layerIndex == index,
        timing.glyphIndex == 0,
        timing.strokeIndex == index
      else {
        throw ChalkPathError.invalidPath("path preparation timeline indexes are not canonical")
      }
      if index > 0 {
        let previous = timeline.strokes[index - 1]
        guard timing.startTime >= previous.endTime,
          timing.endTime >= previous.endTime
        else {
          throw ChalkPathError.invalidPath("path preparation timeline is not ordered")
        }
      }
    }
  }
}

/// A cubic or line segment with a bounded arc-length lookup table.
struct ChalkPathMetricSegment: Equatable, Sendable {
  let start: ChalkPathPoint
  let control1: ChalkPathPoint
  let control2: ChalkPathPoint
  let end: ChalkPathPoint
  let isLine: Bool
  let length: Double
  let lookup: [Double]

  init(
    start: ChalkPathPoint,
    control1: ChalkPathPoint,
    control2: ChalkPathPoint,
    end: ChalkPathPoint,
    isLine: Bool
  ) throws {
    self.start = start
    self.control1 = control1
    self.control2 = control2
    self.end = end
    self.isLine = isLine
    if isLine {
      let length = hypot(end.x - start.x, end.y - start.y)
      self.length = length
      self.lookup = [0, length]
    } else {
      let sampleCount = Self.sampleCount(
        start: start, control1: control1, control2: control2, end: end
      )
      var cumulative = [Double](repeating: 0, count: sampleCount + 1)
      var previous = start
      if sampleCount > 0 {
        for index in 1...sampleCount {
          let point = Self.cubicPoint(
            start: start,
            control1: control1,
            control2: control2,
            end: end,
            fraction: Double(index) / Double(sampleCount)
          )
          cumulative[index] =
            cumulative[index - 1]
            + hypot(
              point.x - previous.x, point.y - previous.y
            )
          previous = point
        }
      }
      let length = cumulative.last ?? 0
      self.length = length
      if length > 0 {
        self.lookup = cumulative.map { $0 / length }
      } else {
        self.lookup = cumulative
      }
    }
  }

  func point(at fraction: Double) -> ChalkPathPoint {
    let value = min(1, max(0, fraction))
    if isLine {
      return try! ChalkPathPoint(
        x: start.x + (end.x - start.x) * value,
        y: start.y + (end.y - start.y) * value
      )
    }
    guard length > 0, lookup.count > 1 else {
      return value < 1 ? start : end
    }
    var low = 0
    var high = lookup.count - 1
    while low + 1 < high {
      let middle = (low + high) / 2
      if lookup[middle] < value {
        low = middle
      } else {
        high = middle
      }
    }
    let lower = lookup[low]
    let upper = lookup[high]
    let local = upper > lower ? (value - lower) / (upper - lower) : 0
    let t = (Double(low) + local) / Double(lookup.count - 1)
    return Self.cubicPoint(
      start: start, control1: control1, control2: control2, end: end, fraction: t
    )
  }

  private static func sampleCount(
    start: ChalkPathPoint,
    control1: ChalkPathPoint,
    control2: ChalkPathPoint,
    end: ChalkPathPoint
  ) -> Int {
    let polygon =
      hypot(control1.x - start.x, control1.y - start.y)
      + hypot(control2.x - control1.x, control2.y - control1.y)
      + hypot(end.x - control2.x, end.y - control2.y)
    let chord = hypot(end.x - start.x, end.y - start.y)
    let curvature = max(0, polygon - chord)
    return min(48, max(12, Int(ceil(curvature / max(1, chord) * 16)) + 12))
  }

  private static func cubicPoint(
    start: ChalkPathPoint,
    control1: ChalkPathPoint,
    control2: ChalkPathPoint,
    end: ChalkPathPoint,
    fraction: Double
  ) -> ChalkPathPoint {
    let t = min(1, max(0, fraction))
    let inverse = 1 - t
    return try! ChalkPathPoint(
      x: inverse * inverse * inverse * start.x
        + 3 * inverse * inverse * t * control1.x
        + 3 * inverse * t * t * control2.x
        + t * t * t * end.x,
      y: inverse * inverse * inverse * start.y
        + 3 * inverse * inverse * t * control1.y
        + 3 * inverse * t * t * control2.y
        + t * t * t * end.y
    )
  }
}

struct ChalkPathGeometry: Equatable, Sendable {
  let id: String
  let commands: [ChalkPathCommand]
  let style: ChalkPathStrokeStyle
  let startPoint: ChalkPathPoint
  let segments: [ChalkPathMetricSegment]
  let cumulativeLengths: [Double]
  let length: Double

  init(stroke: ChalkPathStroke) throws {
    guard case .move(let startPoint) = stroke.commands[0] else {
      throw ChalkPathError.invalidPath("the first command must be move")
    }
    var current = startPoint
    var subpathStart = startPoint
    var segments: [ChalkPathMetricSegment] = []
    segments.reserveCapacity(stroke.commands.count)

    for command in stroke.commands.dropFirst() {
      switch command {
      case .move:
        throw ChalkPathError.invalidPath("a stroke cannot contain multiple move commands")
      case .line(let point):
        try Self.appendLine(from: current, to: point, into: &segments)
        current = point
      case .quadratic(let control, let point):
        let control1 = try ChalkPathPoint(
          x: current.x + (control.x - current.x) * (2 / 3),
          y: current.y + (control.y - current.y) * (2 / 3)
        )
        let control2 = try ChalkPathPoint(
          x: point.x + (control.x - point.x) * (2 / 3),
          y: point.y + (control.y - point.y) * (2 / 3)
        )
        try Self.appendCubic(
          from: current, control1: control1, control2: control2, to: point,
          into: &segments
        )
        current = point
      case .cubic(let control1, let control2, let point):
        try Self.appendCubic(
          from: current, control1: control1, control2: control2, to: point,
          into: &segments
        )
        current = point
      case .close:
        try Self.appendLine(from: current, to: subpathStart, into: &segments)
        current = subpathStart
      }
      if case .close = command { subpathStart = current }
    }

    var cumulative = [Double](repeating: 0, count: segments.count + 1)
    for index in segments.indices {
      cumulative[index + 1] = cumulative[index] + segments[index].length
    }
    self.id = stroke.id
    self.commands = stroke.commands
    self.style = stroke.style
    self.startPoint = startPoint
    self.segments = segments
    self.cumulativeLengths = cumulative
    self.length = cumulative.last ?? 0
  }

  private static func appendLine(
    from start: ChalkPathPoint,
    to end: ChalkPathPoint,
    into segments: inout [ChalkPathMetricSegment]
  ) throws {
    try segments.append(
      ChalkPathMetricSegment(
        start: start, control1: start, control2: end, end: end, isLine: true
      )
    )
  }

  private static func appendCubic(
    from start: ChalkPathPoint,
    control1: ChalkPathPoint,
    control2: ChalkPathPoint,
    to end: ChalkPathPoint,
    into segments: inout [ChalkPathMetricSegment]
  ) throws {
    try segments.append(
      ChalkPathMetricSegment(
        start: start, control1: control1, control2: control2, end: end, isLine: false
      )
    )
  }
}

struct ChalkPathRenderPlan: @unchecked Sendable {
  struct Stroke {
    let timing: WritingStrokeTiming
    let geometry: ChalkPathGeometry
    let fullPath: Path

    var length: Double { geometry.length }
    var startPoint: ChalkPathPoint { geometry.startPoint }
    var style: ChalkPathStrokeStyle { geometry.style }

    func path(upTo fraction: Double) -> Path? {
      let value = min(1, max(0, fraction))
      guard value > 0, !geometry.segments.isEmpty else { return nil }
      if value >= 1 { return fullPath }
      guard geometry.length > 0 else { return nil }
      return pathSlice(start: 0, end: value)
    }

    func path(from fraction: Double) -> Path? {
      let value = min(1, max(0, fraction))
      guard value < 1, !geometry.segments.isEmpty else {
        return value <= 0 ? fullPath : nil
      }
      guard geometry.length > 0 else { return nil }
      return pathSlice(start: value, end: 1)
    }

    var rendersAsDot: Bool { geometry.segments.isEmpty || geometry.length <= 0 }

    private func pathSlice(start: Double, end: Double) -> Path {
      let total = geometry.length
      let startDistance = start * total
      let endDistance = end * total
      var path = Path()
      var moved = false
      let firstIndex = Self.firstSegment(
        after: startDistance, cumulative: geometry.cumulativeLengths)
      let endIndex = Self.firstSegment(
        atOrAfter: endDistance, cumulative: geometry.cumulativeLengths)
      guard firstIndex < endIndex else { return path }
      for index in firstIndex..<endIndex {
        let segmentStart = geometry.cumulativeLengths[index]
        let segmentEnd = geometry.cumulativeLengths[index + 1]
        guard segmentEnd > startDistance, segmentStart < endDistance else { continue }
        guard geometry.segments[index].length > 0 else { continue }
        let localStart = max(0, (startDistance - segmentStart) / geometry.segments[index].length)
        let localEnd = min(1, (endDistance - segmentStart) / geometry.segments[index].length)
        guard localEnd > localStart else { continue }
        let segment = geometry.segments[index]
        let first = segment.point(at: localStart)
        let last = segment.point(at: localEnd)
        if !moved {
          path.move(to: CGPoint(x: first.x, y: first.y))
          moved = true
        }
        if segment.isLine {
          path.addLine(to: CGPoint(x: last.x, y: last.y))
        } else if localStart == 0, localEnd == 1 {
          path.addCurve(
            to: CGPoint(x: segment.end.x, y: segment.end.y),
            control1: CGPoint(x: segment.control1.x, y: segment.control1.y),
            control2: CGPoint(x: segment.control2.x, y: segment.control2.y)
          )
        } else {
          let split = Self.split(segment, from: localStart, to: localEnd)
          path.addCurve(
            to: CGPoint(x: split.end.x, y: split.end.y),
            control1: CGPoint(x: split.control1.x, y: split.control1.y),
            control2: CGPoint(x: split.control2.x, y: split.control2.y)
          )
        }
      }
      return path
    }

    private static func firstSegment(
      after distance: Double,
      cumulative: [Double]
    ) -> Int {
      guard cumulative.count > 1 else { return 0 }
      var low = 0
      var high = cumulative.count - 1
      while low < high {
        let middle = (low + high) / 2
        if cumulative[middle] <= distance {
          low = middle + 1
        } else {
          high = middle
        }
      }
      return max(0, min(cumulative.count - 2, low - 1))
    }

    private static func firstSegment(
      atOrAfter distance: Double,
      cumulative: [Double]
    ) -> Int {
      guard cumulative.count > 1 else { return 0 }
      var low = 0
      var high = cumulative.count - 1
      while low < high {
        let middle = (low + high) / 2
        if cumulative[middle] < distance {
          low = middle + 1
        } else {
          high = middle
        }
      }
      return max(0, min(cumulative.count - 1, low))
    }

    private static func split(
      _ segment: ChalkPathMetricSegment,
      from start: Double,
      to end: Double
    ) -> (
      start: ChalkPathPoint, control1: ChalkPathPoint, control2: ChalkPathPoint, end: ChalkPathPoint
    ) {
      let first = split(segment, at: start).suffix
      let span = end > start ? (end - start) / (1 - start) : 0
      let second = split(
        start: first.start,
        control1: first.control1,
        control2: first.control2,
        end: first.end,
        at: span
      ).prefix
      return second
    }

    private static func split(
      start: ChalkPathPoint,
      control1: ChalkPathPoint,
      control2: ChalkPathPoint,
      end: ChalkPathPoint,
      at fraction: Double
    ) -> (
      prefix: (
        start: ChalkPathPoint, control1: ChalkPathPoint, control2: ChalkPathPoint,
        end: ChalkPathPoint
      ),
      suffix: (
        start: ChalkPathPoint, control1: ChalkPathPoint, control2: ChalkPathPoint,
        end: ChalkPathPoint
      )
    ) {
      let t = min(1, max(0, fraction))
      func interpolate(_ first: ChalkPathPoint, _ second: ChalkPathPoint) -> ChalkPathPoint {
        try! ChalkPathPoint(
          x: first.x + (second.x - first.x) * t,
          y: first.y + (second.y - first.y) * t
        )
      }
      let first = interpolate(start, control1)
      let second = interpolate(control1, control2)
      let third = interpolate(control2, end)
      let fourth = interpolate(first, second)
      let fifth = interpolate(second, third)
      let splitPoint = interpolate(fourth, fifth)
      return (
        prefix: (start, first, fourth, splitPoint),
        suffix: (splitPoint, fifth, third, end)
      )
    }

    private static func split(
      _ segment: ChalkPathMetricSegment,
      at fraction: Double
    ) -> (
      prefix: (
        start: ChalkPathPoint, control1: ChalkPathPoint, control2: ChalkPathPoint,
        end: ChalkPathPoint
      ),
      suffix: (
        start: ChalkPathPoint, control1: ChalkPathPoint, control2: ChalkPathPoint,
        end: ChalkPathPoint
      )
    ) {
      return split(
        start: segment.start,
        control1: segment.control1,
        control2: segment.control2,
        end: segment.end,
        at: fraction
      )
    }
  }

  let sceneSize: WritingSize
  let duration: Double
  let strokes: [Stroke]

  init(preparation: ChalkPathPreparation) throws {
    try self.init(
      scene: preparation.scene,
      timeline: preparation.timeline,
      geometry: preparation.geometry
    )
  }

  init(
    scene: ChalkPathScene,
    timeline: WritingTimeline,
    geometry: [ChalkPathGeometry]
  ) throws {
    var geometryByID: [String: ChalkPathGeometry] = [:]
    geometryByID.reserveCapacity(geometry.count)
    for item in geometry { geometryByID[item.id] = item }

    var strokes: [Stroke] = []
    strokes.reserveCapacity(timeline.strokes.count)
    for timing in timeline.strokes {
      guard let geometry = geometryByID[timing.strokeID] else {
        throw ChalkPathError.invalidPath("timeline references missing path stroke")
      }
      strokes.append(
        Stroke(
          timing: timing,
          geometry: geometry,
          fullPath: Self.makeFullPath(from: geometry)
        )
      )
    }
    self.sceneSize = scene.size
    self.duration = timeline.duration
    self.strokes = strokes
  }

  private static func makeFullPath(from geometry: ChalkPathGeometry) -> Path {
    var path = Path()
    for command in geometry.commands {
      switch command {
      case .move(let point):
        path.move(to: CGPoint(x: point.x, y: point.y))
      case .line(let point):
        path.addLine(to: CGPoint(x: point.x, y: point.y))
      case .quadratic(let control, let point):
        path.addQuadCurve(
          to: CGPoint(x: point.x, y: point.y),
          control: CGPoint(x: control.x, y: control.y)
        )
      case .cubic(let control1, let control2, let point):
        path.addCurve(
          to: CGPoint(x: point.x, y: point.y),
          control1: CGPoint(x: control1.x, y: control1.y),
          control2: CGPoint(x: control2.x, y: control2.y)
        )
      case .close:
        path.closeSubpath()
      }
    }
    return path
  }
}
