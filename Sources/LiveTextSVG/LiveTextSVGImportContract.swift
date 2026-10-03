import Foundation

func liveTextSVGBoundedMagnitude(_ value: Double) -> Int {
  let magnitude = abs(value)
  guard magnitude < Double(Int.max) else { return Int.max }
  return Int(magnitude)
}

private enum LiveTextSVGPathResourceLimits {
  static let hardMaximumPathCommands = 131_072
  static let hardMaximumNormalizedSegments = 131_072
  static let hardMaximumSegmentsPerStroke = 131_072
  static let hardMaximumStrokes = 8_192
  static let hardMaximumCoordinateMagnitude = 1_000_000.0
}

/// Errors produced by the strict, dependency-free SVG adapter.
public enum LiveTextSVGImportError: Error, Equatable, LocalizedError, Sendable {
  case invalidDocument(String)
  case unsupportedElement(String)
  case unsupportedAttribute(String)
  case unsupportedPaint(String)
  case unsupportedSemantic(String)
  case invalidPathData(String)
  case invalidTransform(String)
  case invalidColor(String)
  case missingRoot
  case missingSize
  case missingTrajectory
  case nonUniformStrokeTransform
  case resourceLimitExceeded(resource: String, actual: Int, limit: Int)

  public var errorDescription: String? {
    switch self {
    case .invalidDocument(let message):
      return "Invalid SVG document: \(message)."
    case .unsupportedElement(let element):
      return "Unsupported SVG element: \(element)."
    case .unsupportedAttribute(let attribute):
      return "Unsupported SVG attribute: \(attribute)."
    case .unsupportedPaint(let paint):
      return "Unsupported SVG paint: \(paint)."
    case .unsupportedSemantic(let semantic):
      return "Unsupported SVG semantic: \(semantic)."
    case .invalidPathData(let message):
      return "Invalid SVG path data: \(message)."
    case .invalidTransform(let message):
      return "Invalid SVG transform: \(message)."
    case .invalidColor(let color):
      return "Invalid SVG color: \(color)."
    case .missingRoot:
      return "SVG input must contain one svg root element."
    case .missingSize:
      return "SVG input must provide width and height, or a viewBox."
    case .missingTrajectory:
      return "A fill-only SVG requires an explicit data-live-text-role=trajectory path."
    case .nonUniformStrokeTransform:
      return "Non-uniform transforms cannot preserve SVG stroke width exactly."
    case .resourceLimitExceeded(let resource, let actual, let limit):
      return "SVG \(resource) limit exceeded: \(actual) > \(limit)."
    }
  }
}

/// Resource limits owned by the SVG adapter. Nested path limits are applied
/// while parsing so an imported document is bounded before it is returned.
public struct LiveTextSVGImportLimits: Codable, Equatable, Sendable {
  public static let defaultMaximumInputBytes = 4 * 1_024 * 1_024
  public static let defaultMaximumElements = 20_000
  public static let defaultMaximumDepth = 64
  public static let defaultMaximumPathCommands = 16_384
  public static let defaultMaximumNormalizedSegments = 16_384
  public static let defaultMaximumSegmentsPerStroke = 2_048
  public static let defaultMaximumStrokes = 1_024
  public static let defaultMaximumCoordinateMagnitude = 1_000_000.0
  public static let defaultMaximumAttributeBytes = 64 * 1_024

  /// Permanent upper bounds for the import adapter. The lower defaults keep
  /// interactive preparation bounded; callers may opt into a larger budget
  /// only within these caps.
  public static let hardMaximumInputBytes = 16 * 1_024 * 1_024
  public static let hardMaximumElements = 100_000
  public static let hardMaximumDepth = 128
  public static let hardMaximumPathCommands = LiveTextSVGPathResourceLimits.hardMaximumPathCommands
  public static let hardMaximumNormalizedSegments =
    LiveTextSVGPathResourceLimits.hardMaximumNormalizedSegments
  public static let hardMaximumSegmentsPerStroke =
    LiveTextSVGPathResourceLimits.hardMaximumSegmentsPerStroke
  public static let hardMaximumStrokes = LiveTextSVGPathResourceLimits.hardMaximumStrokes
  public static let hardMaximumCoordinateMagnitude =
    LiveTextSVGPathResourceLimits.hardMaximumCoordinateMagnitude
  public static let hardMaximumAttributeBytes = 1 * 1_024 * 1_024

  public let maximumInputBytes: Int
  public let maximumElements: Int
  public let maximumDepth: Int
  public let maximumPathCommands: Int
  public let maximumNormalizedSegments: Int
  public let maximumSegmentsPerStroke: Int
  public let maximumStrokes: Int
  public let maximumCoordinateMagnitude: Double
  public let maximumAttributeBytes: Int

  public init(
    maximumInputBytes: Int = Self.defaultMaximumInputBytes,
    maximumElements: Int = Self.defaultMaximumElements,
    maximumDepth: Int = Self.defaultMaximumDepth,
    maximumPathCommands: Int = Self.defaultMaximumPathCommands,
    maximumNormalizedSegments: Int = Self.defaultMaximumNormalizedSegments,
    maximumSegmentsPerStroke: Int = Self.defaultMaximumSegmentsPerStroke,
    maximumStrokes: Int = Self.defaultMaximumStrokes,
    maximumCoordinateMagnitude: Double = Self.defaultMaximumCoordinateMagnitude,
    maximumAttributeBytes: Int = Self.defaultMaximumAttributeBytes
  ) throws {
    let integerValues = [
      ("maximumInputBytes", maximumInputBytes),
      ("maximumElements", maximumElements),
      ("maximumDepth", maximumDepth),
      ("maximumPathCommands", maximumPathCommands),
      ("maximumNormalizedSegments", maximumNormalizedSegments),
      ("maximumSegmentsPerStroke", maximumSegmentsPerStroke),
      ("maximumStrokes", maximumStrokes),
      ("maximumAttributeBytes", maximumAttributeBytes),
    ]
    for (field, value) in integerValues where value <= 0 {
      throw LiveTextSVGImportError.invalidDocument("\(field) must be positive")
    }
    let hardMaximums = [
      ("maximumInputBytes", maximumInputBytes, Self.hardMaximumInputBytes),
      ("maximumElements", maximumElements, Self.hardMaximumElements),
      ("maximumDepth", maximumDepth, Self.hardMaximumDepth),
      ("maximumPathCommands", maximumPathCommands, Self.hardMaximumPathCommands),
      (
        "maximumNormalizedSegments", maximumNormalizedSegments,
        Self.hardMaximumNormalizedSegments
      ),
      (
        "maximumSegmentsPerStroke", maximumSegmentsPerStroke,
        Self.hardMaximumSegmentsPerStroke
      ),
      ("maximumStrokes", maximumStrokes, Self.hardMaximumStrokes),
      ("maximumAttributeBytes", maximumAttributeBytes, Self.hardMaximumAttributeBytes),
    ]
    for (field, value, limit) in hardMaximums where value > limit {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: field, actual: value, limit: limit
      )
    }
    guard maximumCoordinateMagnitude.isFinite, maximumCoordinateMagnitude > 0 else {
      throw LiveTextSVGImportError.invalidDocument("maximumCoordinateMagnitude must be positive")
    }
    guard maximumCoordinateMagnitude <= Self.hardMaximumCoordinateMagnitude else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "maximumCoordinateMagnitude",
        actual: liveTextSVGBoundedMagnitude(maximumCoordinateMagnitude),
        limit: liveTextSVGBoundedMagnitude(Self.hardMaximumCoordinateMagnitude)
      )
    }
    self.maximumInputBytes = maximumInputBytes
    self.maximumElements = maximumElements
    self.maximumDepth = maximumDepth
    self.maximumPathCommands = maximumPathCommands
    self.maximumNormalizedSegments = maximumNormalizedSegments
    self.maximumSegmentsPerStroke = maximumSegmentsPerStroke
    self.maximumStrokes = maximumStrokes
    self.maximumCoordinateMagnitude = maximumCoordinateMagnitude
    self.maximumAttributeBytes = maximumAttributeBytes
  }

  private enum CodingKeys: String, CodingKey {
    case maximumInputBytes
    case maximumElements
    case maximumDepth
    case maximumPathCommands
    case maximumNormalizedSegments
    case maximumSegmentsPerStroke
    case maximumStrokes
    case maximumCoordinateMagnitude
    case maximumAttributeBytes
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maximumInputBytes: values.decode(Int.self, forKey: .maximumInputBytes),
      maximumElements: values.decode(Int.self, forKey: .maximumElements),
      maximumDepth: values.decode(Int.self, forKey: .maximumDepth),
      maximumPathCommands: values.decode(Int.self, forKey: .maximumPathCommands),
      maximumNormalizedSegments: values.decode(Int.self, forKey: .maximumNormalizedSegments),
      maximumSegmentsPerStroke: values.decode(Int.self, forKey: .maximumSegmentsPerStroke),
      maximumStrokes: values.decode(Int.self, forKey: .maximumStrokes),
      maximumCoordinateMagnitude: values.decode(Double.self, forKey: .maximumCoordinateMagnitude),
      maximumAttributeBytes: values.decode(Int.self, forKey: .maximumAttributeBytes)
    )
  }

  public static let `default` = try! LiveTextSVGImportLimits()

}

/// Bounded options for the public SVG importer. SVG meaning is derived from
/// the source document; callers may only select resource limits.
public struct LiveTextSVGImportOptions: Codable, Equatable, Sendable {
  public let limits: LiveTextSVGImportLimits

  public init(
    limits: LiveTextSVGImportLimits = .default
  ) {
    self.limits = limits
  }

  private enum CodingKeys: String, CodingKey {
    case limits
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(limits: try values.decode(LiveTextSVGImportLimits.self, forKey: .limits))
  }

  public static let `default` = LiveTextSVGImportOptions()
}

/// Fill winding semantics retained by an imported SVG document.
