import Foundation

public protocol InlineAssetGeometryProvider: Sendable {
  func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset
}

/// Zero-state provider for text/image-only documents that contain no vector geometry.
/// Any vector lookup fails explicitly instead of inventing a placeholder asset.
public struct InlineEmptyAssetGeometryProvider: InlineAssetGeometryProvider {
  public init() {}

  public func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
    throw InlineAssetResolutionError.missingGeometry(assetID, version: version)
  }
}

public struct InlineAssetKey: Sendable, Hashable {
  public let id: InlineAssetID
  public let version: Int

  public init(id: InlineAssetID, version: Int) {
    self.id = id
    self.version = version
  }
}

public struct InlineAssetStore: Sendable {
  private let values: [InlineAssetKey: InlineSVGAsset]

  public init(values: [InlineAssetKey: InlineSVGAsset] = [:]) {
    self.values = values
  }

  public subscript(key: InlineAssetKey) -> InlineSVGAsset? { values[key] }
}

/// Immutable renderer-neutral image payloads resolved for one document.
/// Decoding into a platform image remains outside `LiveTextLayout`.
public struct InlineImageAssetStore: Sendable, Hashable {
  private let values: [InlineImageReference: InlineEncodedImageAsset]
  private let payloadValues: [InlineImageReference: InlineImagePayload]

  public init(values: [InlineImageReference: InlineEncodedImageAsset] = [:]) {
    self.values = values
    self.payloadValues = [:]
  }

  /// Creates a store from placement-independent payloads. One payload may be
  /// resolved by any number of image atoms whose thumbnail metrics differ.
  public init(payloads: [InlineImagePayload]) throws {
    var values: [InlineImageReference: InlineImagePayload] = [:]
    values.reserveCapacity(payloads.count)
    for payload in payloads {
      guard values[payload.reference] == nil else {
        throw InlineImageAssetError.duplicateReference(payload.reference)
      }
      values[payload.reference] = payload
    }
    self.values = [:]
    self.payloadValues = values
  }

  public subscript(reference: InlineImageReference) -> InlineEncodedImageAsset? {
    values[reference]
  }

  public func value(for reference: InlineImageReference) -> InlineEncodedImageAsset? {
    values[reference]
  }

  /// Returns renderer-neutral content without imposing a logical placement.
  /// Encoded metric-bound assets are projected to this view on demand.
  public func payload(for reference: InlineImageReference) -> InlineImagePayload? {
    if let payload = payloadValues[reference] { return payload }
    guard let asset = values[reference] else { return nil }
    if let adaptivePayload = asset.adaptivePayload {
      return InlineImagePayload(
        uncheckedReference: reference,
        rendition: adaptivePayload.content,
        adaptivePayload: adaptivePayload
      )
    }
    return InlineImagePayload(
      uncheckedReference: reference,
      rendition: asset.rendition,
      adaptivePayload: nil
    )
  }

  public func merged(with other: InlineImageAssetStore) -> InlineImageAssetStore {
    var merged = values
    for (reference, asset) in other.values { merged[reference] = asset }
    var mergedPayloads = payloadValues
    for (reference, payload) in other.payloadValues { mergedPayloads[reference] = payload }
    // An explicitly supplied payload takes precedence over an encoded
    // placement-bound value at the same reference. Likewise, a newer encoded
    // value removes an older independent payload.
    for reference in other.values.keys { mergedPayloads.removeValue(forKey: reference) }
    return InlineImageAssetStore(values: merged, payloadValues: mergedPayloads)
  }

  private init(
    values: [InlineImageReference: InlineEncodedImageAsset],
    payloadValues: [InlineImageReference: InlineImagePayload]
  ) {
    self.values = values
    self.payloadValues = payloadValues
  }
}

extension InlineAssetRegistry {
  /// Returns encoded image records retained by this registry. Vector records
  /// are ignored; callers can merge this store with provider-resolved values.
  public var imageStore: InlineImageAssetStore {
    InlineImageAssetStore(
      values: records.reduce(into: [InlineImageReference: InlineEncodedImageAsset]()) {
        result, record in
        if let image = record.image { result[image.reference] = image }
      }
    )
  }
}

/// Validates an already-resolved image store before renderer publication. The
/// function performs no I/O or decoding and is safe to use as a staging step.
public func validateInlineImageAssets(
  document: InlineDocument,
  store: InlineImageAssetStore,
  limits: InlineImageAssetLimits = .default
) throws {
  for atom in document.atoms {
    guard case .image(let image) = atom else { continue }
    guard let payload = store.payload(for: image.reference) else {
      throw InlineImageAssetError.missingImage(image.assetID, version: image.assetVersion)
    }
    try validateInlineImagePayload(payload, for: image, limits: limits)
  }
}

public func resolveInlineAssets(
  document: InlineDocument,
  registry: InlineAssetRegistry,
  provider: some InlineAssetGeometryProvider,
  cache: InlineAssetCache? = nil
) throws -> InlineAssetStore {
  let candidate = try prepareInlineAssets(
    document: document,
    registry: registry,
    provider: provider,
    cache: cache
  )
  cache?.publish(
    assets: candidate.cacheAssets,
    hits: candidate.cacheHits,
    misses: candidate.cacheMisses
  )
  return InlineAssetStore(values: candidate.assets)
}

/// Resolves all image atoms and validates every provider or registry result
/// against the atom's stable reference, metrics, digest, and byte/dimension
/// limits. This operation is side-effect-free and therefore safe to run as a
/// candidate before an append projection publishes anything.
public func resolveInlineImageAssets(
  document: InlineDocument,
  registry: InlineAssetRegistry = .empty,
  provider: some InlineImageAssetProvider,
  limits: InlineImageAssetLimits = .default
) throws -> InlineImageAssetStore {
  let candidate = try prepareInlineImageAssets(
    document: document,
    registry: registry,
    provider: provider,
    limits: limits
  )
  return InlineImageAssetStore(values: candidate.assets)
}

/// Fallible, side-effect-free asset resolution for append adapters. The
/// candidate contains only the newly resolved values and cache accounting
/// receipts; callers publish those receipts after all geometry, hit-test, and
/// accessibility work has succeeded.
package struct InlineAssetResolutionCandidate: Sendable {
  public let assets: [InlineAssetKey: InlineSVGAsset]
  public let cacheAssets: [InlineSVGAsset]
  public let cacheHits: [InlineAssetCache.Key]
  public let cacheMisses: [InlineAssetCache.Key]

  public init(
    assets: [InlineAssetKey: InlineSVGAsset],
    cacheAssets: [InlineSVGAsset],
    cacheHits: [InlineAssetCache.Key],
    cacheMisses: [InlineAssetCache.Key]
  ) {
    self.assets = assets
    self.cacheAssets = cacheAssets
    self.cacheHits = cacheHits
    self.cacheMisses = cacheMisses
  }
}

/// Side-effect-free image resolution receipt for append adapters. The core
/// does not own a decoded image cache; an adapter can publish the encoded
/// values into its own cache only after all render/hit/accessibility work has
/// succeeded.
package struct InlineImageAssetResolutionCandidate: Sendable, Hashable {
  public let assets: [InlineImageReference: InlineEncodedImageAsset]

  public init(assets: [InlineImageReference: InlineEncodedImageAsset]) {
    self.assets = assets
  }
}

/// Resolves a candidate without mutating `cache`. Cache hit/miss counters,
/// LRU order, insertions, and evictions are published only by the caller after
/// every other fallible append operation has completed.
package func prepareInlineAssets(
  document: InlineDocument,
  registry: InlineAssetRegistry,
  provider: some InlineAssetGeometryProvider,
  cache: InlineAssetCache? = nil
) throws -> InlineAssetResolutionCandidate {
  var registryValues: [InlineAssetKey: InlineSVGAsset] = [:]
  for record in registry.records {
    if let geometry = record.geometry {
      registryValues[InlineAssetKey(id: record.id, version: record.version)] = geometry
    }
  }

  var resolved: [InlineAssetKey: InlineSVGAsset] = [:]
  var cacheAssets: [InlineSVGAsset] = []
  var cacheHits: [InlineAssetCache.Key] = []
  var cacheMisses: [InlineAssetCache.Key] = []
  for atom in document.atoms {
    guard case .vector(let vector) = atom else { continue }
    let key = InlineAssetKey(id: vector.assetID, version: vector.assetVersion)
    let asset: InlineSVGAsset
    if let alreadyResolved = resolved[key] {
      asset = alreadyResolved
    } else if let cache {
      let cacheKey = try InlineAssetCache.Key(
        id: vector.assetID, version: vector.assetVersion)
      if let cached = try cache.peek(id: vector.assetID, version: vector.assetVersion) {
        asset = cached
        cacheHits.append(cacheKey)
      } else {
        cacheMisses.append(cacheKey)
        do {
          asset = try provider.resolveGeometry(
            assetID: vector.assetID, version: vector.assetVersion)
        } catch InlineAssetResolutionError.missingGeometry {
          guard let geometry = registryValues[key] else {
            throw InlineAssetResolutionError.missingGeometry(
              vector.assetID, version: vector.assetVersion)
          }
          asset = geometry
        }
        cacheAssets.append(asset)
      }
    } else {
      do {
        asset = try provider.resolveGeometry(
          assetID: vector.assetID, version: vector.assetVersion)
      } catch InlineAssetResolutionError.missingGeometry {
        guard let geometry = registryValues[key] else {
          throw InlineAssetResolutionError.missingGeometry(
            vector.assetID, version: vector.assetVersion)
        }
        asset = geometry
      }
    }
    guard asset.id == vector.assetID, asset.version == vector.assetVersion,
      asset.metrics == vector.metrics
    else { throw InlineAssetResolutionError.metricsMismatch(vector.assetID) }
    resolved[key] = asset
  }
  return InlineAssetResolutionCandidate(
    assets: resolved,
    cacheAssets: cacheAssets,
    cacheHits: cacheHits,
    cacheMisses: cacheMisses
  )
}

/// Resolves image bytes without mutating any cache or projection. Registry
/// payloads take precedence; the provider supplies missing payloads. A
/// provider result is fully checked before it enters the returned candidate.
package func prepareInlineImageAssets(
  document: InlineDocument,
  registry: InlineAssetRegistry = .empty,
  provider: some InlineImageAssetProvider,
  limits: InlineImageAssetLimits = .default
) throws -> InlineImageAssetResolutionCandidate {
  var registryValues: [InlineImageReference: InlineEncodedImageAsset] = [:]
  for record in registry.records {
    if let image = record.image {
      registryValues[image.reference] = image
    }
  }

  var resolved: [InlineImageReference: InlineEncodedImageAsset] = [:]
  for atom in document.atoms {
    guard case .image(let image) = atom else { continue }
    let reference = image.reference
    let asset: InlineEncodedImageAsset
    if let existing = resolved[reference] {
      asset = existing
    } else if let registered = registryValues[reference] {
      asset = registered
    } else {
      asset = try provider.resolveImage(
        reference: reference,
        metrics: image.metrics,
        limits: limits
      )
    }
    try validateInlineImageAsset(asset, for: image, limits: limits)
    resolved[reference] = asset
  }
  return InlineImageAssetResolutionCandidate(assets: resolved)
}

private func validateInlineImageAsset(
  _ asset: InlineEncodedImageAsset,
  for atom: InlineImageAtom,
  limits: InlineImageAssetLimits
) throws {
  // The provider protocol predates placement-independent payloads and
  // promises a metric-bound result. Preserve that contract while the public
  // `InlineImagePayload` store offers reusable fixed rasters.
  guard asset.metrics == atom.metrics else {
    throw InlineImageAssetError.metricsMismatch(atom.assetID)
  }
  let payload: InlineImagePayload
  if let adaptivePayload = asset.adaptivePayload {
    payload = InlineImagePayload(
      uncheckedReference: asset.reference,
      rendition: adaptivePayload.content,
      adaptivePayload: adaptivePayload
    )
  } else {
    payload = InlineImagePayload(
      uncheckedReference: asset.reference,
      rendition: asset.rendition,
      adaptivePayload: nil
    )
  }
  try validateInlineImagePayload(payload, for: atom, limits: limits)
}

private func validateInlineImagePayload(
  _ payload: InlineImagePayload,
  for atom: InlineImageAtom,
  limits: InlineImageAssetLimits
) throws {
  guard payload.reference == atom.reference else {
    throw InlineImageAssetError.referenceMismatch(
      expected: atom.reference, actual: payload.reference)
  }
  switch atom.presentation {
  case .thumbnail:
    guard payload.adaptivePayload == nil else {
      throw InlineImageAssetError.adaptivePayloadMismatch(atom.assetID)
    }
    try limits.validate(payload.rendition)
    let actual = InlineAssetDigest(data: payload.rendition.encodedBytes)
    guard actual == atom.digest else {
      throw InlineImageAssetError.digestMismatch(expected: atom.digest, actual: actual)
    }
  case .adaptiveGlyph(let configuration):
    guard let adaptivePayload = payload.adaptivePayload else {
      throw InlineImageAssetError.adaptivePayloadMissing(atom.assetID)
    }
    guard adaptivePayload.metrics == atom.metrics,
      adaptivePayload.font == configuration.font,
      adaptivePayload.fontFingerprint == configuration.fontFingerprint,
      adaptivePayload.fallbackRaster.png.encodedBytes.isEmpty == false
    else {
      throw InlineImageAssetError.adaptivePayloadMismatch(atom.assetID)
    }
    guard adaptivePayload.content.encoding == .heic else {
      throw InlineImageAssetError.invalidProviderAsset(atom.assetID)
    }
    try limits.validate(adaptivePayload.content)
    try limits.validate(adaptivePayload.fallbackRaster.png)
    let adaptiveDigest = try adaptivePayload.canonicalDigest()
    guard payload.reference.digest == adaptiveDigest else {
      throw InlineImageAssetError.digestMismatch(
        expected: atom.reference.digest, actual: adaptiveDigest)
    }
    guard payload.rendition == adaptivePayload.content else {
      throw InlineImageAssetError.adaptivePayloadMismatch(atom.assetID)
    }
  }
}
