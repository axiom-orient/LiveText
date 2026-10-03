import Foundation
import LiveTextCore

/// A point in the local coordinate space of an inline layout.
public struct InlineHitPoint: Sendable, Hashable, Codable {
  private enum CodingKeys: String, CodingKey {
    case x, y
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      x: values.decode(Double.self, forKey: .x),
      y: values.decode(Double.self, forKey: .y)
    )
  }

  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) throws {
    guard x.isFinite, y.isFinite else {
      throw InlineLayoutError.invalidMetric(name: "hit point", value: x)
    }
    self.x = x
    self.y = y
  }

  package init(validatedX x: Double, validatedY y: Double) {
    precondition(x.isFinite && y.isFinite, "validated hit point must remain finite")
    self.x = x
    self.y = y
  }
}

/// A renderer-neutral rectangle in the local coordinate space of an inline layout.
public struct InlineHitRect: Sendable, Hashable, Codable {
  public let minX: Double
  public let minY: Double
  public let width: Double
  public let height: Double

  public init(minX: Double, minY: Double, width: Double, height: Double) throws {
    guard minX.isFinite, minY.isFinite, width.isFinite, width >= 0,
      height.isFinite, height >= 0
    else {
      throw InlineLayoutError.invalidRenderPlan
    }
    let maxX = minX + width
    guard maxX.isFinite else {
      throw InlineLayoutError.invalidRenderPlan
    }
    let maxY = minY + height
    guard maxY.isFinite else {
      throw InlineLayoutError.invalidRenderPlan
    }
    self.minX = minX
    self.minY = minY
    self.width = width
    self.height = height
  }

  public var maxX: Double { minX + width }
  public var maxY: Double { minY + height }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      minX: values.decode(Double.self, forKey: .minX),
      minY: values.decode(Double.self, forKey: .minY),
      width: values.decode(Double.self, forKey: .width),
      height: values.decode(Double.self, forKey: .height)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(minX, forKey: .minX)
    try values.encode(minY, forKey: .minY)
    try values.encode(width, forKey: .width)
    try values.encode(height, forKey: .height)
  }

  private enum CodingKeys: String, CodingKey { case minX, minY, width, height }

  package func contains(_ point: InlineHitPoint) -> Bool {
    guard width > 0, height > 0 else { return false }
    return point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
  }
}

/// How CJK graphemes become independently selectable word targets.
public enum InlineCJKWordPolicy: String, Sendable, Hashable, Codable {
  /// Each Han, Hangul, Hiragana, or Katakana grapheme is one target.
  case eachGrapheme
}

/// Punctuation is deliberately excluded from word targets in the default profile.
public enum InlinePunctuationWordPolicy: String, Sendable, Hashable, Codable {
  case exclude
}

/// Explicit word-hit behavior. The default is whitespace-independent text-only selection.
public struct InlineTextUnitHitProfile: Sendable, Hashable, Codable {
  /// The single semantic mode indexed by this profile.
  public let unitKind: InlineTextUnitKind
  public let cjk: InlineCJKWordPolicy
  public let punctuation: InlinePunctuationWordPolicy
  public let includeWhitespace: Bool
  public let includeVectors: Bool
  public let includeImages: Bool

  public static let `default` = InlineTextUnitHitProfile(
    unitKind: .word,
    cjk: .eachGrapheme,
    punctuation: .exclude,
    includeWhitespace: false,
    includeVectors: true
  )

  public init(
    unitKind: InlineTextUnitKind = .word,
    cjk: InlineCJKWordPolicy = .eachGrapheme,
    punctuation: InlinePunctuationWordPolicy = .exclude,
    includeWhitespace: Bool = false,
    includeVectors: Bool = true,
    includeImages: Bool = true
  ) {
    self.unitKind = unitKind
    self.cjk = cjk
    self.punctuation = punctuation
    self.includeWhitespace = includeWhitespace
    self.includeVectors = includeVectors
    self.includeImages = includeImages
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      unitKind: try values.decode(InlineTextUnitKind.self, forKey: .unitKind),
      cjk: try values.decode(InlineCJKWordPolicy.self, forKey: .cjk),
      punctuation: try values.decode(InlinePunctuationWordPolicy.self, forKey: .punctuation),
      includeWhitespace: try values.decode(Bool.self, forKey: .includeWhitespace),
      includeVectors: try values.decode(Bool.self, forKey: .includeVectors),
      includeImages: try values.decode(Bool.self, forKey: .includeImages)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(unitKind, forKey: .unitKind)
    try values.encode(cjk, forKey: .cjk)
    try values.encode(punctuation, forKey: .punctuation)
    try values.encode(includeWhitespace, forKey: .includeWhitespace)
    try values.encode(includeVectors, forKey: .includeVectors)
    try values.encode(includeImages, forKey: .includeImages)
  }

  private enum CodingKeys: String, CodingKey {
    case unitKind, cjk, punctuation, includeWhitespace, includeVectors, includeImages
  }
}

public struct InlineTextUnitHit: Sendable, Hashable, Codable {
  public let atomID: String
  public let unitKind: InlineTextUnitKind
  /// Only custom units have an ID; word and sentence identities are defined by
  /// their source range within the atom.
  public let customID: String?
  /// The complete logical text-unit range, expressed in document UTF-16 coordinates.
  public let sourceRange: InlineSourceRange
  public let lineIndex: Int
  /// The visual rectangle of the clicked line fragment. A wrapped unit has one hit per fragment.
  public let rect: InlineHitRect
}

public struct InlineVectorHit: Sendable, Hashable, Codable {
  public let atomID: String
  public let assetID: InlineAssetID
  public let assetVersion: Int
  public let lineIndex: Int
  public let rect: InlineHitRect
}

public struct InlineImageHit: Sendable, Hashable, Codable {
  public let atomID: String
  public let assetID: InlineAssetID
  public let assetVersion: Int
  public let lineIndex: Int
  public let rect: InlineHitRect
  public let accessibilityLabel: String?
  public let isDecorative: Bool
}

extension InlineTextUnitHit {
  private enum CodingKeys: String, CodingKey {
    case atomID, unitKind, customID, sourceRange, lineIndex, rect
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let atomID = try values.decode(String.self, forKey: .atomID)
    let unitKind = try values.decode(InlineTextUnitKind.self, forKey: .unitKind)
    let customID = try values.decodeIfPresent(String.self, forKey: .customID)
    let sourceRange = try values.decode(InlineSourceRange.self, forKey: .sourceRange)
    let lineIndex = try values.decode(Int.self, forKey: .lineIndex)
    let rect = try values.decode(InlineHitRect.self, forKey: .rect)
    let customIdentityIsValid = unitKind == .custom ? !(customID?.isEmpty ?? true) : customID == nil
    guard !atomID.isEmpty, customIdentityIsValid, lineIndex >= 0 else {
      throw DecodingError.dataCorruptedError(
        forKey: .atomID, in: values, debugDescription: "invalid text-unit hit identity")
    }
    self.init(
      atomID: atomID, unitKind: unitKind, customID: customID,
      sourceRange: sourceRange, lineIndex: lineIndex, rect: rect)
  }
}

extension InlineVectorHit {
  private enum CodingKeys: String, CodingKey { case atomID, assetID, assetVersion, lineIndex, rect }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let atomID = try values.decode(String.self, forKey: .atomID)
    let assetID = try values.decode(InlineAssetID.self, forKey: .assetID)
    let assetVersion = try values.decode(Int.self, forKey: .assetVersion)
    let lineIndex = try values.decode(Int.self, forKey: .lineIndex)
    let rect = try values.decode(InlineHitRect.self, forKey: .rect)
    guard !atomID.isEmpty, assetVersion >= 0, lineIndex >= 0 else {
      throw DecodingError.dataCorruptedError(
        forKey: .assetVersion, in: values, debugDescription: "invalid vector hit identity")
    }
    self.init(
      atomID: atomID, assetID: assetID, assetVersion: assetVersion,
      lineIndex: lineIndex, rect: rect)
  }
}

extension InlineImageHit {
  private enum CodingKeys: String, CodingKey {
    case atomID, assetID, assetVersion, lineIndex, rect, accessibilityLabel, isDecorative
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let atomID = try values.decode(String.self, forKey: .atomID)
    let assetID = try values.decode(InlineAssetID.self, forKey: .assetID)
    let assetVersion = try values.decode(Int.self, forKey: .assetVersion)
    let lineIndex = try values.decode(Int.self, forKey: .lineIndex)
    let rect = try values.decode(InlineHitRect.self, forKey: .rect)
    let accessibilityLabel = try values.decodeIfPresent(String.self, forKey: .accessibilityLabel)
    let isDecorative = try values.decode(Bool.self, forKey: .isDecorative)
    guard !atomID.isEmpty, assetVersion >= 0, lineIndex >= 0,
      !(isDecorative && accessibilityLabel != nil)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .isDecorative, in: values,
        debugDescription: "invalid image hit identity/accessibility")
    }
    self.init(
      atomID: atomID, assetID: assetID, assetVersion: assetVersion,
      lineIndex: lineIndex, rect: rect, accessibilityLabel: accessibilityLabel,
      isDecorative: isDecorative)
  }
}

public enum InlineHitResult: Sendable, Hashable, Codable {
  case none
  case textUnit(InlineTextUnitHit)
  case vector(InlineVectorHit)
  case image(InlineImageHit)
}

/// Immutable hit-test data built from one validated layout and its preparation.
public struct InlineHitTestIndex: Sendable, Hashable, Codable {
  private let targets: [InlineHitTestTarget]
  public let profile: InlineTextUnitHitProfile
  public let preparationRevision: String

  /// Builds all hit geometry without invoking a renderer, reshaping, or rewrapping.
  public static func build(
    prepared: PreparedInlineDocument,
    layout: InlineLayoutResult,
    profile: InlineTextUnitHitProfile = .default
  ) throws -> InlineHitTestIndex {
    try layout.validate(for: prepared)
    return try buildForValidatedLayout(prepared: prepared, layout: layout, profile: profile)
  }

  /// Internal composition path after the same immutable layout/preparation
  /// pair has passed validation. Hit-specific invariants are still checked.
  static func buildForValidatedLayout(
    prepared: PreparedInlineDocument,
    layout: InlineLayoutResult,
    profile: InlineTextUnitHitProfile
  ) throws -> InlineHitTestIndex {
    var atomsByID: [String: PreparedInlineDocument.Atom] = [:]
    atomsByID.reserveCapacity(prepared.atoms.count)
    for atom in prepared.atoms {
      switch atom {
      case .text(let text): atomsByID[text.atom.id] = atom
      case .vector(let vector): atomsByID[vector.atom.id] = atom
      case .image(let image): atomsByID[image.atom.id] = atom
      }
    }
    var unitsByAtomID: [String: [TextUnitMetadata]] = [:]
    var unitRangesByAtomID: [String: [InlineSourceRange]] = [:]
    for atom in prepared.atoms {
      if case .text(let text) = atom {
        let units = try textUnitRanges(in: text, profile: profile)
        unitsByAtomID[text.atom.id] = units.map { unit in
          let graphemeIndexes = InlineSourceRangeSearch.overlappingIndices(
            in: text.shaped.graphemeRanges, with: unit.sourceRange)
          return TextUnitMetadata(
            sourceRange: unit.sourceRange,
            unitKind: unit.kind,
            customID: unit.customID,
            graphemeIndexes: graphemeIndexes
          )
        }
        unitRangesByAtomID[text.atom.id] = units.map(\.sourceRange)
      }
    }

    // The indexed range helper below assumes that one atom's positioned text
    // fragments form an ordered, non-overlapping sequence. Layout validation
    // checks ownership and boundaries, but deliberately does not enforce that
    // stronger same-atom invariant.
    var fragmentRangesByAtomID: [String: [InlineSourceRange]] = [:]
    for line in layout.lines {
      for positioned in line.atoms {
        guard positioned.kind == .text, let sourceRange = positioned.sourceRange else {
          continue
        }
        fragmentRangesByAtomID[positioned.atomID, default: []].append(sourceRange)
      }
    }
    for ranges in fragmentRangesByAtomID.values {
      let sortedRanges = ranges.sorted {
        if $0.startUTF16 != $1.startUTF16 {
          return $0.startUTF16 < $1.startUTF16
        }
        return $0.endUTF16 < $1.endUTF16
      }
      for (previous, current) in zip(sortedRanges, sortedRanges.dropFirst()) {
        guard previous.endUTF16 <= current.startUTF16 else {
          throw InlineLayoutError.invalidRenderPlan
        }
      }
    }
    fragmentRangesByAtomID.removeAll(keepingCapacity: false)

    var rawMinXByAtomID: [String: [Double?]] = [:]
    rawMinXByAtomID.reserveCapacity(prepared.atoms.count)
    for atom in prepared.atoms {
      guard case .text(let text) = atom else { continue }
      rawMinXByAtomID[text.atom.id] = buildRawMinXByGraphemeIndex(in: text)
    }

    var targets: [InlineHitTestTarget] = []
    targets.reserveCapacity(layout.lines.reduce(0) { $0 + $1.atoms.count })
    for line in layout.lines {
      for positioned in line.atoms {
        guard let atom = atomsByID[positioned.atomID] else {
          throw InlineLayoutError.invalidRenderPlan
        }
        switch atom {
        case .vector(let vector):
          guard profile.includeVectors else { continue }
          targets.append(
            .vector(
              InlineVectorHit(
                atomID: positioned.atomID,
                assetID: vector.atom.assetID,
                assetVersion: vector.atom.assetVersion,
                lineIndex: line.index,
                rect: try rect(for: positioned)
              )))
        case .image(let image):
          guard positioned.kind == .image, positioned.sourceRange == nil,
            positioned.scale == 1
          else { throw InlineLayoutError.invalidRenderPlan }
          guard profile.includeImages else { continue }
          targets.append(
            .image(
              InlineImageHit(
                atomID: positioned.atomID,
                assetID: image.atom.assetID,
                assetVersion: image.atom.assetVersion,
                lineIndex: line.index,
                rect: try rect(for: positioned),
                accessibilityLabel: image.atom.accessibilityLabel,
                isDecorative: image.atom.isDecorative
              )))
        case .text(let text):
          guard positioned.kind == .text, let fragmentRange = positioned.sourceRange else {
            throw InlineLayoutError.invalidRenderPlan
          }
          guard let words = unitsByAtomID[positioned.atomID] else {
            throw InlineLayoutError.invalidRenderPlan
          }
          guard let textUnitRanges = unitRangesByAtomID[positioned.atomID] else {
            throw InlineLayoutError.invalidRenderPlan
          }
          guard let rawMinXByGraphemeIndex = rawMinXByAtomID[positioned.atomID] else {
            throw InlineLayoutError.invalidRenderPlan
          }
          let fragmentIntervals = try visualIntervals(
            in: text,
            fragmentRange: fragmentRange,
            positioned: positioned,
            rawMinXByGraphemeIndex: rawMinXByGraphemeIndex
          )
          let fragmentGraphemeIndexes = InlineSourceRangeSearch.overlappingIndices(
            in: text.shaped.graphemeRanges, with: fragmentRange)
          let wordIndexes = InlineSourceRangeSearch.overlappingIndices(
            in: textUnitRanges, with: fragmentRange)
          for wordIndex in wordIndexes {
            let unit = words[wordIndex]
            let lowerBound = max(
              unit.graphemeIndexes.lowerBound, fragmentGraphemeIndexes.lowerBound)
            let upperBound = min(
              unit.graphemeIndexes.upperBound, fragmentGraphemeIndexes.upperBound)
            guard lowerBound < upperBound else { continue }
            var minX = Double.infinity
            var maxX = -Double.infinity
            for clusterIndex in lowerBound..<upperBound {
              guard let interval = fragmentIntervals[clusterIndex] else { continue }
              minX = min(minX, interval.minX)
              maxX = max(maxX, interval.maxX)
            }
            guard minX.isFinite, maxX.isFinite, maxX > minX else { continue }
            let hitRect = try InlineHitRect(
              minX: minX,
              minY: positioned.baselineY - positioned.metrics.baselineOffset
                - positioned.metrics.ascent,
              width: maxX - minX,
              height: positioned.height
            )
            targets.append(
              .textUnit(
                InlineTextUnitHit(
                  atomID: positioned.atomID,
                  unitKind: unit.unitKind,
                  customID: unit.customID,
                  sourceRange: unit.sourceRange,
                  lineIndex: line.index,
                  rect: hitRect
                )))
          }
        }
      }
    }
    return InlineHitTestIndex(
      targets: targets, profile: profile, preparationRevision: prepared.revision)
  }

  /// Builds hit geometry for an incremental layout section without requiring
  /// a whole-document preparation snapshot. The caller must pass every
  /// prepared atom referenced by `lines`; lines outside the section are not
  /// considered and are therefore never rescanned.
  public static func buildChunk(
    preparedAtoms: [PreparedInlineDocument.Atom],
    lines: [InlineLayoutLine],
    profile: InlineTextUnitHitProfile = .default,
    preparationRevision: String
  ) throws -> InlineHitTestChunk {
    guard !preparationRevision.isEmpty else { throw InlineLayoutError.invalidRenderPlan }

    var atomsByID: [String: PreparedInlineDocument.Atom] = [:]
    atomsByID.reserveCapacity(preparedAtoms.count)
    for atom in preparedAtoms {
      let id: String
      switch atom {
      case .text(let text): id = text.atom.id
      case .vector(let vector): id = vector.atom.id
      case .image(let image): id = image.atom.id
      }
      guard atomsByID.updateValue(atom, forKey: id) == nil else {
        throw InlineLayoutError.duplicateIdentifier(id)
      }
    }

    var unitsByAtomID: [String: [TextUnitMetadata]] = [:]
    var unitRangesByAtomID: [String: [InlineSourceRange]] = [:]
    for atom in preparedAtoms {
      if case .text(let text) = atom {
        let units = try textUnitRanges(in: text, profile: profile)
        unitsByAtomID[text.atom.id] = units.map { unit in
          let graphemeIndexes = InlineSourceRangeSearch.overlappingIndices(
            in: text.shaped.graphemeRanges, with: unit.sourceRange)
          return TextUnitMetadata(
            sourceRange: unit.sourceRange,
            unitKind: unit.kind,
            customID: unit.customID,
            graphemeIndexes: graphemeIndexes
          )
        }
        unitRangesByAtomID[text.atom.id] = units.map(\.sourceRange)
      }
    }

    var fragmentRangesByAtomID: [String: [InlineSourceRange]] = [:]
    for line in lines {
      for positioned in line.atoms {
        guard positioned.kind == .text, let sourceRange = positioned.sourceRange else {
          continue
        }
        fragmentRangesByAtomID[positioned.atomID, default: []].append(sourceRange)
      }
    }
    for ranges in fragmentRangesByAtomID.values {
      let sortedRanges = ranges.sorted {
        if $0.startUTF16 != $1.startUTF16 {
          return $0.startUTF16 < $1.startUTF16
        }
        return $0.endUTF16 < $1.endUTF16
      }
      for (previous, current) in zip(sortedRanges, sortedRanges.dropFirst()) {
        guard previous.endUTF16 <= current.startUTF16 else {
          throw InlineLayoutError.invalidRenderPlan
        }
      }
    }

    var rawMinXByAtomID: [String: [Double?]] = [:]
    rawMinXByAtomID.reserveCapacity(preparedAtoms.count)
    for atom in preparedAtoms {
      guard case .text(let text) = atom else { continue }
      rawMinXByAtomID[text.atom.id] = buildRawMinXByGraphemeIndex(in: text)
    }

    var targets: [InlineHitTestTarget] = []
    targets.reserveCapacity(lines.reduce(0) { $0 + $1.atoms.count })
    for line in lines {
      guard line.index >= 0 else { throw InlineLayoutError.invalidRenderPlan }
      for positioned in line.atoms {
        guard positioned.lineIndex == line.index,
          let atom = atomsByID[positioned.atomID]
        else { throw InlineLayoutError.invalidRenderPlan }
        switch atom {
        case .vector(let vector):
          guard positioned.kind == .vector, positioned.sourceRange == nil else {
            throw InlineLayoutError.invalidRenderPlan
          }
          let expectedAdvance = vector.atom.metrics.advance * positioned.scale
          let expectedAscent = vector.atom.metrics.ascent * positioned.scale
          let expectedDescent = vector.atom.metrics.descent * positioned.scale
          let expectedBaselineOffset = vector.atom.metrics.baselineOffset * positioned.scale
          let tolerance = 1.0 / 64.0
          guard abs(positioned.width - expectedAdvance) <= tolerance,
            abs(positioned.metrics.advance - expectedAdvance) <= tolerance,
            abs(positioned.metrics.ascent - expectedAscent) <= tolerance,
            abs(positioned.metrics.descent - expectedDescent) <= tolerance,
            abs(positioned.metrics.baselineOffset - expectedBaselineOffset) <= tolerance,
            abs(positioned.height - expectedAscent - expectedDescent) <= tolerance
          else { throw InlineLayoutError.invalidRenderPlan }
          guard profile.includeVectors else { continue }
          targets.append(
            .vector(
              InlineVectorHit(
                atomID: positioned.atomID,
                assetID: vector.atom.assetID,
                assetVersion: vector.atom.assetVersion,
                lineIndex: line.index,
                rect: try rect(for: positioned)
              )))
        case .image(let image):
          guard positioned.kind == .image,
            positioned.scale == 1,
            positioned.sourceRange == nil
          else { throw InlineLayoutError.invalidRenderPlan }
          let expectedAdvance = image.atom.metrics.advance
          let expectedAscent = image.atom.metrics.ascent
          let expectedDescent = image.atom.metrics.descent
          let expectedBaselineOffset = image.atom.metrics.baselineOffset
          let tolerance = 1.0 / 64.0
          guard abs(positioned.width - expectedAdvance) <= tolerance,
            abs(positioned.metrics.advance - expectedAdvance) <= tolerance,
            abs(positioned.metrics.ascent - expectedAscent) <= tolerance,
            abs(positioned.metrics.descent - expectedDescent) <= tolerance,
            abs(positioned.metrics.baselineOffset - expectedBaselineOffset) <= tolerance,
            abs(positioned.height - expectedAscent - expectedDescent) <= tolerance
          else { throw InlineLayoutError.invalidRenderPlan }
          guard profile.includeImages else { continue }
          targets.append(
            .image(
              InlineImageHit(
                atomID: positioned.atomID,
                assetID: image.atom.assetID,
                assetVersion: image.atom.assetVersion,
                lineIndex: line.index,
                rect: try rect(for: positioned),
                accessibilityLabel: image.atom.accessibilityLabel,
                isDecorative: image.atom.isDecorative
              )))
        case .text(let text):
          guard positioned.kind == .text, positioned.scale == 1,
            let fragmentRange = positioned.sourceRange,
            fragmentRange.startUTF16 >= text.sourceRange.startUTF16,
            fragmentRange.endUTF16 <= text.sourceRange.endUTF16
          else { throw InlineLayoutError.invalidRenderPlan }
          try text.validateSourceRangeBoundaries(fragmentRange)
          guard let words = unitsByAtomID[positioned.atomID],
            let textUnitRanges = unitRangesByAtomID[positioned.atomID],
            let rawMinXByGraphemeIndex = rawMinXByAtomID[positioned.atomID]
          else { throw InlineLayoutError.invalidRenderPlan }
          let fragmentIntervals = try visualIntervals(
            in: text,
            fragmentRange: fragmentRange,
            positioned: positioned,
            rawMinXByGraphemeIndex: rawMinXByGraphemeIndex
          )
          let fragmentGraphemeIndexes = InlineSourceRangeSearch.overlappingIndices(
            in: text.shaped.graphemeRanges, with: fragmentRange)
          let wordIndexes = InlineSourceRangeSearch.overlappingIndices(
            in: textUnitRanges, with: fragmentRange)
          for wordIndex in wordIndexes {
            let unit = words[wordIndex]
            let lowerBound = max(
              unit.graphemeIndexes.lowerBound, fragmentGraphemeIndexes.lowerBound)
            let upperBound = min(
              unit.graphemeIndexes.upperBound, fragmentGraphemeIndexes.upperBound)
            guard lowerBound < upperBound else { continue }
            var minX = Double.infinity
            var maxX = -Double.infinity
            for clusterIndex in lowerBound..<upperBound {
              guard let interval = fragmentIntervals[clusterIndex] else { continue }
              minX = min(minX, interval.minX)
              maxX = max(maxX, interval.maxX)
            }
            guard minX.isFinite, maxX.isFinite, maxX > minX else { continue }
            let hitRect = try InlineHitRect(
              minX: minX,
              minY: positioned.baselineY - positioned.metrics.baselineOffset
                - positioned.metrics.ascent,
              width: maxX - minX,
              height: positioned.height
            )
            targets.append(
              .textUnit(
                InlineTextUnitHit(
                  atomID: positioned.atomID,
                  unitKind: unit.unitKind,
                  customID: unit.customID,
                  sourceRange: unit.sourceRange,
                  lineIndex: line.index,
                  rect: hitRect
                )))
          }
        }
      }
    }
    return InlineHitTestChunk(
      targets: targets, profile: profile, preparationRevision: preparationRevision)
  }

  /// Returns the first deterministic target containing the point, or `.none`.
  public func hitTest(_ point: InlineHitPoint) -> InlineHitResult {
    for target in targets {
      switch target {
      case .textUnit(let word):
        if word.rect.contains(point) { return .textUnit(word) }
      case .vector(let vector):
        if vector.rect.contains(point) { return .vector(vector) }
      case .image(let image):
        if image.rect.contains(point) { return .image(image) }
      }
    }
    return .none
  }

  /// Returns every visual fragment for one logical text-unit identity in canonical
  /// line/target order. Consumers use this to derive selection decoration;
  /// they must not reconstruct geometry from the source string.
  public func textUnitHits(
    atomID: String,
    unitKind: InlineTextUnitKind? = nil,
    customID: String? = nil,
    sourceRange: InlineSourceRange
  ) -> [InlineTextUnitHit] {
    targets.compactMap { target in
      guard case .textUnit(let hit) = target,
        hit.atomID == atomID,
        hit.sourceRange == sourceRange,
        unitKind == nil || hit.unitKind == unitKind,
        customID == nil || hit.customID == customID
      else { return nil }
      return hit
    }
  }

  public var allTextUnitHits: [InlineTextUnitHit] {
    targets.compactMap { target in
      guard case .textUnit(let hit) = target else { return nil }
      return hit
    }
  }

  private static func rect(for positioned: PositionedInlineAtom) throws -> InlineHitRect {
    try InlineHitRect(
      minX: positioned.originX,
      minY: positioned.baselineY - positioned.metrics.baselineOffset
        - positioned.metrics.ascent,
      width: positioned.width,
      height: positioned.height
    )
  }

  private struct VisualInterval {
    let minX: Double
    let maxX: Double
  }

  private struct TextUnitMetadata {
    let sourceRange: InlineSourceRange
    let unitKind: InlineTextUnitKind
    let customID: String?
    let graphemeIndexes: Range<Int>
  }

  private struct TextUnitCandidate {
    let sourceRange: InlineSourceRange
    let kind: InlineTextUnitKind
    let customID: String?

    init(
      sourceRange: InlineSourceRange,
      kind: InlineTextUnitKind,
      customID: String? = nil
    ) {
      self.sourceRange = sourceRange
      self.kind = kind
      self.customID = customID
    }
  }

  private struct RawPositionEvent {
    let start: Int
    let end: Int
    let positionX: Double
    let positionY: Double
    let glyphID: UInt16
    let sourceUTF16Index: Int
  }

  private struct RawPositionMinHeap {
    private var storage: [RawPositionEvent] = []

    var minimum: RawPositionEvent? { storage.first }

    mutating func insert(_ event: RawPositionEvent) {
      storage.append(event)
      var child = storage.count - 1
      while child > 0 {
        let parent = (child - 1) / 2
        guard InlineHitTestIndex.rawEventPrecedes(storage[child], storage[parent]) else {
          break
        }
        storage.swapAt(child, parent)
        child = parent
      }
    }

    @discardableResult
    mutating func removeMinimum() -> RawPositionEvent? {
      guard !storage.isEmpty else { return nil }
      if storage.count == 1 { return storage.removeLast() }
      let result = storage[0]
      let last = storage.removeLast()
      storage[0] = last

      var parent = 0
      while true {
        let left = parent * 2 + 1
        guard left < storage.count else { break }
        var child = left
        let right = left + 1
        if right < storage.count,
          InlineHitTestIndex.rawEventPrecedes(storage[right], storage[left])
        {
          child = right
        }
        guard InlineHitTestIndex.rawEventPrecedes(storage[child], storage[parent]) else {
          break
        }
        storage.swapAt(parent, child)
        parent = child
      }
      return result
    }
  }

  private static func rawEventPrecedes(
    _ lhs: RawPositionEvent, _ rhs: RawPositionEvent
  ) -> Bool {
    if lhs.positionX != rhs.positionX { return lhs.positionX < rhs.positionX }
    if lhs.start != rhs.start { return lhs.start < rhs.start }
    if lhs.end != rhs.end { return lhs.end < rhs.end }
    if lhs.glyphID != rhs.glyphID { return lhs.glyphID < rhs.glyphID }
    if lhs.positionY != rhs.positionY { return lhs.positionY < rhs.positionY }
    return lhs.sourceUTF16Index < rhs.sourceUTF16Index
  }

  private static func buildRawMinXByGraphemeIndex(
    in text: PreparedInlineText
  ) -> [Double?] {
    let graphemeRanges = text.shaped.graphemeRanges
    var events: [RawPositionEvent] = []
    let glyphCount = text.shaped.runs.reduce(0) { $0 + $1.glyphs.count }
    events.reserveCapacity(glyphCount)
    for run in text.shaped.runs {
      for glyph in run.glyphs {
        let graphemeIndexes = InlineSourceRangeSearch.overlappingIndices(
          in: graphemeRanges, with: glyph.sourceRange)
        guard let start = graphemeIndexes.first else { continue }
        events.append(
          RawPositionEvent(
            start: start,
            end: graphemeIndexes.upperBound,
            positionX: glyph.positionX,
            positionY: glyph.positionY,
            glyphID: glyph.glyphID,
            sourceUTF16Index: glyph.sourceUTF16Index
          ))
      }
    }
    events.sort {
      if $0.start != $1.start { return $0.start < $1.start }
      if $0.end != $1.end { return $0.end < $1.end }
      if $0.glyphID != $1.glyphID { return $0.glyphID < $1.glyphID }
      if $0.sourceUTF16Index != $1.sourceUTF16Index {
        return $0.sourceUTF16Index < $1.sourceUTF16Index
      }
      if $0.positionY != $1.positionY { return $0.positionY < $1.positionY }
      return $0.positionX < $1.positionX
    }

    var result = [Double?](repeating: nil, count: graphemeRanges.count)
    var heap = RawPositionMinHeap()
    var nextEvent = 0
    for graphemeIndex in graphemeRanges.indices {
      while nextEvent < events.count && events[nextEvent].start <= graphemeIndex {
        heap.insert(events[nextEvent])
        nextEvent += 1
      }
      while let minimum = heap.minimum, minimum.end <= graphemeIndex {
        _ = heap.removeMinimum()
      }
      result[graphemeIndex] = heap.minimum?.positionX
    }
    return result
  }

  private static func visualIntervals(
    in text: PreparedInlineText,
    fragmentRange: InlineSourceRange,
    positioned: PositionedInlineAtom,
    rawMinXByGraphemeIndex: [Double?]
  ) throws -> [Int: VisualInterval] {
    let graphemeIndexes = InlineSourceRangeSearch.overlappingIndices(
      in: text.shaped.graphemeRanges, with: fragmentRange)
    guard !graphemeIndexes.isEmpty else { return [:] }

    var fallbackX = positioned.originX
    var fallback: [Int: VisualInterval] = [:]
    for index in graphemeIndexes {
      let width = max(0, text.shaped.graphemeAdvances[index])
      if width > 0 {
        let fallbackMaxX = fallbackX + width
        guard fallbackX.isFinite, fallbackMaxX.isFinite, fallbackMaxX > fallbackX else {
          throw InlineLayoutError.invalidRenderPlan
        }
        fallback[index] = VisualInterval(minX: fallbackX, maxX: fallbackMaxX)
      }
      fallbackX += width
      guard fallbackX.isFinite else { throw InlineLayoutError.invalidRenderPlan }
    }

    // The glyph-to-grapheme minimum is computed once per text atom. Restricting
    // it to this fragment here preserves the old fragment-local scaling while
    // avoiding another glyph scan for every wrapped fragment.
    var rawMin = Double.infinity
    var rawMax = -Double.infinity
    for index in graphemeIndexes {
      guard let rawX = rawMinXByGraphemeIndex[index] else { continue }
      guard rawX.isFinite else { throw InlineLayoutError.invalidRenderPlan }
      rawMin = min(rawMin, rawX)
      let width = max(0, text.shaped.graphemeAdvances[index])
      let rawEndX = rawX + width
      guard rawEndX.isFinite, width == 0 || rawEndX > rawX else {
        throw InlineLayoutError.invalidRenderPlan
      }
      rawMax = max(rawMax, rawEndX)
    }
    guard rawMin.isFinite, rawMax.isFinite else { return fallback }
    let rawWidth = rawMax - rawMin
    guard rawWidth.isFinite, rawWidth >= 0 else {
      throw InlineLayoutError.invalidRenderPlan
    }
    let scale = rawWidth > 0 ? positioned.width / rawWidth : 1
    guard scale.isFinite, scale >= 0 else { throw InlineLayoutError.invalidRenderPlan }
    var result: [Int: VisualInterval] = [:]
    result.reserveCapacity(fallback.count)
    for (index, interval) in fallback {
      guard let rawX = rawMinXByGraphemeIndex[index] else {
        result[index] = interval
        continue
      }
      let width = interval.maxX - interval.minX
      let scaledMin = positioned.originX + (rawX - rawMin) * scale
      let scaledWidth = width * scale
      let scaledMax = scaledMin + scaledWidth
      guard scaledMin.isFinite, scaledWidth.isFinite, scaledMax.isFinite,
        scaledMax >= scaledMin, scale == 0 || scaledMax > scaledMin
      else {
        throw InlineLayoutError.invalidRenderPlan
      }
      result[index] = VisualInterval(minX: scaledMin, maxX: scaledMax)
    }
    return result
  }

  private static func textUnitRanges(
    in text: PreparedInlineText, profile: InlineTextUnitHitProfile
  ) throws -> [TextUnitCandidate] {
    switch profile.unitKind {
    case .custom:
      return try text.atom.customTextUnits.map {
        TextUnitCandidate(
          sourceRange: try InlineSourceRange(
            startUTF16: $0.sourceRange.startUTF16 + text.sourceRange.startUTF16,
            endUTF16: $0.sourceRange.endUTF16 + text.sourceRange.startUTF16),
          kind: .custom,
          customID: $0.id)
      }
    case .sentence:
      return try sentenceCandidates(in: text.atom.text, offset: text.sourceRange.startUTF16)
    case .word:
      break
    }
    let graphemeRanges = text.shaped.graphemeRanges
    var candidates = try unicodeWordCandidates(text.atom.text, offset: text.sourceRange.startUTF16)
    if profile.includeWhitespace {
      var whitespaceStart: InlineSourceRange?
      for (index, range) in graphemeRanges.enumerated() {
        let grapheme = text.graphemes[index]
        if isWhitespace(grapheme) {
          if whitespaceStart == nil { whitespaceStart = range }
        } else if let completed = whitespaceStart {
          candidates.append(completed)
          whitespaceStart = nil
        }
      }
      if let whitespaceStart { candidates.append(whitespaceStart) }
    }
    var result: [TextUnitCandidate] = []
    var seen = Set<InlineSourceRange>()
    for candidate in candidates {
      let indexes = InlineSourceRangeSearch.overlappingIndices(in: graphemeRanges, with: candidate)
      var current: InlineSourceRange?
      for index in indexes {
        let grapheme = text.graphemes[index]
        let range = graphemeRanges[index]
        if isWhitespace(grapheme) {
          if profile.includeWhitespace {
            if let existing = current {
              current = try InlineSourceRange(
                startUTF16: existing.startUTF16, endUTF16: range.endUTF16)
            } else {
              current = range
            }
          } else if let completed = current {
            append(TextUnitCandidate(sourceRange: completed, kind: .word), to: &result, seen: &seen)
            current = nil
          }
          continue
        }
        guard isWordLike(grapheme) else {
          if let current {
            append(TextUnitCandidate(sourceRange: current, kind: .word), to: &result, seen: &seen)
          }
          current = nil
          continue
        }
        if isCJK(grapheme) {
          if let current {
            append(TextUnitCandidate(sourceRange: current, kind: .word), to: &result, seen: &seen)
          }
          current = nil
          if profile.cjk == .eachGrapheme {
            append(TextUnitCandidate(sourceRange: range, kind: .word), to: &result, seen: &seen)
          }
        } else if let existing = current {
          current = try InlineSourceRange(
            startUTF16: existing.startUTF16, endUTF16: range.endUTF16)
        } else {
          current = range
        }
      }
      if let current {
        append(TextUnitCandidate(sourceRange: current, kind: .word), to: &result, seen: &seen)
      }
    }
    return result.sorted {
      if $0.sourceRange.startUTF16 != $1.sourceRange.startUTF16 {
        return $0.sourceRange.startUTF16 < $1.sourceRange.startUTF16
      }
      return $0.sourceRange.endUTF16 < $1.sourceRange.endUTF16
    }
  }

  private static func sentenceCandidates(in text: String, offset: Int) throws
    -> [TextUnitCandidate]
  {
    try TextUnitBoundaryAnalyzer.sentenceRanges(in: text).map { range in
      TextUnitCandidate(
        sourceRange: try InlineSourceRange(
          startUTF16: range.startUTF16 + offset,
          endUTF16: range.endUTF16 + offset
        ),
        kind: .sentence
      )
    }
  }

  private static func unicodeWordCandidates(_ text: String, offset: Int) throws
    -> [InlineSourceRange]
  {
    try TextUnitBoundaryAnalyzer.wordRanges(in: text).map { range in
      try InlineSourceRange(
        startUTF16: range.startUTF16 + offset,
        endUTF16: range.endUTF16 + offset
      )
    }
  }

  private static func append(
    _ candidate: TextUnitCandidate,
    to result: inout [TextUnitCandidate],
    seen: inout Set<InlineSourceRange>
  ) {
    guard candidate.sourceRange.lengthUTF16 > 0,
      seen.insert(candidate.sourceRange).inserted
    else { return }
    result.append(candidate)
  }

  private static func isWhitespace(_ grapheme: String) -> Bool {
    TextUnitBoundaryAnalyzer.isWhitespace(grapheme)
  }

  private static func isWordLike(_ grapheme: String) -> Bool {
    TextUnitBoundaryAnalyzer.isWordLike(grapheme)
  }

  private static func isCJK(_ grapheme: String) -> Bool {
    TextUnitBoundaryAnalyzer.isCJK(grapheme)
  }

}

extension InlineHitTestIndex {
  private enum CodingKeys: String, CodingKey { case targets, profile, preparationRevision }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let targets = try values.decode([InlineHitTestTarget].self, forKey: .targets)
    let profile = try values.decode(InlineTextUnitHitProfile.self, forKey: .profile)
    let preparationRevision = try values.decode(String.self, forKey: .preparationRevision)
    guard !preparationRevision.isEmpty,
      Self.targetsMatchProfile(targets, profile: profile)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .targets, in: values,
        debugDescription: "hit-test index targets do not match the stored profile/revision")
    }
    self.init(targets: targets, profile: profile, preparationRevision: preparationRevision)
  }

  private static func targetsMatchProfile(
    _ targets: [InlineHitTestTarget], profile: InlineTextUnitHitProfile
  ) -> Bool {
    targets.allSatisfy { target in
      switch target {
      case .textUnit(let hit): return hit.unitKind == profile.unitKind
      case .vector: return profile.includeVectors
      case .image: return profile.includeImages
      }
    }
  }
}

private enum InlineHitTestTarget: Sendable, Hashable, Codable {
  case textUnit(InlineTextUnitHit)
  case vector(InlineVectorHit)
  case image(InlineImageHit)
}

/// Hit geometry for one retained append-renderer section. It is intentionally
/// immutable so committed sections can be retained without rebuilding.
public struct InlineHitTestChunk: Sendable, Hashable, Codable {
  fileprivate let targets: [InlineHitTestTarget]
  public let profile: InlineTextUnitHitProfile
  public let preparationRevision: String

  public func hitTest(_ point: InlineHitPoint) -> InlineHitResult {
    for target in targets {
      switch target {
      case .textUnit(let word):
        if word.rect.contains(point) { return .textUnit(word) }
      case .vector(let vector):
        if vector.rect.contains(point) { return .vector(vector) }
      case .image(let image):
        if image.rect.contains(point) { return .image(image) }
      }
    }
    return .none
  }

  /// Conservative union of every exact target rectangle in this chunk.
  /// Append renderers use it only for section broad-phase candidate
  /// selection; the exact half-open target checks above remain authoritative.
  package func targetBounds() throws -> InlineHitRect? {
    var result: InlineHitRect?
    for target in targets {
      let bounds: InlineHitRect
      switch target {
      case .textUnit(let word): bounds = word.rect
      case .vector(let vector): bounds = vector.rect
      case .image(let image): bounds = image.rect
      }
      result = try InlineRenderSectionRecord.union(result, bounds)
    }
    return result
  }
}

extension InlineHitTestChunk {
  private enum CodingKeys: String, CodingKey { case targets, profile, preparationRevision }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let targets = try values.decode([InlineHitTestTarget].self, forKey: .targets)
    let profile = try values.decode(InlineTextUnitHitProfile.self, forKey: .profile)
    let preparationRevision = try values.decode(String.self, forKey: .preparationRevision)
    let targetsMatchProfile = targets.allSatisfy { target in
      switch target {
      case .textUnit(let hit): return hit.unitKind == profile.unitKind
      case .vector: return profile.includeVectors
      case .image: return profile.includeImages
      }
    }
    guard !preparationRevision.isEmpty, targetsMatchProfile else {
      throw DecodingError.dataCorruptedError(
        forKey: .targets, in: values,
        debugDescription: "hit-test chunk targets do not match the stored profile/revision")
    }
    self.init(targets: targets, profile: profile, preparationRevision: preparationRevision)
  }
}
