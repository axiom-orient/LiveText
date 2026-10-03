import Foundation

/// The semantic unit used for text interaction. A render plan has exactly one
/// active mode; geometry and state never need to guess whether a hit is a word
/// or a sentence.
public enum InlineTextUnitKind: String, Sendable, Hashable, Codable {
  case word
  case sentence
  case custom
}

/// An atom-local semantic range supplied by the document author. Ranges are
/// converted to document-global coordinates only by the hit-test index.
public struct InlineCustomTextUnit: Sendable, Hashable, Codable {
  private enum CodingKeys: String, CodingKey {
    case id, sourceRange
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(String.self, forKey: .id),
      sourceRange: values.decode(InlineSourceRange.self, forKey: .sourceRange)
    )
  }

  public let id: String
  public let sourceRange: InlineSourceRange

  public init(id: String, sourceRange: InlineSourceRange) throws {
    guard !id.isEmpty, sourceRange.lengthUTF16 > 0 else {
      throw InlineLayoutError.invalidIdentifier
    }
    self.id = id
    self.sourceRange = sourceRange
  }
}

/// A text run with one shaping style and one atom-level break policy.
public struct InlineTextAtom: Sendable, Hashable, Codable {
  public let id: String
  public let text: String
  public let style: InlineTextStyle
  public let breakBehavior: InlineBreakBehavior
  /// Custom semantic units are local to this atom and must not overlap.
  public let customTextUnits: [InlineCustomTextUnit]

  public init(
    id: String,
    text: String,
    style: InlineTextStyle,
    breakBehavior: InlineBreakBehavior = .normal,
    customTextUnits: [InlineCustomTextUnit] = []
  ) throws {
    guard !id.isEmpty else { throw InlineLayoutError.invalidIdentifier }
    let atomRange = try InlineSourceRange(startUTF16: 0, endUTF16: text.utf16.count)
    // Author-supplied units share one immutable source. Index its boundaries
    // once rather than walking String.indices separately for every unit.
    var boundaries = Set<Int>()
    if !customTextUnits.isEmpty {
      var offset = 0
      boundaries.insert(offset)
      for character in text {
        offset += String(character).utf16.count
        boundaries.insert(offset)
      }
    }
    var identifiers = Set<String>()
    var previousEnd = -1
    for unit in customTextUnits {
      guard identifiers.insert(unit.id).inserted,
        unit.sourceRange.endUTF16 <= atomRange.endUTF16,
        unit.sourceRange.startUTF16 >= previousEnd
      else { throw InlineLayoutError.invalidSourceRange }
      guard boundaries.contains(unit.sourceRange.startUTF16),
        boundaries.contains(unit.sourceRange.endUTF16)
      else {
        throw InlineLayoutError.sourceRangeNotAtGraphemeBoundary(unit.sourceRange)
      }
      previousEnd = unit.sourceRange.endUTF16
    }
    self.id = id
    self.text = text
    self.style = style
    self.breakBehavior = breakBehavior
    self.customTextUnits = customTextUnits
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(String.self, forKey: .id),
      text: values.decode(String.self, forKey: .text),
      style: values.decode(InlineTextStyle.self, forKey: .style),
      breakBehavior: values.decode(InlineBreakBehavior.self, forKey: .breakBehavior),
      customTextUnits: values.decode([InlineCustomTextUnit].self, forKey: .customTextUnits)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id, text, style, breakBehavior, customTextUnits
  }
}

/// A first-class vector atom addressed by stable asset identity.
public struct InlineVectorAtom: Sendable, Hashable, Codable {
  public let id: String
  public let assetID: InlineAssetID
  public let assetVersion: Int
  public let metrics: InlineMetrics
  public let breakBehavior: InlineBreakBehavior
  public let accessibilityLabel: String?

  public init(
    id: String,
    assetID: InlineAssetID,
    assetVersion: Int = 1,
    metrics: InlineMetrics,
    breakBehavior: InlineBreakBehavior = .normal,
    accessibilityLabel: String? = nil
  ) throws {
    guard !id.isEmpty else { throw InlineLayoutError.invalidIdentifier }
    guard assetVersion >= 0 else {
      throw InlineLayoutError.invalidMetric(name: "assetVersion", value: Double(assetVersion))
    }
    self.id = id
    self.assetID = assetID
    self.assetVersion = assetVersion
    self.metrics = metrics
    self.breakBehavior = breakBehavior
    self.accessibilityLabel = accessibilityLabel
  }

  /// Creates an atom from a validated renderer-neutral asset record.
  public init(
    id: String,
    asset: InlineSVGAsset,
    breakBehavior: InlineBreakBehavior = .normal
  ) throws {
    try self.init(
      id: id,
      assetID: asset.id,
      assetVersion: asset.version,
      metrics: asset.metrics,
      breakBehavior: breakBehavior,
      accessibilityLabel: asset.accessibilityLabel
    )
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(String.self, forKey: .id),
      assetID: values.decode(InlineAssetID.self, forKey: .assetID),
      assetVersion: values.decode(Int.self, forKey: .assetVersion),
      metrics: values.decode(InlineMetrics.self, forKey: .metrics),
      breakBehavior: values.decode(InlineBreakBehavior.self, forKey: .breakBehavior),
      accessibilityLabel: values.decodeIfPresent(String.self, forKey: .accessibilityLabel)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id, assetID, assetVersion, metrics, breakBehavior, accessibilityLabel
  }
}

/// The renderer-neutral inline atom sum type.
public enum InlineAtom: Sendable, Hashable, Codable {
  case text(InlineTextAtom)
  case vector(InlineVectorAtom)
  case image(InlineImageAtom)

  private enum CodingKeys: String, CodingKey { case kind, text, vector, image }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(String.self, forKey: .kind) {
    case "text": self = .text(try values.decode(InlineTextAtom.self, forKey: .text))
    case "vector": self = .vector(try values.decode(InlineVectorAtom.self, forKey: .vector))
    case "image": self = .image(try values.decode(InlineImageAtom.self, forKey: .image))
    default: throw InlineLayoutError.invalidIdentifier
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let atom):
      try values.encode("text", forKey: .kind)
      try values.encode(atom, forKey: .text)
    case .vector(let atom):
      try values.encode("vector", forKey: .kind)
      try values.encode(atom, forKey: .vector)
    case .image(let atom):
      try values.encode("image", forKey: .kind)
      try values.encode(atom, forKey: .image)
    }
  }

  public var id: String {
    switch self {
    case .text(let atom): return atom.id
    case .vector(let atom): return atom.id
    case .image(let atom): return atom.id
    }
  }

  public var breakBehavior: InlineBreakBehavior {
    switch self {
    case .text(let atom): return atom.breakBehavior
    case .vector(let atom): return atom.breakBehavior
    case .image(let atom): return atom.breakBehavior
    }
  }
}

/// An ordered, validated inline document.
public struct InlineDocument: Sendable, Hashable, Codable {
  /// Canonical durable schema. Unsupported payloads are rejected before this
  /// model is constructed.
  public static let schemaVersion = 3

  public let atoms: [InlineAtom]

  public init(atoms: [InlineAtom]) throws {
    var atomIDs = Set<String>()
    for atom in atoms {
      guard atomIDs.insert(atom.id).inserted else {
        throw InlineLayoutError.duplicateIdentifier(atom.id)
      }
    }
    self.atoms = atoms
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let version = try values.decode(Int.self, forKey: .schemaVersion)
    guard version == Self.schemaVersion else {
      throw InlineLayoutError.unsupportedSchemaVersion(
        expected: Self.schemaVersion, actual: version
      )
    }
    try self.init(atoms: values.decode([InlineAtom].self, forKey: .atoms))
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(Self.schemaVersion, forKey: .schemaVersion)
    try values.encode(atoms, forKey: .atoms)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, atoms
  }
}
