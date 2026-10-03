import CoreGraphics
import Foundation
import ImageIO
public import LiveTextLayout
import SwiftUI
import UniformTypeIdentifiers

#if canImport(CoreText)
  import CoreText
#endif

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

#if canImport(CoreText) && (canImport(AppKit) || canImport(UIKit))
  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
  private func makeAdaptiveProvider(data: Data) -> NSAdaptiveImageGlyph {
    NSAdaptiveImageGlyph(imageContent: data)
  }

  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
  private func adaptiveMetrics(font: CTFont, provider: NSAdaptiveImageGlyph) -> CGRect {
    CTFontGetTypographicBoundsForAdaptiveImageProvider(font, provider)
  }
#endif

/// A bounded, main-actor image cache used by both SwiftUI and Canvas. The key
/// contains the immutable asset reference, presentation, scale, and color
/// space so a decoded image is never reused for a different rendition.
@MainActor
public final class InlineImageRenderCache {
  public struct Key: Sendable, Hashable {
    public let reference: InlineImageReference
    public let presentation: InlineImagePresentation
    public let scale: Double
    public let colorSpace: String

    public init(
      reference: InlineImageReference,
      presentation: InlineImagePresentation,
      scale: Double = 1,
      colorSpace: String = "sRGB"
    ) throws {
      guard scale.isFinite, scale > 0 else {
        throw InlineLayoutError.invalidMetric(name: "image cache scale", value: scale)
      }
      guard !colorSpace.isEmpty else { throw InlineLayoutError.invalidIdentifier }
      self.reference = reference
      self.presentation = presentation
      self.scale = scale
      self.colorSpace = colorSpace
    }
  }

  fileprivate struct Entry {
    let image: CGImage
    let byteCount: Int
  }

  public let maximumBytes: Int
  private var values: [Key: Entry] = [:]
  private var order: [Key] = []
  private var activeTransaction: Transaction?
  private(set) public var byteCount = 0

  public init(maximumBytes: Int = 32 * 1024 * 1024) throws {
    guard maximumBytes > 0 else {
      throw InlineLayoutError.assetCacheLimitExceeded(actual: maximumBytes, limit: 1)
    }
    self.maximumBytes = maximumBytes
  }

  public var count: Int { values.count }

  /// A short-lived staged cache view. Renderers create one before preparing a
  /// candidate and commit it only after every fallible image operation has
  /// succeeded. The staged view copies the small LRU index, so a failed
  /// candidate cannot alter entries, byte accounting, evictions, or order.
  @MainActor
  package final class Transaction {
    private weak var owner: InlineImageRenderCache?
    private var values: [Key: Entry]
    private var order: [Key]
    private var byteCount: Int
    private var isActive = true

    fileprivate init(owner: InlineImageRenderCache) {
      self.owner = owner
      self.values = owner.values
      self.order = owner.order
      self.byteCount = owner.byteCount
    }

    fileprivate func image(
      for key: Key,
      load: () throws -> CGImage
    ) throws -> CGImage {
      guard isActive else { throw InlineLayoutError.invalidContinuation }
      return try InlineImageRenderCache.resolve(
        key: key,
        load: load,
        values: &values,
        order: &order,
        byteCount: &byteCount,
        maximumBytes: owner?.maximumBytes ?? 0
      )
    }

    /// Publishes the staged cache state. This operation is intentionally
    /// nonthrowing: all resource validation happens while staging.
    package func commit() {
      guard isActive else { return }
      if let owner, owner.activeTransaction === self {
        owner.values = values
        owner.order = order
        owner.byteCount = byteCount
        owner.activeTransaction = nil
      }
      isActive = false
    }

    /// Discards all staged hits, insertions, and evictions.
    package func rollback() {
      guard isActive else { return }
      if let owner, owner.activeTransaction === self {
        owner.activeTransaction = nil
      }
      isActive = false
    }
  }

  /// Whether another candidate currently owns the cache's publication
  /// boundary. This is package-internal so the SwiftUI and Canvas adapters can join one
  /// transaction instead of publishing each section independently.
  package var hasActiveTransaction: Bool { activeTransaction != nil }

  /// Starts a cache candidate transaction. Only one transaction is permitted
  /// at a time because the cache is main-actor isolated and its LRU order is a
  /// single serial resource.
  package func beginTransaction() -> Transaction {
    precondition(activeTransaction == nil, "an image cache transaction is already active")
    let transaction = Transaction(owner: self)
    activeTransaction = transaction
    return transaction
  }

  public func image(
    for key: Key,
    load: () throws -> CGImage
  ) throws -> CGImage {
    if let activeTransaction {
      return try activeTransaction.image(for: key, load: load)
    }
    return try Self.resolve(
      key: key,
      load: load,
      values: &values,
      order: &order,
      byteCount: &byteCount,
      maximumBytes: maximumBytes
    )
  }

  public func removeAll() {
    values.removeAll(keepingCapacity: true)
    order.removeAll(keepingCapacity: true)
    byteCount = 0
  }

  fileprivate static func resolve(
    key: Key,
    load: () throws -> CGImage,
    values: inout [Key: Entry],
    order: inout [Key],
    byteCount: inout Int,
    maximumBytes: Int
  ) throws -> CGImage {
    if let entry = values[key] {
      touch(key, order: &order)
      return entry.image
    }
    let image = try load()
    let bytesPerRow = max(1, image.bytesPerRow)
    let (estimatedBytes, overflow) = bytesPerRow.multipliedReportingOverflow(by: image.height)
    guard !overflow else {
      throw InlineLayoutError.assetCacheLimitExceeded(actual: Int.max, limit: maximumBytes)
    }
    let entry = Entry(image: image, byteCount: estimatedBytes)
    guard estimatedBytes <= maximumBytes else {
      throw InlineLayoutError.assetCacheLimitExceeded(
        actual: estimatedBytes, limit: maximumBytes)
    }
    while true {
      let (projectedBytes, overflow) = byteCount.addingReportingOverflow(estimatedBytes)
      guard !overflow else {
        throw InlineLayoutError.assetCacheLimitExceeded(actual: Int.max, limit: maximumBytes)
      }
      guard projectedBytes > maximumBytes else { break }
      guard let evicted = order.first else { break }
      order.removeFirst()
      if let old = values.removeValue(forKey: evicted) {
        byteCount -= old.byteCount
      }
    }
    values[key] = entry
    order.append(key)
    byteCount += estimatedBytes
    return image
  }

  private static func touch(_ key: Key, order: inout [Key]) {
    guard let index = order.firstIndex(of: key) else { return }
    order.remove(at: index)
    order.append(key)
  }
}

/// One predecoded image paint operation. All decoding, provider construction,
/// and metric validation happen before a renderer's frame callback.
@MainActor
package final class InlineImagePaintEntry {
  public enum Kind: String {
    case bitmap
    case adaptiveGlyph
  }

  public let kind: Kind
  public let localPaintBounds: CGRect

  private let image: CGImage?
  private let drawBounds: CGRect
  private let clipBounds: CGRect?
  private let adaptiveDraw: ((CGPoint, CGContext) -> Void)?
  private let adaptiveBaselineY: CGFloat?
  private let adaptiveBaselineX: CGFloat?
  private let isAdaptiveModern: Bool

  fileprivate init(
    image: CGImage,
    drawBounds: CGRect,
    clipBounds: CGRect?,
    kind: Kind = .bitmap
  ) throws {
    guard Self.isValid(bounds: drawBounds) else { throw InlineLayoutError.invalidRenderPlan }
    self.kind = kind
    if let clipBounds {
      guard Self.isValid(bounds: clipBounds),
        !drawBounds.intersection(clipBounds).isNull,
        drawBounds.intersection(clipBounds).width > 0,
        drawBounds.intersection(clipBounds).height > 0
      else { throw InlineLayoutError.invalidRenderPlan }
      self.localPaintBounds = drawBounds.intersection(clipBounds)
    } else {
      self.localPaintBounds = drawBounds
    }
    self.image = image
    self.drawBounds = drawBounds
    self.clipBounds = clipBounds
    self.adaptiveDraw = nil
    self.adaptiveBaselineY = nil
    self.adaptiveBaselineX = nil
    self.isAdaptiveModern = false
  }

  #if canImport(CoreText) && (canImport(AppKit) || canImport(UIKit))
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
    fileprivate init(
      adaptiveFont: CTFont,
      adaptiveProvider: NSAdaptiveImageGlyph,
      localPaintBounds: CGRect,
      baselineY: CGFloat
    ) throws {
      guard Self.isValid(bounds: localPaintBounds),
        baselineY.isFinite
      else { throw InlineLayoutError.invalidRenderPlan }
      self.kind = .adaptiveGlyph
      self.localPaintBounds = localPaintBounds
      self.image = nil
      self.drawBounds = localPaintBounds
      self.clipBounds = nil
      self.adaptiveDraw = { point, context in
        CTFontDrawImageFromAdaptiveImageProviderAtPoint(
          adaptiveFont, adaptiveProvider, point, context)
      }
      self.adaptiveBaselineY = baselineY
      // The adaptive provider was captured at the Core Text baseline origin
      // `(0, 0)`.  Paint bounds may start at a positive offset (transparent
      // source padding) or a negative offset (ink overhang), but neither
      // changes the provider's baseline point.
      self.adaptiveBaselineX = 0
      self.isAdaptiveModern = true
    }
  #endif

  private static func isValid(bounds: CGRect) -> Bool {
    bounds.minX.isFinite && bounds.minY.isFinite
      && bounds.width.isFinite && bounds.width > 0
      && bounds.height.isFinite && bounds.height > 0
      && bounds.maxX.isFinite && bounds.maxY.isFinite
  }

  /// Draws in a fragment-local y-down coordinate system. Core Text's adaptive
  /// API is given the baseline point after a local y-up transform; the state
  /// is always restored before returning to the renderer.
  public func draw(in context: inout GraphicsContext) {
    if isAdaptiveModern {
      #if canImport(CoreText) && (canImport(AppKit) || canImport(UIKit))
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *), let adaptiveDraw {
          context.withCGContext { cgContext in
            cgContext.saveGState()
            // Core Text receives a baseline point in y-up space. The inline
            // cell is y-down, so the local baseline is the frozen ascent,
            // not the bottom of the cell.
            cgContext.translateBy(x: 0, y: adaptiveBaselineY ?? 0)
            cgContext.scaleBy(x: 1, y: -1)
            adaptiveDraw(
              CGPoint(x: adaptiveBaselineX ?? drawBounds.minX, y: 0),
              cgContext
            )
            cgContext.restoreGState()
          }
        }
      #endif
    } else if let image {
      context.withCGContext { cgContext in
        cgContext.saveGState()
        if let clipBounds { cgContext.clip(to: clipBounds) }
        cgContext.draw(image, in: drawBounds)
        cgContext.restoreGState()
      }
    }
  }
}

/// Compiles image atoms into predecoded bitmap or Core Text adaptive paint
/// entries. Adaptive metrics are checked against the frozen atom metrics; a
/// mismatch aborts the entire candidate before a renderer publishes it.
@MainActor
package enum InlineImagePaintCompiler {
  public static func compile(
    geometry: [PreparedInlineGeometry],
    assets: InlineImageAssetStore,
    cache: InlineImageRenderCache? = nil,
    scale: Double = 1
  ) throws -> [PositionedInlineAtom: InlineImagePaintEntry] {
    try withCacheTransaction(cache) {
      var result: [PositionedInlineAtom: InlineImagePaintEntry] = [:]
      for item in geometry {
        guard case .image(let positioned, let prepared) = item else { continue }
        let atom = prepared.atom
        guard let payload = assets.payload(for: atom.reference) else {
          throw InlineImageAssetError.missingImage(atom.assetID, version: atom.assetVersion)
        }
        let entry = try compile(
          positioned: positioned, atom: atom, payload: payload, cache: cache, scale: scale)
        result[positioned] = entry
      }
      return result
    }
  }

  public static func compile(
    positioned: PositionedInlineAtom,
    atom: InlineImageAtom,
    asset: InlineEncodedImageAsset,
    cache: InlineImageRenderCache? = nil,
    scale: Double = 1
  ) throws -> InlineImagePaintEntry {
    let payload: InlineImagePayload
    if let adaptivePayload = asset.adaptivePayload {
      payload = try InlineImagePayload(
        reference: asset.reference, adaptivePayload: adaptivePayload)
    } else {
      payload = try InlineImagePayload(
        reference: asset.reference, rendition: asset.rendition)
    }
    return try compile(
      positioned: positioned,
      atom: atom,
      payload: payload,
      cache: cache,
      scale: scale
    )
  }

  /// Compiles placement-independent image content against the atom's frozen
  /// metrics. This overload is what permits one fixed raster payload to be
  /// reused at multiple thumbnail sizes.
  public static func compile(
    positioned: PositionedInlineAtom,
    atom: InlineImageAtom,
    payload: InlineImagePayload,
    cache: InlineImageRenderCache? = nil,
    scale: Double = 1
  ) throws -> InlineImagePaintEntry {
    try compile(
      positioned: positioned,
      atom: atom,
      payload: payload,
      cache: cache,
      scale: scale,
      forceMinimumOS: false
    )
  }

  /// Exercises the deterministic minimum-OS branch with a fully validated
  /// artifact. This is package-internal for adapter tests and diagnostics; normal callers
  /// must let availability select the modern provider path.
  package static func compileMinimumOSForTesting(
    positioned: PositionedInlineAtom,
    atom: InlineImageAtom,
    payload: InlineImagePayload,
    cache: InlineImageRenderCache? = nil,
    scale: Double = 1
  ) throws -> InlineImagePaintEntry {
    try compile(
      positioned: positioned,
      atom: atom,
      payload: payload,
      cache: cache,
      scale: scale,
      forceMinimumOS: true
    )
  }

  /// Package-internal counterpart to the normal batch compiler for deterministic render
  /// back tests of the minimum-OS path.
  package static func compileMinimumOSForTesting(
    geometry: [PreparedInlineGeometry],
    assets: InlineImageAssetStore,
    cache: InlineImageRenderCache? = nil,
    scale: Double = 1
  ) throws -> [PositionedInlineAtom: InlineImagePaintEntry] {
    try withCacheTransaction(cache) {
      var result: [PositionedInlineAtom: InlineImagePaintEntry] = [:]
      for item in geometry {
        guard case .image(let positioned, let prepared) = item else { continue }
        let atom = prepared.atom
        guard let payload = assets.payload(for: atom.reference) else {
          throw InlineImageAssetError.missingImage(atom.assetID, version: atom.assetVersion)
        }
        result[positioned] = try compile(
          positioned: positioned,
          atom: atom,
          payload: payload,
          cache: cache,
          scale: scale,
          forceMinimumOS: true
        )
      }
      return result
    }
  }

  private static func compile(
    positioned: PositionedInlineAtom,
    atom: InlineImageAtom,
    payload: InlineImagePayload,
    cache: InlineImageRenderCache?,
    scale: Double,
    forceMinimumOS: Bool
  ) throws -> InlineImagePaintEntry {
    try withCacheTransaction(cache) {
      guard positioned.kind == .image, positioned.scale == 1,
        positioned.sourceRange == nil,
        abs(positioned.width - atom.metrics.advance) <= 1.0 / 64.0,
        abs(positioned.metrics.advance - atom.metrics.advance) <= 1.0 / 64.0,
        abs(positioned.metrics.ascent - atom.metrics.ascent) <= 1.0 / 64.0,
        abs(positioned.metrics.descent - atom.metrics.descent) <= 1.0 / 64.0,
        abs(positioned.metrics.baselineOffset - atom.metrics.baselineOffset) <= 1.0 / 64.0,
        abs(positioned.height - atom.metrics.ascent - atom.metrics.descent) <= 1.0 / 64.0
      else { throw InlineLayoutError.invalidRenderPlan }
      guard scale.isFinite, scale > 0 else {
        throw InlineLayoutError.invalidMetric(name: "image scale", value: scale)
      }

      switch atom.presentation {
      case .thumbnail(let contentMode):
        guard payload.adaptivePayload == nil,
          payload.reference == atom.reference
        else {
          throw InlineImageAssetError.adaptivePayloadMismatch(atom.assetID)
        }
        let image = try decoded(
          rendition: payload.rendition,
          reference: payload.reference,
          presentation: atom.presentation,
          scale: scale,
          cache: cache
        )
        let bounds = destinationRect(
          contentMode: contentMode,
          pixelWidth: payload.rendition.pixelWidth,
          pixelHeight: payload.rendition.pixelHeight,
          cellWidth: positioned.width,
          cellHeight: positioned.height
        )
        let cellBounds = CGRect(x: 0, y: 0, width: positioned.width, height: positioned.height)
        return try InlineImagePaintEntry(
          image: image, drawBounds: bounds, clipBounds: cellBounds)

      case .adaptiveGlyph(let configuration):
        guard let adaptivePayload = payload.adaptivePayload,
          payload.reference == atom.reference
        else {
          throw InlineLayoutError.adaptiveGlyphFallbackUnavailable(atom.assetID)
        }
        let adaptiveDigest = try adaptivePayload.canonicalDigest()
        guard adaptivePayload.metrics == atom.metrics,
          adaptivePayload.font == configuration.font,
          adaptivePayload.fontFingerprint == configuration.fontFingerprint,
          payload.reference.digest == adaptiveDigest
        else { throw InlineLayoutError.adaptiveGlyphMetricsMismatch(atom.assetID) }
        guard adaptivePayload.content.encoding == .heic else {
          throw InlineImageAssetError.invalidProviderAsset(atom.assetID)
        }

        #if canImport(CoreText) && (canImport(AppKit) || canImport(UIKit))
          if !forceMinimumOS,
            #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
          {
            guard
              let source = CGImageSourceCreateWithData(
                adaptivePayload.content.encodedBytes as CFData, nil
              ), CGImageSourceGetCount(source) > 0
            else {
              throw InlineImageAssetError.invalidProviderAsset(atom.assetID)
            }
            try preflight(
              rendition: adaptivePayload.content,
              reference: payload.reference,
              source: source
            )
            let font = CTFontCreateWithName(
              configuration.font.postScriptName as CFString,
              configuration.font.pointSize,
              nil
            )
            guard let resolvedName = CTFontCopyPostScriptName(font) as String?,
              resolvedName == configuration.font.postScriptName
            else {
              throw InlineLayoutError.unsupportedShaping(
                "adaptive image font '\(configuration.font.postScriptName)' was not resolved")
            }
            let provider = makeAdaptiveProvider(data: adaptivePayload.content.encodedBytes)
            guard !provider.imageContent.isEmpty,
              provider.imageContent == adaptivePayload.content.encodedBytes
            else { throw InlineImageAssetError.invalidProviderAsset(atom.assetID) }
            let bounds = adaptiveMetrics(font: font, provider: provider)
            guard bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.width > 0,
              bounds.height.isFinite, bounds.height > 0,
              bounds.maxX.isFinite, bounds.maxY.isFinite
            else { throw InlineImageAssetError.invalidProviderAsset(atom.assetID) }
            let derived = try InlineMetrics(
              advance: max(0, Double(bounds.width)),
              ascent: max(0, Double(bounds.maxY)),
              descent: max(0, Double(-bounds.minY)),
              baselineOffset: atom.metrics.baselineOffset
            )
            guard metricsEqual(derived, atom.metrics) else {
              throw InlineLayoutError.adaptiveGlyphMetricsMismatch(atom.assetID)
            }
            let paint = adaptivePayload.fallbackRaster.paintBounds
            let localPaintBounds = CGRect(
              x: CGFloat(paint.minX),
              y: CGFloat(atom.metrics.ascent - paint.maxY),
              width: CGFloat(paint.width),
              height: CGFloat(paint.height)
            )
            return try InlineImagePaintEntry(
              adaptiveFont: font,
              adaptiveProvider: provider,
              localPaintBounds: localPaintBounds,
              baselineY: CGFloat(atom.metrics.ascent)
            )
          }
        #endif

        // The minimum OS path deliberately ignores modern provider content. It
        // only draws the pre-captured baseline-aware fallback raster. Unlike a
        // fixed thumbnail, adaptive paint is not clipped to the typographic
        // cell because its stored bounds may intentionally protrude.
        let fallback = adaptivePayload.fallbackRaster
        let image = try decoded(
          rendition: fallback.png,
          reference: payload.reference,
          presentation: atom.presentation,
          scale: scale,
          cache: cache
        )
        let paint = fallback.paintBounds
        let drawBounds = CGRect(
          x: CGFloat(paint.minX),
          y: CGFloat(atom.metrics.ascent - paint.maxY),
          width: CGFloat(paint.width),
          height: CGFloat(paint.height)
        )
        return try InlineImagePaintEntry(
          image: image,
          drawBounds: drawBounds,
          clipBounds: nil,
          kind: .adaptiveGlyph
        )
      }
    }
  }

  private static func metricsEqual(_ lhs: InlineMetrics, _ rhs: InlineMetrics) -> Bool {
    let tolerance = 1.0 / 64.0
    return abs(lhs.advance - rhs.advance) <= tolerance
      && abs(lhs.ascent - rhs.ascent) <= tolerance
      && abs(lhs.descent - rhs.descent) <= tolerance
      && abs(lhs.baselineOffset - rhs.baselineOffset) <= tolerance
  }

  private static func destinationRect(
    contentMode: InlineImageContentMode,
    pixelWidth: Int,
    pixelHeight: Int,
    cellWidth: Double,
    cellHeight: Double
  ) -> CGRect {
    let width = CGFloat(cellWidth)
    let height = CGFloat(cellHeight)
    guard contentMode != .stretch, pixelWidth > 0, pixelHeight > 0 else {
      return CGRect(x: 0, y: 0, width: width, height: height)
    }
    let imageAspect = CGFloat(pixelWidth) / CGFloat(pixelHeight)
    let cellAspect = width / max(height, 0.0001)
    let scale: CGFloat
    switch contentMode {
    case .fit: scale = min(width / CGFloat(pixelWidth), height / CGFloat(pixelHeight))
    case .fill: scale = max(width / CGFloat(pixelWidth), height / CGFloat(pixelHeight))
    case .stretch: scale = 1
    }
    let drawWidth = CGFloat(pixelWidth) * scale
    let drawHeight = CGFloat(pixelHeight) * scale
    let x = (width - drawWidth) * 0.5
    let y = (height - drawHeight) * 0.5
    _ = imageAspect
    _ = cellAspect
    return CGRect(x: x, y: y, width: drawWidth, height: drawHeight)
  }

  private static func decoded(
    rendition: InlineImageRendition,
    reference: InlineImageReference,
    presentation: InlineImagePresentation,
    scale: Double,
    cache: InlineImageRenderCache?
  ) throws -> CGImage {
    let key = try InlineImageRenderCache.Key(
      reference: reference, presentation: presentation, scale: scale)
    guard let source = CGImageSourceCreateWithData(rendition.encodedBytes as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else {
      throw InlineImageAssetError.invalidProviderAsset(reference.assetID)
    }
    try preflight(rendition: rendition, reference: reference, source: source)
    let load = {
      guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else {
        throw InlineImageAssetError.invalidProviderAsset(reference.assetID)
      }
      guard image.width == rendition.pixelWidth, image.height == rendition.pixelHeight else {
        throw InlineImageAssetError.invalidPixelDimensions(
          width: image.width, height: image.height)
      }
      return image
    }
    if let cache { return try cache.image(for: key, load: load) }
    return try load()
  }

  /// Inspects the encoded image type, header metadata, and resource bounds
  /// before any decoded pixel buffer can be allocated. Thumbnail payloads
  /// must match their declared PNG, JPEG, or HEIC container exactly. Adaptive
  /// fallbacks remain canonical 8-bit sRGB PNGs; validating actual metadata
  /// prevents a forged 1x1 declaration from hiding a much larger image.
  private static func preflight(
    rendition: InlineImageRendition,
    reference: InlineImageReference,
    source: CGImageSource
  ) throws {
    let expectedType: String
    switch rendition.encoding {
    case .png:
      expectedType = UTType.png.identifier
    case .jpeg:
      expectedType = UTType.jpeg.identifier
    case .heic:
      expectedType = UTType.heic.identifier
    }
    guard let sourceType = CGImageSourceGetType(source) else {
      throw InlineImageAssetError.encodedImageMetadataInvalid(reference.assetID)
    }
    let actualType = sourceType as String
    guard actualType == expectedType else {
      throw InlineImageAssetError.encodedImageTypeMismatch(
        reference.assetID, expected: rendition.encoding, actual: actualType)
    }
    let limits = InlineImageAssetLimits.default
    func validateDimensions(_ width: Int, _ height: Int) throws {
      guard width > 0, height > 0 else {
        throw InlineImageAssetError.encodedImageMetadataInvalid(reference.assetID)
      }
      // Apply the same caps to dimensions read from the actual file header,
      // before comparing with caller-declared dimensions or decoding pixels.
      guard width <= limits.maximumPixelWidth, height <= limits.maximumPixelHeight else {
        throw InlineImageAssetError.pixelDimensionLimitExceeded(
          width: width,
          height: height,
          maximumWidth: limits.maximumPixelWidth,
          maximumHeight: limits.maximumPixelHeight
        )
      }
      let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
      guard !overflow else {
        throw InlineImageAssetError.pixelCountLimitExceeded(
          actual: Int.max, limit: limits.maximumPixels)
      }
      guard pixels <= limits.maximumPixels else {
        throw InlineImageAssetError.pixelCountLimitExceeded(
          actual: pixels, limit: limits.maximumPixels)
      }
    }

    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
    guard let properties,
      let actualWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let actualHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    else {
      // Some ImageIO versions decline to materialize a property dictionary
      // for a deliberately enormous PNG header. Read only the fixed IHDR
      // bytes in that case so the cap still rejects the bomb before any decode.
      guard rendition.encoding == .png,
        let header = pngHeaderDimensions(rendition.encodedBytes)
      else {
        throw InlineImageAssetError.encodedImageMetadataInvalid(reference.assetID)
      }
      try validateDimensions(header.width, header.height)
      throw InlineImageAssetError.encodedImageMetadataInvalid(reference.assetID)
    }
    try validateDimensions(actualWidth, actualHeight)
    guard actualWidth == rendition.pixelWidth, actualHeight == rendition.pixelHeight else {
      throw InlineImageAssetError.encodedImageDimensionsMismatch(
        reference.assetID,
        expectedWidth: rendition.pixelWidth,
        expectedHeight: rendition.pixelHeight,
        actualWidth: actualWidth,
        actualHeight: actualHeight
      )
    }

    guard rendition.encoding == .png else { return }
    guard let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue else {
      throw InlineImageAssetError.encodedImageMetadataInvalid(reference.assetID)
    }
    guard depth == 8 else {
      throw InlineImageAssetError.encodedImageBitDepthUnsupported(
        reference.assetID, actual: depth)
    }
    guard let colorModel = properties[kCGImagePropertyColorModel] as? String else {
      throw InlineImageAssetError.encodedImageMetadataInvalid(reference.assetID)
    }
    guard
      colorModel == (kCGImagePropertyColorModelRGB as String)
        || colorModel == (kCGImagePropertyColorModelGray as String)
    else {
      throw InlineImageAssetError.encodedImageColorModelUnsupported(
        reference.assetID, actual: colorModel)
    }
    if (properties[kCGImagePropertyIsIndexed] as? NSNumber)?.boolValue == true {
      throw InlineImageAssetError.encodedImageColorModelUnsupported(
        reference.assetID, actual: "indexed")
    }
    if (properties[kCGImagePropertyIsFloat] as? NSNumber)?.boolValue == true {
      throw InlineImageAssetError.encodedImageBitDepthUnsupported(
        reference.assetID, actual: depth)
    }

    // A missing profile is the PNG default (sRGB); an explicit profile must
    // name sRGB. The PNG sRGB intent is also an explicit compatible marker.
    let profileName =
      (properties[kCGImagePropertyProfileName] as? String)
      ?? ""
    let pngDictionary = properties[kCGImagePropertyPNGDictionary] as? NSDictionary
    let hasSRGBIntent = pngDictionary?[kCGImagePropertyPNGsRGBIntent] != nil
    guard
      profileName.isEmpty
        || profileName.localizedCaseInsensitiveContains("srgb")
        || hasSRGBIntent
    else {
      throw InlineImageAssetError.encodedImageColorSpaceUnsupported(
        reference.assetID, actual: profileName)
    }
  }

  private static func pngHeaderDimensions(_ data: Data) -> (width: Int, height: Int)? {
    let signature: [UInt8] = [
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ]
    guard data.count >= 29,
      data.prefix(8).elementsEqual(signature),
      data[8] == 0,
      data[9] == 0,
      data[10] == 0,
      data[11] == 13,
      data[12] == 0x49,
      data[13] == 0x48,
      data[14] == 0x44,
      data[15] == 0x52
    else { return nil }
    let width = Int(
      UInt32(data[16]) << 24 | UInt32(data[17]) << 16
        | UInt32(data[18]) << 8 | UInt32(data[19]))
    let height = Int(
      UInt32(data[20]) << 24 | UInt32(data[21]) << 16
        | UInt32(data[22]) << 8 | UInt32(data[23]))
    guard width > 0, height > 0 else { return nil }
    return (width, height)
  }

  private static func withCacheTransaction<Result>(
    _ cache: InlineImageRenderCache?,
    operation: () throws -> Result
  ) throws -> Result {
    let transaction: InlineImageRenderCache.Transaction?
    if let cache, !cache.hasActiveTransaction {
      transaction = cache.beginTransaction()
    } else {
      transaction = nil
    }
    var committed = false
    defer {
      if let transaction, !committed { transaction.rollback() }
    }
    let result = try operation()
    transaction?.commit()
    committed = true
    return result
  }
}
