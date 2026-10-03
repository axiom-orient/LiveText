import Foundation

public struct StrokeTemplate: Equatable, Sendable {
  public let points: [WritingPoint]

  public init(points: [WritingPoint]) throws {
    guard !points.isEmpty else { throw WritingCoreError.insufficientStrokePoints(0) }
    self.points = points
  }
}

public struct GlyphStrokeTemplate: Equatable, Sendable {
  public let advance: Double
  public let strokes: [StrokeTemplate]

  public init(advance: Double, strokes: [StrokeTemplate]) throws {
    guard advance.isFinite, advance >= 0 else {
      throw WritingCoreError.invalidNumber(field: "template.advance", value: advance)
    }
    self.advance = advance
    self.strokes = strokes
  }
}

public protocol StrokeOrderCatalog: Sendable {
  var identifier: String { get }
  var version: String { get }
  func template(for character: Character) throws -> GlyphStrokeTemplate?
}

public struct BuiltinStrokeOrderCatalog: StrokeOrderCatalog, Sendable {
  public let identifier = "chalkline.semantic.stroke-order"
  public let version = "2.0.0"

  public init() {}

  public func template(for character: Character) throws -> GlyphStrokeTemplate? {
    if let template = try HangulStrokeCatalog.template(for: character) { return template }
    return try LatinStrokeCatalog.template(for: character)
  }
}

public struct WritingLayoutOptions: Codable, Equatable, Sendable {
  public let glyphHeight: Double
  public let tracking: Double
  public let lineSpacing: Double
  public let margin: Double
  public let baseStrokeWidth: Double
  public let maximumLineWidth: Double?

  public init(
    glyphHeight: Double = 180,
    tracking: Double = 22,
    lineSpacing: Double = 44,
    margin: Double = 40,
    baseStrokeWidth: Double = 12,
    maximumLineWidth: Double? = nil
  ) throws {
    for (field, value) in [
      ("layout.glyphHeight", glyphHeight),
      ("layout.tracking", tracking),
      ("layout.lineSpacing", lineSpacing),
      ("layout.margin", margin),
      ("layout.baseStrokeWidth", baseStrokeWidth),
    ] {
      guard value.isFinite, value >= 0 else {
        throw WritingCoreError.invalidNumber(field: field, value: value)
      }
    }
    guard glyphHeight > 0, baseStrokeWidth > 0 else {
      throw WritingCoreError.invalidNumber(field: "layout.positive", value: 0)
    }
    if let maximumLineWidth {
      guard maximumLineWidth.isFinite, maximumLineWidth > margin * 2 else {
        throw WritingCoreError.invalidNumber(
          field: "layout.maximumLineWidth", value: maximumLineWidth)
      }
    }
    self.glyphHeight = glyphHeight
    self.tracking = tracking
    self.lineSpacing = lineSpacing
    self.margin = margin
    self.baseStrokeWidth = baseStrokeWidth
    self.maximumLineWidth = maximumLineWidth
  }

  public static let `default` = WritingLayoutOptions(
    uncheckedGlyphHeight: 180,
    tracking: 22,
    lineSpacing: 44,
    margin: 40,
    baseStrokeWidth: 12,
    maximumLineWidth: nil
  )

  private init(
    uncheckedGlyphHeight glyphHeight: Double,
    tracking: Double,
    lineSpacing: Double,
    margin: Double,
    baseStrokeWidth: Double,
    maximumLineWidth: Double?
  ) {
    self.glyphHeight = glyphHeight
    self.tracking = tracking
    self.lineSpacing = lineSpacing
    self.margin = margin
    self.baseStrokeWidth = baseStrokeWidth
    self.maximumLineWidth = maximumLineWidth
  }

  private enum CodingKeys: String, CodingKey {
    case glyphHeight, tracking, lineSpacing, margin, baseStrokeWidth, maximumLineWidth
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      glyphHeight: values.decode(Double.self, forKey: .glyphHeight),
      tracking: values.decode(Double.self, forKey: .tracking),
      lineSpacing: values.decode(Double.self, forKey: .lineSpacing),
      margin: values.decode(Double.self, forKey: .margin),
      baseStrokeWidth: values.decode(Double.self, forKey: .baseStrokeWidth),
      maximumLineWidth: values.decodeIfPresent(Double.self, forKey: .maximumLineWidth)
    )
  }
}

public enum SemanticWritingPlanner {
  public static func makeScene<Catalog: StrokeOrderCatalog>(
    text: String,
    catalog: Catalog = BuiltinStrokeOrderCatalog(),
    options: WritingLayoutOptions = .default,
    limits: WritingResourceLimits = .default
  ) throws -> StrokeWritingScene {
    var glyphs: [StrokeGlyph] = []
    var x = options.margin
    var y = options.margin
    var maximumX = x
    var glyphIndex = 0
    var strokeCount = 0
    var pointCount = 0

    for character in text {
      if character == "\n" {
        x = options.margin
        y += options.glyphHeight + options.lineSpacing
        continue
      }
      guard let template = try catalog.template(for: character) else {
        throw WritingCoreError.unsupportedCharacter(String(character))
      }
      guard glyphIndex < limits.maximumGlyphs else {
        throw WritingCoreError.resourceLimitExceeded(
          resource: "glyphs", actual: glyphIndex + 1, limit: limits.maximumGlyphs
        )
      }
      let advance = template.advance * options.glyphHeight
      if let maximumLineWidth = options.maximumLineWidth,
        x > options.margin,
        x + advance > maximumLineWidth - options.margin
      {
        x = options.margin
        y += options.glyphHeight + options.lineSpacing
      }
      let strokes = try template.strokes.enumerated().map { strokeIndex, templateStroke in
        let points = try templateStroke.points.map { point in
          try WritingPoint(
            x: x + point.x * options.glyphHeight,
            y: y + point.y * options.glyphHeight,
            width: point.width * options.baseStrokeWidth
          )
        }
        return try WritingStroke(id: "g\(glyphIndex)-s\(strokeIndex)", points: points)
      }
      strokeCount += strokes.count
      pointCount += strokes.reduce(0) { $0 + $1.points.count }
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
      glyphs.append(
        try StrokeGlyph(
          index: glyphIndex,
          cluster: String(character),
          advance: advance,
          strokes: strokes
        )
      )
      x += advance + options.tracking
      maximumX = max(maximumX, x)
      glyphIndex += 1
    }

    let width = max(maximumX + options.margin - options.tracking, options.margin * 2 + 1)
    let height = y + options.glyphHeight + options.margin
    return try StrokeWritingScene(
      text: text,
      size: WritingSize(width: width, height: height),
      glyphs: glyphs,
      source: .semantic(profile: catalog.identifier),
      catalogVersion: catalog.version,
      limits: limits
    )
  }
}

struct NormalizedPoint: Equatable, Sendable {
  let x: Double
  let y: Double
  let width: Double

  init(_ x: Double, _ y: Double, _ width: Double = 1) {
    self.x = x
    self.y = y
    self.width = width
  }
}

func makeTemplate(advance: Double, strokes: [[NormalizedPoint]]) throws -> GlyphStrokeTemplate {
  try GlyphStrokeTemplate(
    advance: advance,
    strokes: strokes.map { points in
      try StrokeTemplate(
        points: points.map { try WritingPoint(x: $0.x, y: $0.y, width: $0.width) }
      )
    }
  )
}

func sampledArc(
  centerX: Double,
  centerY: Double,
  radiusX: Double,
  radiusY: Double,
  start: Double,
  end: Double,
  count: Int = 20,
  width: Double = 1
) -> [NormalizedPoint] {
  let steps = max(2, count)
  return (0..<steps).map { index in
    let t = Double(index) / Double(steps - 1)
    let angle = start + (end - start) * t
    return NormalizedPoint(
      centerX + cos(angle) * radiusX,
      centerY + sin(angle) * radiusY,
      width
    )
  }
}

func sampledCubic(
  _ p0: NormalizedPoint,
  _ c1: NormalizedPoint,
  _ c2: NormalizedPoint,
  _ p3: NormalizedPoint,
  count: Int = 18
) -> [NormalizedPoint] {
  let steps = max(2, count)
  return (0..<steps).map { index in
    let t = Double(index) / Double(steps - 1)
    let u = 1 - t
    let x =
      u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x
      + t * t * t * p3.x
    let y =
      u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y
      + t * t * t * p3.y
    let w = p0.width + (p3.width - p0.width) * t
    return NormalizedPoint(x, y, w)
  }
}

func transformed(
  _ strokes: [[NormalizedPoint]],
  x: Double,
  y: Double,
  width: Double,
  height: Double
) -> [[NormalizedPoint]] {
  strokes.map { stroke in
    stroke.map { point in
      NormalizedPoint(x + point.x * width, y + point.y * height, point.width)
    }
  }
}
