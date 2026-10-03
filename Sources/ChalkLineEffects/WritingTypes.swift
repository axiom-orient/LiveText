import Foundation

public enum WritingCoreError: Error, Equatable, Sendable {
  case invalidNumber(field: String, value: Double)
  case insufficientStrokePoints(Int)
  case emptyGlyphs
  case emptyScene
  case invalidTimeline
  case unsupportedSceneVersion(Int)
  case unsupportedCharacter(String)
  case invalidIndex(field: String, value: Int)
  case duplicateGlyphIndex(Int)
  case duplicateTimelineLayer(Int)
  case duplicateStrokeID(String)
  case resourceLimitExceeded(resource: String, actual: Int, limit: Int)
}

/// Bounded scene construction policy shared by semantic writing callers.
/// Font-outline adapters retain their tighter contour-specific limits.
public struct WritingResourceLimits: Codable, Equatable, Sendable {
  public let maximumGlyphs: Int
  public let maximumStrokes: Int
  public let maximumPoints: Int

  public init(
    maximumGlyphs: Int = 128,
    maximumStrokes: Int = 1_024,
    maximumPoints: Int = 16_384
  ) throws {
    for (field, value) in [
      ("maximumGlyphs", maximumGlyphs),
      ("maximumStrokes", maximumStrokes),
      ("maximumPoints", maximumPoints),
    ] where value <= 0 {
      throw WritingCoreError.invalidIndex(field: field, value: value)
    }
    self.maximumGlyphs = maximumGlyphs
    self.maximumStrokes = maximumStrokes
    self.maximumPoints = maximumPoints
  }

  public static let `default` = WritingResourceLimits(
    uncheckedGlyphs: 128,
    strokes: 1_024,
    points: 16_384
  )

  private init(uncheckedGlyphs: Int, strokes: Int, points: Int) {
    maximumGlyphs = uncheckedGlyphs
    maximumStrokes = strokes
    maximumPoints = points
  }

  private enum CodingKeys: String, CodingKey { case maximumGlyphs, maximumStrokes, maximumPoints }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maximumGlyphs: values.decode(Int.self, forKey: .maximumGlyphs),
      maximumStrokes: values.decode(Int.self, forKey: .maximumStrokes),
      maximumPoints: values.decode(Int.self, forKey: .maximumPoints)
    )
  }
}

public struct WritingPoint: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double

  public init(x: Double, y: Double, width: Double = 1) throws {
    guard x.isFinite else { throw WritingCoreError.invalidNumber(field: "point.x", value: x) }
    guard y.isFinite else { throw WritingCoreError.invalidNumber(field: "point.y", value: y) }
    guard width.isFinite, width > 0 else {
      throw WritingCoreError.invalidNumber(field: "point.width", value: width)
    }
    self.x = x
    self.y = y
    self.width = width
  }

  init(validatedX x: Double, y: Double, width: Double) {
    precondition(x.isFinite && y.isFinite && width.isFinite && width > 0)
    self.x = x
    self.y = y
    self.width = width
  }

  public func interpolated(to other: WritingPoint, fraction: Double) throws -> WritingPoint {
    let t = min(1, max(0, fraction))
    return try WritingPoint(
      x: x + (other.x - x) * t,
      y: y + (other.y - y) * t,
      width: width + (other.width - width) * t
    )
  }

  private enum CodingKeys: String, CodingKey { case x, y, width }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      x: values.decode(Double.self, forKey: .x),
      y: values.decode(Double.self, forKey: .y),
      width: values.decode(Double.self, forKey: .width)
    )
  }
}

public struct WritingStroke: Codable, Equatable, Sendable {
  public let id: String
  public let points: [WritingPoint]

  public init(id: String, points: [WritingPoint]) throws {
    guard !id.isEmpty else { throw WritingCoreError.duplicateStrokeID(id) }
    guard !points.isEmpty else { throw WritingCoreError.insufficientStrokePoints(points.count) }
    self.id = id
    self.points = points
  }

  public var length: Double {
    zip(points, points.dropFirst()).reduce(0) { partial, pair in
      partial + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
    }
  }

  public var averageWidth: Double {
    points.reduce(0) { $0 + $1.width } / Double(points.count)
  }

  public var bounds: WritingRect {
    WritingRect(
      minX: points.map(\.x).min() ?? 0,
      minY: points.map(\.y).min() ?? 0,
      maxX: points.map(\.x).max() ?? 0,
      maxY: points.map(\.y).max() ?? 0
    )
  }

  public func point(at fraction: Double) throws -> WritingPoint {
    guard points.count > 1, length > 0 else { return points[0] }
    let target = min(1, max(0, fraction)) * length
    var consumed = 0.0
    for pair in zip(points, points.dropFirst()) {
      let segment = hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
      if consumed + segment >= target, segment > 0 {
        return try pair.0.interpolated(to: pair.1, fraction: (target - consumed) / segment)
      }
      consumed += segment
    }
    return points[points.count - 1]
  }

  public func prefix(upTo fraction: Double) throws -> [WritingPoint] {
    let clamped = min(1, max(0, fraction))
    if clamped <= 0 { return [] }
    if clamped >= 1 || points.count == 1 { return points }
    let target = clamped * length
    var consumed = 0.0
    var result = [points[0]]
    for pair in zip(points, points.dropFirst()) {
      let segment = hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
      if consumed + segment < target {
        result.append(pair.1)
        consumed += segment
        continue
      }
      if segment > 0 {
        result.append(try pair.0.interpolated(to: pair.1, fraction: (target - consumed) / segment))
      }
      break
    }
    return result
  }

  public func reversed() throws -> WritingStroke {
    try WritingStroke(id: id, points: points.reversed())
  }

  private enum CodingKeys: String, CodingKey { case id, points }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(String.self, forKey: .id),
      points: values.decode([WritingPoint].self, forKey: .points)
    )
  }
}

public struct WritingRect: Codable, Equatable, Sendable {
  public let minX: Double
  public let minY: Double
  public let maxX: Double
  public let maxY: Double

  public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
    self.minX = minX
    self.minY = minY
    self.maxX = maxX
    self.maxY = maxY
  }

  public var width: Double { max(0, maxX - minX) }
  public var height: Double { max(0, maxY - minY) }
}

public struct WritingSize: Codable, Equatable, Sendable {
  public let width: Double
  public let height: Double

  public init(width: Double, height: Double) throws {
    guard width.isFinite, height.isFinite, width > 0, height > 0 else {
      throw WritingCoreError.invalidNumber(field: "scene.size", value: max(width, height))
    }
    self.width = width
    self.height = height
  }

  private enum CodingKeys: String, CodingKey { case width, height }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      width: values.decode(Double.self, forKey: .width),
      height: values.decode(Double.self, forKey: .height)
    )
  }
}

public enum WritingSceneSource: Codable, Equatable, Sendable {
  case semantic(profile: String)
  case captured(modeler: String)
  case custom(description: String)
}

public struct StrokeGlyph: Codable, Equatable, Sendable {
  public let index: Int
  public let cluster: String
  public let advance: Double
  public let strokes: [WritingStroke]

  public init(index: Int, cluster: String, advance: Double, strokes: [WritingStroke]) throws {
    guard index >= 0 else {
      throw WritingCoreError.invalidIndex(field: "glyph.index", value: index)
    }
    guard advance.isFinite, advance >= 0 else {
      throw WritingCoreError.invalidNumber(field: "glyph.advance", value: advance)
    }
    var ids = Set<String>()
    for stroke in strokes {
      guard ids.insert(stroke.id).inserted else {
        throw WritingCoreError.duplicateStrokeID(stroke.id)
      }
    }
    self.index = index
    self.cluster = cluster
    self.advance = advance
    self.strokes = strokes
  }

  private enum CodingKeys: String, CodingKey { case index, cluster, advance, strokes }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      index: values.decode(Int.self, forKey: .index),
      cluster: values.decode(String.self, forKey: .cluster),
      advance: values.decode(Double.self, forKey: .advance),
      strokes: values.decode([WritingStroke].self, forKey: .strokes)
    )
  }
}

public struct StrokeWritingScene: Codable, Equatable, Sendable {
  public static let currentVersion = 2

  public let version: Int
  public let text: String
  public let size: WritingSize
  public let glyphs: [StrokeGlyph]
  public let source: WritingSceneSource
  public let catalogVersion: String

  public init(
    text: String,
    size: WritingSize,
    glyphs: [StrokeGlyph],
    source: WritingSceneSource,
    catalogVersion: String,
    limits: WritingResourceLimits = .default
  ) throws {
    guard !glyphs.isEmpty else { throw WritingCoreError.emptyGlyphs }
    guard glyphs.contains(where: { !$0.strokes.isEmpty }) else { throw WritingCoreError.emptyScene }
    guard glyphs.count <= limits.maximumGlyphs else {
      throw WritingCoreError.resourceLimitExceeded(
        resource: "glyphs", actual: glyphs.count, limit: limits.maximumGlyphs
      )
    }
    var glyphIndexes = Set<Int>()
    var strokeIDs = Set<String>()
    var strokeCount = 0
    var pointCount = 0
    for glyph in glyphs {
      guard glyphIndexes.insert(glyph.index).inserted else {
        throw WritingCoreError.duplicateGlyphIndex(glyph.index)
      }
      for stroke in glyph.strokes {
        strokeCount += 1
        pointCount += stroke.points.count
        guard strokeIDs.insert(stroke.id).inserted else {
          throw WritingCoreError.duplicateStrokeID(stroke.id)
        }
      }
    }
    guard strokeCount <= limits.maximumStrokes else {
      throw WritingCoreError.resourceLimitExceeded(
        resource: "strokes", actual: strokeCount, limit: limits.maximumStrokes
      )
    }
    guard pointCount <= limits.maximumPoints else {
      throw WritingCoreError.resourceLimitExceeded(
        resource: "points", actual: pointCount, limit: limits.maximumPoints
      )
    }
    self.version = Self.currentVersion
    self.text = text
    self.size = size
    self.glyphs = glyphs
    self.source = source
    self.catalogVersion = catalogVersion
  }

  public init(from decoder: Decoder) throws {
    enum CodingKeys: String, CodingKey { case version, text, size, glyphs, source, catalogVersion }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.currentVersion else {
      throw WritingCoreError.unsupportedSceneVersion(version)
    }
    try self.init(
      text: container.decode(String.self, forKey: .text),
      size: container.decode(WritingSize.self, forKey: .size),
      glyphs: container.decode([StrokeGlyph].self, forKey: .glyphs),
      source: container.decode(WritingSceneSource.self, forKey: .source),
      catalogVersion: container.decode(String.self, forKey: .catalogVersion),
      limits: .default
    )
  }

  public var strokes: [WritingStroke] { glyphs.flatMap(\.strokes) }
}

public struct WritingTimingOptions: Codable, Equatable, Sendable {
  public let pointsPerSecond: Double
  public let minimumStrokeDuration: Double
  public let interStrokeDelay: Double
  public let interGlyphDelay: Double

  public init(
    pointsPerSecond: Double = 600,
    minimumStrokeDuration: Double = 0.04,
    interStrokeDelay: Double = 0.008,
    interGlyphDelay: Double = 0.018
  ) throws {
    guard pointsPerSecond.isFinite, pointsPerSecond > 0 else {
      throw WritingCoreError.invalidNumber(field: "timing.pointsPerSecond", value: pointsPerSecond)
    }
    for (field, value) in [
      ("timing.minimumStrokeDuration", minimumStrokeDuration),
      ("timing.interStrokeDelay", interStrokeDelay),
      ("timing.interGlyphDelay", interGlyphDelay),
    ] {
      guard value.isFinite, value >= 0 else {
        throw WritingCoreError.invalidNumber(field: field, value: value)
      }
    }
    self.pointsPerSecond = pointsPerSecond
    self.minimumStrokeDuration = minimumStrokeDuration
    self.interStrokeDelay = interStrokeDelay
    self.interGlyphDelay = interGlyphDelay
  }

  public static let `default` = WritingTimingOptions(
    uncheckedPointsPerSecond: 600,
    minimumStrokeDuration: 0.04,
    interStrokeDelay: 0.008,
    interGlyphDelay: 0.018
  )

  private init(
    uncheckedPointsPerSecond pointsPerSecond: Double,
    minimumStrokeDuration: Double,
    interStrokeDelay: Double,
    interGlyphDelay: Double
  ) {
    self.pointsPerSecond = pointsPerSecond
    self.minimumStrokeDuration = minimumStrokeDuration
    self.interStrokeDelay = interStrokeDelay
    self.interGlyphDelay = interGlyphDelay
  }

  private enum CodingKeys: String, CodingKey {
    case pointsPerSecond, minimumStrokeDuration, interStrokeDelay, interGlyphDelay
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      pointsPerSecond: values.decode(Double.self, forKey: .pointsPerSecond),
      minimumStrokeDuration: values.decode(Double.self, forKey: .minimumStrokeDuration),
      interStrokeDelay: values.decode(Double.self, forKey: .interStrokeDelay),
      interGlyphDelay: values.decode(Double.self, forKey: .interGlyphDelay)
    )
  }
}

public struct WritingStrokeTiming: Codable, Equatable, Sendable {
  public let layerIndex: Int
  public let glyphIndex: Int
  public let strokeIndex: Int
  public let strokeID: String
  public let startTime: Double
  public let endTime: Double

  public init(
    layerIndex: Int,
    glyphIndex: Int,
    strokeIndex: Int,
    strokeID: String,
    startTime: Double,
    endTime: Double
  ) throws {
    guard layerIndex >= 0 else {
      throw WritingCoreError.invalidIndex(field: "timing.layerIndex", value: layerIndex)
    }
    guard glyphIndex >= 0 else {
      throw WritingCoreError.invalidIndex(field: "timing.glyphIndex", value: glyphIndex)
    }
    guard strokeIndex >= 0 else {
      throw WritingCoreError.invalidIndex(field: "timing.strokeIndex", value: strokeIndex)
    }
    guard !strokeID.isEmpty, startTime.isFinite, endTime.isFinite, startTime >= 0,
      endTime > startTime
    else {
      throw WritingCoreError.invalidTimeline
    }
    self.layerIndex = layerIndex
    self.glyphIndex = glyphIndex
    self.strokeIndex = strokeIndex
    self.strokeID = strokeID
    self.startTime = startTime
    self.endTime = endTime
  }

  private enum CodingKeys: String, CodingKey {
    case layerIndex, glyphIndex, strokeIndex, strokeID, startTime, endTime
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      layerIndex: values.decode(Int.self, forKey: .layerIndex),
      glyphIndex: values.decode(Int.self, forKey: .glyphIndex),
      strokeIndex: values.decode(Int.self, forKey: .strokeIndex),
      strokeID: values.decode(String.self, forKey: .strokeID),
      startTime: values.decode(Double.self, forKey: .startTime),
      endTime: values.decode(Double.self, forKey: .endTime)
    )
  }
}

public struct WritingTimeline: Codable, Equatable, Sendable {
  public let duration: Double
  public let strokes: [WritingStrokeTiming]

  public init(duration: Double, strokes: [WritingStrokeTiming]) throws {
    guard duration.isFinite, duration > 0 else { throw WritingCoreError.invalidTimeline }
    guard !strokes.isEmpty else { throw WritingCoreError.invalidTimeline }
    guard strokes.allSatisfy({ $0.endTime <= duration }) else {
      throw WritingCoreError.invalidTimeline
    }
    var layers = Set<Int>()
    var ids = Set<String>()
    var previous: WritingStrokeTiming?
    for stroke in strokes {
      guard layers.insert(stroke.layerIndex).inserted else {
        throw WritingCoreError.duplicateTimelineLayer(stroke.layerIndex)
      }
      guard ids.insert(stroke.strokeID).inserted else {
        throw WritingCoreError.duplicateStrokeID(stroke.strokeID)
      }
      if let previous {
        guard stroke.layerIndex > previous.layerIndex,
          stroke.startTime >= previous.endTime,
          stroke.endTime >= previous.endTime
        else {
          throw WritingCoreError.invalidTimeline
        }
      }
      previous = stroke
    }
    self.duration = duration
    self.strokes = strokes
  }

  private enum CodingKeys: String, CodingKey { case duration, strokes }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      duration: values.decode(Double.self, forKey: .duration),
      strokes: values.decode([WritingStrokeTiming].self, forKey: .strokes)
    )
  }
}

public enum WritingTextAlignment: String, CaseIterable, Codable, Equatable, Sendable {
  case leading
  case center
  case trailing
}
