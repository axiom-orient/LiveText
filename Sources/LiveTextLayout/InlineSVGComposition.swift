import Foundation

/// The explicit role of one SVG composition instance. An asset's trajectory
/// is never interpreted as a mask unless a mask instance declares it.
public enum InlineSVGCompositionRole: String, Sendable, Hashable, Codable {
  case artwork
  case mask
}

/// The only mask operations currently supported by the inline adapters.
/// `reveal` clips a target to the mask coverage; `erase` removes that coverage
/// from the already painted target. Both are explicit. Each instance also
/// carries a deterministic declaration order. The adapters normalize all
/// declarations into reveal-before-paint and erase-after-paint phases; the
/// order is not a sequential cross-operation pixel program.
public enum InlineSVGMaskOperation: String, Sendable, Hashable, Codable {
  case reveal
  case erase
}

/// A typed composition instance. `sourceAtomID` identifies the vector atom
/// which owns an artwork instance when present. A mask may instead reference a
/// registry/provider asset without introducing a document atom.
public struct InlineSVGCompositionInstance: Sendable, Hashable, Codable {
  public let instanceID: String
  public let assetID: InlineAssetID
  public let assetVersion: Int
  public let sourceAtomID: String?
  public let role: InlineSVGCompositionRole
  public let targetID: String?
  public let operation: InlineSVGMaskOperation?
  /// Canonical declaration order within the immutable composition plan. It is
  /// retained for deterministic validation, projection, and diagnostics while
  /// adapters normalize masks into reveal and erase phases.
  public let declarationOrder: Int

  public init(
    instanceID: String,
    assetID: InlineAssetID,
    assetVersion: Int,
    sourceAtomID: String? = nil,
    role: InlineSVGCompositionRole,
    targetID: String? = nil,
    operation: InlineSVGMaskOperation? = nil,
    declarationOrder: Int
  ) throws {
    guard !instanceID.isEmpty, assetVersion >= 0, declarationOrder >= 0 else {
      throw InlineSVGCompositionError.invalid(
        operation: "composition.instance",
        targetID: targetID,
        assetID: assetID,
        assetVersion: assetVersion,
        preparationRevision: "",
        cause: "instance, asset version, and order must be non-negative/non-empty")
    }
    switch role {
    case .artwork:
      guard let sourceAtomID, !sourceAtomID.isEmpty,
        targetID == nil, operation == nil else {
        throw InlineSVGCompositionError.invalid(
          operation: "composition.artwork",
          targetID: targetID,
          assetID: assetID,
          assetVersion: assetVersion,
          preparationRevision: "",
          cause: "artwork requires sourceAtomID and cannot declare target/operation")
      }
    case .mask:
      guard let targetID, !targetID.isEmpty, operation != nil else {
        throw InlineSVGCompositionError.invalid(
          operation: "composition.mask",
          targetID: targetID,
          assetID: assetID,
          assetVersion: assetVersion,
          preparationRevision: "",
          cause: "mask requires a targetID and explicit operation")
      }
    }
    self.instanceID = instanceID
    self.assetID = assetID
    self.assetVersion = assetVersion
    self.sourceAtomID = sourceAtomID
    self.role = role
    self.targetID = targetID
    self.operation = operation
    self.declarationOrder = declarationOrder
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      instanceID: values.decode(String.self, forKey: .instanceID),
      assetID: values.decode(InlineAssetID.self, forKey: .assetID),
      assetVersion: values.decode(Int.self, forKey: .assetVersion),
      sourceAtomID: values.decodeIfPresent(String.self, forKey: .sourceAtomID),
      role: values.decode(InlineSVGCompositionRole.self, forKey: .role),
      targetID: values.decodeIfPresent(String.self, forKey: .targetID),
      operation: values.decodeIfPresent(InlineSVGMaskOperation.self, forKey: .operation),
      declarationOrder: values.decode(Int.self, forKey: .declarationOrder)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case instanceID, assetID, assetVersion, sourceAtomID, role, targetID, operation,
      declarationOrder
  }
}

/// Structured SVG composition failure. It retains operation, target, source
/// asset/version, preparation revision, and cause for diagnostics and retry.
public enum InlineSVGCompositionError: Error, Equatable, LocalizedError, Sendable {
  case invalid(
    operation: String,
    targetID: String?,
    assetID: InlineAssetID?,
    assetVersion: Int?,
    preparationRevision: String,
    cause: String
  )
  case missingAsset(
    operation: String,
    targetID: String?,
    assetID: InlineAssetID,
    assetVersion: Int,
    preparationRevision: String
  )
  case versionMismatch(
    operation: String,
    targetID: String?,
    assetID: InlineAssetID,
    expected: Int,
    actual: Int,
    preparationRevision: String
  )

  public var operation: String {
    switch self {
    case .invalid(let operation, _, _, _, _, _),
      .missingAsset(let operation, _, _, _, _),
      .versionMismatch(let operation, _, _, _, _, _): return operation
    }
  }

  public var targetID: String? {
    switch self {
    case .invalid(_, let targetID, _, _, _, _),
      .missingAsset(_, let targetID, _, _, _),
      .versionMismatch(_, let targetID, _, _, _, _): return targetID
    }
  }

  public var assetID: InlineAssetID? {
    switch self {
    case .invalid(_, _, let assetID, _, _, _): return assetID
    case .missingAsset(_, _, let assetID, _, _),
      .versionMismatch(_, _, let assetID, _, _, _): return assetID
    }
  }

  public var assetVersion: Int? {
    switch self {
    case .invalid(_, _, _, let version, _, _): return version
    case .missingAsset(_, _, _, let version, _): return version
    case .versionMismatch(_, _, _, let expected, _, _): return expected
    }
  }

  public var cause: String {
    switch self {
    case .invalid(_, _, _, _, _, let cause): return cause
    case .missingAsset: return "asset is unavailable at the requested identity"
    case .versionMismatch: return "asset version does not match the requested identity"
    }
  }

  public var preparationRevision: String {
    switch self {
    case .invalid(_, _, _, _, let revision, _),
      .missingAsset(_, _, _, _, let revision),
      .versionMismatch(_, _, _, _, _, let revision): return revision
    }
  }

  public var errorDescription: String? {
    let target = targetID.map { " target '\($0)'" } ?? ""
    switch self {
    case .invalid(_, _, _, _, _, let cause):
      return "Inline SVG composition failed for\(target) at revision '\(preparationRevision)': \(cause)."
    case .missingAsset(_, _, let assetID, let version, _):
      return "Inline SVG composition is missing asset \(assetID.rawValue) version \(version)\(target) at revision '\(preparationRevision)'."
    case .versionMismatch(_, _, let assetID, let expected, let actual, _):
      return "Inline SVG composition asset \(assetID.rawValue) version \(actual) does not match \(expected)\(target) at revision '\(preparationRevision)'."
    }
  }
}

/// Immutable SVG composition input shared by SwiftUI and Canvas.
/// Instances are sorted by canonical declaration order. Mask operations are
/// consumed in two deterministic phases (reveal, paint, erase); declaration
/// order is retained for stable validation/projection/diagnostics and is not a
/// sequential cross-operation blend program.
public struct InlineSVGCompositionPlan: Sendable, Hashable, Codable {
  public let preparationRevision: String
  public let instances: [InlineSVGCompositionInstance]

  public init(
    preparationRevision: String,
    instances: [InlineSVGCompositionInstance]
  ) throws {
    guard !preparationRevision.isEmpty else {
      throw InlineSVGCompositionError.invalid(
        operation: "composition.plan",
        targetID: nil,
        assetID: nil,
        assetVersion: nil,
        preparationRevision: preparationRevision,
        cause: "preparation revision is empty")
    }
    var IDs = Set<String>()
    var declarationOrders = Set<Int>()
    for instance in instances {
      guard IDs.insert(instance.instanceID).inserted else {
        throw InlineSVGCompositionError.invalid(
          operation: "composition.declarationOrder",
          targetID: instance.targetID,
          assetID: instance.assetID,
          assetVersion: instance.assetVersion,
          preparationRevision: preparationRevision,
          cause: "instance ID is duplicated")
      }
      guard declarationOrders.insert(instance.declarationOrder).inserted else {
        throw InlineSVGCompositionError.invalid(
          operation: "composition.declarationOrder",
          targetID: instance.targetID,
          assetID: instance.assetID,
          assetVersion: instance.assetVersion,
          preparationRevision: preparationRevision,
          cause: "declaration order must be unique")
      }
    }
    self.preparationRevision = preparationRevision
    self.instances = instances.sorted {
      if $0.declarationOrder != $1.declarationOrder {
        return $0.declarationOrder < $1.declarationOrder
      }
      return $0.instanceID < $1.instanceID
    }
  }

  /// Validates all source/target/version/order invariants against the one
  /// prepared document and already resolved immutable assets.
  public func validate(
    prepared: PreparedInlineDocument,
    assets: InlineAssetStore
  ) throws {
    guard preparationRevision == prepared.revision else {
      throw InlineSVGCompositionError.invalid(
        operation: "composition.validate",
        targetID: nil,
        assetID: nil,
        assetVersion: nil,
        preparationRevision: prepared.revision,
        cause: "composition plan belongs to a stale preparation revision")
    }
    var vectors: [String: InlineVectorAtom] = [:]
    var atomIDs = Set<String>()
    for atom in prepared.document.atoms {
      switch atom {
      case .vector(let vector): vectors[vector.id] = vector; atomIDs.insert(vector.id)
      case .text(let text): atomIDs.insert(text.id)
      case .image(let image): atomIDs.insert(image.id)
      }
    }
    var artworkSources = Set<String>()
    var declarationOrders = Set<Int>()
    for instance in instances {
      guard declarationOrders.insert(instance.declarationOrder).inserted else {
        throw InlineSVGCompositionError.invalid(
          operation: "composition.declarationOrder", targetID: instance.targetID,
          assetID: instance.assetID, assetVersion: instance.assetVersion,
          preparationRevision: prepared.revision, cause: "declaration order is duplicated")
      }
      let key = InlineAssetKey(id: instance.assetID, version: instance.assetVersion)
      guard let asset = assets[key] else {
        throw InlineSVGCompositionError.missingAsset(
          operation: "composition.resolve", targetID: instance.targetID,
          assetID: instance.assetID, assetVersion: instance.assetVersion,
          preparationRevision: prepared.revision)
      }
      guard asset.id == instance.assetID, asset.version == instance.assetVersion else {
        throw InlineSVGCompositionError.versionMismatch(
          operation: "composition.resolve", targetID: instance.targetID,
          assetID: instance.assetID, expected: instance.assetVersion,
          actual: asset.version, preparationRevision: prepared.revision)
      }
      switch instance.role {
      case .artwork:
        guard let sourceAtomID = instance.sourceAtomID,
          let vector = vectors[sourceAtomID],
          vector.assetID == instance.assetID,
          vector.assetVersion == instance.assetVersion,
          artworkSources.insert(sourceAtomID).inserted else {
          throw InlineSVGCompositionError.invalid(
            operation: "composition.artwork", targetID: nil,
            assetID: instance.assetID, assetVersion: instance.assetVersion,
            preparationRevision: prepared.revision,
            cause: "artwork sourceAtomID is not a unique matching vector atom")
        }
      case .mask:
        guard let targetID = instance.targetID, atomIDs.contains(targetID),
          instance.operation != nil else {
          throw InlineSVGCompositionError.invalid(
            operation: "composition.mask", targetID: instance.targetID,
            assetID: instance.assetID, assetVersion: instance.assetVersion,
            preparationRevision: prepared.revision,
            cause: "mask target or operation is invalid")
        }
        if let sourceAtomID = instance.sourceAtomID {
          guard let vector = vectors[sourceAtomID],
            vector.assetID == instance.assetID,
            vector.assetVersion == instance.assetVersion else {
            throw InlineSVGCompositionError.invalid(
              operation: "composition.mask", targetID: targetID,
              assetID: instance.assetID, assetVersion: instance.assetVersion,
              preparationRevision: prepared.revision,
              cause: "mask sourceAtomID does not match its SVG asset")
          }
        }
      }
    }
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      preparationRevision: values.decode(String.self, forKey: .preparationRevision),
      instances: values.decode([InlineSVGCompositionInstance].self, forKey: .instances)
    )
  }

  private enum CodingKeys: String, CodingKey { case preparationRevision, instances }
}
