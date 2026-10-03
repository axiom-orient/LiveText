import Foundation

/// Stable identity for one reveal unit.
public struct InlineRevealUnitID: Sendable, Hashable, Codable, CustomStringConvertible {
  public let rawValue: String

  public init(rawValue: String) throws {
    guard !rawValue.isEmpty else { throw InlineLayoutError.invalidIdentifier }
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    try self.init(rawValue: value)
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.singleValueContainer()
    try values.encode(rawValue)
  }

  public var description: String { rawValue }
}

/// Source or prepared geometry represented by a reveal unit.
public enum InlineRevealUnitKind: String, Sendable, Hashable, Codable {
  case grapheme
  case textUnit
  case sentence
  case shapedGlyph
  case semanticStroke
  case nativeAtomic
  case timingOnly
  case vectorPath
  case image
}

/// Immutable timing and source mapping for one reveal unit.
public struct InlineRevealUnit: Sendable, Hashable, Codable {
  private enum CodingKeys: String, CodingKey {
    case id, kind, atomID, sourceRange, startTime, duration
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(InlineRevealUnitID.self, forKey: .id),
      kind: values.decode(InlineRevealUnitKind.self, forKey: .kind),
      atomID: values.decode(String.self, forKey: .atomID),
      sourceRange: values.decodeIfPresent(InlineSourceRange.self, forKey: .sourceRange),
      startTime: values.decode(Double.self, forKey: .startTime),
      duration: values.decode(Double.self, forKey: .duration)
    )
  }

  public let id: InlineRevealUnitID
  public let kind: InlineRevealUnitKind
  public let atomID: String
  public let sourceRange: InlineSourceRange?
  public let startTime: Double
  public let duration: Double

  public init(
    id: InlineRevealUnitID,
    kind: InlineRevealUnitKind,
    atomID: String,
    sourceRange: InlineSourceRange? = nil,
    startTime: Double,
    duration: Double
  ) throws {
    guard !atomID.isEmpty else { throw InlineLayoutError.invalidIdentifier }
    guard startTime.isFinite, startTime >= 0,
      duration.isFinite, duration > 0
    else {
      throw InlineLayoutError.invalidMetric(name: "reveal timing", value: duration)
    }
    self.id = id
    self.kind = kind
    self.atomID = atomID
    self.sourceRange = sourceRange
    self.startTime = startTime
    self.duration = duration
  }
}

/// Immutable reveal schedule consumed by a renderer at frame time.
public struct InlineRevealPlan: Sendable, Hashable, Codable {
  public let units: [InlineRevealUnit]
  public let duration: Double

  public init(units: [InlineRevealUnit]) throws {
    var identifiers = Set<InlineRevealUnitID>()
    var endTime = 0.0
    for unit in units {
      guard identifiers.insert(unit.id).inserted else {
        throw InlineLayoutError.duplicateIdentifier(unit.id.rawValue)
      }
      let end = unit.startTime + unit.duration
      guard end.isFinite else {
        throw InlineLayoutError.invalidMetric(name: "reveal duration", value: end)
      }
      endTime = max(endTime, end)
    }
    self.units = units
    self.duration = endTime
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(units: values.decode([InlineRevealUnit].self, forKey: .units))
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(units, forKey: .units)
    try values.encode(duration, forKey: .duration)
  }

  private enum CodingKeys: String, CodingKey { case units, duration }
}

/// A renderer-independent, validated scalar reveal phase.
///
/// Keeping the phase as one value avoids putting clocks, tasks, or mutable
/// progress maps in the renderer-neutral layer.  Codable deliberately uses a
/// scalar representation so malformed persisted values are rejected by the
/// same initializer as in-memory values.
public struct InlineRenderRevealPhase: Sendable, Hashable, Codable {
  public let rawValue: Double

  public static let zero = InlineRenderRevealPhase(unchecked: 0)
  public static let complete = InlineRenderRevealPhase(unchecked: 1)

  public init(rawValue: Double) throws {
    guard rawValue.isFinite, (0...1).contains(rawValue) else {
      throw InlineLayoutError.invalidMetric(name: "reveal phase", value: rawValue)
    }
    self.rawValue = rawValue
  }

  public init(_ rawValue: Double) throws {
    try self.init(rawValue: rawValue)
  }

  private init(unchecked rawValue: Double) {
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    try self.init(rawValue: decoder.singleValueContainer().decode(Double.self))
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.singleValueContainer()
    try values.encode(rawValue)
  }
}

/// One text activation unit retained by the compiled renderer schedule.
/// Source ranges remain in document UTF-16 coordinates and therefore stay
/// stable when the same prepared document is laid out at another width.
public struct InlineRenderRevealTextUnit: Sendable, Hashable {
  public let id: InlineRevealUnitID
  public let kind: InlineRevealUnitKind
  public let sourceRange: InlineSourceRange
  public let startTime: Double
  public let duration: Double

  public init(
    id: InlineRevealUnitID,
    kind: InlineRevealUnitKind,
    sourceRange: InlineSourceRange,
    startTime: Double,
    duration: Double
  ) throws {
    guard startTime.isFinite, startTime >= 0,
      duration.isFinite, duration > 0
    else {
      throw InlineLayoutError.invalidMetric(name: "reveal timing", value: duration)
    }
    self.id = id
    self.kind = kind
    self.sourceRange = sourceRange
    self.startTime = startTime
    self.duration = duration
  }

  public init(unit: InlineRevealUnit) throws {
    guard let sourceRange = unit.sourceRange else {
      throw InlineLayoutError.invalidRenderPlan
    }
    try self.init(
      id: unit.id,
      kind: unit.kind,
      sourceRange: sourceRange,
      startTime: unit.startTime,
      duration: unit.duration
    )
  }

}

/// All text activation units for one stable atom identity.
public struct InlineRenderRevealTextActivation: Sendable, Hashable {
  public let atomID: String
  public let units: [InlineRenderRevealTextUnit]
  public let duration: Double
  private let unitIndexByID: [InlineRevealUnitID: Int]

  public init(atomID: String, units: [InlineRenderRevealTextUnit]) throws {
    guard !atomID.isEmpty, !units.isEmpty else {
      throw InlineLayoutError.invalidRenderPlan
    }
    var unitIndexByID: [InlineRevealUnitID: Int] = [:]
    unitIndexByID.reserveCapacity(units.count)
    var previousStart = 0.0
    var previousSourceStart = 0
    var previousSourceEnd = 0
    var duration = 0.0
    for (index, unit) in units.enumerated() {
      guard unitIndexByID.updateValue(index, forKey: unit.id) == nil,
        unit.startTime >= previousStart,
        unit.sourceRange.startUTF16 >= previousSourceStart,
        unit.sourceRange.endUTF16 > unit.sourceRange.startUTF16,
        unit.sourceRange.endUTF16 >= previousSourceEnd
      else {
        throw InlineLayoutError.invalidRenderPlan
      }
      previousStart = unit.startTime
      previousSourceStart = unit.sourceRange.startUTF16
      previousSourceEnd = unit.sourceRange.endUTF16
      let end = unit.startTime + unit.duration
      guard end.isFinite else {
        throw InlineLayoutError.invalidRenderPlan
      }
      duration = max(duration, end)
    }
    self.atomID = atomID
    self.units = units
    self.duration = duration
    self.unitIndexByID = unitIndexByID
  }

  /// Returns the greatest progress of a unit intersecting the source range.
  /// This method only scans immutable schedule storage; it allocates no
  /// per-frame collection and never reshapes or materializes render data.
  public func progress(at time: Double, sourceRange: InlineSourceRange) -> Double {
    let clampedTime = min(max(time, 0), duration)
    var result = 0.0
    var lowerBound = 0
    var upperBound = units.count
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      if units[middle].sourceRange.endUTF16 <= sourceRange.startUTF16 {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    for index in lowerBound..<units.count {
      let unit = units[index]
      if unit.sourceRange.startUTF16 >= sourceRange.endUTF16 { break }
      guard rangesOverlap(unit.sourceRange, sourceRange) else { continue }
      let value = min(1, max(0, (clampedTime - unit.startTime) / unit.duration))
      result = max(result, value)
      if result == 1 { return result }
    }
    return result
  }

  /// Returns progress for one prepared unit identity. This is distinct from
  /// source-range sampling because semantic strokes may share one range.
  public func progress(at time: Double, unitID: InlineRevealUnitID) -> Double {
    guard let index = unitIndexByID[unitID] else { return 0 }
    let unit = units[index]
    let clampedTime = min(max(time, 0), duration)
    return min(1, max(0, (clampedTime - unit.startTime) / unit.duration))
  }

  public func isVisible(at time: Double, sourceRange: InlineSourceRange) -> Bool {
    progress(at: time, sourceRange: sourceRange) > 0
  }

  public func progress(
    at phase: InlineRenderRevealPhase, sourceRange: InlineSourceRange
  ) -> Double {
    progress(at: duration * phase.rawValue, sourceRange: sourceRange)
  }

  public func progress(
    at phase: InlineRenderRevealPhase, unitID: InlineRevealUnitID
  ) -> Double {
    progress(at: duration * phase.rawValue, unitID: unitID)
  }
}

/// One vector-path command activation.  Only command metadata is retained;
/// the actual path remains an adapter-owned asset and is never copied into a
/// frame sample.
public struct InlineRenderRevealVectorUnit: Sendable, Hashable {
  public let commandIndex: Int
  public let startTime: Double
  public let duration: Double

  public init(commandIndex: Int, startTime: Double, duration: Double) throws {
    guard commandIndex >= 0,
      startTime.isFinite, startTime >= 0,
      duration.isFinite, duration > 0
    else {
      throw InlineLayoutError.invalidRenderPlan
    }
    self.commandIndex = commandIndex
    self.startTime = startTime
    self.duration = duration
  }

  public init(unit: InlinePathRevealUnit, startTime: Double) throws {
    try self.init(
      commandIndex: unit.commandIndex,
      startTime: startTime,
      duration: unit.duration
    )
  }

}

/// All vector command activations for one stable atom identity.
public struct InlineRenderRevealVectorActivation: Sendable, Hashable {
  public let atomID: String
  public let assetID: InlineAssetID
  public let assetVersion: Int
  public let units: [InlineRenderRevealVectorUnit]
  public let duration: Double

  public init(
    atomID: String,
    assetID: InlineAssetID,
    assetVersion: Int,
    units: [InlineRenderRevealVectorUnit]
  ) throws {
    guard !atomID.isEmpty, assetVersion >= 0, !units.isEmpty else {
      throw InlineLayoutError.invalidRenderPlan
    }
    var commandIndexes = Set<Int>()
    var previousCommandIndex = -1
    var previousCompletion = 0.0
    var duration = 0.0
    for unit in units {
      guard commandIndexes.insert(unit.commandIndex).inserted,
        unit.commandIndex > previousCommandIndex,
        unit.startTime >= previousCompletion
      else {
        throw InlineLayoutError.invalidRenderPlan
      }
      previousCommandIndex = unit.commandIndex
      guard unit.startTime <= Double.greatestFiniteMagnitude - unit.duration else {
        throw InlineLayoutError.invalidRenderPlan
      }
      let end = unit.startTime + unit.duration
      guard end.isFinite else {
        throw InlineLayoutError.invalidRenderPlan
      }
      previousCompletion = end
      duration = max(duration, end)
    }
    self.atomID = atomID
    self.assetID = assetID
    self.assetVersion = assetVersion
    self.units = units
    self.duration = duration
  }

  /// Returns progress for one command without creating a path or an
  /// intermediate progress array.
  public func progress(at time: Double, commandIndex: Int) -> Double {
    var lowerBound = 0
    var upperBound = units.count
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      if units[middle].commandIndex < commandIndex {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    guard lowerBound < units.count,
      units[lowerBound].commandIndex == commandIndex
    else { return 0 }
    let unit = units[lowerBound]
    let clampedTime = min(max(time, 0), duration)
    return min(1, max(0, (clampedTime - unit.startTime) / unit.duration))
  }

  public func progress(
    at phase: InlineRenderRevealPhase, commandIndex: Int
  ) -> Double {
    progress(at: duration * phase.rawValue, commandIndex: commandIndex)
  }

  /// Number of commands that are complete at the supplied time.
  public func completedCommandCount(at time: Double) -> Int {
    let clampedTime = min(max(time, 0), duration)
    var lowerBound = 0
    var upperBound = units.count
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      let end = units[middle].startTime + units[middle].duration
      if end <= clampedTime {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    return lowerBound
  }
}

/// One atomic image activation. Images do not expose partial pixels or
/// drawing commands: a frame sees the whole image at progress zero or one.
public struct InlineRenderRevealImageActivation: Sendable, Hashable {
  public let atomID: String
  public let startTime: Double
  public let duration: Double

  public init(atomID: String, startTime: Double, duration: Double) throws {
    guard !atomID.isEmpty,
      startTime.isFinite, startTime >= 0,
      duration.isFinite, duration > 0,
      startTime <= Double.greatestFiniteMagnitude - duration
    else {
      throw InlineLayoutError.invalidRenderPlan
    }
    self.atomID = atomID
    self.startTime = startTime
    self.duration = duration
  }

  public func progress(at time: Double) -> Double {
    let clampedTime = max(0, time)
    guard clampedTime.isFinite else { return 0 }
    return clampedTime >= startTime + duration ? 1 : 0
  }

  public func progress(at phase: InlineRenderRevealPhase) -> Double {
    phase == .complete ? 1 : 0
  }
}

/// Immutable compiled reveal schedule for all renderer-visible atom kinds.
/// It owns only stable IDs, source ranges, timing, and vector command
/// metadata.  Frame sampling never builds dictionaries, progress arrays, or
/// full path command arrays.
private struct InlineRenderRevealTextLookup: Sendable, Hashable {
  let atomID: String
  let activationIndex: Int
}

private struct InlineRenderRevealVectorLookup: Sendable, Hashable {
  let atomID: String
  let activationIndex: Int
}

private struct InlineRenderRevealImageLookup: Sendable, Hashable {
  let atomID: String
  let activationIndex: Int
}

public struct InlineRenderRevealSchedule: Sendable, Hashable {
  public let preparationRevision: String
  public let textActivations: [InlineRenderRevealTextActivation]
  public let vectorActivations: [InlineRenderRevealVectorActivation]
  public let imageActivations: [InlineRenderRevealImageActivation]
  public let duration: Double
  private let textLookup: [InlineRenderRevealTextLookup]
  private let vectorLookup: [InlineRenderRevealVectorLookup]
  private let imageLookup: [InlineRenderRevealImageLookup]
  /// A schedule compiled for a static renderer has the same validated
  /// activation payload as an animated schedule, but samples every activation
  /// as complete. Keeping this bit on the common schedule means adapters do
  /// not grow a second "no schedule" state of their own.
  fileprivate var completesImmediately = false

  public init(
    plan: InlineRenderPlan,
    assets: InlineAssetStore,
    textPlan: InlineRevealPlan? = nil,
    vectorPlans: [String: InlinePathRevealPlan]? = nil,
    imagePlan: InlineRevealPlan? = nil,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws {
    let prepared = plan.prepared
    try cancellation()
    guard !prepared.revision.isEmpty else { throw InlineLayoutError.invalidRenderPlan }

    var textAtoms: [String: PreparedInlineText] = [:]
    var vectorAtoms: [String: InlineVectorAtom] = [:]
    var imageAtoms: [String: InlineImageAtom] = [:]
    textAtoms.reserveCapacity(prepared.atoms.count)
    vectorAtoms.reserveCapacity(prepared.atoms.count)
    for atom in prepared.atoms {
      try cancellation()
      switch atom {
      case .text(let text): textAtoms[text.atom.id] = text
      case .vector(let vector): vectorAtoms[vector.atom.id] = vector.atom
      case .image(let image): imageAtoms[image.atom.id] = image.atom
      }
    }

    let resolvedTextPlan: InlineRevealPlan
    if let textPlan {
      resolvedTextPlan = textPlan
    } else {
      resolvedTextPlan = try InlineRevealPlanBuilder().textPlan(
        prepared: prepared, cancellation: cancellation)
    }
    let textUnitsByAtomID = try Self.validateTextPlan(
      resolvedTextPlan, atoms: textAtoms, cancellation: cancellation)

    var resolvedVectorPlans: [String: InlinePathRevealPlan] = [:]
    let vectorIDs = Set(vectorAtoms.keys)
    if let vectorPlans {
      guard Set(vectorPlans.keys) == vectorIDs else {
        throw InlineLayoutError.invalidRenderPlan
      }
      for atomID in vectorIDs {
        try cancellation()
        guard let vector = vectorAtoms[atomID], let pathPlan = vectorPlans[atomID] else {
          throw InlineLayoutError.invalidRenderPlan
        }
        guard let asset = assets[InlineAssetKey(id: vector.assetID, version: vector.assetVersion)],
          asset.metrics == vector.metrics
        else { throw InlineLayoutError.missingAsset(vector.assetID) }
        try pathPlan.validate(for: asset)
        resolvedVectorPlans[atomID] = pathPlan
      }
    } else {
      resolvedVectorPlans.reserveCapacity(vectorAtoms.count)
      for atom in prepared.atoms {
        try cancellation()
        guard case .vector(let vector) = atom else { continue }
        let key = InlineAssetKey(id: vector.atom.assetID, version: vector.atom.assetVersion)
        guard let asset = assets[key], asset.metrics == vector.atom.metrics else {
          throw InlineLayoutError.missingAsset(vector.atom.assetID)
        }
        let builder = try InlinePathRevealPlanBuilder()
        resolvedVectorPlans[vector.atom.id] = try builder.plan(
          asset: asset, cancellation: cancellation)
      }
    }

    let resolvedImagePlan: InlineRevealPlan
    if let imagePlan {
      resolvedImagePlan = imagePlan
    } else {
      resolvedImagePlan = try InlineRevealPlanBuilder().imagePlan(
        prepared: prepared, cancellation: cancellation)
    }
    let imageUnitsByAtomID = try Self.validateImagePlan(
      resolvedImagePlan, atoms: imageAtoms, cancellation: cancellation)

    var textActivations: [InlineRenderRevealTextActivation] = []
    var vectorActivations: [InlineRenderRevealVectorActivation] = []
    var imageActivations: [InlineRenderRevealImageActivation] = []
    textActivations.reserveCapacity(textAtoms.count)
    vectorActivations.reserveCapacity(vectorAtoms.count)
    imageActivations.reserveCapacity(imageAtoms.count)
    var nextStartTime = 0.0
    for atom in prepared.atoms {
      try cancellation()
      switch atom {
      case .text(let text):
        guard let units = textUnitsByAtomID[text.atom.id], !units.isEmpty else {
          throw InlineLayoutError.invalidRenderPlan
        }
        let (activation, endTime) = try Self.textActivation(
          atomID: text.atom.id,
          units: units,
          atom: text,
          startTime: nextStartTime
        )
        textActivations.append(activation)
        nextStartTime = endTime
      case .vector(let vector):
        guard let pathPlan = resolvedVectorPlans[vector.atom.id],
          let asset = assets[
            InlineAssetKey(id: vector.atom.assetID, version: vector.atom.assetVersion)]
        else { throw InlineLayoutError.missingAsset(vector.atom.assetID) }
        try pathPlan.validate(for: asset)
        var units: [InlineRenderRevealVectorUnit] = []
        units.reserveCapacity(pathPlan.units.count)
        var startTime = nextStartTime
        for pathUnit in pathPlan.units {
          try cancellation()
          units.append(try InlineRenderRevealVectorUnit(unit: pathUnit, startTime: startTime))
          guard startTime <= Double.greatestFiniteMagnitude - pathUnit.duration else {
            throw InlineLayoutError.invalidRenderPlan
          }
          startTime += pathUnit.duration
        }
        guard !units.isEmpty, startTime.isFinite else {
          throw InlineLayoutError.invalidRenderPlan
        }
        vectorActivations.append(
          try InlineRenderRevealVectorActivation(
            atomID: vector.atom.id,
            assetID: vector.atom.assetID,
            assetVersion: vector.atom.assetVersion,
            units: units
          ))
        nextStartTime = startTime
      case .image(let image):
        guard let units = imageUnitsByAtomID[image.atom.id], units.count == 1,
          let unit = units.first
        else { throw InlineLayoutError.invalidRenderPlan }
        let activation = try InlineRenderRevealImageActivation(
          atomID: image.atom.id, startTime: nextStartTime, duration: unit.duration)
        imageActivations.append(activation)
        guard nextStartTime <= Double.greatestFiniteMagnitude - unit.duration else {
          throw InlineLayoutError.invalidRenderPlan
        }
        nextStartTime += unit.duration
      }
    }

    guard nextStartTime.isFinite, nextStartTime >= 0 else {
      throw InlineLayoutError.invalidRenderPlan
    }
    try cancellation()

    self.preparationRevision = prepared.revision
    // Public activation arrays preserve document order for deterministic
    // scheduling and inspection. Lookups are a separate immutable index so
    // atom-ID queries remain logarithmic without changing that order.
    self.textActivations = textActivations
    self.textLookup = textActivations.enumerated().map {
      InlineRenderRevealTextLookup(atomID: $0.element.atomID, activationIndex: $0.offset)
    }.sorted { $0.atomID < $1.atomID }
    self.vectorActivations = vectorActivations
    self.imageActivations = imageActivations
    self.vectorLookup = vectorActivations.enumerated().map {
      InlineRenderRevealVectorLookup(atomID: $0.element.atomID, activationIndex: $0.offset)
    }.sorted { $0.atomID < $1.atomID }
    self.imageLookup = imageActivations.enumerated().map {
      InlineRenderRevealImageLookup(atomID: $0.element.atomID, activationIndex: $0.offset)
    }.sorted { $0.atomID < $1.atomID }
    self.duration = nextStartTime
  }

  /// Builds the canonical completed schedule used when a renderer caller did
  /// not request an animation. All plan validation remains identical to the
  /// animated initializer; only frame sampling changes.
  package static func completed(
    plan: InlineRenderPlan,
    assets: InlineAssetStore,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws -> InlineRenderRevealSchedule {
    var result = try InlineRenderRevealSchedule(
      plan: plan, assets: assets, cancellation: cancellation)
    result.completesImmediately = true
    return result
  }

  private static func validateTextPlan(
    _ plan: InlineRevealPlan,
    atoms: [String: PreparedInlineText],
    cancellation: @escaping InlineCancellationCheck
  ) throws -> [String: [InlineRevealUnit]] {
    var result: [String: [InlineRevealUnit]] = [:]
    for unit in plan.units {
      try cancellation()
      guard let text = atoms[unit.atomID], let sourceRange = unit.sourceRange,
        unit.kind != .vectorPath, unit.kind != .image,
        sourceRange.startUTF16 >= text.sourceRange.startUTF16,
        sourceRange.endUTF16 <= text.sourceRange.endUTF16
      else { throw InlineLayoutError.invalidRenderPlan }
      try text.validateSourceRangeBoundaries(sourceRange)
      result[unit.atomID, default: []].append(unit)
    }
    guard Set(result.keys) == Set(atoms.keys) else {
      throw InlineLayoutError.invalidRenderPlan
    }
    for (atomID, text) in atoms {
      guard let units = result[atomID] else { throw InlineLayoutError.invalidRenderPlan }
      switch text.atom.style.revealMode {
      case .native:
        break
      case .handwriting:
        // Preparation owns the semantic unit identity and source order. A
        // caller may tune timings, but may not forge a different grapheme /
        // stroke sequence after preparation.
        guard units.count == text.writingUnits.count else {
          throw InlineLayoutError.invalidRenderPlan
        }
        for (planned, prepared) in zip(units, text.writingUnits) {
          let expectedKind: InlineRevealUnitKind
          switch prepared.kind {
          case .semanticStroke: expectedKind = .semanticStroke
          case .nativeAtomic: expectedKind = .nativeAtomic
          case .timingOnly: expectedKind = .timingOnly
          }
          guard planned.id == prepared.id,
            planned.kind == expectedKind,
            planned.sourceRange == prepared.sourceRange
          else {
            throw InlineLayoutError.invalidRenderPlan
          }
        }
      }
    }
    return result
  }

  private static func validateImagePlan(
    _ plan: InlineRevealPlan,
    atoms: [String: InlineImageAtom],
    cancellation: @escaping InlineCancellationCheck
  ) throws -> [String: [InlineRevealUnit]] {
    var result: [String: [InlineRevealUnit]] = [:]
    for unit in plan.units {
      try cancellation()
      guard unit.kind == .image, unit.sourceRange == nil,
        atoms[unit.atomID] != nil
      else { throw InlineLayoutError.invalidRenderPlan }
      result[unit.atomID, default: []].append(unit)
    }
    guard result.values.allSatisfy({ $0.count == 1 }), Set(result.keys) == Set(atoms.keys)
    else { throw InlineLayoutError.invalidRenderPlan }
    return result
  }

  private static func textActivation(
    atomID: String,
    units sourceUnits: [InlineRevealUnit],
    atom: PreparedInlineText,
    startTime: Double
  ) throws -> (InlineRenderRevealTextActivation, Double) {
    guard let firstStart = sourceUnits.map(\.startTime).min(), firstStart.isFinite else {
      throw InlineLayoutError.invalidRenderPlan
    }
    var units: [InlineRenderRevealTextUnit] = []
    units.reserveCapacity(sourceUnits.count)
    var endTime = startTime
    for sourceUnit in sourceUnits {
      guard let sourceRange = sourceUnit.sourceRange else {
        throw InlineLayoutError.invalidRenderPlan
      }
      let localStart = sourceUnit.startTime - firstStart
      guard localStart.isFinite, localStart >= 0,
        startTime <= Double.greatestFiniteMagnitude - localStart,
        sourceRange.startUTF16 >= atom.sourceRange.startUTF16,
        sourceRange.endUTF16 <= atom.sourceRange.endUTF16
      else { throw InlineLayoutError.invalidRenderPlan }
      let unit = try InlineRenderRevealTextUnit(
        id: sourceUnit.id,
        kind: sourceUnit.kind,
        sourceRange: sourceRange,
        startTime: startTime + localStart,
        duration: sourceUnit.duration
      )
      units.append(unit)
      endTime = max(endTime, unit.startTime + unit.duration)
    }
    guard endTime.isFinite else { throw InlineLayoutError.invalidRenderPlan }
    return (try InlineRenderRevealTextActivation(atomID: atomID, units: units), endTime)
  }

  public func sample(at phase: InlineRenderRevealPhase) -> InlineRenderRevealFrame {
    InlineRenderRevealFrame(schedule: self, phase: phase)
  }

  public func textActivation(for atomID: String) -> InlineRenderRevealTextActivation? {
    var lowerBound = 0
    var upperBound = textLookup.count
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      if textLookup[middle].atomID < atomID {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    guard lowerBound < textLookup.count,
      textLookup[lowerBound].atomID == atomID
    else { return nil }
    return textActivations[textLookup[lowerBound].activationIndex]
  }

  public func vectorActivation(for atomID: String) -> InlineRenderRevealVectorActivation? {
    vectorActivation(atomID: atomID)
  }

  public func imageActivation(for atomID: String) -> InlineRenderRevealImageActivation? {
    imageActivation(atomID: atomID)
  }

  private func vectorActivation(atomID: String) -> InlineRenderRevealVectorActivation? {
    var lowerBound = 0
    var upperBound = vectorLookup.count
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      if vectorLookup[middle].atomID < atomID {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    guard lowerBound < vectorLookup.count,
      vectorLookup[lowerBound].atomID == atomID
    else { return nil }
    return vectorActivations[vectorLookup[lowerBound].activationIndex]
  }

  private func imageActivation(atomID: String) -> InlineRenderRevealImageActivation? {
    var lowerBound = 0
    var upperBound = imageLookup.count
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      if imageLookup[middle].atomID < atomID {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    guard lowerBound < imageLookup.count,
      imageLookup[lowerBound].atomID == atomID
    else { return nil }
    return imageActivations[imageLookup[lowerBound].activationIndex]
  }
}

/// A zero-allocation frame-time view over one compiled schedule and phase.
public struct InlineRenderRevealFrame: Sendable, Hashable {
  public let phase: InlineRenderRevealPhase
  public let time: Double
  private let schedule: InlineRenderRevealSchedule

  fileprivate init(schedule: InlineRenderRevealSchedule, phase: InlineRenderRevealPhase) {
    self.schedule = schedule
    self.phase = phase
    self.time =
      schedule.completesImmediately
      ? schedule.duration
      : schedule.duration * phase.rawValue
  }

  public var duration: Double { schedule.duration }
  public var isComplete: Bool { phase == .complete || schedule.completesImmediately }

  public func textActivation(for atomID: String) -> InlineRenderRevealTextActivation? {
    schedule.textActivation(for: atomID)
  }

  public func vectorActivation(for atomID: String) -> InlineRenderRevealVectorActivation? {
    schedule.vectorActivation(for: atomID)
  }

  public func imageActivation(for atomID: String) -> InlineRenderRevealImageActivation? {
    schedule.imageActivation(for: atomID)
  }

  public func textProgress(atomID: String, sourceRange: InlineSourceRange) -> Double {
    textActivation(for: atomID)?.progress(at: time, sourceRange: sourceRange) ?? 0
  }

  public func textIsVisible(atomID: String, sourceRange: InlineSourceRange) -> Bool {
    textProgress(atomID: atomID, sourceRange: sourceRange) > 0
  }

  public func vectorProgress(atomID: String, commandIndex: Int) -> Double {
    vectorActivation(for: atomID)?.progress(at: time, commandIndex: commandIndex) ?? 0
  }

  public func completedVectorCommandCount(atomID: String) -> Int {
    vectorActivation(for: atomID)?.completedCommandCount(at: time) ?? 0
  }

  public func imageProgress(atomID: String) -> Double {
    imageActivation(for: atomID)?.progress(at: time) ?? 0
  }

  public func imageIsVisible(atomID: String) -> Bool {
    imageProgress(atomID: atomID) > 0
  }
}

private func rangesOverlap(_ lhs: InlineSourceRange, _ rhs: InlineSourceRange) -> Bool {
  lhs.startUTF16 < rhs.endUTF16 && rhs.startUTF16 < lhs.endUTF16
}

/// Builds source-mapped reveal units from already prepared inline geometry.
public struct InlineRevealPlanBuilder: Sendable {
  public let secondsPerUnit: Double

  public init(secondsPerUnit: Double = 0.05) throws {
    guard secondsPerUnit.isFinite, secondsPerUnit > 0 else {
      throw InlineLayoutError.invalidMetric(name: "secondsPerUnit", value: secondsPerUnit)
    }
    self.secondsPerUnit = secondsPerUnit
  }

  public func graphemePlan(
    prepared: PreparedInlineDocument,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws -> InlineRevealPlan {
    var units: [InlineRevealUnit] = []
    var time = 0.0
    for atom in prepared.atoms {
      try cancellation()
      guard case .text(let text) = atom else { continue }
      for (index, range) in try clusterRanges(for: text).enumerated() {
        try cancellation()
        let id = try InlineRevealUnitID(rawValue: "\(text.atom.id)-grapheme-cluster-\(index)")
        units.append(
          try InlineRevealUnit(
            id: id,
            kind: .grapheme,
            atomID: text.atom.id,
            sourceRange: range,
            startTime: time,
            duration: secondsPerUnit
          ))
        time += secondsPerUnit
      }
    }
    return try InlineRevealPlan(units: units)
  }

  /// Builds the canonical text schedule selected by each prepared text style.
  /// Native atoms use grapheme units; handwriting atoms use the immutable
  /// prepared stroke/emoji/timing units in their source order.
  public func textPlan(
    prepared: PreparedInlineDocument,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws -> InlineRevealPlan {
    var units: [InlineRevealUnit] = []
    var time = 0.0
    for atom in prepared.atoms {
      try cancellation()
      guard case .text(let text) = atom else { continue }
      switch text.atom.style.revealMode {
      case .native:
        for (index, range) in try clusterRanges(for: text).enumerated() {
          try cancellation()
          units.append(
            try InlineRevealUnit(
              id: try InlineRevealUnitID(rawValue: "\(text.atom.id)-grapheme-cluster-\(index)"),
              kind: .grapheme,
              atomID: text.atom.id,
              sourceRange: range,
              startTime: time,
              duration: secondsPerUnit
            ))
          time += secondsPerUnit
        }
      case .handwriting:
        for unit in text.writingUnits {
          try cancellation()
          let kind: InlineRevealUnitKind
          switch unit.kind {
          case .semanticStroke: kind = .semanticStroke
          case .nativeAtomic: kind = .nativeAtomic
          case .timingOnly: kind = .timingOnly
          }
          units.append(
            try InlineRevealUnit(
              id: unit.id,
              kind: kind,
              atomID: text.atom.id,
              sourceRange: unit.sourceRange,
              startTime: time,
              duration: secondsPerUnit
            ))
          time += secondsPerUnit
        }
      }
    }
    return try InlineRevealPlan(units: units)
  }

  public func shapedGlyphPlan(
    prepared: PreparedInlineDocument,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws -> InlineRevealPlan {
    var units: [InlineRevealUnit] = []
    var time = 0.0
    for atom in prepared.atoms {
      try cancellation()
      guard case .text(let text) = atom else { continue }
      let ranges = try clusterRanges(for: text)
      let coveredClusters = coveredClusters(in: ranges, runs: text.shaped.runs)
      for (index, range) in ranges.enumerated() where coveredClusters[index] {
        try cancellation()
        let id = try InlineRevealUnitID(
          rawValue: "\(text.atom.id)-shaped-cluster-\(index)")
        units.append(
          try InlineRevealUnit(
            id: id,
            kind: .shapedGlyph,
            atomID: text.atom.id,
            sourceRange: range,
            startTime: time,
            duration: secondsPerUnit
          ))
        time += secondsPerUnit
      }
    }
    return try InlineRevealPlan(units: units)
  }

  /// Builds one reveal unit per image atom. An image is intentionally a
  /// single atomic activation; unlike text and vector paths it has no
  /// meaningful partial reveal representation in the core layer.
  public func imagePlan(
    prepared: PreparedInlineDocument,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws -> InlineRevealPlan {
    var units: [InlineRevealUnit] = []
    var time = 0.0
    for atom in prepared.atoms {
      try cancellation()
      guard case .image(let image) = atom else { continue }
      let id = try InlineRevealUnitID(rawValue: "\(image.atom.id)-image")
      units.append(
        try InlineRevealUnit(
          id: id,
          kind: .image,
          atomID: image.atom.id,
          sourceRange: nil,
          startTime: time,
          duration: secondsPerUnit
        ))
      guard time <= Double.greatestFiniteMagnitude - secondsPerUnit else {
        throw InlineLayoutError.invalidRenderPlan
      }
      time += secondsPerUnit
    }
    return try InlineRevealPlan(units: units)
  }

  private func coveredClusters(
    in clusters: [InlineSourceRange],
    runs: [InlineShapedRun]
  ) -> [Bool] {
    guard !clusters.isEmpty else { return [] }
    let clusterStarts = clusters.map(\.startUTF16)
    let clusterEnds = clusters.map(\.endUTF16)
    var differences = Array(repeating: 0, count: clusters.count + 1)
    for run in runs {
      for glyph in run.glyphs {
        let first = firstClusterEnding(after: glyph.sourceRange.startUTF16, ends: clusterEnds)
        let end = firstClusterStarting(
          atOrAfter: glyph.sourceRange.endUTF16,
          starts: clusterStarts
        )
        guard first < end else { continue }
        differences[first] += 1
        differences[end] -= 1
      }
    }

    var covered = Array(repeating: false, count: clusters.count)
    var activeGlyphs = 0
    for index in clusters.indices {
      activeGlyphs += differences[index]
      covered[index] = activeGlyphs > 0
    }
    return covered
  }

  private func firstClusterEnding(after value: Int, ends: [Int]) -> Int {
    var lowerBound = 0
    var upperBound = ends.count
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      if ends[middle] > value {
        upperBound = middle
      } else {
        lowerBound = middle + 1
      }
    }
    return lowerBound
  }

  private func firstClusterStarting(atOrAfter value: Int, starts: [Int]) -> Int {
    var lowerBound = 0
    var upperBound = starts.count
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      if starts[middle] >= value {
        upperBound = middle
      } else {
        lowerBound = middle + 1
      }
    }
    return lowerBound
  }

  private func clusterRanges(for text: PreparedInlineText) throws -> [InlineSourceRange] {
    guard !text.graphemes.isEmpty else { return [] }
    var result: [InlineSourceRange] = []
    var clusterStart = 0
    for index in text.graphemes.indices {
      let isLast = index == text.graphemes.index(before: text.graphemes.endIndex)
      guard isLast || text.shaped.graphemeCanBreakAfter[index] else { continue }
      result.append(
        try InlineSourceRange(
          startUTF16: text.shaped.graphemeRanges[clusterStart].startUTF16,
          endUTF16: text.shaped.graphemeRanges[index].endUTF16
        )
      )
      clusterStart = index + 1
    }
    return result
  }
}
