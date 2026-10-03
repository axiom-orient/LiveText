import Foundation

public enum PositionedInlineAtomKind: String, Sendable, Hashable, Codable {
  case text
  case vector
  case image
}

/// One atom fragment placed by the shared layout engine.
public struct PositionedInlineAtom: Sendable, Hashable, Codable {
  private enum CodingKeys: String, CodingKey {
    case atomID, kind, lineIndex, originX, baselineY, width, height, metrics, scale, sourceRange
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      atomID: values.decode(String.self, forKey: .atomID),
      kind: values.decode(PositionedInlineAtomKind.self, forKey: .kind),
      lineIndex: values.decode(Int.self, forKey: .lineIndex),
      originX: values.decode(Double.self, forKey: .originX),
      baselineY: values.decode(Double.self, forKey: .baselineY),
      width: values.decode(Double.self, forKey: .width),
      height: values.decode(Double.self, forKey: .height),
      metrics: values.decode(InlineMetrics.self, forKey: .metrics),
      scale: values.decode(Double.self, forKey: .scale),
      sourceRange: values.decodeIfPresent(InlineSourceRange.self, forKey: .sourceRange)
    )
  }

  public let atomID: String
  public let kind: PositionedInlineAtomKind
  public let lineIndex: Int
  public let originX: Double
  public let baselineY: Double
  public let width: Double
  public let height: Double
  public let metrics: InlineMetrics
  public let scale: Double
  public let sourceRange: InlineSourceRange?

  public init(
    atomID: String,
    kind: PositionedInlineAtomKind,
    lineIndex: Int,
    originX: Double,
    baselineY: Double,
    width: Double,
    height: Double,
    metrics: InlineMetrics,
    scale: Double = 1,
    sourceRange: InlineSourceRange? = nil
  ) throws {
    guard !atomID.isEmpty else { throw InlineLayoutError.invalidIdentifier }
    guard lineIndex >= 0,
      originX.isFinite, baselineY.isFinite,
      width.isFinite, width >= 0,
      height.isFinite, height >= 0,
      scale.isFinite, scale > 0
    else {
      throw InlineLayoutError.unsupportedShaping("invalid positioned atom geometry")
    }
    self.atomID = atomID
    self.kind = kind
    self.lineIndex = lineIndex
    self.originX = originX
    self.baselineY = baselineY
    self.width = width
    self.height = height
    self.metrics = metrics
    self.scale = scale
    self.sourceRange = sourceRange
  }
}

/// One line of immutable mixed-flow geometry.
public struct InlineLayoutLine: Sendable, Hashable, Codable {
  private enum CodingKeys: String, CodingKey {
    case index, baselineY, ascent, descent, leading, width, start, end, atoms
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      index: values.decode(Int.self, forKey: .index),
      baselineY: values.decode(Double.self, forKey: .baselineY),
      ascent: values.decode(Double.self, forKey: .ascent),
      descent: values.decode(Double.self, forKey: .descent),
      leading: values.decode(Double.self, forKey: .leading),
      width: values.decode(Double.self, forKey: .width),
      start: values.decode(InlineCursor.self, forKey: .start),
      end: values.decode(InlineCursor.self, forKey: .end),
      atoms: values.decode([PositionedInlineAtom].self, forKey: .atoms)
    )
  }

  public let index: Int
  public let baselineY: Double
  public let ascent: Double
  public let descent: Double
  public let leading: Double
  public let width: Double
  public let start: InlineCursor
  public let end: InlineCursor
  public let atoms: [PositionedInlineAtom]

  public var height: Double { ascent + descent + leading }

  public init(
    index: Int,
    baselineY: Double,
    ascent: Double,
    descent: Double,
    leading: Double,
    width: Double,
    start: InlineCursor,
    end: InlineCursor,
    atoms: [PositionedInlineAtom]
  ) throws {
    guard index >= 0,
      baselineY.isFinite,
      ascent.isFinite, ascent >= 0,
      descent.isFinite, descent >= 0,
      leading.isFinite, leading >= 0,
      width.isFinite, width >= 0
    else {
      throw InlineLayoutError.unsupportedShaping("invalid line geometry")
    }
    self.index = index
    self.baselineY = baselineY
    self.ascent = ascent
    self.descent = descent
    self.leading = leading
    self.width = width
    self.start = start
    self.end = end
    self.atoms = atoms
  }
}

/// A resumable logical cursor tied to one prepared document and layout policy.
public struct InlineLayoutContinuation: Sendable, Hashable, Codable {
  public let cursor: InlineCursor
  public let preparationRevision: String
  public let width: Double
  public let leading: Double
  public let oversizedVectorPolicy: InlineOversizedVectorPolicy
  /// Identity of the external flow geometry used for this continuation.
  /// Width-only layout uses the default revision zero.
  public let flowRevision: UInt64
  /// Absolute y origin at which the continuation must resume.
  public let nextY: Double

  public init(
    cursor: InlineCursor,
    preparationRevision: String,
    width: Double,
    leading: Double = 0,
    oversizedVectorPolicy: InlineOversizedVectorPolicy,
    flowRevision: UInt64 = 0,
    nextY: Double = 0
  ) {
    self.cursor = cursor
    self.preparationRevision = preparationRevision
    self.width = width
    self.leading = leading
    self.oversizedVectorPolicy = oversizedVectorPolicy
    self.flowRevision = flowRevision
    self.nextY = nextY
  }

  private enum CodingKeys: String, CodingKey {
    case cursor, preparationRevision, width, leading, oversizedVectorPolicy
    case flowRevision, nextY
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.cursor = try values.decode(InlineCursor.self, forKey: .cursor)
    self.preparationRevision = try values.decode(String.self, forKey: .preparationRevision)
    self.width = try values.decode(Double.self, forKey: .width)
    self.leading = try values.decode(Double.self, forKey: .leading)
    self.oversizedVectorPolicy = try values.decode(
      InlineOversizedVectorPolicy.self, forKey: .oversizedVectorPolicy)
    self.flowRevision = try values.decode(UInt64.self, forKey: .flowRevision)
    self.nextY = try values.decode(Double.self, forKey: .nextY)
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(cursor, forKey: .cursor)
    try values.encode(preparationRevision, forKey: .preparationRevision)
    try values.encode(width, forKey: .width)
    try values.encode(leading, forKey: .leading)
    try values.encode(oversizedVectorPolicy, forKey: .oversizedVectorPolicy)
    try values.encode(flowRevision, forKey: .flowRevision)
    try values.encode(nextY, forKey: .nextY)
  }
}

/// Immutable output consumed by every renderer adapter.
public struct InlineLayoutResult: Sendable, Hashable, Codable {
  public let lines: [InlineLayoutLine]
  public let width: Double
  public let height: Double
  public let preparationRevision: String
  /// Identity of the external flow geometry used to produce this result.
  /// Width-only layout uses revision zero.
  public let flowRevision: UInt64
  public let continuation: InlineLayoutContinuation?

  public init(
    lines: [InlineLayoutLine],
    width: Double,
    height: Double,
    preparationRevision: String,
    continuation: InlineLayoutContinuation?,
    flowRevision: UInt64 = 0
  ) {
    self.lines = lines
    self.width = width
    self.height = height
    self.preparationRevision = preparationRevision
    self.flowRevision = flowRevision
    self.continuation = continuation
  }

  private enum CodingKeys: String, CodingKey {
    case lines, width, height, preparationRevision, flowRevision, continuation
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let lines = try values.decode([InlineLayoutLine].self, forKey: .lines)
    let width = try values.decode(Double.self, forKey: .width)
    let height = try values.decode(Double.self, forKey: .height)
    let preparationRevision = try values.decode(String.self, forKey: .preparationRevision)
    let flowRevision = try values.decode(UInt64.self, forKey: .flowRevision)
    let continuation = try values.decodeIfPresent(
      InlineLayoutContinuation.self, forKey: .continuation)
    guard width.isFinite, width >= 0,
      height.isFinite, height >= 0,
      !preparationRevision.isEmpty
    else {
      throw InlineLayoutError.invalidRenderPlan
    }
    self.init(
      lines: lines,
      width: width,
      height: height,
      preparationRevision: preparationRevision,
      continuation: continuation,
      flowRevision: flowRevision
    )
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(lines, forKey: .lines)
    try values.encode(width, forKey: .width)
    try values.encode(height, forKey: .height)
    try values.encode(preparationRevision, forKey: .preparationRevision)
    try values.encode(flowRevision, forKey: .flowRevision)
    try values.encodeIfPresent(continuation, forKey: .continuation)
  }

  /// Verifies that every positioned atom belongs to the preparation that
  /// produced this result before a renderer consumes it.
  public func validate(for prepared: PreparedInlineDocument) throws {
    guard width.isFinite, width >= 0,
      height.isFinite, height >= 0,
      !preparationRevision.isEmpty,
      preparationRevision == prepared.revision
    else {
      throw InlineLayoutError.invalidRenderPlan
    }

    if let continuation {
      guard continuation.preparationRevision == prepared.revision,
        continuation.flowRevision == flowRevision,
        continuation.width == width,
        continuation.width.isFinite,
        continuation.width >= 0,
        continuation.leading.isFinite,
        continuation.leading >= 0,
        continuation.nextY.isFinite,
        continuation.cursor.atomIndex >= 0,
        continuation.cursor.atomIndex <= prepared.atoms.count
      else {
        throw InlineLayoutError.invalidContinuation
      }
      try continuation.oversizedVectorPolicy.validate()
      if continuation.cursor.atomIndex == prepared.atoms.count {
        guard continuation.cursor.graphemeIndex == 0 else {
          throw InlineLayoutError.invalidContinuation
        }
      } else {
        switch prepared.atoms[continuation.cursor.atomIndex] {
        case .text(let text):
          guard continuation.cursor.graphemeIndex >= 0,
            continuation.cursor.graphemeIndex <= text.graphemes.count
          else { throw InlineLayoutError.invalidContinuation }
        case .vector:
          guard continuation.cursor.graphemeIndex == 0 else {
            throw InlineLayoutError.invalidContinuation
          }
        case .image:
          guard continuation.cursor.graphemeIndex == 0 else {
            throw InlineLayoutError.invalidContinuation
          }
        }
      }
    }

    var atomsByID: [String: PreparedInlineDocument.Atom] = [:]
    atomsByID.reserveCapacity(prepared.atoms.count)
    for atom in prepared.atoms {
      switch atom {
      case .text(let text): atomsByID[text.atom.id] = atom
      case .vector(let vector): atomsByID[vector.atom.id] = atom
      case .image(let image): atomsByID[image.atom.id] = atom
      }
    }

    for line in lines {
      for positioned in line.atoms {
        guard positioned.lineIndex == line.index,
          let atom = atomsByID[positioned.atomID]
        else {
          throw InlineLayoutError.invalidRenderPlan
        }
        switch (atom, positioned.kind) {
        case (.text(let text), .text):
          guard positioned.scale == 1 else {
            throw InlineLayoutError.invalidRenderPlan
          }
          guard let range = positioned.sourceRange,
            range.startUTF16 >= text.sourceRange.startUTF16,
            range.endUTF16 <= text.sourceRange.endUTF16
          else {
            throw InlineLayoutError.invalidRenderPlan
          }
          try text.validateSourceRangeBoundaries(range)
        case (.vector(let vector), .vector):
          let expectedAdvance = vector.atom.metrics.advance * positioned.scale
          let expectedAscent = vector.atom.metrics.ascent * positioned.scale
          let expectedDescent = vector.atom.metrics.descent * positioned.scale
          let expectedBaselineOffset = vector.atom.metrics.baselineOffset * positioned.scale
          let tolerance = 1.0 / 64.0
          guard positioned.sourceRange == nil,
            abs(positioned.width - expectedAdvance) <= tolerance,
            abs(positioned.metrics.advance - expectedAdvance) <= tolerance,
            abs(positioned.metrics.ascent - expectedAscent) <= tolerance,
            abs(positioned.metrics.descent - expectedDescent) <= tolerance,
            abs(positioned.metrics.baselineOffset - expectedBaselineOffset) <= tolerance,
            abs(positioned.height - expectedAscent - expectedDescent) <= tolerance
          else {
            throw InlineLayoutError.invalidRenderPlan
          }
        case (.image(let image), .image):
          let expectedAdvance = image.atom.metrics.advance
          let expectedAscent = image.atom.metrics.ascent
          let expectedDescent = image.atom.metrics.descent
          let expectedBaselineOffset = image.atom.metrics.baselineOffset
          let tolerance = 1.0 / 64.0
          guard positioned.scale == 1,
            positioned.sourceRange == nil,
            abs(positioned.width - expectedAdvance) <= tolerance,
            abs(positioned.metrics.advance - expectedAdvance) <= tolerance,
            abs(positioned.metrics.ascent - expectedAscent) <= tolerance,
            abs(positioned.metrics.descent - expectedDescent) <= tolerance,
            abs(positioned.metrics.baselineOffset - expectedBaselineOffset) <= tolerance,
            abs(positioned.height - expectedAscent - expectedDescent) <= tolerance
          else {
            throw InlineLayoutError.invalidRenderPlan
          }
        default:
          throw InlineLayoutError.invalidRenderPlan
        }
      }
    }
  }
}

/// Prepared payload paired with one positioned atom.  Adapters consume this
/// value rather than looking up logical atoms independently (or reshaping
/// text during rendering).
public enum PreparedInlineGeometry: Sendable, Hashable, Codable {
  case text(positioned: PositionedInlineAtom, prepared: PreparedInlineText)
  case vector(positioned: PositionedInlineAtom, prepared: PreparedInlineVector)
  case image(positioned: PositionedInlineAtom, prepared: PreparedInlineImage)

  private enum CodingKeys: String, CodingKey { case kind, positioned, prepared }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let positioned = try values.decode(PositionedInlineAtom.self, forKey: .positioned)
    switch try values.decode(String.self, forKey: .kind) {
    case "text":
      self = .text(
        positioned: positioned,
        prepared: try values.decode(PreparedInlineText.self, forKey: .prepared)
      )
    case "vector":
      self = .vector(
        positioned: positioned,
        prepared: try values.decode(PreparedInlineVector.self, forKey: .prepared)
      )
    case "image":
      self = .image(
        positioned: positioned,
        prepared: try values.decode(PreparedInlineImage.self, forKey: .prepared)
      )
    default:
      throw InlineLayoutError.invalidRenderPlan
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let positioned, let prepared):
      try values.encode("text", forKey: .kind)
      try values.encode(positioned, forKey: .positioned)
      try values.encode(prepared, forKey: .prepared)
    case .vector(let positioned, let prepared):
      try values.encode("vector", forKey: .kind)
      try values.encode(positioned, forKey: .positioned)
      try values.encode(prepared, forKey: .prepared)
    case .image(let positioned, let prepared):
      try values.encode("image", forKey: .kind)
      try values.encode(positioned, forKey: .positioned)
      try values.encode(prepared, forKey: .prepared)
    }
  }
}

extension InlineLayoutResult {
  /// Validates and joins positioned geometry with the immutable preparation.
  /// The returned values preserve layout order and carry the shaped runs and
  /// validated vector metadata used by every renderer adapter.
  public func preparedGeometry(for prepared: PreparedInlineDocument) throws
    -> [PreparedInlineGeometry]
  {
    try validate(for: prepared)
    return try preparedGeometryForValidatedLayout(for: prepared)
  }

  /// Only callers that have validated this immutable layout/preparation pair
  /// may use this join. Public entry points retain their own trust boundary.
  func preparedGeometryForValidatedLayout(for prepared: PreparedInlineDocument) throws
    -> [PreparedInlineGeometry]
  {
    var atomsByID: [String: PreparedInlineDocument.Atom] = [:]
    atomsByID.reserveCapacity(prepared.atoms.count)
    for atom in prepared.atoms {
      switch atom {
      case .text(let text): atomsByID[text.atom.id] = atom
      case .vector(let vector): atomsByID[vector.atom.id] = atom
      case .image(let image): atomsByID[image.atom.id] = atom
      }
    }
    var result: [PreparedInlineGeometry] = []
    result.reserveCapacity(lines.reduce(0) { $0 + $1.atoms.count })
    for line in lines {
      for positioned in line.atoms {
        guard let atom = atomsByID[positioned.atomID] else {
          throw InlineLayoutError.invalidRenderPlan
        }
        switch (atom, positioned.kind) {
        case (.text(let text), .text):
          result.append(.text(positioned: positioned, prepared: text))
        case (.vector(let vector), .vector):
          result.append(.vector(positioned: positioned, prepared: vector))
        case (.image(let image), .image):
          result.append(.image(positioned: positioned, prepared: image))
        default:
          throw InlineLayoutError.invalidRenderPlan
        }
      }
    }
    return result
  }
}

/// The single validated handoff shared by renderer adapters.
///
/// Preparation, positioned geometry, and hit targets are created together so
/// an adapter cannot accidentally pair a layout with a different preparation
/// revision.  The value is immutable after construction; all intermediate
/// work stays local until every validation step succeeds.
public struct InlineRenderPlan: Sendable, Hashable, Codable {
  public let prepared: PreparedInlineDocument
  public let layout: InlineLayoutResult
  public let geometry: [PreparedInlineGeometry]
  public let hitIndex: InlineHitTestIndex

  /// Builds one renderer-neutral plan from one prepared document and layout.
  /// Asset lookup and pixel/render objects remain outside this core value.
  public init(
    prepared: PreparedInlineDocument,
    layout: InlineLayoutResult,
    hitProfile: InlineTextUnitHitProfile = .default,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws {
    try cancellation()
    try layout.validate(for: prepared)
    try cancellation()
    let geometry = try layout.preparedGeometryForValidatedLayout(for: prepared)
    try cancellation()
    let hitIndex = try InlineHitTestIndex.buildForValidatedLayout(
      prepared: prepared,
      layout: layout,
      profile: hitProfile
    )
    try cancellation()

    self.prepared = prepared
    self.layout = layout
    self.geometry = geometry
    self.hitIndex = hitIndex
  }

  private enum CodingKeys: String, CodingKey { case prepared, layout, geometry, hitIndex }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let prepared = try values.decode(PreparedInlineDocument.self, forKey: .prepared)
    let layout = try values.decode(InlineLayoutResult.self, forKey: .layout)
    let geometry = try values.decode([PreparedInlineGeometry].self, forKey: .geometry)
    let hitIndex = try values.decode(InlineHitTestIndex.self, forKey: .hitIndex)

    try layout.validate(for: prepared)
    let expectedGeometry = try layout.preparedGeometryForValidatedLayout(for: prepared)
    let expectedHitIndex = try InlineHitTestIndex.buildForValidatedLayout(
      prepared: prepared,
      layout: layout,
      profile: hitIndex.profile
    )
    guard geometry == expectedGeometry,
      hitIndex == expectedHitIndex
    else {
      throw InlineLayoutError.invalidRenderPlan
    }

    self.prepared = prepared
    self.layout = layout
    self.geometry = geometry
    self.hitIndex = hitIndex
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(prepared, forKey: .prepared)
    try values.encode(layout, forKey: .layout)
    try values.encode(geometry, forKey: .geometry)
    try values.encode(hitIndex, forKey: .hitIndex)
  }
}
