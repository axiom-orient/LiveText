import Foundation

public enum InlineAssetResolutionError: Error, Equatable, LocalizedError, Sendable {
  case duplicateAssetID(InlineAssetID)
  case missingAsset(InlineAssetID, version: Int)
  case versionMismatch(InlineAssetID, expected: Int, actual: Int)
  case metricsMismatch(InlineAssetID)
  case missingGeometry(InlineAssetID, version: Int)

  public var errorDescription: String? {
    switch self {
    case .duplicateAssetID(let id): return "Duplicate inline asset: \(id.rawValue)."
    case .missingAsset(let id, let version):
      return "Missing inline asset \(id.rawValue) version \(version)."
    case .versionMismatch(let id, let expected, let actual):
      return "Inline asset \(id.rawValue) version mismatch: \(actual), expected \(expected)."
    case .metricsMismatch(let id): return "Inline asset metrics do not match \(id.rawValue)."
    case .missingGeometry(let id, let version):
      return "Inline asset geometry is unavailable for \(id.rawValue) version \(version)."
    }
  }
}

public struct InlineAssetRecord: Sendable, Hashable, Codable {
  public let id: InlineAssetID
  public let version: Int
  public let metrics: InlineMetrics
  public let accessibilityLabel: String?
  public let geometry: InlineSVGAsset?
  /// Optional encoded image payload for image atoms. The payload is kept
  /// renderer-neutral; a platform adapter owns decoding and display objects.
  public let image: InlineEncodedImageAsset?

  public init(
    id: InlineAssetID,
    version: Int,
    metrics: InlineMetrics,
    accessibilityLabel: String? = nil,
    geometry: InlineSVGAsset? = nil,
    image: InlineEncodedImageAsset? = nil
  ) throws {
    guard version >= 0 else {
      throw InlineLayoutError.invalidMetric(name: "assetVersion", value: Double(version))
    }
    self.id = id
    self.version = version
    self.metrics = metrics
    self.accessibilityLabel = accessibilityLabel
    self.geometry = geometry
    self.image = image
    if let geometry {
      guard geometry.id == id, geometry.version == version, geometry.metrics == metrics else {
        throw InlineAssetResolutionError.metricsMismatch(id)
      }
    }
    guard geometry == nil || image == nil else {
      throw InlineImageAssetError.invalidProviderAsset(id)
    }
    if let image {
      guard image.reference.assetID == id,
        image.reference.version == version,
        image.metrics == metrics
      else {
        throw InlineImageAssetError.metricsMismatch(id)
      }
    }
  }

  public init(asset: InlineSVGAsset) throws {
    try self.init(
      id: asset.id,
      version: asset.version,
      metrics: asset.metrics,
      accessibilityLabel: asset.accessibilityLabel,
      geometry: asset,
      image: nil
    )
  }

  public init(image: InlineEncodedImageAsset) throws {
    try self.init(
      id: image.reference.assetID,
      version: image.reference.version,
      metrics: image.metrics,
      image: image
    )
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(InlineAssetID.self, forKey: .id),
      version: values.decode(Int.self, forKey: .version),
      metrics: values.decode(InlineMetrics.self, forKey: .metrics),
      accessibilityLabel: values.decodeIfPresent(String.self, forKey: .accessibilityLabel),
      geometry: values.decodeIfPresent(InlineSVGAsset.self, forKey: .geometry),
      image: values.decodeIfPresent(InlineEncodedImageAsset.self, forKey: .image)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id, version, metrics, accessibilityLabel, geometry, image
  }
}

public struct InlineAssetRegistry: Sendable, Hashable, Codable {
  private enum CodingKeys: String, CodingKey {
    case records
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      records: values.decode([InlineAssetRecord].self, forKey: .records)
    )
  }

  public let records: [InlineAssetRecord]

  public static let empty = try! InlineAssetRegistry(records: [])

  public init(records: [InlineAssetRecord]) throws {
    var ids = Set<InlineAssetID>()
    for record in records {
      guard ids.insert(record.id).inserted else {
        throw InlineAssetResolutionError.duplicateAssetID(record.id)
      }
    }
    self.records = records
  }

  public func validate(document: InlineDocument) throws {
    var recordsByID: [InlineAssetID: InlineAssetRecord] = [:]
    recordsByID.reserveCapacity(records.count)
    for record in records { recordsByID[record.id] = record }
    for atom in document.atoms {
      switch atom {
      case .text:
        continue
      case .vector(let vector):
        guard let record = recordsByID[vector.assetID] else {
          throw InlineAssetResolutionError.missingAsset(
            vector.assetID, version: vector.assetVersion)
        }
        guard record.version == vector.assetVersion else {
          throw InlineAssetResolutionError.versionMismatch(
            vector.assetID, expected: vector.assetVersion, actual: record.version)
        }
        guard record.metrics == vector.metrics else {
          throw InlineAssetResolutionError.metricsMismatch(vector.assetID)
        }
      case .image(let image):
        guard let record = recordsByID[image.assetID] else {
          throw InlineAssetResolutionError.missingAsset(image.assetID, version: image.assetVersion)
        }
        guard record.version == image.assetVersion else {
          throw InlineAssetResolutionError.versionMismatch(
            image.assetID, expected: image.assetVersion, actual: record.version)
        }
        guard record.metrics == image.metrics else {
          throw InlineAssetResolutionError.metricsMismatch(image.assetID)
        }
        if let asset = record.image {
          guard asset.reference == image.reference else {
            throw InlineImageAssetError.referenceMismatch(
              expected: image.reference, actual: asset.reference)
          }
          guard asset.metrics == image.metrics else {
            throw InlineImageAssetError.metricsMismatch(image.assetID)
          }
          switch image.presentation {
          case .thumbnail:
            guard asset.adaptivePayload == nil else {
              throw InlineImageAssetError.adaptivePayloadMismatch(image.assetID)
            }
          case .adaptiveGlyph(let configuration):
            guard let payload = asset.adaptivePayload,
              payload.metrics == image.metrics,
              payload.font == configuration.font,
              payload.fontFingerprint == configuration.fontFingerprint,
              !payload.fallbackRaster.png.encodedBytes.isEmpty
            else {
              throw InlineImageAssetError.adaptivePayloadMissing(image.assetID)
            }
            guard payload.content.encoding == .heic else {
              throw InlineImageAssetError.invalidProviderAsset(image.assetID)
            }
            let payloadDigest = try payload.canonicalDigest()
            guard asset.reference.digest == payloadDigest else {
              throw InlineImageAssetError.adaptivePayloadMismatch(image.assetID)
            }
          }
        }
      }
    }
  }
}
