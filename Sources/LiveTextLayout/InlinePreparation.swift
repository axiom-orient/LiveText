import Foundation
import LiveTextCore

/// Bounds applied before a prepared document can be published.
public struct InlinePreparationLimits: Sendable, Hashable, Codable {
  // Supply every argument explicitly: initializer defaults refer back to this
  // canonical value, while ceilings and the image policy each own one number.
  public static let `default` = InlinePreparationLimits(
    maximumAtoms: maximumAtomsCeiling,
    maximumTextUTF16Units: maximumTextUTF16UnitsCeiling,
    maximumGraphemes: maximumGraphemesCeiling,
    maximumGlyphs: maximumGlyphsCeiling,
    maximumRuns: maximumRunsCeiling,
    maximumImageAtoms: defaultMaximumImageAtoms,
    maximumCancellableAtomUTF16Units: maximumCancellableAtomUTF16UnitsCeiling,
    maximumCancellableAtomGlyphs: maximumCancellableAtomGlyphsCeiling,
    maximumCancellableAtomRuns: maximumCancellableAtomRunsCeiling,
    maximumWritingStrokes: maximumWritingStrokesCeiling,
    maximumWritingPoints: maximumWritingPointsCeiling
  )

  private static let maximumAtomsCeiling = 16_384
  private static let maximumTextUTF16UnitsCeiling = 1_000_000
  private static let maximumGraphemesCeiling = 1_000_000
  private static let maximumGlyphsCeiling = 2_000_000
  private static let maximumRunsCeiling = 500_000
  private static let maximumImageAtomsCeiling = 16_384
  private static let defaultMaximumImageAtoms = 4_096
  private static let maximumCancellableAtomUTF16UnitsCeiling = 65_536
  private static let maximumCancellableAtomGlyphsCeiling = 131_072
  private static let maximumCancellableAtomRunsCeiling = 65_536

  public let maximumAtoms: Int
  public let maximumTextUTF16Units: Int
  public let maximumGraphemes: Int
  public let maximumGlyphs: Int
  public let maximumRuns: Int
  /// Maximum image atoms in one prepared document. Encoded bytes are checked
  /// separately at the image-provider boundary.
  public let maximumImageAtoms: Int
  /// Maximum UTF-16 units in one atom when cancellation-aware preparation is used.
  /// Values above the hard ceiling are clamped to preserve bounded work.
  public let maximumCancellableAtomUTF16Units: Int
  public let maximumCancellableAtomGlyphs: Int
  public let maximumCancellableAtomRuns: Int
  /// Maximum semantic handwriting strokes in one prepared document.
  public let maximumWritingStrokes: Int
  /// Maximum normalized points in one prepared document.
  public let maximumWritingPoints: Int

  public static let maximumWritingStrokesCeiling = 65_536
  public static let maximumWritingPointsCeiling = 1_048_576

  public init(
    maximumAtoms: Int = InlinePreparationLimits.default.maximumAtoms,
    maximumTextUTF16Units: Int = InlinePreparationLimits.default.maximumTextUTF16Units,
    maximumGraphemes: Int = InlinePreparationLimits.default.maximumGraphemes,
    maximumGlyphs: Int = InlinePreparationLimits.default.maximumGlyphs,
    maximumRuns: Int = InlinePreparationLimits.default.maximumRuns,
    maximumImageAtoms: Int = InlinePreparationLimits.default.maximumImageAtoms,
    maximumCancellableAtomUTF16Units: Int = InlinePreparationLimits.default
      .maximumCancellableAtomUTF16Units,
    maximumCancellableAtomGlyphs: Int = InlinePreparationLimits.default
      .maximumCancellableAtomGlyphs,
    maximumCancellableAtomRuns: Int = InlinePreparationLimits.default.maximumCancellableAtomRuns,
    maximumWritingStrokes: Int = InlinePreparationLimits.default.maximumWritingStrokes,
    maximumWritingPoints: Int = InlinePreparationLimits.default.maximumWritingPoints
  ) {
    self.maximumAtoms = min(maximumAtoms, Self.maximumAtomsCeiling)
    self.maximumTextUTF16Units = min(maximumTextUTF16Units, Self.maximumTextUTF16UnitsCeiling)
    self.maximumGraphemes = min(maximumGraphemes, Self.maximumGraphemesCeiling)
    self.maximumGlyphs = min(maximumGlyphs, Self.maximumGlyphsCeiling)
    self.maximumRuns = min(maximumRuns, Self.maximumRunsCeiling)
    self.maximumImageAtoms = min(maximumImageAtoms, Self.maximumImageAtomsCeiling)
    self.maximumCancellableAtomUTF16Units = min(
      maximumCancellableAtomUTF16Units, Self.maximumCancellableAtomUTF16UnitsCeiling)
    self.maximumCancellableAtomGlyphs = min(
      maximumCancellableAtomGlyphs, Self.maximumCancellableAtomGlyphsCeiling)
    self.maximumCancellableAtomRuns = min(
      maximumCancellableAtomRuns, Self.maximumCancellableAtomRunsCeiling)
    // Unlike the historical cancellable limits above, these new limits are
    // intentionally not clamped. Preparation validates them and reports a
    // typed error so a caller can never believe a different bound was used.
    self.maximumWritingStrokes = maximumWritingStrokes
    self.maximumWritingPoints = maximumWritingPoints
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let maximumAtoms = try values.decode(Int.self, forKey: .maximumAtoms)
    let maximumTextUTF16Units = try values.decode(Int.self, forKey: .maximumTextUTF16Units)
    let maximumGraphemes = try values.decode(Int.self, forKey: .maximumGraphemes)
    let maximumGlyphs = try values.decode(Int.self, forKey: .maximumGlyphs)
    let maximumRuns = try values.decode(Int.self, forKey: .maximumRuns)
    let maximumImageAtoms = try values.decode(Int.self, forKey: .maximumImageAtoms)
    let maximumCancellableAtomUTF16Units = try values.decode(
      Int.self, forKey: .maximumCancellableAtomUTF16Units)
    let maximumCancellableAtomGlyphs = try values.decode(
      Int.self, forKey: .maximumCancellableAtomGlyphs)
    let maximumCancellableAtomRuns = try values.decode(
      Int.self, forKey: .maximumCancellableAtomRuns)
    let maximumWritingStrokes = try values.decode(Int.self, forKey: .maximumWritingStrokes)
    let maximumWritingPoints = try values.decode(Int.self, forKey: .maximumWritingPoints)

    guard maximumAtoms >= 0, maximumAtoms <= Self.maximumAtomsCeiling,
      maximumTextUTF16Units >= 0,
      maximumTextUTF16Units <= Self.maximumTextUTF16UnitsCeiling,
      maximumGraphemes >= 0, maximumGraphemes <= Self.maximumGraphemesCeiling,
      maximumGlyphs >= 0, maximumGlyphs <= Self.maximumGlyphsCeiling,
      maximumRuns >= 0, maximumRuns <= Self.maximumRunsCeiling,
      maximumImageAtoms >= 0, maximumImageAtoms <= Self.maximumImageAtomsCeiling,
      maximumCancellableAtomUTF16Units >= 0,
      maximumCancellableAtomUTF16Units <= Self.maximumCancellableAtomUTF16UnitsCeiling,
      maximumCancellableAtomGlyphs >= 0,
      maximumCancellableAtomGlyphs <= Self.maximumCancellableAtomGlyphsCeiling,
      maximumCancellableAtomRuns >= 0,
      maximumCancellableAtomRuns <= Self.maximumCancellableAtomRunsCeiling
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .maximumAtoms,
        in: values,
        debugDescription: "Inline preparation limits exceed the canonical hard bounds."
      )
    }
    guard maximumWritingStrokes > 0,
      maximumWritingStrokes <= Self.maximumWritingStrokesCeiling
    else {
      throw InlineLayoutError.invalidWritingLimit(
        resource: "strokes", value: maximumWritingStrokes)
    }
    guard maximumWritingPoints > 0,
      maximumWritingPoints <= Self.maximumWritingPointsCeiling
    else {
      throw InlineLayoutError.invalidWritingLimit(
        resource: "points", value: maximumWritingPoints)
    }

    self.init(
      maximumAtoms: maximumAtoms,
      maximumTextUTF16Units: maximumTextUTF16Units,
      maximumGraphemes: maximumGraphemes,
      maximumGlyphs: maximumGlyphs,
      maximumRuns: maximumRuns,
      maximumImageAtoms: maximumImageAtoms,
      maximumCancellableAtomUTF16Units: maximumCancellableAtomUTF16Units,
      maximumCancellableAtomGlyphs: maximumCancellableAtomGlyphs,
      maximumCancellableAtomRuns: maximumCancellableAtomRuns,
      maximumWritingStrokes: maximumWritingStrokes,
      maximumWritingPoints: maximumWritingPoints
    )
  }

  private enum CodingKeys: String, CodingKey {
    case maximumAtoms, maximumTextUTF16Units, maximumGraphemes, maximumGlyphs, maximumRuns,
      maximumImageAtoms
    case maximumCancellableAtomUTF16Units, maximumCancellableAtomGlyphs, maximumCancellableAtomRuns
    case maximumWritingStrokes, maximumWritingPoints
  }
}

/// Prepared representation of one text atom.
public struct PreparedInlineText: Sendable, Hashable, Codable {
  public let atom: InlineTextAtom
  public let sourceRange: InlineSourceRange
  public let graphemes: [String]
  public let shaped: InlineShapedText
  /// Public optional text-only metadata retained by the native preparation contract.
  /// Mixed-inline layout does not consume this payload.
  public let textKernelPrepared: PreparedText?
  /// Canonical UTF-16 ends at which the shared text boundary policy permits a break.
  public let textBreakEnds: [Int]
  /// Prepared semantic writing units. Native text leaves this empty; a
  /// handwriting atom contains one or more ordered units per grapheme.
  public let writingUnits: [InlinePreparedWritingUnit]

  public var metrics: InlineMetrics { shaped.metrics }

  public init(
    atom: InlineTextAtom,
    sourceRange: InlineSourceRange,
    graphemes: [String],
    shaped: InlineShapedText,
    textKernelPrepared: PreparedText? = nil,
    textBreakEnds: [Int],
    writingUnits: [InlinePreparedWritingUnit] = []
  ) throws {
    try self.init(
      atom: atom,
      sourceRange: sourceRange,
      graphemes: graphemes,
      shaped: shaped,
      textKernelPrepared: textKernelPrepared,
      textBreakEnds: textBreakEnds,
      writingUnits: writingUnits,
      cancellation: {}
    )
  }

  fileprivate init(
    atom: InlineTextAtom,
    sourceRange: InlineSourceRange,
    graphemes: [String],
    shaped: InlineShapedText,
    textKernelPrepared: PreparedText?,
    textBreakEnds: [Int],
    writingUnits: [InlinePreparedWritingUnit],
    cancellation: InlineCancellationCheck
  ) throws {
    guard graphemes.count == shaped.graphemeRanges.count else {
      throw InlineLayoutError.unsupportedShaping("grapheme count does not match shaped data")
    }
    let localRange = try InlineSourceRange(startUTF16: 0, endUTF16: atom.text.utf16.count)
    guard sourceRange.lengthUTF16 == localRange.lengthUTF16 else {
      throw InlineLayoutError.invalidSourceRange
    }
    var expectedOffset = sourceRange.startUTF16
    var expectedGraphemeCount = 0
    for (index, character) in atom.text.enumerated() {
      try cancellation()
      let length = String(character).utf16.count
      let expectedRange = try InlineSourceRange(
        startUTF16: expectedOffset,
        endUTF16: expectedOffset + length
      )
      guard index < graphemes.count,
        graphemes[index] == String(character),
        shaped.graphemeRanges[index] == expectedRange
      else {
        throw InlineLayoutError.unsupportedShaping(
          "grapheme source mapping does not match the text"
        )
      }
      expectedOffset += length
      expectedGraphemeCount += 1
    }
    guard expectedGraphemeCount == graphemes.count else {
      throw InlineLayoutError.unsupportedShaping(
        "grapheme source mapping does not match the text"
      )
    }
    // Validate this trust boundary once, while still observing cancellation.
    // InlineShapedRun has already proved each glyph belongs to its own run.
    for run in shaped.runs {
      try cancellation()
      guard sourceRange.startUTF16 <= run.sourceRange.startUTF16,
        run.sourceRange.endUTF16 <= sourceRange.endUTF16
      else {
        throw InlineLayoutError.unsupportedShaping(
          "shaped run source mapping is outside the text atom"
        )
      }
      for glyph in run.glyphs {
        try cancellation()
        guard sourceRange.startUTF16 <= glyph.sourceUTF16Index,
          glyph.sourceUTF16Index < sourceRange.endUTF16,
          sourceRange.startUTF16 <= glyph.sourceRange.startUTF16,
          glyph.sourceRange.endUTF16 <= sourceRange.endUTF16
        else {
          throw InlineLayoutError.unsupportedShaping(
            "shaped run source mapping is outside the text atom"
          )
        }
      }
    }
    if let textKernelPrepared {
      let expectedOptions = PrepareOptions(
        whiteSpace: .preWrap,
        wordBreak: .normal,
        localeIdentifier: atom.style.font.localeIdentifier
      )
      guard textKernelPrepared.source == atom.text,
        textKernelPrepared.normalized == atom.text,
        textKernelPrepared.font == atom.style.font,
        textKernelPrepared.options == expectedOptions,
        textKernelPrepared.profile == .appleRecommended
      else {
        throw InlineLayoutError.unsupportedShaping(
          "prepared-text payload does not match the text atom"
        )
      }
    }
    let expectedBreakEnds = LineBreakOpportunityKernel.breakEnds(
      graphemes: graphemes,
      sourceStartUTF16: sourceRange.startUTF16
    )
    guard textBreakEnds == expectedBreakEnds else {
      throw InlineLayoutError.unsupportedShaping(
        "break metadata does not match the canonical Core break-opportunity kernel"
      )
    }
    switch atom.style.revealMode {
    case .native:
      guard writingUnits.isEmpty else {
        throw InlineLayoutError.invalidRenderPlan
      }
    case .handwriting:
      var unitIDs = Set<InlineRevealUnitID>()
      let graphemeRanges = Set(shaped.graphemeRanges)
      var coveredRanges = Set<InlineSourceRange>()
      var previousStart = sourceRange.startUTF16
      for unit in writingUnits {
        try cancellation()
        guard unitIDs.insert(unit.id).inserted,
          unit.sourceRange.startUTF16 >= sourceRange.startUTF16,
          unit.sourceRange.endUTF16 <= sourceRange.endUTF16,
          unit.sourceRange.startUTF16 >= previousStart,
          graphemeRanges.contains(unit.sourceRange)
        else {
          throw InlineLayoutError.invalidRenderPlan
        }
        // Exact membership above proves both source boundaries. Re-scanning
        // String.indices here would make many-stroke handwriting quadratic.
        coveredRanges.insert(unit.sourceRange)
        previousStart = unit.sourceRange.startUTF16
      }
      if !graphemes.isEmpty {
        guard !writingUnits.isEmpty else { throw InlineLayoutError.invalidRenderPlan }
        guard coveredRanges == graphemeRanges else {
          throw InlineLayoutError.invalidRenderPlan
        }
      }
    }
    self.atom = atom
    self.sourceRange = sourceRange
    self.graphemes = graphemes
    self.shaped = shaped
    self.textKernelPrepared = textKernelPrepared
    self.textBreakEnds = textBreakEnds
    self.writingUnits = writingUnits
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      atom: values.decode(InlineTextAtom.self, forKey: .atom),
      sourceRange: values.decode(InlineSourceRange.self, forKey: .sourceRange),
      graphemes: values.decode([String].self, forKey: .graphemes),
      shaped: values.decode(InlineShapedText.self, forKey: .shaped),
      textKernelPrepared: values.decodeIfPresent(PreparedText.self, forKey: .textKernelPrepared),
      textBreakEnds: values.decode([Int].self, forKey: .textBreakEnds),
      writingUnits: values.decode([InlinePreparedWritingUnit].self, forKey: .writingUnits)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case atom, sourceRange, graphemes, shaped, textKernelPrepared, textBreakEnds, writingUnits
  }
}

extension PreparedInlineText {
  /// Preserves the public source-range error coordinates while reusing the
  /// exact source mapping already validated by this immutable value.
  package func validateSourceRangeBoundaries(_ range: InlineSourceRange) throws {
    guard range.startUTF16 >= sourceRange.startUTF16,
      range.endUTF16 <= sourceRange.endUTF16
    else { throw InlineLayoutError.invalidSourceRange }
    func isBoundary(_ offset: Int) -> Bool {
      if offset == sourceRange.startUTF16 || offset == sourceRange.endUTF16 { return true }
      let index = InlineSourceRangeSearch.firstStarting(
        atOrAfter: offset, in: shaped.graphemeRanges)
      return index < shaped.graphemeRanges.count
        && shaped.graphemeRanges[index].startUTF16 == offset
    }
    guard isBoundary(range.startUTF16), isBoundary(range.endUTF16) else {
      throw InlineLayoutError.sourceRangeNotAtGraphemeBoundary(
        try InlineSourceRange(
          startUTF16: range.startUTF16 - sourceRange.startUTF16,
          endUTF16: range.endUTF16 - sourceRange.startUTF16))
    }
  }
}

/// Prepared representation of one vector atom.
public struct PreparedInlineVector: Sendable, Hashable, Codable {
  public let atom: InlineVectorAtom

  public init(atom: InlineVectorAtom) {
    self.atom = atom
  }
}

func inlineValidatePreparedPair(
  source: InlineAtom,
  prepared: PreparedInlineDocument.Atom,
  expectedUTF16Offset: Int? = nil
) throws {
  switch (source, prepared) {
  case (.text(let sourceText), .text(let preparedText)):
    guard sourceText == preparedText.atom else {
      throw InlineLayoutError.unsupportedShaping("prepared text atom does not match source")
    }
    guard preparedText.sourceRange.startUTF16 >= 0,
      preparedText.sourceRange.lengthUTF16 == sourceText.text.utf16.count
    else {
      throw InlineLayoutError.invalidSourceRange
    }
    if let expectedUTF16Offset {
      guard preparedText.sourceRange.startUTF16 == expectedUTF16Offset else {
        throw InlineLayoutError.invalidSourceRange
      }
    }
    guard preparedText.shaped.graphemeRanges.count == preparedText.graphemes.count else {
      throw InlineLayoutError.unsupportedShaping("prepared grapheme mapping mismatch")
    }
  case (.vector(let sourceVector), .vector(let preparedVector)):
    guard sourceVector == preparedVector.atom else {
      throw InlineLayoutError.unsupportedShaping("prepared vector atom does not match source")
    }
  case (.image(let sourceImage), .image(let preparedImage)):
    guard sourceImage == preparedImage.atom else {
      throw InlineLayoutError.unsupportedShaping("prepared image atom does not match source")
    }
  default:
    throw InlineLayoutError.unsupportedShaping("prepared atom kind does not match source")
  }
}

extension InlinePreparationLimits {
  fileprivate func check(_ actual: Int, resource: String, limit: Int) throws {
    guard limit >= 0, actual <= limit else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: resource, actual: actual, limit: limit)
    }
  }
}

/// Immutable, width-independent preparation shared by all renderers.
public struct PreparedInlineDocument: Sendable, Hashable, Codable {
  public enum Atom: Sendable, Hashable, Codable {
    case text(PreparedInlineText)
    case vector(PreparedInlineVector)
    case image(PreparedInlineImage)
  }

  public let document: InlineDocument
  public let atoms: [Atom]
  public let revision: String
  /// Canonical profile/limit context used to derive `revision`.
  public let identityContext: InlinePreparationIdentityContext
  public let totalTextUTF16Units: Int
  public let totalGraphemes: Int
  public let totalGlyphs: Int
  public let totalRuns: Int
  public let totalImageAtoms: Int

  /// Creates a prepared document and derives its canonical revision from the
  /// exact document, prepared atoms, and preparation identity context.
  public init(
    document: InlineDocument,
    atoms: [Atom],
    identityContext: InlinePreparationIdentityContext = .full(),
    totalTextUTF16Units: Int,
    totalGraphemes: Int,
    totalGlyphs: Int,
    totalRuns: Int,
    totalImageAtoms: Int = 0,
    cancellation: InlineCancellationCheck = {}
  ) throws {
    try Self.validateContents(
      document: document,
      atoms: atoms,
      identityContext: identityContext,
      totalTextUTF16Units: totalTextUTF16Units,
      totalGraphemes: totalGraphemes,
      totalGlyphs: totalGlyphs,
      totalRuns: totalRuns,
      totalImageAtoms: totalImageAtoms,
      cancellation: cancellation
    )
    let revision = try canonicalInlinePreparationRevision(
      document: document,
      preparedAtoms: atoms,
      identityContext: identityContext,
      cancellation: cancellation
    )
    self.init(
      validatedDocument: document,
      atoms: atoms,
      revision: revision,
      identityContext: identityContext,
      totalTextUTF16Units: totalTextUTF16Units,
      totalGraphemes: totalGraphemes,
      totalGlyphs: totalGlyphs,
      totalRuns: totalRuns,
      totalImageAtoms: totalImageAtoms
    )
  }

  /// Validates an externally supplied revision against the canonical identity
  /// context. The digest is never accepted as an independent authority.
  public init(
    document: InlineDocument,
    atoms: [Atom],
    revision: String,
    identityContext: InlinePreparationIdentityContext = .full(),
    totalTextUTF16Units: Int,
    totalGraphemes: Int,
    totalGlyphs: Int,
    totalRuns: Int,
    totalImageAtoms: Int = 0,
    cancellation: InlineCancellationCheck = {}
  ) throws {
    guard !revision.isEmpty else { throw InlineLayoutError.invalidIdentifier }
    try Self.validateContents(
      document: document,
      atoms: atoms,
      identityContext: identityContext,
      totalTextUTF16Units: totalTextUTF16Units,
      totalGraphemes: totalGraphemes,
      totalGlyphs: totalGlyphs,
      totalRuns: totalRuns,
      totalImageAtoms: totalImageAtoms,
      cancellation: cancellation
    )
    let canonicalRevision = try canonicalInlinePreparationRevision(
      document: document,
      preparedAtoms: atoms,
      identityContext: identityContext,
      cancellation: cancellation
    )
    guard revision == canonicalRevision else {
      throw InlineLayoutError.invalidRenderPlan
    }
    self.init(
      validatedDocument: document,
      atoms: atoms,
      revision: canonicalRevision,
      identityContext: identityContext,
      totalTextUTF16Units: totalTextUTF16Units,
      totalGraphemes: totalGraphemes,
      totalGlyphs: totalGlyphs,
      totalRuns: totalRuns,
      totalImageAtoms: totalImageAtoms
    )
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let document = try values.decode(InlineDocument.self, forKey: .document)
    let atoms = try values.decode([Atom].self, forKey: .atoms)
    let revision = try values.decode(String.self, forKey: .revision)
    let totalTextUTF16Units = try values.decode(Int.self, forKey: .totalTextUTF16Units)
    let totalGraphemes = try values.decode(Int.self, forKey: .totalGraphemes)
    let totalGlyphs = try values.decode(Int.self, forKey: .totalGlyphs)
    let totalRuns = try values.decode(Int.self, forKey: .totalRuns)
    let totalImageAtoms = try values.decode(Int.self, forKey: .totalImageAtoms)

    if let identityContext = try values.decodeIfPresent(
      InlinePreparationIdentityContext.self,
      forKey: .identityContext
    ) {
      try self.init(
        document: document,
        atoms: atoms,
        revision: revision,
        identityContext: identityContext,
        totalTextUTF16Units: totalTextUTF16Units,
        totalGraphemes: totalGraphemes,
        totalGlyphs: totalGlyphs,
        totalRuns: totalRuns,
        totalImageAtoms: totalImageAtoms
      )
      return
    }

    throw InlineLayoutError.invalidRenderPlan
  }

  private init(
    validatedDocument document: InlineDocument,
    atoms: [Atom],
    revision: String,
    identityContext: InlinePreparationIdentityContext,
    totalTextUTF16Units: Int,
    totalGraphemes: Int,
    totalGlyphs: Int,
    totalRuns: Int,
    totalImageAtoms: Int
  ) {
    self.document = document
    self.atoms = atoms
    self.revision = revision
    self.identityContext = identityContext
    self.totalTextUTF16Units = totalTextUTF16Units
    self.totalGraphemes = totalGraphemes
    self.totalGlyphs = totalGlyphs
    self.totalRuns = totalRuns
    self.totalImageAtoms = totalImageAtoms
  }

  private static func validateContents(
    document: InlineDocument,
    atoms: [Atom],
    identityContext: InlinePreparationIdentityContext,
    totalTextUTF16Units: Int,
    totalGraphemes: Int,
    totalGlyphs: Int,
    totalRuns: Int,
    totalImageAtoms: Int,
    cancellation: InlineCancellationCheck
  ) throws {
    guard atoms.count == document.atoms.count else {
      throw InlineLayoutError.unsupportedShaping("prepared atom count does not match document")
    }
    guard totalTextUTF16Units >= 0, totalGraphemes >= 0, totalGlyphs >= 0, totalRuns >= 0,
      totalImageAtoms >= 0
    else {
      throw InlineLayoutError.unsupportedShaping("negative preparation counters")
    }
    try identityContext.validateLimits()
    let limits = identityContext.limits
    try limits.check(atoms.count, resource: "atoms", limit: limits.maximumAtoms)
    var computedWritingStrokes = 0
    var computedWritingPoints = 0
    var computedTextUTF16Units = 0
    var computedGraphemes = 0
    var computedGlyphs = 0
    var computedRuns = 0
    var computedImageAtoms = 0
    for (documentAtom, preparedAtom) in zip(document.atoms, atoms) {
      try cancellation()
      try inlineValidatePreparedPair(
        source: documentAtom,
        prepared: preparedAtom,
        expectedUTF16Offset: computedTextUTF16Units
      )
      switch preparedAtom {
      case .text(let preparedText):
        if identityContext.mode == .cancellationAware {
          try limits.check(
            preparedText.sourceRange.lengthUTF16,
            resource: "cancellable text atom UTF-16 units",
            limit: limits.maximumCancellableAtomUTF16Units)
          try limits.check(
            preparedText.shaped.runs.count, resource: "cancellable atom runs",
            limit: limits.maximumCancellableAtomRuns)
        }
        let (nextTextUTF16Units, textOverflow) = computedTextUTF16Units.addingReportingOverflow(
          preparedText.atom.text.utf16.count)
        let (nextGraphemes, graphemeOverflow) = computedGraphemes.addingReportingOverflow(
          preparedText.graphemes.count)
        guard !textOverflow, !graphemeOverflow else {
          throw InlineLayoutError.unsupportedShaping("preparation counter overflow")
        }
        computedTextUTF16Units = nextTextUTF16Units
        computedGraphemes = nextGraphemes
        try limits.check(
          computedTextUTF16Units, resource: "text UTF-16 units", limit: limits.maximumTextUTF16Units
        )
        try limits.check(computedGraphemes, resource: "graphemes", limit: limits.maximumGraphemes)
        let glyphsBeforeAtom = computedGlyphs
        for run in preparedText.shaped.runs {
          try cancellation()
          let (nextGlyphs, glyphOverflow) = computedGlyphs.addingReportingOverflow(run.glyphs.count)
          let (nextRuns, runOverflow) = computedRuns.addingReportingOverflow(1)
          guard !glyphOverflow, !runOverflow else {
            throw InlineLayoutError.unsupportedShaping("preparation counter overflow")
          }
          computedGlyphs = nextGlyphs
          computedRuns = nextRuns
          try limits.check(computedGlyphs, resource: "glyphs", limit: limits.maximumGlyphs)
          try limits.check(computedRuns, resource: "runs", limit: limits.maximumRuns)
          if identityContext.mode == .cancellationAware {
            try limits.check(
              computedGlyphs - glyphsBeforeAtom, resource: "cancellable atom glyphs",
              limit: limits.maximumCancellableAtomGlyphs)
          }
        }
        for unit in preparedText.writingUnits {
          try cancellation()
          guard case .semanticStroke(let stroke) = unit.kind else { continue }
          let (nextStrokes, strokeOverflow) = computedWritingStrokes.addingReportingOverflow(1)
          guard !strokeOverflow else {
            throw InlineLayoutError.unsupportedShaping("preparation counter overflow")
          }
          computedWritingStrokes = nextStrokes
          try limits.check(
            computedWritingStrokes, resource: "writing strokes", limit: limits.maximumWritingStrokes
          )
          let (nextPoints, overflow) = computedWritingPoints.addingReportingOverflow(
            stroke.points.count)
          guard !overflow else {
            throw InlineLayoutError.unsupportedShaping("preparation counter overflow")
          }
          computedWritingPoints = nextPoints
          try limits.check(
            computedWritingPoints, resource: "writing points", limit: limits.maximumWritingPoints)
        }
      case .vector:
        break
      case .image:
        let (nextImages, imageOverflow) = computedImageAtoms.addingReportingOverflow(1)
        guard !imageOverflow else {
          throw InlineLayoutError.unsupportedShaping("preparation counter overflow")
        }
        computedImageAtoms = nextImages
        try limits.check(
          computedImageAtoms, resource: "image atoms", limit: limits.maximumImageAtoms)
      }
    }
    guard computedTextUTF16Units == totalTextUTF16Units,
      computedGraphemes == totalGraphemes,
      computedGlyphs == totalGlyphs,
      computedRuns == totalRuns,
      computedImageAtoms == totalImageAtoms
    else {
      throw InlineLayoutError.unsupportedShaping("preparation counters do not match atoms")
    }
  }

  private enum CodingKeys: String, CodingKey {
    case document, atoms, revision, identityContext, totalTextUTF16Units, totalGraphemes,
      totalGlyphs, totalRuns, totalImageAtoms
  }
}

/// Converts logical atoms into reusable shaped and validated preparation.
public struct InlinePreparation: Sendable {
  public let shaper: any InlineTextShaping
  public let limits: InlinePreparationLimits
  public let writingFaceStore: InlineWritingFaceStore

  public init(
    shaper: any InlineTextShaping,
    limits: InlinePreparationLimits = .default,
    writingFaceStore: InlineWritingFaceStore = .empty
  ) {
    self.shaper = shaper
    self.limits = limits
    self.writingFaceStore = writingFaceStore
  }

  #if canImport(CoreText)
    public init(
      limits: InlinePreparationLimits = .default,
      writingFaceStore: InlineWritingFaceStore = .empty
    ) {
      self.init(shaper: CoreTextInlineShaper(), limits: limits, writingFaceStore: writingFaceStore)
    }
  #endif

  /// Prepares a document with all eligible text-only fast-path metadata retained.
  public func prepare(document: InlineDocument) throws -> PreparedInlineDocument {
    try prepare(
      document: document,
      cancellation: {},
      includeTextKernelPreparation: true
    )
  }

  /// Prepares with cancellation checks between bounded shaping units.
  ///
  /// The synchronous prepared-text backend has no cancellation input. This bounded
  /// mode therefore omits optional prepared-text metadata rather than entering an
  /// uninterruptible preparation call; layout remains valid through the
  /// explicit generic policy path.
  public func prepare(
    document: InlineDocument,
    cancellation: @escaping InlineCancellationCheck
  ) throws -> PreparedInlineDocument {
    try prepare(
      document: document,
      cancellation: cancellation,
      includeTextKernelPreparation: false
    )
  }

  private func prepare(
    document: InlineDocument,
    cancellation: @escaping InlineCancellationCheck,
    includeTextKernelPreparation: Bool
  ) throws -> PreparedInlineDocument {
    try cancellation()
    try validateWritingLimits()
    try limits.check(document.atoms.count, resource: "atoms", limit: limits.maximumAtoms)
    var hasTextAtom = false
    for atom in document.atoms {
      try cancellation()
      if case .text = atom {
        hasTextAtom = true
        break
      }
    }
    if !includeTextKernelPreparation, hasTextAtom,
      !(shaper is any CancellableInlineTextShaping)
    {
      throw InlineLayoutError.unsupportedShaping(
        "cancellation-aware preparation requires a cancellable shaper"
      )
    }
    var prepared: [PreparedInlineDocument.Atom] = []
    prepared.reserveCapacity(document.atoms.count)
    var utf16Offset = 0
    var textUnits = 0
    var graphemeCount = 0
    var glyphCount = 0
    var runCount = 0
    var imageCount = 0
    var strokeCount = 0
    var pointCount = 0

    for atom in document.atoms {
      try cancellation()
      switch atom {
      case .text(let textAtom):
        let length = textAtom.text.utf16.count
        if !includeTextKernelPreparation {
          try limits.check(
            length,
            resource: "cancellable text atom UTF-16 units",
            limit: limits.maximumCancellableAtomUTF16Units
          )
        }
        textUnits += length
        try limits.check(
          textUnits, resource: "text UTF-16 units", limit: limits.maximumTextUTF16Units)
        let sourceRange = try InlineSourceRange(
          startUTF16: utf16Offset,
          endUTF16: utf16Offset + length
        )
        var graphemes: [String] = []
        graphemes.reserveCapacity(textAtom.text.count)
        for grapheme in textAtom.text {
          try cancellation()
          graphemes.append(String(grapheme))
        }
        try limits.check(graphemes.count, resource: "graphemes", limit: limits.maximumGraphemes)
        let shaped: InlineShapedText
        if let cancellableShaper = shaper as? any CancellableInlineTextShaping {
          shaped = try cancellableShaper.shape(
            text: textAtom.text,
            style: textAtom.style,
            sourceRange: sourceRange,
            cancellation: cancellation
          )
        } else {
          try cancellation()
          shaped = try shaper.shape(
            text: textAtom.text, style: textAtom.style, sourceRange: sourceRange)
        }
        try cancellation()
        guard shaped.graphemeRanges.count == graphemes.count else {
          throw InlineLayoutError.unsupportedShaping(
            "shaper did not return one mapping per grapheme")
        }
        var atomGlyphCount = 0
        for run in shaped.runs {
          try cancellation()
          atomGlyphCount += run.glyphs.count
          try limits.check(atomGlyphCount, resource: "glyphs", limit: limits.maximumGlyphs)
          if !includeTextKernelPreparation {
            try limits.check(
              atomGlyphCount,
              resource: "cancellable atom glyphs",
              limit: limits.maximumCancellableAtomGlyphs
            )
          }
        }
        try limits.check(shaped.runs.count, resource: "runs", limit: limits.maximumRuns)
        if !includeTextKernelPreparation {
          try limits.check(
            shaped.runs.count,
            resource: "cancellable atom runs",
            limit: limits.maximumCancellableAtomRuns
          )
        }
        let canonicalBreakEnds = LineBreakOpportunityKernel.breakEnds(
          graphemes: graphemes,
          sourceStartUTF16: sourceRange.startUTF16
        )
        #if canImport(CoreText)
          let textKernelData: (prepared: PreparedText?, breakEnds: [Int])
          if includeTextKernelPreparation {
            textKernelData = try makeTextKernelData(
              for: textAtom,
              sourceRange: sourceRange,
              canonicalBreakEnds: canonicalBreakEnds,
              cancellation: cancellation
            )
          } else {
            textKernelData = (nil, canonicalBreakEnds)
          }
        #else
          let textKernelData: (prepared: PreparedText?, breakEnds: [Int]) = (
            nil, canonicalBreakEnds
          )
        #endif
        let writingUnits = try makeWritingUnits(
          atom: textAtom,
          graphemes: graphemes,
          shaped: shaped,
          strokeCount: &strokeCount,
          pointCount: &pointCount,
          cancellation: cancellation
        )
        prepared.append(
          .text(
            try PreparedInlineText(
              atom: textAtom,
              sourceRange: sourceRange,
              graphemes: graphemes,
              shaped: shaped,
              textKernelPrepared: textKernelData.prepared,
              textBreakEnds: textKernelData.breakEnds,
              writingUnits: writingUnits,
              cancellation: cancellation
            )))
        graphemeCount += graphemes.count
        for run in shaped.runs {
          try cancellation()
          glyphCount += run.glyphs.count
          runCount += 1
        }
        utf16Offset += length
      case .vector(let vectorAtom):
        prepared.append(.vector(PreparedInlineVector(atom: vectorAtom)))
      case .image(let imageAtom):
        imageCount += 1
        try limits.check(imageCount, resource: "image atoms", limit: limits.maximumImageAtoms)
        prepared.append(.image(PreparedInlineImage(atom: imageAtom)))
      }
      try limits.check(graphemeCount, resource: "graphemes", limit: limits.maximumGraphemes)
      try limits.check(glyphCount, resource: "glyphs", limit: limits.maximumGlyphs)
      try limits.check(runCount, resource: "runs", limit: limits.maximumRuns)
    }

    try cancellation()
    return try PreparedInlineDocument(
      document: document,
      atoms: prepared,
      identityContext: InlinePreparationIdentityContext(
        mode: includeTextKernelPreparation ? .full : .cancellationAware,
        limits: limits
      ),
      totalTextUTF16Units: textUnits,
      totalGraphemes: graphemeCount,
      totalGlyphs: glyphCount,
      totalRuns: runCount,
      totalImageAtoms: imageCount,
      cancellation: cancellation
    )
  }

  private func validateWritingLimits() throws {
    guard limits.maximumWritingStrokes > 0,
      limits.maximumWritingStrokes <= InlinePreparationLimits.maximumWritingStrokesCeiling
    else {
      throw InlineLayoutError.invalidWritingLimit(
        resource: "strokes", value: limits.maximumWritingStrokes)
    }
    guard limits.maximumWritingPoints > 0,
      limits.maximumWritingPoints <= InlinePreparationLimits.maximumWritingPointsCeiling
    else {
      throw InlineLayoutError.invalidWritingLimit(
        resource: "points", value: limits.maximumWritingPoints)
    }
  }

  private func makeWritingUnits(
    atom: InlineTextAtom,
    graphemes: [String],
    shaped: InlineShapedText,
    strokeCount: inout Int,
    pointCount: inout Int,
    cancellation: InlineCancellationCheck
  ) throws -> [InlinePreparedWritingUnit] {
    guard case .handwriting(let faceID) = atom.style.revealMode else { return [] }
    guard let face = writingFaceStore.face(for: faceID) else {
      let glyph = graphemes.first ?? ""
      throw InlineLayoutError.missingWritingFace(faceID: faceID, atomID: atom.id, glyph: glyph)
    }
    var result: [InlinePreparedWritingUnit] = []
    for (index, grapheme) in graphemes.enumerated() {
      try cancellation()
      let range = shaped.graphemeRanges[index]
      if inlineIsWritingWhitespace(grapheme) {
        result.append(
          try InlinePreparedWritingUnit(
            id: try InlineRevealUnitID(rawValue: "\(atom.id)-writing-\(index)-timing"),
            sourceRange: range,
            kind: .timingOnly
          ))
        continue
      }
      if inlineIsNativeEmoji(grapheme) {
        result.append(
          try InlinePreparedWritingUnit(
            id: try InlineRevealUnitID(rawValue: "\(atom.id)-writing-\(index)-emoji"),
            sourceRange: range,
            kind: .nativeAtomic
          ))
        continue
      }
      let glyph: InlineWritingGlyph?
      do {
        glyph = try face.glyph(for: Character(grapheme))
      } catch {
        throw InlineLayoutError.malformedWritingFace(
          faceID: faceID,
          glyph: grapheme,
          reason: String(describing: error)
        )
      }
      guard let glyph else {
        throw InlineLayoutError.unsupportedWritingGlyph(faceID: faceID, glyph: grapheme)
      }
      guard glyph.character == grapheme, !glyph.strokes.isEmpty else {
        throw InlineLayoutError.malformedWritingFace(
          faceID: faceID,
          glyph: grapheme,
          reason: "glyph identity or stroke list is invalid"
        )
      }
      for (strokeIndex, stroke) in glyph.strokes.enumerated() {
        try cancellation()
        strokeCount += 1
        try limits.check(
          strokeCount, resource: "writing strokes", limit: limits.maximumWritingStrokes)
        for _ in stroke.points {
          try cancellation()
          pointCount += 1
          try limits.check(
            pointCount, resource: "writing points", limit: limits.maximumWritingPoints)
        }
        result.append(
          try InlinePreparedWritingUnit(
            id: try InlineRevealUnitID(
              rawValue: "\(atom.id)-writing-\(index)-stroke-\(strokeIndex)"
            ),
            sourceRange: range,
            kind: .semanticStroke(stroke)
          ))
      }
    }
    return result
  }

  #if canImport(CoreText)
    private func makeTextKernelData(
      for atom: InlineTextAtom,
      sourceRange: InlineSourceRange,
      canonicalBreakEnds: [Int],
      cancellation: InlineCancellationCheck
    ) throws -> (prepared: PreparedText?, breakEnds: [Int]) {
      guard shaper is CoreTextInlineShaper, atom.style.tracking == 0 else {
        return (nil, canonicalBreakEnds)
      }
      try cancellation()
      let options = PrepareOptions(
        whiteSpace: .preWrap,
        wordBreak: .normal,
        localeIdentifier: atom.style.font.localeIdentifier
      )
      let prepared = try LiveTextEngine.appleDefault().prepare(
        atom.text, font: atom.style.font, options: options)
      try cancellation()
      return (prepared, canonicalBreakEnds)
    }
  #endif
}

#if canImport(CoreText)
  import CoreText

  /// Apple shaping adapter. Core Text objects are discarded before publication.
  public struct CoreTextInlineShaper: CancellableInlineTextShaping {
    public init() {}

    public func shape(
      text: String,
      style: InlineTextStyle,
      sourceRange: InlineSourceRange
    ) throws -> InlineShapedText {
      try shape(text: text, style: style, sourceRange: sourceRange, cancellation: {})
    }

    public func shape(
      text: String,
      style: InlineTextStyle,
      sourceRange: InlineSourceRange,
      cancellation: InlineCancellationCheck
    ) throws -> InlineShapedText {
      try cancellation()
      let textUTF16Count = text.utf16.count
      guard sourceRange.lengthUTF16 == textUTF16Count else {
        throw InlineLayoutError.invalidSourceRange
      }
      let font = CTFontCreateWithName(
        style.font.postScriptName as CFString, style.font.pointSize, nil)
      guard let resolvedName = CTFontCopyPostScriptName(font) as String?,
        resolvedName == style.font.postScriptName
      else {
        throw InlineLayoutError.unsupportedShaping(
          "font '\(style.font.postScriptName)' was not resolved"
        )
      }
      var attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font
      ]
      if let locale = style.font.localeIdentifier, !locale.isEmpty {
        attributes[NSAttributedString.Key(rawValue: kCTLanguageAttributeName as String)] = locale
      }
      if style.tracking != 0 {
        attributes[NSAttributedString.Key(rawValue: kCTKernAttributeName as String)] =
          style.tracking
      }
      let attributed = NSAttributedString(string: text, attributes: attributes)
      let line = CTLineCreateWithAttributedString(attributed)
      let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
      guard text.isEmpty || !runs.isEmpty else {
        throw InlineLayoutError.unsupportedShaping("Core Text returned no glyph runs")
      }
      var shapedRuns: [InlineShapedRun] = []
      shapedRuns.reserveCapacity(runs.count)
      let ranges = try graphemeRanges(
        text: text,
        offset: sourceRange.startUTF16,
        cancellation: cancellation
      )
      var glyphContributions: [(range: InlineSourceRange, advance: Double)] = []

      for run in runs {
        try cancellation()
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { continue }
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        var indices = [CFIndex](repeating: 0, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
        let stringRange = CTRunGetStringRange(run)
        let runEndUTF16 = min(
          textUTF16Count,
          max(0, stringRange.location + stringRange.length)
        )

        let runAttributes = CTRunGetAttributes(run) as NSDictionary
        guard let rawRunFont = runAttributes[kCTFontAttributeName] else {
          throw InlineLayoutError.unsupportedShaping("Core Text run has no resolved font")
        }
        let rawRunFontObject = rawRunFont as AnyObject
        let runFontRef = rawRunFontObject as CFTypeRef
        guard CFGetTypeID(runFontRef) == CTFontGetTypeID() else {
          throw InlineLayoutError.unsupportedShaping("Core Text run has no resolved font")
        }
        let runFont = unsafeDowncast(rawRunFontObject, to: CTFont.self)
        guard let runFontName = CTFontCopyPostScriptName(runFont) as String?
        else {
          throw InlineLayoutError.unsupportedShaping("Core Text run has no resolved font")
        }
        var advances = [CGSize](repeating: .zero, count: count)
        CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
        let sortedSourceIndices = Array(Set(indices.map { Int($0) })).sorted()
        let firstIndex = max(0, sortedSourceIndices.first ?? 0)
        var inlineGlyphs: [InlineGlyph] = []
        inlineGlyphs.reserveCapacity(count)
        for index in 0..<count {
          try cancellation()
          let localIndex = max(0, min(textUTF16Count, Int(indices[index])))
          let clusterEnd = clusterEnd(
            for: localIndex,
            sortedSourceIndices: sortedSourceIndices,
            runUTF16End: runEndUTF16
          )
          let glyphRange = try InlineSourceRange(
            startUTF16: sourceRange.startUTF16 + localIndex,
            endUTF16: sourceRange.startUTF16 + clusterEnd
          )
          inlineGlyphs.append(
            try InlineGlyph(
              glyphID: glyphs[index],
              positionX: Double(positions[index].x),
              positionY: Double(positions[index].y),
              sourceUTF16Index: sourceRange.startUTF16 + localIndex,
              sourceRange: glyphRange
            ))
          glyphContributions.append(
            (range: glyphRange, advance: max(0, Double(advances[index].width)))
          )
        }
        let runStart =
          inlineGlyphs.map(\.sourceRange.startUTF16).min()
          ?? sourceRange.startUTF16 + firstIndex
        let runEnd = inlineGlyphs.map(\.sourceRange.endUTF16).max() ?? runStart
        let runRange = try InlineSourceRange(startUTF16: runStart, endUTF16: runEnd)
        let runAdvance = Double(
          CTRunGetTypographicBounds(run, CFRange(location: 0, length: count), nil, nil, nil))
        shapedRuns.append(
          try InlineShapedRun(
            glyphs: inlineGlyphs,
            font: FontDescriptor(
              postScriptName: runFontName,
              pointSize: style.font.pointSize,
              localeIdentifier: style.font.localeIdentifier
            ),
            sourceRange: runRange,
            advance: max(0, runAdvance),
            ascent: max(0, Double(CTFontGetAscent(runFont))),
            descent: max(0, Double(CTFontGetDescent(runFont)))
          ))
      }

      var advances = Array(repeating: 0.0, count: ranges.count)
      for contribution in glyphContributions {
        try cancellation()
        let matchingIndices = InlineSourceRangeSearch.overlappingIndices(
          in: ranges, with: contribution.range)
        guard !matchingIndices.isEmpty else {
          throw InlineLayoutError.unsupportedShaping(
            "glyph cluster does not map to a grapheme"
          )
        }
        let sharedAdvance = contribution.advance / Double(matchingIndices.count)
        for index in matchingIndices {
          try cancellation()
          advances[index] += sharedAdvance
        }
      }
      let ascent = shapedRuns.map(\.ascent).max() ?? max(0, style.font.pointSize)
      let descent = shapedRuns.map(\.descent).max() ?? 0
      let metrics = try InlineMetrics(
        advance: advances.reduce(0, +),
        ascent: ascent,
        descent: descent,
        baselineOffset: style.baselineOffset
      )
      return try InlineShapedText(
        graphemeRanges: ranges,
        graphemeAdvances: advances,
        runs: shapedRuns,
        metrics: metrics
      )
    }

    private func graphemeRanges(
      text: String,
      offset: Int,
      cancellation: InlineCancellationCheck
    ) throws -> [InlineSourceRange] {
      var ranges: [InlineSourceRange] = []
      var start = offset
      for character in text {
        try cancellation()
        let end = start + String(character).utf16.count
        ranges.append(try InlineSourceRange(startUTF16: start, endUTF16: end))
        start = end
      }
      return ranges
    }

    private func clusterEnd(for start: Int, sortedSourceIndices: [Int], runUTF16End: Int) -> Int {
      var lower = 0
      var upper = sortedSourceIndices.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if sortedSourceIndices[middle] <= start { lower = middle + 1 } else { upper = middle }
      }
      return lower < sortedSourceIndices.count
        ? min(sortedSourceIndices[lower], runUTF16End) : runUTF16End
    }
  }
#endif
