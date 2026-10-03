import Foundation

/// Errors produced while constructing a vector writing scene.
public enum ChalkPathError: Error, Equatable, LocalizedError, Sendable {
  case emptyScene
  case emptyPath
  case invalidPath(String)
  case invalidIdentifier
  case duplicateStrokeID(String)
  case invalidNumber(field: String, value: Double)
  case resourceLimitExceeded(resource: String, actual: Int, limit: Int)

  public var errorDescription: String? {
    switch self {
    case .emptyScene:
      return "A chalk path scene must contain at least one drawable stroke."
    case .emptyPath:
      return "A chalk path stroke must contain a move and at least one drawable command."
    case .invalidPath(let message):
      return "Invalid chalk path: \(message)."
    case .invalidIdentifier:
      return "A chalk path stroke identifier must not be empty."
    case .duplicateStrokeID(let id):
      return "Duplicate chalk path stroke identifier: \(id)."
    case .invalidNumber(let field, let value):
      return "Invalid chalk path number '\(field)': \(value)."
    case .resourceLimitExceeded(let resource, let actual, let limit):
      return "Chalk path \(resource) limit exceeded: \(actual) > \(limit)."
    }
  }
}

/// Resource limits owned by the exact vector core. SVG-specific XML limits are
/// declared by the optional `LiveTextSVG` adapter target.
public struct ChalkPathResourceLimits: Codable, Equatable, Sendable {
  public static let defaultMaximumPathCommands = 16_384
  public static let defaultMaximumNormalizedSegments = 16_384
  public static let defaultMaximumSegmentsPerStroke = 2_048
  public static let defaultMaximumStrokes = 1_024
  public static let defaultMaximumCoordinateMagnitude = 1_000_000.0

  /// Permanent upper bounds used by scene construction and scene decoding.
  /// The lower defaults are the normal interactive budget; callers may opt in
  /// to a larger budget only within these bounds.
  public static let hardMaximumPathCommands = 131_072
  public static let hardMaximumNormalizedSegments = 131_072
  public static let hardMaximumSegmentsPerStroke = 131_072
  public static let hardMaximumStrokes = 8_192
  public static let hardMaximumCoordinateMagnitude = 1_000_000.0

  public let maximumPathCommands: Int
  public let maximumNormalizedSegments: Int
  public let maximumSegmentsPerStroke: Int
  public let maximumStrokes: Int
  public let maximumCoordinateMagnitude: Double

  public init(
    maximumPathCommands: Int = Self.defaultMaximumPathCommands,
    maximumNormalizedSegments: Int = Self.defaultMaximumNormalizedSegments,
    maximumSegmentsPerStroke: Int = Self.defaultMaximumSegmentsPerStroke,
    maximumStrokes: Int = Self.defaultMaximumStrokes,
    maximumCoordinateMagnitude: Double = Self.defaultMaximumCoordinateMagnitude
  ) throws {
    let integerValues = [
      ("maximumPathCommands", maximumPathCommands),
      ("maximumNormalizedSegments", maximumNormalizedSegments),
      ("maximumSegmentsPerStroke", maximumSegmentsPerStroke),
      ("maximumStrokes", maximumStrokes),
    ]
    for (field, value) in integerValues where value <= 0 {
      throw ChalkPathError.invalidNumber(field: field, value: Double(value))
    }
    let hardMaximums = [
      ("maximumPathCommands", maximumPathCommands, Self.hardMaximumPathCommands),
      ("maximumNormalizedSegments", maximumNormalizedSegments, Self.hardMaximumNormalizedSegments),
      (
        "maximumSegmentsPerStroke", maximumSegmentsPerStroke,
        Self.hardMaximumSegmentsPerStroke
      ),
      ("maximumStrokes", maximumStrokes, Self.hardMaximumStrokes),
    ]
    for (field, value, limit) in hardMaximums where value > limit {
      throw ChalkPathError.resourceLimitExceeded(
        resource: field, actual: value, limit: limit
      )
    }
    guard maximumCoordinateMagnitude.isFinite, maximumCoordinateMagnitude > 0 else {
      throw ChalkPathError.invalidNumber(
        field: "maximumCoordinateMagnitude", value: maximumCoordinateMagnitude
      )
    }
    guard maximumCoordinateMagnitude <= Self.hardMaximumCoordinateMagnitude else {
      throw ChalkPathError.resourceLimitExceeded(
        resource: "maximumCoordinateMagnitude",
        actual: Self.boundedMagnitude(maximumCoordinateMagnitude),
        limit: Self.boundedMagnitude(Self.hardMaximumCoordinateMagnitude)
      )
    }
    self.maximumPathCommands = maximumPathCommands
    self.maximumNormalizedSegments = maximumNormalizedSegments
    self.maximumSegmentsPerStroke = maximumSegmentsPerStroke
    self.maximumStrokes = maximumStrokes
    self.maximumCoordinateMagnitude = maximumCoordinateMagnitude
  }

  private enum CodingKeys: String, CodingKey {
    case maximumPathCommands
    case maximumNormalizedSegments
    case maximumSegmentsPerStroke
    case maximumStrokes
    case maximumCoordinateMagnitude
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maximumPathCommands: values.decode(Int.self, forKey: .maximumPathCommands),
      maximumNormalizedSegments: values.decode(Int.self, forKey: .maximumNormalizedSegments),
      maximumSegmentsPerStroke: values.decode(Int.self, forKey: .maximumSegmentsPerStroke),
      maximumStrokes: values.decode(Int.self, forKey: .maximumStrokes),
      maximumCoordinateMagnitude: values.decode(Double.self, forKey: .maximumCoordinateMagnitude)
    )
  }

  public static let `default` = try! ChalkPathResourceLimits(
    maximumPathCommands: defaultMaximumPathCommands,
    maximumNormalizedSegments: defaultMaximumNormalizedSegments,
    maximumSegmentsPerStroke: defaultMaximumSegmentsPerStroke,
    maximumStrokes: defaultMaximumStrokes,
    maximumCoordinateMagnitude: defaultMaximumCoordinateMagnitude
  )

  /// The safe limit used when decoding a persisted `ChalkPathScene`. Runtime
  /// operating limits are intentionally not serialized into the scene.
  public static let hardMaximum = try! ChalkPathResourceLimits(
    maximumPathCommands: hardMaximumPathCommands,
    maximumNormalizedSegments: hardMaximumNormalizedSegments,
    maximumSegmentsPerStroke: hardMaximumSegmentsPerStroke,
    maximumStrokes: hardMaximumStrokes,
    maximumCoordinateMagnitude: hardMaximumCoordinateMagnitude
  )

  private static func boundedMagnitude(_ value: Double) -> Int {
    let magnitude = abs(value)
    guard magnitude < Double(Int.max) else { return Int.max }
    return Int(magnitude)
  }
}

/// A coordinate in the exact vector path model. Curves retain their control
/// points; they are not reduced to sampled writing points.
public struct ChalkPathPoint: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) throws {
    guard x.isFinite else { throw ChalkPathError.invalidNumber(field: "point.x", value: x) }
    guard y.isFinite else { throw ChalkPathError.invalidNumber(field: "point.y", value: y) }
    self.x = x
    self.y = y
  }

  private enum CodingKeys: String, CodingKey { case x, y }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      x: values.decode(Double.self, forKey: .x),
      y: values.decode(Double.self, forKey: .y)
    )
  }
}

/// Exact vector commands accepted by the public path renderer.
public enum ChalkPathCommand: Codable, Equatable, Sendable {
  case move(to: ChalkPathPoint)
  case line(to: ChalkPathPoint)
  case quadratic(control: ChalkPathPoint, to: ChalkPathPoint)
  case cubic(control1: ChalkPathPoint, control2: ChalkPathPoint, to: ChalkPathPoint)
  case close

  private enum CodingKeys: String, CodingKey {
    case type
    case point
    case control
    case control1
    case control2
  }

  private enum CommandType: String, Codable {
    case move
    case line
    case quadratic
    case cubic
    case close
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(CommandType.self, forKey: .type) {
    case .move:
      self = .move(to: try container.decode(ChalkPathPoint.self, forKey: .point))
    case .line:
      self = .line(to: try container.decode(ChalkPathPoint.self, forKey: .point))
    case .quadratic:
      self = .quadratic(
        control: try container.decode(ChalkPathPoint.self, forKey: .control),
        to: try container.decode(ChalkPathPoint.self, forKey: .point)
      )
    case .cubic:
      self = .cubic(
        control1: try container.decode(ChalkPathPoint.self, forKey: .control1),
        control2: try container.decode(ChalkPathPoint.self, forKey: .control2),
        to: try container.decode(ChalkPathPoint.self, forKey: .point)
      )
    case .close:
      self = .close
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .move(let point):
      try container.encode(CommandType.move, forKey: .type)
      try container.encode(point, forKey: .point)
    case .line(let point):
      try container.encode(CommandType.line, forKey: .type)
      try container.encode(point, forKey: .point)
    case .quadratic(let control, let point):
      try container.encode(CommandType.quadratic, forKey: .type)
      try container.encode(control, forKey: .control)
      try container.encode(point, forKey: .point)
    case .cubic(let control1, let control2, let point):
      try container.encode(CommandType.cubic, forKey: .type)
      try container.encode(control1, forKey: .control1)
      try container.encode(control2, forKey: .control2)
      try container.encode(point, forKey: .point)
    case .close:
      try container.encode(CommandType.close, forKey: .type)
    }
  }
}

public enum ChalkPathLineCap: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case butt
  case round
  case square
}

public enum ChalkPathLineJoin: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case miter
  case round
  case bevel
}

/// Paint information retained for one source SVG path or a custom vector
/// stroke. A nil color means the view's `ChalkWritingStyle.color` is used.
public struct ChalkPathStrokeStyle: Codable, Equatable, Hashable, Sendable {
  public let color: ChalkColor?
  public let width: Double
  public let lineCap: ChalkPathLineCap
  public let lineJoin: ChalkPathLineJoin
  public let miterLimit: Double

  public init(
    color: ChalkColor? = nil,
    width: Double = 1,
    lineCap: ChalkPathLineCap = .round,
    lineJoin: ChalkPathLineJoin = .round,
    miterLimit: Double = 4
  ) throws {
    guard width.isFinite, width > 0 else {
      throw ChalkPathError.invalidNumber(field: "stroke.width", value: width)
    }
    guard miterLimit.isFinite, miterLimit >= 1 else {
      throw ChalkPathError.invalidNumber(field: "stroke.miterLimit", value: miterLimit)
    }
    self.color = color
    self.width = width
    self.lineCap = lineCap
    self.lineJoin = lineJoin
    self.miterLimit = miterLimit
  }

  private enum CodingKeys: String, CodingKey {
    case color
    case width
    case lineCap
    case lineJoin
    case miterLimit
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      color: values.decodeIfPresent(ChalkColor.self, forKey: .color),
      width: values.decode(Double.self, forKey: .width),
      lineCap: values.decode(ChalkPathLineCap.self, forKey: .lineCap),
      lineJoin: values.decode(ChalkPathLineJoin.self, forKey: .lineJoin),
      miterLimit: values.decode(Double.self, forKey: .miterLimit)
    )
  }

  public static let `default` = ChalkPathStrokeStyle(
    uncheckedColor: nil,
    width: 1,
    lineCap: .round,
    lineJoin: .round,
    miterLimit: 4
  )

  private init(
    uncheckedColor color: ChalkColor?,
    width: Double,
    lineCap: ChalkPathLineCap,
    lineJoin: ChalkPathLineJoin,
    miterLimit: Double
  ) {
    self.color = color
    self.width = width
    self.lineCap = lineCap
    self.lineJoin = lineJoin
    self.miterLimit = miterLimit
  }
}

/// One pen-up-separated path. The first command must be `move`; subsequent
/// subpaths are represented as separate strokes by the SVG importer.
public struct ChalkPathStroke: Codable, Equatable, Sendable {
  public let id: String
  public let commands: [ChalkPathCommand]
  public let style: ChalkPathStrokeStyle

  public init(
    id: String,
    commands: [ChalkPathCommand],
    style: ChalkPathStrokeStyle = .default
  ) throws {
    guard !id.isEmpty else { throw ChalkPathError.invalidIdentifier }
    guard !commands.isEmpty else { throw ChalkPathError.emptyPath }
    guard case .move = commands[0] else {
      throw ChalkPathError.invalidPath("the first command must be move")
    }

    var hasDrawableCommand = false
    var hasClosed = false
    for (index, command) in commands.enumerated() {
      if index > 0, case .move = command {
        throw ChalkPathError.invalidPath("a stroke cannot contain multiple move commands")
      }
      switch command {
      case .move, .line, .quadratic, .cubic:
        if index > 0 { hasDrawableCommand = true }
      case .close:
        guard !hasClosed else {
          throw ChalkPathError.invalidPath("a stroke cannot close more than once")
        }
        hasClosed = true
        hasDrawableCommand = true
      }
      if hasClosed, index + 1 < commands.count {
        throw ChalkPathError.invalidPath("commands after close are unsupported")
      }
    }
    guard hasDrawableCommand else { throw ChalkPathError.emptyPath }
    self.id = id
    self.commands = commands
    self.style = style
  }

  private enum CodingKeys: String, CodingKey { case id, commands, style }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let commandContainer = try values.nestedUnkeyedContainer(forKey: .commands)
    guard let commandCount = commandContainer.count else {
      throw ChalkPathError.invalidPath("stroke command count is not bounded")
    }
    guard commandCount <= ChalkPathResourceLimits.hardMaximumPathCommands else {
      throw ChalkPathError.resourceLimitExceeded(
        resource: "path commands",
        actual: commandCount,
        limit: ChalkPathResourceLimits.hardMaximumPathCommands
      )
    }
    try self.init(
      id: values.decode(String.self, forKey: .id),
      commands: values.decode([ChalkPathCommand].self, forKey: .commands),
      style: values.decode(ChalkPathStrokeStyle.self, forKey: .style)
    )
  }
}

public enum ChalkPathSceneSource: Codable, Equatable, Sendable {
  case svg
  case custom(description: String)
}

/// Exact, render-ready vector scene. Geometry remains in command form until
/// the preparation phase builds a bounded arc-length index for animation.
public struct ChalkPathScene: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let size: WritingSize
  public let strokes: [ChalkPathStroke]
  public let source: ChalkPathSceneSource

  public init(
    size: WritingSize,
    strokes: [ChalkPathStroke],
    source: ChalkPathSceneSource = .custom(description: "vector path"),
    limits: ChalkPathResourceLimits = .default
  ) throws {
    guard !strokes.isEmpty else { throw ChalkPathError.emptyScene }
    guard strokes.count <= limits.maximumStrokes else {
      throw ChalkPathError.resourceLimitExceeded(
        resource: "strokes", actual: strokes.count, limit: limits.maximumStrokes
      )
    }

    var identifiers = Set<String>()
    var commandCount = 0
    var segmentCount = 0
    for stroke in strokes {
      guard identifiers.insert(stroke.id).inserted else {
        throw ChalkPathError.duplicateStrokeID(stroke.id)
      }
      commandCount += stroke.commands.count
      var strokeSegmentCount = 0
      for command in stroke.commands {
        switch command {
        case .move(let point), .line(let point):
          try Self.validate(point, limits: limits)
        case .quadratic(let control, let point):
          try Self.validate(control, limits: limits)
          try Self.validate(point, limits: limits)
          segmentCount += 1
          strokeSegmentCount += 1
        case .cubic(let control1, let control2, let point):
          try Self.validate(control1, limits: limits)
          try Self.validate(control2, limits: limits)
          try Self.validate(point, limits: limits)
          segmentCount += 1
          strokeSegmentCount += 1
        case .close:
          segmentCount += 1
          strokeSegmentCount += 1
        }
        if case .line = command {
          segmentCount += 1
          strokeSegmentCount += 1
        }
      }
      guard strokeSegmentCount <= limits.maximumSegmentsPerStroke else {
        throw ChalkPathError.resourceLimitExceeded(
          resource: "segments per stroke", actual: strokeSegmentCount,
          limit: limits.maximumSegmentsPerStroke
        )
      }
    }
    guard commandCount <= limits.maximumPathCommands else {
      throw ChalkPathError.resourceLimitExceeded(
        resource: "path commands", actual: commandCount, limit: limits.maximumPathCommands
      )
    }
    guard segmentCount <= limits.maximumNormalizedSegments else {
      throw ChalkPathError.resourceLimitExceeded(
        resource: "normalized segments", actual: segmentCount,
        limit: limits.maximumNormalizedSegments
      )
    }
    self.version = Self.currentVersion
    self.size = size
    self.strokes = strokes
    self.source = source
  }

  public init(from decoder: Decoder) throws {
    enum CodingKeys: String, CodingKey { case version, size, strokes, source }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.currentVersion else {
      throw ChalkPathError.invalidPath("unsupported scene version \(version)")
    }
    let strokeContainer = try container.nestedUnkeyedContainer(forKey: .strokes)
    guard let strokeCount = strokeContainer.count else {
      throw ChalkPathError.invalidPath("scene stroke count is not bounded")
    }
    guard strokeCount <= ChalkPathResourceLimits.hardMaximumStrokes else {
      throw ChalkPathError.resourceLimitExceeded(
        resource: "strokes",
        actual: strokeCount,
        limit: ChalkPathResourceLimits.hardMaximumStrokes
      )
    }
    try self.init(
      size: try container.decode(WritingSize.self, forKey: .size),
      strokes: try container.decode([ChalkPathStroke].self, forKey: .strokes),
      source: try container.decode(ChalkPathSceneSource.self, forKey: .source),
      limits: .hardMaximum
    )
  }

  private static func validate(
    _ point: ChalkPathPoint,
    limits: ChalkPathResourceLimits
  ) throws {
    guard abs(point.x) <= limits.maximumCoordinateMagnitude else {
      throw ChalkPathError.resourceLimitExceeded(
        resource: "coordinate magnitude",
        actual: boundedMagnitude(point.x),
        limit: boundedMagnitude(limits.maximumCoordinateMagnitude)
      )
    }
    guard abs(point.y) <= limits.maximumCoordinateMagnitude else {
      throw ChalkPathError.resourceLimitExceeded(
        resource: "coordinate magnitude",
        actual: boundedMagnitude(point.y),
        limit: boundedMagnitude(limits.maximumCoordinateMagnitude)
      )
    }
  }

  private static func boundedMagnitude(_ value: Double) -> Int {
    let magnitude = abs(value)
    guard magnitude < Double(Int.max) else { return Int.max }
    return Int(magnitude)
  }
}

/// Chooses whether an imported solid SVG paint or the view style controls ink.
public enum ChalkPathColorPolicy: String, Codable, CaseIterable, Hashable, Sendable {
  /// Always use `ChalkWritingStyle.color` for consistent recoloring.
  case style
  /// Use each stroke's source color when present, otherwise the view style.
  case source
}
