import CoreGraphics
import Foundation
import ImageIO
import LiveTextCore
public import LiveTextLayout
import UniformTypeIdentifiers

#if canImport(CoreText)
  import CoreText
#endif

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// The result of preparing one adaptive image glyph for an inline document.
///
/// `atom` contains only renderer-neutral identity, presentation, and frozen
/// typographic metrics. `asset` contains the adaptive HEIC bytes and the
/// deterministic baseline-aware PNG used below the adaptive-image API's
/// availability boundary.
public struct InlineAdaptiveImageGlyphArtifact: Sendable, Hashable {
  public let atom: InlineImageAtom
  public let asset: InlineEncodedImageAsset
  public let payload: InlineImagePayload

  public init(atom: InlineImageAtom, asset: InlineEncodedImageAsset) throws {
    guard atom.reference == asset.reference,
      atom.metrics == asset.metrics,
      let adaptivePayload = asset.adaptivePayload
    else {
      throw InlineImageAssetError.adaptivePayloadMismatch(atom.assetID)
    }
    let payload = try InlineImagePayload(
      reference: asset.reference,
      adaptivePayload: adaptivePayload
    )
    self.atom = atom
    self.asset = asset
    self.payload = payload
  }

  /// Stores the same adaptive content without binding it to a second logical
  /// placement. This is useful when a document contains repeated glyphs.
  public var imageStore: InlineImageAssetStore {
    // `payload` was validated by the initializer, so this cannot fail.
    try! InlineImageAssetStore(payloads: [payload])
  }
}

/// Creates adaptive image atoms with metrics frozen from Core Text on modern
/// Apple systems.
public enum InlineAdaptiveImageGlyphFactory {

  #if canImport(CoreText) && (canImport(AppKit) || canImport(UIKit))
    /// Creates an adaptive inline image from Apple's public image-glyph model.
    ///
    /// The factory derives accessibility from `contentDescription` when the
    /// caller does not provide it, freezes the exact Core Text metrics, and
    /// captures a deterministic sRGB fallback at three pixels per point. No
    /// fallback image argument is required from the caller.
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
    public static func make(
      id: String,
      assetID: InlineAssetID,
      version: Int = 2,
      adaptiveGlyph: NSAdaptiveImageGlyph,
      font: FontDescriptor,
      fontFingerprint: String? = nil,
      breakBehavior: InlineBreakBehavior = .normal,
      accessibility: InlineImageAccessibility? = nil,
      limits: InlineImageAssetLimits = .default
    ) throws -> InlineAdaptiveImageGlyphArtifact {
      let resolvedAccessibility: InlineImageAccessibility
      if let accessibility {
        resolvedAccessibility = accessibility
      } else {
        let description = adaptiveGlyph.contentDescription
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
          throw InlineImageAssetError.adaptiveGlyphDescriptionEmpty(assetID)
        }
        resolvedAccessibility = try InlineImageAccessibility(label: description)
      }

      let configuration = try InlineAdaptiveGlyphConfiguration(
        font: font,
        fontFingerprint: fontFingerprint
      )
      let content = try adaptiveContentRendition(
        for: adaptiveGlyph,
        assetID: assetID,
        limits: limits
      )
      let ctFont = try makeFont(configuration)
      let bounds = try adaptiveBounds(
        font: ctFont,
        provider: adaptiveGlyph,
        assetID: assetID
      )
      let metrics = try metrics(from: bounds)
      let fallbackRaster = try captureFallbackRaster(
        font: ctFont,
        provider: adaptiveGlyph,
        typographicBounds: bounds,
        assetID: assetID,
        limits: limits
      )
      return try makeArtifact(
        id: id,
        assetID: assetID,
        version: version,
        content: content,
        fallbackRaster: fallbackRaster,
        metrics: metrics,
        configuration: configuration,
        breakBehavior: breakBehavior,
        accessibility: resolvedAccessibility,
        limits: limits
      )
    }
  #endif

  /// Builds an artifact from already-frozen adaptive bytes and fallback
  /// geometry. This is intentionally package-internal: persistence and authoring should
  /// use the `NSAdaptiveImageGlyph` overload so Core Text and the fallback are
  /// captured together.
  package static func makeWithFrozenAdaptivePayload(
    id: String,
    assetID: InlineAssetID,
    version: Int = 2,
    adaptiveContent: InlineImageRendition,
    fallbackRaster: InlineAdaptiveFallbackRaster,
    metrics: InlineMetrics,
    font: FontDescriptor,
    fontFingerprint: String? = nil,
    breakBehavior: InlineBreakBehavior = .normal,
    accessibility: InlineImageAccessibility,
    limits: InlineImageAssetLimits = .default
  ) throws -> InlineAdaptiveImageGlyphArtifact {
    guard adaptiveContent.encoding == .heic else {
      throw InlineImageAssetError.invalidAdaptiveContentEncoding
    }
    let configuration = try InlineAdaptiveGlyphConfiguration(
      font: font,
      fontFingerprint: fontFingerprint
    )
    return try makeArtifact(
      id: id,
      assetID: assetID,
      version: version,
      content: adaptiveContent,
      fallbackRaster: fallbackRaster,
      metrics: metrics,
      configuration: configuration,
      breakBehavior: breakBehavior,
      accessibility: accessibility,
      limits: limits
    )
  }

  private static func makeArtifact(
    id: String,
    assetID: InlineAssetID,
    version: Int,
    content: InlineImageRendition,
    fallbackRaster: InlineAdaptiveFallbackRaster,
    metrics: InlineMetrics,
    configuration: InlineAdaptiveGlyphConfiguration,
    breakBehavior: InlineBreakBehavior,
    accessibility: InlineImageAccessibility,
    limits: InlineImageAssetLimits
  ) throws -> InlineAdaptiveImageGlyphArtifact {
    let payload = try InlineAdaptiveImagePayload(
      content: content,
      fallbackRaster: fallbackRaster,
      metrics: metrics,
      configuration: configuration,
      limits: limits
    )
    let reference = try InlineImageReference(
      assetID: assetID,
      version: version,
      digest: try payload.canonicalDigest()
    )
    let asset = try InlineEncodedImageAsset(
      reference: reference,
      payload: payload,
      limits: limits
    )
    let atom = try InlineImageAtom(
      id: id,
      reference: reference,
      metrics: metrics,
      presentation: .adaptiveGlyph(configuration),
      breakBehavior: breakBehavior,
      accessibility: accessibility
    )
    return try InlineAdaptiveImageGlyphArtifact(atom: atom, asset: asset)
  }

  #if canImport(CoreText) && (canImport(AppKit) || canImport(UIKit))
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
    private static func adaptiveContentRendition(
      for glyph: NSAdaptiveImageGlyph,
      assetID: InlineAssetID,
      limits: InlineImageAssetLimits
    ) throws -> InlineImageRendition {
      let bytes = glyph.imageContent
      guard !bytes.isEmpty else {
        throw InlineImageAssetError.emptyEncodedBytes
      }
      // Check the byte cap before asking ImageIO for any image representation.
      guard bytes.count <= limits.maximumEncodedBytes else {
        throw InlineImageAssetError.encodedBytesLimitExceeded(
          actual: bytes.count,
          limit: limits.maximumEncodedBytes
        )
      }

      let expectedType = NSAdaptiveImageGlyph.contentType.identifier
      guard expectedType == UTType.heic.identifier else {
        throw InlineImageAssetError.adaptiveContentTypeMismatch(
          assetID,
          actual: expectedType
        )
      }
      guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
        CGImageSourceGetCount(source) > 0,
        let sourceType = CGImageSourceGetType(source),
        (sourceType as String) == expectedType,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
        width > 0,
        height > 0
      else {
        throw InlineImageAssetError.adaptiveContentMetadataInvalid(assetID)
      }
      // `InlineImageRendition` applies dimensions and pixel caps without
      // decoding the primary image. The adaptive provider performs decoding
      // later, only inside the deterministic capture below.
      return try InlineImageRendition(
        encoding: .heic,
        encodedBytes: bytes,
        pixelWidth: width,
        pixelHeight: height,
        limits: limits
      )
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
    private static func makeFont(
      _ configuration: InlineAdaptiveGlyphConfiguration
    ) throws -> CTFont {
      let font = CTFontCreateWithName(
        configuration.font.postScriptName as CFString,
        configuration.font.pointSize,
        nil
      )
      guard let resolvedName = CTFontCopyPostScriptName(font) as String?,
        resolvedName == configuration.font.postScriptName
      else {
        throw InlineLayoutError.unsupportedShaping(
          "adaptive image font '\(configuration.font.postScriptName)' was not resolved"
        )
      }
      return font
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
    private static func adaptiveBounds(
      font: CTFont,
      provider: NSAdaptiveImageGlyph,
      assetID: InlineAssetID
    ) throws -> CGRect {
      guard !provider.imageContent.isEmpty else {
        throw InlineImageAssetError.invalidProviderAsset(assetID)
      }
      let bounds = CTFontGetTypographicBoundsForAdaptiveImageProvider(font, provider)
      guard bounds.minX.isFinite,
        bounds.minY.isFinite,
        bounds.width.isFinite,
        bounds.width > 0,
        bounds.height.isFinite,
        bounds.height > 0,
        bounds.maxX.isFinite,
        bounds.maxY.isFinite
      else {
        throw InlineImageAssetError.invalidProviderAsset(assetID)
      }
      return bounds
    }

    private static func metrics(from bounds: CGRect) throws -> InlineMetrics {
      try InlineMetrics(
        advance: Double(bounds.width),
        ascent: max(0, Double(bounds.maxY)),
        descent: max(0, Double(-bounds.minY)),
        baselineOffset: 0
      )
    }

    private struct PixelBounds {
      var minX: Int
      var maxX: Int
      var minY: Int
      var maxY: Int

      var width: Int { maxX - minX }
      var height: Int { maxY - minY }

      func expanded(by pixels: Int) -> PixelBounds {
        PixelBounds(
          minX: minX - pixels,
          maxX: maxX + pixels,
          minY: minY - pixels,
          maxY: maxY + pixels
        )
      }
    }

    private struct CapturedBitmap {
      let image: CGImage
      let pixels: Data
      let width: Int
      let height: Int
      let bytesPerRow: Int
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
    private static func captureFallbackRaster(
      font: CTFont,
      provider: NSAdaptiveImageGlyph,
      typographicBounds: CGRect,
      assetID: InlineAssetID,
      limits: InlineImageAssetLimits
    ) throws -> InlineAdaptiveFallbackRaster {
      let pixelsPerPoint = InlineAdaptiveFallbackRaster.defaultPixelsPerPoint
      let scale = CGFloat(pixelsPerPoint)
      var capture = try initialCaptureBounds(
        typographicBounds,
        scale: scale,
        paddingPixels: 2,
        assetID: assetID
      )

      // A provider is allowed to paint outside its typographic bounds. Grow
      // the capture until alpha no longer touches its boundary, or fail at a
      // typed resource limit instead of clipping and claiming success.
      for _ in 0..<64 {
        guard capture.width > 0,
          capture.height > 0,
          capture.width <= limits.maximumPixelWidth,
          capture.height <= limits.maximumPixelHeight,
          pixelsResultIsValid(capture.width, capture.height, limit: limits.maximumPixels)
        else {
          throw InlineImageAssetError.adaptiveFallbackCaptureLimitExceeded(
            assetID,
            width: max(0, capture.width),
            height: max(0, capture.height)
          )
        }

        let captured = try captureBitmap(
          font: font,
          provider: provider,
          capture: capture,
          scale: scale,
          assetID: assetID
        )
        guard let alpha = alphaBounds(in: captured) else {
          throw InlineImageAssetError.adaptiveFallbackCaptureEmpty(assetID)
        }
        if alpha.minX == 0 || alpha.minY == 0
          || alpha.maxX == captured.width || alpha.maxY == captured.height
        {
          capture = capture.expanded(by: 8)
          continue
        }

        // One transparent pixel is retained around the detected ink. The
        // alpha scan and CGImage crop use raw image rows whose origin is the
        // top-left. The stored baseline bounds convert that crop back to the
        // lower-left y-up coordinate system below.
        let crop = PixelBounds(
          minX: alpha.minX - 1,
          maxX: alpha.maxX + 1,
          minY: alpha.minY - 1,
          maxY: alpha.maxY + 1
        )
        guard crop.minX >= 0,
          crop.minY >= 0,
          crop.maxX <= captured.width,
          crop.maxY <= captured.height,
          crop.width > 0,
          crop.height > 0
        else {
          throw InlineImageAssetError.adaptiveFallbackCaptureLimitExceeded(
            assetID,
            width: captured.width,
            height: captured.height
          )
        }
        guard
          let cropped = captured.image.cropping(
            to: CGRect(
              x: crop.minX,
              y: crop.minY,
              width: crop.width,
              height: crop.height
            )
          )
        else {
          throw InlineImageAssetError.adaptiveFallbackEncodeFailed(assetID)
        }
        let pngData = try encodePNG(
          cropped,
          assetID: assetID,
          limits: limits
        )
        let rendition = try InlineImageRendition(
          encoding: .png,
          encodedBytes: pngData,
          pixelWidth: crop.width,
          pixelHeight: crop.height,
          limits: limits
        )
        let paintBounds = try InlineBaselinePaintBounds(
          minX: Double(capture.minX) / pixelsPerPoint + Double(crop.minX) / pixelsPerPoint,
          maxX: Double(capture.minX) / pixelsPerPoint + Double(crop.maxX) / pixelsPerPoint,
          minY: Double(capture.minY) / pixelsPerPoint
            + Double(captured.height - crop.maxY) / pixelsPerPoint,
          maxY: Double(capture.minY) / pixelsPerPoint
            + Double(captured.height - crop.minY) / pixelsPerPoint
        )
        return try InlineAdaptiveFallbackRaster(
          png: rendition,
          paintBounds: paintBounds,
          pixelsPerPoint: pixelsPerPoint,
          colorSpace: .sRGB,
          limits: limits
        )
      }
      throw InlineImageAssetError.adaptiveFallbackCaptureLimitExceeded(
        assetID,
        width: max(0, capture.width),
        height: max(0, capture.height)
      )
    }

    private static func initialCaptureBounds(
      _ bounds: CGRect,
      scale: CGFloat,
      paddingPixels: Int,
      assetID: InlineAssetID
    ) throws -> PixelBounds {
      guard bounds.minX.isFinite, bounds.maxX.isFinite,
        bounds.minY.isFinite, bounds.maxY.isFinite,
        scale.isFinite, scale > 0
      else { throw InlineImageAssetError.invalidProviderAsset(assetID) }
      let minX =
        try pixelCoordinate(
          bounds.minX * scale,
          rounding: .down,
          assetID: assetID
        ) - paddingPixels
      let maxX =
        try pixelCoordinate(
          bounds.maxX * scale,
          rounding: .up,
          assetID: assetID
        ) + paddingPixels
      let minY =
        try pixelCoordinate(
          bounds.minY * scale,
          rounding: .down,
          assetID: assetID
        ) - paddingPixels
      let maxY =
        try pixelCoordinate(
          bounds.maxY * scale,
          rounding: .up,
          assetID: assetID
        ) + paddingPixels
      guard maxX > minX, maxY > minY else {
        throw InlineImageAssetError.invalidProviderAsset(assetID)
      }
      return PixelBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    private static func pixelCoordinate(
      _ value: CGFloat,
      rounding: FloatingPointRoundingRule,
      assetID: InlineAssetID
    ) throws -> Int {
      let rounded = value.rounded(rounding)
      guard rounded.isFinite,
        rounded >= CGFloat(Int.min + 1_024),
        rounded <= CGFloat(Int.max - 1_024)
      else {
        throw InlineImageAssetError.adaptiveFallbackCaptureLimitExceeded(
          assetID,
          width: Int.max,
          height: Int.max
        )
      }
      return Int(rounded)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
    private static func captureBitmap(
      font: CTFont,
      provider: NSAdaptiveImageGlyph,
      capture: PixelBounds,
      scale: CGFloat,
      assetID: InlineAssetID
    ) throws -> CapturedBitmap {
      let width = capture.width
      let height = capture.height
      let bytesPerRow = width.multipliedReportingOverflow(by: 4)
      guard !bytesPerRow.overflow else {
        throw InlineImageAssetError.adaptiveFallbackCaptureLimitExceeded(
          assetID,
          width: width,
          height: height
        )
      }
      let byteCount = bytesPerRow.partialValue.multipliedReportingOverflow(by: height)
      guard !byteCount.overflow
      else {
        throw InlineImageAssetError.adaptiveFallbackCaptureLimitExceeded(
          assetID,
          width: width,
          height: height
        )
      }
      guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw InlineImageAssetError.adaptiveFallbackColorSpaceUnsupported(assetID)
      }
      var pixels = Data(repeating: 0, count: byteCount.partialValue)
      let image: CGImage? = pixels.withUnsafeMutableBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress,
          let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow.partialValue,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
        else { return nil }
        // The capture rectangle is pixel-aligned in baseline-relative y-up
        // coordinates. Drawing at (0, 0) therefore preserves the baseline
        // origin while translating the capture's lower-left corner to (0, 0).
        context.scaleBy(x: scale, y: scale)
        context.translateBy(
          x: -CGFloat(capture.minX) / scale,
          y: -CGFloat(capture.minY) / scale
        )
        CTFontDrawImageFromAdaptiveImageProviderAtPoint(
          font,
          provider,
          .zero,
          context
        )
        return context.makeImage()
      }
      guard let image else {
        throw InlineImageAssetError.adaptiveFallbackEncodeFailed(assetID)
      }
      guard image.colorSpace?.name == CGColorSpace.sRGB else {
        throw InlineImageAssetError.adaptiveFallbackColorSpaceUnsupported(assetID)
      }
      return CapturedBitmap(
        image: image,
        pixels: pixels,
        width: width,
        height: height,
        bytesPerRow: bytesPerRow.partialValue
      )
    }

    private static func pixelsResultIsValid(
      _ width: Int,
      _ height: Int,
      limit: Int
    ) -> Bool {
      let result = width.multipliedReportingOverflow(by: height)
      return !result.overflow && result.partialValue <= limit
    }

    private static func alphaBounds(in bitmap: CapturedBitmap) -> PixelBounds? {
      var result: PixelBounds?
      bitmap.pixels.withUnsafeBytes { rawBuffer in
        guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
          return
        }
        var minX = bitmap.width
        var maxX = 0
        var minY = bitmap.height
        var maxY = 0
        var found = false
        for rawRow in 0..<bitmap.height {
          // CGBitmapContext memory and CGImage cropping both use top-to-bottom
          // rows. Baseline-relative geometry is converted after cropping.
          let row = bytes.advanced(by: rawRow * bitmap.bytesPerRow)
          for x in 0..<bitmap.width {
            let alpha = row[x * 4 + 3]
            guard alpha != 0 else { continue }
            found = true
            minX = min(minX, x)
            maxX = max(maxX, x + 1)
            minY = min(minY, rawRow)
            maxY = max(maxY, rawRow + 1)
          }
        }
        if found {
          result = PixelBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
        }
      }
      return result
    }

    private static func encodePNG(
      _ image: CGImage,
      assetID: InlineAssetID,
      limits: InlineImageAssetLimits
    ) throws -> Data {
      let output = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          output,
          UTType.png.identifier as CFString,
          1,
          nil
        )
      else {
        throw InlineImageAssetError.adaptiveFallbackEncodeFailed(assetID)
      }
      // No metadata is attached, so the same pixel buffer and color space
      // produce the same serialized PNG independent of display scale/profile.
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else {
        throw InlineImageAssetError.adaptiveFallbackEncodeFailed(assetID)
      }
      let data = output as Data
      guard !data.isEmpty else {
        throw InlineImageAssetError.adaptiveFallbackEncodeFailed(assetID)
      }
      guard data.count <= limits.maximumEncodedBytes else {
        throw InlineImageAssetError.encodedBytesLimitExceeded(
          actual: data.count,
          limit: limits.maximumEncodedBytes
        )
      }
      return data
    }
  #endif
}
