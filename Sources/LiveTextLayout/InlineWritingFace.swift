import Foundation

/// Selects the text reveal representation. Handwriting is prepared from one
/// explicit face and never silently falls back to native glyph rendering.
public enum InlineTextRevealMode: Sendable, Hashable, Codable {
  case native
  case handwriting(faceID: String)

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(String.self, forKey: .kind) {
    case "native":
      self = .native
    case "handwriting":
      let faceID = try values.decode(String.self, forKey: .faceID)
      guard !faceID.isEmpty else {
        throw InlineLayoutError.invalidWritingFace(faceID: faceID, reason: "face ID is empty")
      }
      self = .handwriting(faceID: faceID)
    default:
      throw InlineLayoutError.invalidRenderPlan
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .native:
      try values.encode("native", forKey: .kind)
    case .handwriting(let faceID):
      guard !faceID.isEmpty else {
        throw InlineLayoutError.invalidWritingFace(faceID: faceID, reason: "face ID is empty")
      }
      try values.encode("handwriting", forKey: .kind)
      try values.encode(faceID, forKey: .faceID)
    }
  }

  private enum CodingKeys: String, CodingKey { case kind, faceID }
}

/// A normalized point supplied by a handwriting face. x/y are in the glyph
/// cell and width is a positive normalized brush width.
public struct InlineNormalizedWritingPoint: Sendable, Hashable, Codable {
  private enum CodingKeys: String, CodingKey {
    case x, y, width
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      x: values.decode(Double.self, forKey: .x),
      y: values.decode(Double.self, forKey: .y),
      width: values.decode(Double.self, forKey: .width)
    )
  }

  public let x: Double
  public let y: Double
  public let width: Double

  public init(x: Double, y: Double, width: Double = 1) throws {
    guard x.isFinite, (0...1).contains(x) else {
      throw InlineLayoutError.invalidWritingPoint(field: "x", value: x)
    }
    guard y.isFinite, (0...1).contains(y) else {
      throw InlineLayoutError.invalidWritingPoint(field: "y", value: y)
    }
    guard width.isFinite, width > 0 else {
      throw InlineLayoutError.invalidWritingPoint(field: "width", value: width)
    }
    self.x = x
    self.y = y
    self.width = width
  }
}

/// One ordered semantic stroke in a handwriting glyph.
public struct InlineWritingStroke: Sendable, Hashable, Codable {
  private enum CodingKeys: String, CodingKey {
    case points
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      points: values.decode([InlineNormalizedWritingPoint].self, forKey: .points)
    )
  }

  public let points: [InlineNormalizedWritingPoint]

  public init(points: [InlineNormalizedWritingPoint]) throws {
    guard !points.isEmpty else {
      throw InlineLayoutError.invalidWritingStroke("stroke has no points")
    }
    self.points = points
  }
}

/// A validated glyph template returned by a writing face.
public struct InlineWritingGlyph: Sendable, Hashable, Codable {
  private enum CodingKeys: String, CodingKey {
    case character, advance, strokes
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      character: values.decode(String.self, forKey: .character),
      advance: values.decode(Double.self, forKey: .advance),
      strokes: values.decode([InlineWritingStroke].self, forKey: .strokes)
    )
  }

  public let character: String
  public let advance: Double
  public let strokes: [InlineWritingStroke]

  public init(
    character: String,
    advance: Double,
    strokes: [InlineWritingStroke]
  ) throws {
    guard character.count == 1 else {
      throw InlineLayoutError.invalidWritingGlyph(character)
    }
    guard advance.isFinite, advance >= 0 else {
      throw InlineLayoutError.invalidWritingGlyph(character)
    }
    self.character = character
    self.advance = advance
    self.strokes = strokes
  }
}

/// Renderer-neutral writing face. Face lookup is intentionally restricted to
/// preparation; renderers consume only prepared units.
public protocol InlineWritingFace: Sendable {
  var id: String { get }
  var version: String { get }
  func glyph(for character: Character) throws -> InlineWritingGlyph?
}

/// Immutable face registry owned by preparation. Duplicate identities are a
/// construction error, so a document cannot depend on an ambiguous catalog.
public struct InlineWritingFaceStore: Sendable {
  private let values: [String: any InlineWritingFace]

  public static let empty = InlineWritingFaceStore(values: [:])

  private init(values: [String: any InlineWritingFace]) {
    self.values = values
  }

  public init(faces: [any InlineWritingFace] = []) throws {
    var values: [String: any InlineWritingFace] = [:]
    values.reserveCapacity(faces.count)
    for face in faces {
      guard !face.id.isEmpty, !face.version.isEmpty else {
        throw InlineLayoutError.invalidWritingFace(faceID: face.id, reason: "id/version is empty")
      }
      guard values[face.id] == nil else {
        throw InlineLayoutError.duplicateWritingFace(face.id)
      }
      values[face.id] = face
    }
    self.values = values
  }

  public func face(for id: String) -> (any InlineWritingFace)? {
    values[id]
  }
}

/// One immutable prepared unit. A handwriting grapheme may produce several
/// semantic strokes sharing the same source range but each has a distinct ID.
public struct InlinePreparedWritingUnit: Sendable, Hashable, Codable {
  private enum CodingKeys: String, CodingKey {
    case id, sourceRange, kind
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(InlineRevealUnitID.self, forKey: .id),
      sourceRange: values.decode(InlineSourceRange.self, forKey: .sourceRange),
      kind: values.decode(Kind.self, forKey: .kind)
    )
  }

  public enum Kind: Sendable, Hashable, Codable {
    case semanticStroke(InlineWritingStroke)
    case nativeAtomic
    case timingOnly

    private enum CodingKeys: String, CodingKey { case kind, stroke }

    public init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      switch try values.decode(String.self, forKey: .kind) {
      case "semanticStroke":
        self = .semanticStroke(try values.decode(InlineWritingStroke.self, forKey: .stroke))
      case "nativeAtomic":
        self = .nativeAtomic
      case "timingOnly":
        self = .timingOnly
      default:
        throw InlineLayoutError.invalidRenderPlan
      }
    }

    public func encode(to encoder: Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .semanticStroke(let stroke):
        try values.encode("semanticStroke", forKey: .kind)
        try values.encode(stroke, forKey: .stroke)
      case .nativeAtomic:
        try values.encode("nativeAtomic", forKey: .kind)
      case .timingOnly:
        try values.encode("timingOnly", forKey: .kind)
      }
    }
  }

  public let id: InlineRevealUnitID
  public let sourceRange: InlineSourceRange
  public let kind: Kind

  public init(
    id: InlineRevealUnitID,
    sourceRange: InlineSourceRange,
    kind: Kind
  ) throws {
    guard sourceRange.endUTF16 > sourceRange.startUTF16 else {
      throw InlineLayoutError.invalidSourceRange
    }
    self.id = id
    self.sourceRange = sourceRange
    self.kind = kind
  }
}

/// Deliberately narrow classifiers used only while preparing handwriting
/// units. Graphemes outside these cases must be supplied by the face.
func inlineIsWritingWhitespace(_ value: String) -> Bool {
  !value.isEmpty
    && value.unicodeScalars.allSatisfy {
      CharacterSet.whitespacesAndNewlines.contains($0)
    }
}

func inlineIsNativeEmoji(_ value: String) -> Bool {
  let scalars = Array(value.unicodeScalars)
  guard !scalars.isEmpty else { return false }
  // Keycaps have one of the three permitted bases, an optional variation
  // selector, and exactly one combining enclosing keycap.  Treating any
  // string containing U+20E3 as a keycap incorrectly classifies ordinary
  // writing glyphs such as `A\u{20E3}` as native emoji.
  let hasKeycap: Bool = {
    guard scalars.count == 2 || scalars.count == 3,
      scalars.last?.value == 0x20E3,
      [0x23, 0x2A].contains(scalars[0].value)
        || (0x30...0x39).contains(scalars[0].value)
    else { return false }
    if scalars.count == 3 { return scalars[1].value == 0xFE0F }
    return true
  }()
  let hasExtendedEmoji = scalars.contains { scalar in
    (0x1F000...0x1FAFF).contains(scalar.value)
  }
  let hasVariationSelector = scalars.contains { (0xFE00...0xFE0F).contains($0.value) }
  let hasJoiner = scalars.contains { $0.value == 0x200D }
  let hasCommonEmojiBase = scalars.contains { scalar in
    (0x2300...0x23FF).contains(scalar.value)
      || (0x2600...0x27BF).contains(scalar.value)
  }
  return hasKeycap || hasExtendedEmoji || (hasVariationSelector && hasCommonEmojiBase)
    || (hasJoiner && hasExtendedEmoji)
}
