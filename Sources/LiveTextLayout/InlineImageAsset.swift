import Foundation
import LiveTextCore

/// A canonical SHA-256 digest used to bind an inline image reference to the
/// bytes returned by an asset provider.
///
/// The digest is kept as lowercase hexadecimal so it remains stable across
/// Codable transports and does not expose a platform image type to the core
/// package. The implementation is internal and Foundation-only; no image
/// decoding framework is imported here.
public struct InlineAssetDigest: Sendable, Hashable, Codable, CustomStringConvertible {
  private enum CodingKeys: String, CodingKey {
    case hex
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      hex: values.decode(String.self, forKey: .hex)
    )
  }

  public static let byteCount = 32
  public static let hexCharacterCount = byteCount * 2

  public let hex: String

  /// Creates a digest from a lowercase or uppercase 64-character hex value.
  public init(hex: String) throws {
    let normalized = hex.lowercased()
    guard normalized.utf8.count == Self.hexCharacterCount,
      normalized.utf8.allSatisfy(Self.isHexDigit)
    else {
      throw InlineImageAssetError.invalidDigest
    }
    self.hex = normalized
  }

  /// Creates the SHA-256 digest of encoded bytes.
  public init(data: Data) {
    self.hex = Self.hexString(StableSHA256.hash(data: data))
  }

  /// Creates a digest from its 32 raw SHA-256 bytes.
  public init(bytes: [UInt8]) throws {
    guard bytes.count == Self.byteCount else {
      throw InlineImageAssetError.invalidDigest
    }
    self.hex = Self.hexString(bytes)
  }

  public static func sha256(_ data: Data) -> Self {
    Self(data: data)
  }

  public var description: String { hex }

  public var bytes: [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(Self.byteCount)
    let values = Array(hex.utf8)
    for offset in stride(from: 0, to: values.count, by: 2) {
      result.append((Self.hexValue(values[offset]) << 4) | Self.hexValue(values[offset + 1]))
    }
    return result
  }

  public func matches(_ data: Data) -> Bool {
    self == Self(data: data)
  }

  private static func isHexDigit(_ value: UInt8) -> Bool {
    switch value {
    case 48...57, 65...70, 97...102: return true
    default: return false
    }
  }

  private static func hexValue(_ value: UInt8) -> UInt8 {
    switch value {
    case 48...57: return value - 48
    case 65...70: return value - 55
    default: return value - 87
    }
  }

  private static func hexString(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var encoded: [UInt8] = []
    encoded.reserveCapacity(bytes.count * 2)
    for byte in bytes {
      encoded.append(digits[Int(byte >> 4)])
      encoded.append(digits[Int(byte & 0x0f)])
    }
    return String(decoding: encoded, as: UTF8.self)
  }
}

/// Stable identity of encoded inline image content.
public struct InlineImageReference: Sendable, Hashable, Codable, CustomStringConvertible {
  private enum CodingKeys: String, CodingKey {
    case assetID, version, digest
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      assetID: values.decode(InlineAssetID.self, forKey: .assetID),
      version: values.decode(Int.self, forKey: .version),
      digest: values.decode(InlineAssetDigest.self, forKey: .digest)
    )
  }

  public let assetID: InlineAssetID
  public let version: Int
  public let digest: InlineAssetDigest

  public init(
    assetID: InlineAssetID,
    version: Int = 1,
    digest: InlineAssetDigest
  ) throws {
    guard version >= 0 else {
      throw InlineLayoutError.invalidMetric(name: "image assetVersion", value: Double(version))
    }
    self.assetID = assetID
    self.version = version
    self.digest = digest
  }

  /// Creates a reference whose digest is derived from the encoded payload.
  /// The payload itself is still validated when an asset is constructed or
  /// resolved; this initializer only makes the common authoring path concise.
  public init(assetID: InlineAssetID, version: Int = 1, data: Data) throws {
    try self.init(
      assetID: assetID,
      version: version,
      digest: InlineAssetDigest(data: data)
    )
  }

  public var description: String {
    "\(assetID.rawValue)@\(version)#\(digest.hex)"
  }
}

/// How an inline image occupies its already-frozen typographic cell.
public enum InlineImageContentMode: String, Sendable, Hashable, Codable {
  case fit
  case fill
  case stretch
}

/// Explicit font identity for an adaptive image glyph.
///
/// The fingerprint is serialized with the atom and payload so a frozen
/// fallback raster cannot be silently reused with another font.
public struct InlineAdaptiveGlyphConfiguration: Sendable, Hashable, Codable {
  public let font: FontDescriptor
  public let fontFingerprint: String

  public init(font: FontDescriptor, fontFingerprint: String? = nil) throws {
    guard !font.postScriptName.isEmpty else { throw InlineLayoutError.emptyFontName }
    guard font.pointSize.isFinite, font.pointSize > 0 else {
      throw InlineLayoutError.invalidFontSize(font.pointSize)
    }
    if let fontFingerprint {
      guard !fontFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw InlineLayoutError.invalidIdentifier
      }
      self.fontFingerprint = fontFingerprint
    } else {
      var data = Data("Packages/LiveText/font-descriptor-v1".utf8)
      data.append(0)
      data.append(try CanonicalIdentityEncoder.encode(font))
      self.fontFingerprint = InlineAssetDigest(data: data).hex
    }
    self.font = font
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      font: values.decode(FontDescriptor.self, forKey: .font),
      fontFingerprint: values.decode(String.self, forKey: .fontFingerprint)
    )
  }

  private enum CodingKeys: String, CodingKey { case font, fontFingerprint }
}

/// Renderer-neutral image presentation. Platform image and Core Text types
/// remain outside the layout module.
public enum InlineImagePresentation: Sendable, Hashable, Codable {
  case thumbnail(contentMode: InlineImageContentMode)
  case adaptiveGlyph(InlineAdaptiveGlyphConfiguration)

  public static let thumbnail = InlineImagePresentation.thumbnail(contentMode: .fit)

  public var adaptiveConfiguration: InlineAdaptiveGlyphConfiguration? {
    guard case .adaptiveGlyph(let configuration) = self else { return nil }
    return configuration
  }

  public var isAdaptiveGlyph: Bool {
    if case .adaptiveGlyph = self { return true }
    return false
  }

  private enum CodingKeys: String, CodingKey { case kind, contentMode, configuration }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(String.self, forKey: .kind) {
    case "thumbnail":
      self = .thumbnail(
        contentMode: try values.decode(InlineImageContentMode.self, forKey: .contentMode)
      )
    case "adaptiveGlyph":
      self = .adaptiveGlyph(
        try values.decode(InlineAdaptiveGlyphConfiguration.self, forKey: .configuration)
      )
    default:
      throw InlineLayoutError.invalidRenderPlan
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .thumbnail(let contentMode):
      try values.encode("thumbnail", forKey: .kind)
      try values.encode(contentMode, forKey: .contentMode)
    case .adaptiveGlyph(let configuration):
      try values.encode("adaptiveGlyph", forKey: .kind)
      try values.encode(configuration, forKey: .configuration)
    }
  }
}

/// The encoding label is intentionally semantic. The core stores bytes and
/// metadata only; a platform adapter decides whether it can decode a format.
public enum InlineImageEncoding: String, Sendable, Hashable, Codable {
  case png
  case jpeg
  case heic
}

/// Accessibility contract for an inline image. Every image is either named
/// for assistive technologies or explicitly decorative; there is no silent
/// fallback to an asset identifier.
public enum InlineImageAccessibility: Sendable, Hashable, Codable {
  case label(String)
  case decorative

  private enum DecodedValue: Decodable {
    case label(String)
    case decorative
  }

  public init(label: String) throws {
    guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw InlineLayoutError.invalidImageAccessibility
    }
    self = .label(label)
  }

  public init(from decoder: Decoder) throws {
    switch try DecodedValue(from: decoder) {
    case .label(let label):
      try self.init(label: label)
    case .decorative:
      self = .decorative
    }
  }

  public var label: String? {
    guard case .label(let value) = self else { return nil }
    return value
  }

  public var isDecorative: Bool {
    if case .decorative = self { return true }
    return false
  }
}

/// Bounded limits applied to encoded bytes and declared image dimensions.
/// Dimensions are metadata in the Foundation-only layer; decoding is an
/// adapter responsibility and therefore cannot be used to bypass these caps.
public struct InlineImageAssetLimits: Sendable, Hashable, Codable {
  public static let `default` = try! InlineImageAssetLimits()

  public static let maximumEncodedBytesHardCap = 64 * 1024 * 1024
  public static let maximumDimensionHardCap = 32_768
  public static let maximumPixelsHardCap = 268_435_456

  public let maximumEncodedBytes: Int
  public let maximumPixelWidth: Int
  public let maximumPixelHeight: Int
  public let maximumPixels: Int

  public init(
    maximumEncodedBytes: Int = 4 * 1024 * 1024,
    maximumPixelWidth: Int = 8_192,
    maximumPixelHeight: Int = 8_192,
    maximumPixels: Int = 16 * 1024 * 1024
  ) throws {
    guard maximumEncodedBytes > 0,
      maximumEncodedBytes <= Self.maximumEncodedBytesHardCap
    else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "image encoded bytes", actual: maximumEncodedBytes,
        limit: Self.maximumEncodedBytesHardCap)
    }
    guard maximumPixelWidth > 0, maximumPixelWidth <= Self.maximumDimensionHardCap else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "image pixel width", actual: maximumPixelWidth,
        limit: Self.maximumDimensionHardCap)
    }
    guard maximumPixelHeight > 0, maximumPixelHeight <= Self.maximumDimensionHardCap else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "image pixel height", actual: maximumPixelHeight,
        limit: Self.maximumDimensionHardCap)
    }
    guard maximumPixels > 0, maximumPixels <= Self.maximumPixelsHardCap else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "image pixels", actual: maximumPixels,
        limit: Self.maximumPixelsHardCap)
    }
    self.maximumEncodedBytes = maximumEncodedBytes
    self.maximumPixelWidth = maximumPixelWidth
    self.maximumPixelHeight = maximumPixelHeight
    self.maximumPixels = maximumPixels
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maximumEncodedBytes: values.decode(Int.self, forKey: .maximumEncodedBytes),
      maximumPixelWidth: values.decode(Int.self, forKey: .maximumPixelWidth),
      maximumPixelHeight: values.decode(Int.self, forKey: .maximumPixelHeight),
      maximumPixels: values.decode(Int.self, forKey: .maximumPixels)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case maximumEncodedBytes, maximumPixelWidth, maximumPixelHeight, maximumPixels
  }

  func validate(_ asset: InlineEncodedImageAsset) throws {
    let byteCount = asset.encodedBytes.count
    guard byteCount > 0 else { throw InlineImageAssetError.emptyEncodedBytes }
    guard byteCount <= maximumEncodedBytes else {
      throw InlineImageAssetError.encodedBytesLimitExceeded(
        actual: byteCount, limit: maximumEncodedBytes)
    }
    guard asset.pixelWidth > 0, asset.pixelHeight > 0 else {
      throw InlineImageAssetError.invalidPixelDimensions(
        width: asset.pixelWidth, height: asset.pixelHeight)
    }
    guard asset.pixelWidth <= maximumPixelWidth,
      asset.pixelHeight <= maximumPixelHeight
    else {
      throw InlineImageAssetError.pixelDimensionLimitExceeded(
        width: asset.pixelWidth,
        height: asset.pixelHeight,
        maximumWidth: maximumPixelWidth,
        maximumHeight: maximumPixelHeight
      )
    }
    let (pixels, overflow) = asset.pixelWidth.multipliedReportingOverflow(
      by: asset.pixelHeight)
    guard !overflow else {
      throw InlineImageAssetError.pixelCountLimitExceeded(
        actual: Int.max, limit: maximumPixels)
    }
    guard pixels <= maximumPixels else {
      throw InlineImageAssetError.pixelCountLimitExceeded(
        actual: pixels, limit: maximumPixels)
    }
    if let payload = asset.adaptivePayload {
      // The top-level rendition mirrors modern content, but the fallback is
      // an independent encoded raster and must be covered by the same caps.
      try validate(payload.fallbackRaster.png)
    }
  }

  internal func validate(_ rendition: InlineImageRendition) throws {
    let byteCount = rendition.encodedBytes.count
    guard byteCount > 0 else { throw InlineImageAssetError.emptyEncodedBytes }
    guard byteCount <= maximumEncodedBytes else {
      throw InlineImageAssetError.encodedBytesLimitExceeded(
        actual: byteCount, limit: maximumEncodedBytes)
    }
    guard rendition.pixelWidth > 0, rendition.pixelHeight > 0 else {
      throw InlineImageAssetError.invalidPixelDimensions(
        width: rendition.pixelWidth, height: rendition.pixelHeight)
    }
    guard rendition.pixelWidth <= maximumPixelWidth,
      rendition.pixelHeight <= maximumPixelHeight
    else {
      throw InlineImageAssetError.pixelDimensionLimitExceeded(
        width: rendition.pixelWidth,
        height: rendition.pixelHeight,
        maximumWidth: maximumPixelWidth,
        maximumHeight: maximumPixelHeight
      )
    }
    let (pixels, overflow) = rendition.pixelWidth.multipliedReportingOverflow(
      by: rendition.pixelHeight)
    guard !overflow else {
      throw InlineImageAssetError.pixelCountLimitExceeded(
        actual: Int.max, limit: maximumPixels)
    }
    guard pixels <= maximumPixels else {
      throw InlineImageAssetError.pixelCountLimitExceeded(
        actual: pixels, limit: maximumPixels)
    }
  }
}

/// One encoded image rendition. Logical metrics are intentionally not stored
/// here so a fixed raster can be reused at multiple thumbnail sizes.
public struct InlineImageRendition: Sendable, Hashable, Codable {
  public let encoding: InlineImageEncoding
  public let encodedBytes: Data
  public let pixelWidth: Int
  public let pixelHeight: Int

  public init(
    encoding: InlineImageEncoding,
    encodedBytes: Data,
    pixelWidth: Int,
    pixelHeight: Int,
    limits: InlineImageAssetLimits = .default
  ) throws {
    self.encoding = encoding
    self.encodedBytes = encodedBytes
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    try limits.validate(self)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      encoding: values.decode(InlineImageEncoding.self, forKey: .encoding),
      encodedBytes: values.decode(Data.self, forKey: .encodedBytes),
      pixelWidth: values.decode(Int.self, forKey: .pixelWidth),
      pixelHeight: values.decode(Int.self, forKey: .pixelHeight)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case encoding, encodedBytes, pixelWidth, pixelHeight
  }

  internal init(
    uncheckedEncoding: InlineImageEncoding,
    encodedBytes: Data,
    pixelWidth: Int,
    pixelHeight: Int
  ) {
    self.encoding = uncheckedEncoding
    self.encodedBytes = encodedBytes
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }

  public var byteCount: Int { encodedBytes.count }
  public var pixelCount: Int {
    let (value, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
    return overflow ? Int.max : value
  }
}

/// The color space used by a renderer-neutral image payload.
///
/// Adaptive fallback capture is deliberately restricted to one canonical
/// space.  This keeps a serialized fallback independent of the display's
/// current color profile and makes modern/fallback comparisons meaningful.
public enum InlineImageColorSpace: String, Sendable, Hashable, Codable {
  case sRGB
}

/// A baseline-relative paint rectangle expressed in Core Text's y-up space.
///
/// `minY` and `maxY` are relative to the effective baseline (zero).  The
/// rectangle may protrude beyond the typographic ascent/descent and may have a
/// negative `minX`; neither case is clipped by an adaptive renderer.
public struct InlineBaselinePaintBounds: Sendable, Hashable, Codable {
  public let minX: Double
  public let maxX: Double
  public let minY: Double
  public let maxY: Double

  public init(minX: Double, maxX: Double, minY: Double, maxY: Double) throws {
    guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite,
      maxX > minX, maxY > minY,
      (maxX - minX).isFinite, (maxY - minY).isFinite
    else {
      throw InlineImageAssetError.invalidFallbackRaster
    }
    self.minX = minX
    self.maxX = maxX
    self.minY = minY
    self.maxY = maxY
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      minX: values.decode(Double.self, forKey: .minX),
      maxX: values.decode(Double.self, forKey: .maxX),
      minY: values.decode(Double.self, forKey: .minY),
      maxY: values.decode(Double.self, forKey: .maxY)
    )
  }

  private enum CodingKeys: String, CodingKey { case minX, maxX, minY, maxY }

  public var width: Double { maxX - minX }
  public var height: Double { maxY - minY }
}

/// A deterministic raster used by adaptive glyphs on systems below the
/// adaptive-image API availability boundary.
///
/// The PNG is cropped to the visible alpha bounds plus one transparent pixel
/// on every side.  Its logical rectangle is therefore exactly
/// `pixelWidth / pixelsPerPoint` by `pixelHeight / pixelsPerPoint`, while the
/// baseline-relative y-up bounds preserve overhangs that do not fit inside the
/// typographic cell. The v2 persisted contract fixes `pixelsPerPoint` at 3;
/// paint overhang is for culling and drawing only. Hit testing remains the
/// frozen typographic-cell contract, so adaptive overhang is decorative and
/// non-interactive.
public struct InlineAdaptiveFallbackRaster: Sendable, Hashable, Codable {
  public static let defaultPixelsPerPoint = 3.0

  public let png: InlineImageRendition
  public let paintBounds: InlineBaselinePaintBounds
  public let pixelsPerPoint: Double
  public let colorSpace: InlineImageColorSpace

  public init(
    png: InlineImageRendition,
    paintBounds: InlineBaselinePaintBounds,
    pixelsPerPoint: Double = Self.defaultPixelsPerPoint,
    colorSpace: InlineImageColorSpace = .sRGB,
    limits: InlineImageAssetLimits = .default
  ) throws {
    guard png.encoding == .png,
      pixelsPerPoint.isFinite, pixelsPerPoint > 0,
      colorSpace == .sRGB
    else {
      throw InlineImageAssetError.invalidFallbackRaster
    }
    guard pixelsPerPoint == Self.defaultPixelsPerPoint else {
      throw InlineImageAssetError.fallbackRasterPixelsPerPointUnsupported(
        actual: pixelsPerPoint,
        expected: Self.defaultPixelsPerPoint
      )
    }
    try limits.validate(png)
    let expectedWidth = Double(png.pixelWidth) / pixelsPerPoint
    let expectedHeight = Double(png.pixelHeight) / pixelsPerPoint
    let tolerance = 1.0 / max(1.0, pixelsPerPoint * 1_024.0)
    guard abs(paintBounds.width - expectedWidth) <= tolerance,
      abs(paintBounds.height - expectedHeight) <= tolerance
    else {
      throw InlineImageAssetError.fallbackRasterDimensionMismatch
    }
    self.png = png
    self.paintBounds = paintBounds
    self.pixelsPerPoint = pixelsPerPoint
    self.colorSpace = colorSpace
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      png: values.decode(InlineImageRendition.self, forKey: .png),
      paintBounds: values.decode(InlineBaselinePaintBounds.self, forKey: .paintBounds),
      pixelsPerPoint: values.decode(Double.self, forKey: .pixelsPerPoint),
      colorSpace: values.decode(InlineImageColorSpace.self, forKey: .colorSpace)
    )
  }

  private enum CodingKeys: String, CodingKey { case png, paintBounds, pixelsPerPoint, colorSpace }
}

/// Modern adaptive-image content plus its deterministic minimum-OS fallback.
///
/// The digest covers both encoded renditions, fallback placement metadata,
/// frozen metrics, and the explicit font identity. A provider cannot replace
/// only one half of the payload.
public struct InlineAdaptiveImagePayload: Sendable, Hashable, Codable {
  public let content: InlineImageRendition
  public let fallbackRaster: InlineAdaptiveFallbackRaster
  public let metrics: InlineMetrics
  public let font: FontDescriptor
  public let fontFingerprint: String

  public init(
    content: InlineImageRendition,
    fallbackRaster: InlineAdaptiveFallbackRaster,
    metrics: InlineMetrics,
    font: FontDescriptor,
    fontFingerprint: String,
    limits: InlineImageAssetLimits = .default
  ) throws {
    guard !font.postScriptName.isEmpty else { throw InlineLayoutError.emptyFontName }
    guard font.pointSize.isFinite, font.pointSize > 0 else {
      throw InlineLayoutError.invalidFontSize(font.pointSize)
    }
    guard !fontFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw InlineLayoutError.invalidIdentifier
    }
    guard content.encoding == .heic else {
      throw InlineImageAssetError.invalidAdaptiveContentEncoding
    }
    try limits.validate(content)
    try limits.validate(fallbackRaster.png)
    self.content = content
    self.fallbackRaster = fallbackRaster
    self.metrics = metrics
    self.font = font
    self.fontFingerprint = fontFingerprint
  }

  public init(from decoder: Decoder) throws {
    // v1 stored a metric-cell field that was not baseline-aware and could
    // silently clip adaptive overhangs. Reject that serialized schema; do
    // not decode it into the v2 fallback meaning.
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      content: values.decode(InlineImageRendition.self, forKey: .content),
      fallbackRaster: values.decode(InlineAdaptiveFallbackRaster.self, forKey: .fallbackRaster),
      metrics: values.decode(InlineMetrics.self, forKey: .metrics),
      font: values.decode(FontDescriptor.self, forKey: .font),
      fontFingerprint: values.decode(String.self, forKey: .fontFingerprint)
    )
  }

  public init(
    content: InlineImageRendition,
    fallbackRaster: InlineAdaptiveFallbackRaster,
    metrics: InlineMetrics,
    configuration: InlineAdaptiveGlyphConfiguration,
    limits: InlineImageAssetLimits = .default
  ) throws {
    try self.init(
      content: content,
      fallbackRaster: fallbackRaster,
      metrics: metrics,
      font: configuration.font,
      fontFingerprint: configuration.fontFingerprint,
      limits: limits
    )
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(content, forKey: .content)
    try values.encode(fallbackRaster, forKey: .fallbackRaster)
    try values.encode(metrics, forKey: .metrics)
    try values.encode(font, forKey: .font)
    try values.encode(fontFingerprint, forKey: .fontFingerprint)
  }

  /// Stable payload digest used by `InlineImageReference` for adaptive atoms.
  /// Identity construction is fallible and never substitutes a weaker payload.
  public func canonicalDigest() throws -> InlineAssetDigest {
    var canonical = Data("Packages/LiveText/adaptive-image-payload-v3".utf8)
    canonical.append(0)
    canonical.append(try CanonicalIdentityEncoder.encode(self))
    return InlineAssetDigest(data: canonical)
  }

  public func configuration() throws -> InlineAdaptiveGlyphConfiguration {
    try InlineAdaptiveGlyphConfiguration(font: font, fontFingerprint: fontFingerprint)
  }

  private enum CodingKeys: String, CodingKey {
    case content, fallbackRaster, metrics, font, fontFingerprint
    // Decode-only sentinel: this key exists solely to reject the removed v1
    // schema before the v2 fallback is decoded.
  }
}

/// Renderer-neutral image content independent of any one typographic
/// placement. A fixed thumbnail payload can therefore be reused by multiple
/// `InlineImageAtom` values with different frozen metrics. Adaptive payloads
/// retain their own frozen metrics because Core Text derives those metrics from
/// the provider and explicit font identity.
public struct InlineImagePayload: Sendable, Hashable, Codable {
  public let reference: InlineImageReference
  public let rendition: InlineImageRendition
  public let adaptivePayload: InlineAdaptiveImagePayload?

  public init(
    reference: InlineImageReference,
    rendition: InlineImageRendition,
    limits: InlineImageAssetLimits = .default
  ) throws {
    try limits.validate(rendition)
    let actual = InlineAssetDigest(data: rendition.encodedBytes)
    guard actual == reference.digest else {
      throw InlineImageAssetError.digestMismatch(expected: reference.digest, actual: actual)
    }
    self.reference = reference
    self.rendition = rendition
    self.adaptivePayload = nil
  }

  public init(
    reference: InlineImageReference,
    adaptivePayload: InlineAdaptiveImagePayload,
    limits: InlineImageAssetLimits = .default
  ) throws {
    guard adaptivePayload.content.encoding == .heic else {
      throw InlineImageAssetError.invalidAdaptiveContentEncoding
    }
    let payloadDigest = try adaptivePayload.canonicalDigest()
    guard reference.digest == payloadDigest else {
      throw InlineImageAssetError.digestMismatch(
        expected: reference.digest, actual: payloadDigest)
    }
    try limits.validate(adaptivePayload.content)
    try limits.validate(adaptivePayload.fallbackRaster.png)
    self.reference = reference
    self.rendition = adaptivePayload.content
    self.adaptivePayload = adaptivePayload
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let reference = try values.decode(InlineImageReference.self, forKey: .reference)
    let rendition = try values.decode(InlineImageRendition.self, forKey: .rendition)
    if let adaptivePayload = try values.decodeIfPresent(
      InlineAdaptiveImagePayload.self, forKey: .adaptivePayload)
    {
      let validated = try Self(
        reference: reference,
        adaptivePayload: adaptivePayload
      )
      guard rendition == validated.rendition else {
        throw InlineImageAssetError.adaptivePayloadMismatch(reference.assetID)
      }
      self = validated
    } else {
      self = try Self(reference: reference, rendition: rendition)
    }
  }

  internal init(
    uncheckedReference: InlineImageReference,
    rendition: InlineImageRendition,
    adaptivePayload: InlineAdaptiveImagePayload?
  ) {
    self.reference = uncheckedReference
    self.rendition = rendition
    self.adaptivePayload = adaptivePayload
  }

  public var isAdaptiveGlyph: Bool { adaptivePayload != nil }

  public var byteCount: Int {
    rendition.encodedBytes.count + (adaptivePayload?.fallbackRaster.png.encodedBytes.count ?? 0)
  }

  private enum CodingKeys: String, CodingKey {
    case reference, rendition, adaptivePayload
  }
}

/// Errors raised while constructing or validating encoded image assets.
public enum InlineImageAssetError: Error, Equatable, LocalizedError, Sendable {
  case invalidDigest
  case emptyEncodedBytes
  case encodedBytesLimitExceeded(actual: Int, limit: Int)
  case invalidPixelDimensions(width: Int, height: Int)
  case pixelDimensionLimitExceeded(
    width: Int, height: Int, maximumWidth: Int, maximumHeight: Int)
  case pixelCountLimitExceeded(actual: Int, limit: Int)
  case digestMismatch(expected: InlineAssetDigest, actual: InlineAssetDigest)
  case referenceMismatch(expected: InlineImageReference, actual: InlineImageReference)
  case metricsMismatch(InlineAssetID)
  case missingImage(InlineAssetID, version: Int)
  case duplicateReference(InlineImageReference)
  case invalidProviderAsset(InlineAssetID)
  case adaptivePayloadMissing(InlineAssetID)
  case adaptivePayloadMismatch(InlineAssetID)
  case invalidAdaptiveContentEncoding
  case invalidFallbackRaster
  case fallbackRasterDimensionMismatch
  case adaptiveContentTypeMismatch(InlineAssetID, actual: String)
  case adaptiveContentMetadataInvalid(InlineAssetID)
  case adaptiveFallbackCaptureEmpty(InlineAssetID)
  case adaptiveFallbackCaptureLimitExceeded(InlineAssetID, width: Int, height: Int)
  case adaptiveFallbackEncodeFailed(InlineAssetID)
  case adaptiveFallbackColorSpaceUnsupported(InlineAssetID)
  case adaptiveGlyphDescriptionEmpty(InlineAssetID)
  case encodedImageTypeMismatch(InlineAssetID, expected: InlineImageEncoding, actual: String)
  case encodedImageMetadataInvalid(InlineAssetID)
  case encodedImageDimensionsMismatch(
    InlineAssetID, expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
  case encodedImageBitDepthUnsupported(InlineAssetID, actual: Int)
  case encodedImageColorModelUnsupported(InlineAssetID, actual: String)
  case encodedImageColorSpaceUnsupported(InlineAssetID, actual: String)
  case fallbackRasterPixelsPerPointUnsupported(actual: Double, expected: Double)

  public var errorDescription: String? {
    switch self {
    case .invalidDigest:
      return "An inline image SHA-256 digest must contain exactly 64 hexadecimal characters."
    case .emptyEncodedBytes:
      return "Inline image encoded bytes must not be empty."
    case .encodedBytesLimitExceeded(let actual, let limit):
      return "Inline image encoded bytes exceed the limit: \(actual) > \(limit)."
    case .invalidPixelDimensions(let width, let height):
      return "Inline image pixel dimensions must be positive: \(width)x\(height)."
    case .pixelDimensionLimitExceeded(let width, let height, let maximumWidth, let maximumHeight):
      return
        "Inline image dimensions exceed the limit: \(width)x\(height), maximum \(maximumWidth)x\(maximumHeight)."
    case .pixelCountLimitExceeded(let actual, let limit):
      return "Inline image pixel count exceeds the limit: \(actual) > \(limit)."
    case .digestMismatch(let expected, let actual):
      return "Inline image digest mismatch: received \(actual), expected \(expected)."
    case .referenceMismatch(let expected, let actual):
      return "Inline image reference mismatch: received \(actual), expected \(expected)."
    case .metricsMismatch(let id):
      return "Inline image metrics do not match \(id.rawValue)."
    case .missingImage(let id, let version):
      return "Inline image \(id.rawValue) version \(version) is unavailable."
    case .duplicateReference(let reference):
      return "Duplicate inline image payload reference: \(reference)."
    case .invalidProviderAsset(let id):
      return "The inline image provider returned an invalid asset for \(id.rawValue)."
    case .adaptivePayloadMissing(let id):
      return "Adaptive inline image \(id.rawValue) has no deterministic fallback raster."
    case .adaptivePayloadMismatch(let id):
      return "Adaptive inline image payload metadata does not match \(id.rawValue)."
    case .invalidAdaptiveContentEncoding:
      return "Adaptive image content must use the HEIC provider representation."
    case .invalidFallbackRaster:
      return
        "An adaptive fallback raster must be a valid sRGB PNG with finite baseline paint bounds."
    case .fallbackRasterDimensionMismatch:
      return
        "Adaptive fallback paint bounds must match the PNG dimensions at its declared pixels-per-point."
    case .adaptiveContentTypeMismatch(let id, let actual):
      return
        "Adaptive image \(id.rawValue) has unsupported content type \(actual); a HEIC adaptive payload is required."
    case .adaptiveContentMetadataInvalid(let id):
      return "Adaptive image \(id.rawValue) has invalid or missing image metadata."
    case .adaptiveFallbackCaptureEmpty(let id):
      return "Adaptive image \(id.rawValue) produced an empty fallback capture."
    case .adaptiveFallbackCaptureLimitExceeded(let id, let width, let height):
      return
        "Adaptive image \(id.rawValue) fallback capture exceeded bounds at \(width)x\(height) pixels."
    case .adaptiveFallbackEncodeFailed(let id):
      return "Adaptive image \(id.rawValue) fallback PNG encoding failed."
    case .adaptiveFallbackColorSpaceUnsupported(let id):
      return "Adaptive image \(id.rawValue) fallback could not use the canonical sRGB color space."
    case .adaptiveGlyphDescriptionEmpty(let id):
      return "Adaptive image \(id.rawValue) has no non-empty content description for accessibility."
    case .encodedImageTypeMismatch(let id, let expected, let actual):
      return "Encoded image \(id.rawValue) has type \(actual), expected \(expected.rawValue)."
    case .encodedImageMetadataInvalid(let id):
      return "Encoded image \(id.rawValue) has missing or invalid ImageIO metadata."
    case .encodedImageDimensionsMismatch(
      let id, let expectedWidth, let expectedHeight, let actualWidth, let actualHeight):
      return
        "Encoded image \(id.rawValue) declares \(expectedWidth)x\(expectedHeight) but its header is \(actualWidth)x\(actualHeight)."
    case .encodedImageBitDepthUnsupported(let id, let actual):
      return
        "Encoded image \(id.rawValue) uses unsupported bit depth \(actual); only 8-bit samples are supported."
    case .encodedImageColorModelUnsupported(let id, let actual):
      return "Encoded image \(id.rawValue) uses unsupported color model \(actual)."
    case .encodedImageColorSpaceUnsupported(let id, let actual):
      return "Encoded image \(id.rawValue) is not sRGB-compatible: \(actual)."
    case .fallbackRasterPixelsPerPointUnsupported(let actual, let expected):
      return
        "Adaptive fallback raster pixelsPerPoint must be the v2 value \(expected), received \(actual)."
    }
  }
}

/// Encoded image bytes and their provider-supplied metadata.
///
/// This value deliberately contains no `CGImage`, `NSImage`, `UIImage`, or
/// decoder state. A renderer adapter can decode the bytes after core
/// validation and keep that platform object in its own cache.
public struct InlineEncodedImageAsset: Sendable, Hashable, Codable {
  public let reference: InlineImageReference
  public let metrics: InlineMetrics
  public let encoding: InlineImageEncoding
  public let encodedBytes: Data
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let adaptivePayload: InlineAdaptiveImagePayload?

  public init(
    reference: InlineImageReference,
    metrics: InlineMetrics,
    encoding: InlineImageEncoding,
    encodedBytes: Data,
    pixelWidth: Int,
    pixelHeight: Int,
    limits: InlineImageAssetLimits = .default
  ) throws {
    self.reference = reference
    self.metrics = metrics
    self.encoding = encoding
    self.encodedBytes = encodedBytes
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.adaptivePayload = nil
    try limits.validate(self)
    let actual = InlineAssetDigest(data: encodedBytes)
    guard actual == reference.digest else {
      throw InlineImageAssetError.digestMismatch(expected: reference.digest, actual: actual)
    }
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let reference = try values.decode(InlineImageReference.self, forKey: .reference)
    if let adaptivePayload = try values.decodeIfPresent(
      InlineAdaptiveImagePayload.self, forKey: .adaptivePayload)
    {
      let value = try Self(reference: reference, payload: adaptivePayload)
      // The mirrored top-level rendition is retained for metric-bound
      // providers. If it is present in serialized data, every
      // field must still agree with the adaptive payload.
      if let metrics = try values.decodeIfPresent(InlineMetrics.self, forKey: .metrics),
        metrics != value.metrics
      {
        throw InlineImageAssetError.adaptivePayloadMismatch(reference.assetID)
      }
      if let encoding = try values.decodeIfPresent(
        InlineImageEncoding.self, forKey: .encoding),
        encoding != value.encoding
      {
        throw InlineImageAssetError.adaptivePayloadMismatch(reference.assetID)
      }
      if let bytes = try values.decodeIfPresent(Data.self, forKey: .encodedBytes),
        bytes != value.encodedBytes
      {
        throw InlineImageAssetError.adaptivePayloadMismatch(reference.assetID)
      }
      if let width = try values.decodeIfPresent(Int.self, forKey: .pixelWidth),
        width != value.pixelWidth
      {
        throw InlineImageAssetError.adaptivePayloadMismatch(reference.assetID)
      }
      if let height = try values.decodeIfPresent(Int.self, forKey: .pixelHeight),
        height != value.pixelHeight
      {
        throw InlineImageAssetError.adaptivePayloadMismatch(reference.assetID)
      }
      self = value
    } else {
      self = try Self(
        reference: reference,
        metrics: values.decode(InlineMetrics.self, forKey: .metrics),
        encoding: values.decode(InlineImageEncoding.self, forKey: .encoding),
        encodedBytes: values.decode(Data.self, forKey: .encodedBytes),
        pixelWidth: values.decode(Int.self, forKey: .pixelWidth),
        pixelHeight: values.decode(Int.self, forKey: .pixelHeight)
      )
    }
  }

  /// Creates an adaptive asset whose modern content and deterministic fallback
  /// share one reference digest. The top-level rendition mirrors modern
  /// content for existing provider code; adapters select `adaptivePayload`.
  public init(
    reference: InlineImageReference,
    payload: InlineAdaptiveImagePayload,
    limits: InlineImageAssetLimits = .default
  ) throws {
    guard payload.content.encoding == .heic else {
      throw InlineImageAssetError.invalidAdaptiveContentEncoding
    }
    let payloadDigest = try payload.canonicalDigest()
    guard reference.digest == payloadDigest else {
      throw InlineImageAssetError.digestMismatch(
        expected: reference.digest, actual: payloadDigest)
    }
    self.reference = reference
    self.metrics = payload.metrics
    self.encoding = payload.content.encoding
    self.encodedBytes = payload.content.encodedBytes
    self.pixelWidth = payload.content.pixelWidth
    self.pixelHeight = payload.content.pixelHeight
    self.adaptivePayload = payload
    try limits.validate(self)
    try limits.validate(payload.fallbackRaster.png)
  }

  public var isAdaptiveGlyph: Bool { adaptivePayload != nil }

  /// The encoded bytes as a placement-independent rendition. New callers that
  /// reuse one raster across placements should store an `InlineImagePayload`.
  public var rendition: InlineImageRendition {
    InlineImageRendition(
      uncheckedEncoding: encoding,
      encodedBytes: encodedBytes,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
  }

  public var byteCount: Int { encodedBytes.count }
  public var totalByteCount: Int {
    encodedBytes.count + (adaptivePayload?.fallbackRaster.png.encodedBytes.count ?? 0)
  }
  public var pixelCount: Int {
    let (value, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
    return overflow ? Int.max : value
  }

  private enum CodingKeys: String, CodingKey {
    case reference, metrics, encoding, encodedBytes, pixelWidth, pixelHeight, adaptivePayload
  }
}

/// An image atom embeds stable metadata in the document while keeping bytes
/// in a separately resolved asset store.
public struct InlineImageAtom: Sendable, Hashable, Codable {
  public let id: String
  public let reference: InlineImageReference
  public let metrics: InlineMetrics
  public let presentation: InlineImagePresentation
  public let breakBehavior: InlineBreakBehavior
  public let accessibility: InlineImageAccessibility

  public var assetID: InlineAssetID { reference.assetID }
  public var assetVersion: Int { reference.version }
  public var digest: InlineAssetDigest { reference.digest }
  public var accessibilityLabel: String? { accessibility.label }
  public var isDecorative: Bool { accessibility.isDecorative }

  public init(
    id: String,
    reference: InlineImageReference,
    metrics: InlineMetrics,
    presentation: InlineImagePresentation = .thumbnail,
    breakBehavior: InlineBreakBehavior = .normal,
    accessibility: InlineImageAccessibility
  ) throws {
    guard !id.isEmpty else { throw InlineLayoutError.invalidIdentifier }
    switch accessibility {
    case .label(let label):
      guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw InlineLayoutError.invalidImageAccessibility
      }
    case .decorative:
      break
    }
    self.id = id
    self.reference = reference
    self.metrics = metrics
    self.presentation = presentation
    self.breakBehavior = breakBehavior
    self.accessibility = accessibility
  }

  public init(
    id: String,
    assetID: InlineAssetID,
    assetVersion: Int = 1,
    digest: InlineAssetDigest,
    metrics: InlineMetrics,
    presentation: InlineImagePresentation = .thumbnail,
    breakBehavior: InlineBreakBehavior = .normal,
    accessibilityLabel: String? = nil,
    isDecorative: Bool = false
  ) throws {
    let reference = try InlineImageReference(
      assetID: assetID, version: assetVersion, digest: digest)
    let accessibility: InlineImageAccessibility
    if let accessibilityLabel {
      guard !isDecorative else { throw InlineLayoutError.invalidImageAccessibility }
      accessibility = try InlineImageAccessibility(label: accessibilityLabel)
    } else if isDecorative {
      accessibility = .decorative
    } else {
      throw InlineLayoutError.invalidImageAccessibility
    }
    try self.init(
      id: id,
      reference: reference,
      metrics: metrics,
      presentation: presentation,
      breakBehavior: breakBehavior,
      accessibility: accessibility
    )
  }

  public init(
    id: String,
    asset: InlineEncodedImageAsset,
    presentation: InlineImagePresentation? = nil,
    breakBehavior: InlineBreakBehavior = .normal,
    accessibilityLabel: String? = nil,
    isDecorative: Bool = false
  ) throws {
    try self.init(
      id: id,
      assetID: asset.reference.assetID,
      assetVersion: asset.reference.version,
      digest: asset.reference.digest,
      metrics: asset.metrics,
      presentation: try Self.resolvedPresentation(
        explicit: presentation, adaptivePayload: asset.adaptivePayload
      ),
      breakBehavior: breakBehavior,
      accessibilityLabel: accessibilityLabel,
      isDecorative: isDecorative
    )
  }

  private static func resolvedPresentation(
    explicit: InlineImagePresentation?,
    adaptivePayload: InlineAdaptiveImagePayload?
  ) throws -> InlineImagePresentation {
    if let explicit { return explicit }
    if let adaptivePayload {
      return .adaptiveGlyph(try adaptivePayload.configuration())
    }
    return .thumbnail
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(String.self, forKey: .id),
      reference: values.decode(InlineImageReference.self, forKey: .reference),
      metrics: values.decode(InlineMetrics.self, forKey: .metrics),
      presentation: values.decode(InlineImagePresentation.self, forKey: .presentation),
      breakBehavior: values.decode(InlineBreakBehavior.self, forKey: .breakBehavior),
      accessibility: values.decode(InlineImageAccessibility.self, forKey: .accessibility)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id, reference, metrics, presentation, breakBehavior, accessibility
  }
}

/// Provider boundary for image bytes. Implementations may fetch, read, or
/// otherwise own transport state; this Foundation-only layer validates the
/// returned value before publishing it.
public protocol InlineImageAssetProvider: Sendable {
  func resolveImage(
    reference: InlineImageReference,
    metrics: InlineMetrics,
    limits: InlineImageAssetLimits
  ) throws -> InlineEncodedImageAsset
}

/// A validated image atom paired with its immutable prepared representation.
public struct PreparedInlineImage: Sendable, Hashable, Codable {
  public let atom: InlineImageAtom

  public init(atom: InlineImageAtom) {
    self.atom = atom
  }
}
