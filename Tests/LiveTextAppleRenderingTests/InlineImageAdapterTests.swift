import CoreGraphics
import CoreText
import Foundation
import ImageIO
@testable import LiveTextAppleRendering
@testable import LiveTextCanvas
import LiveTextCore
import LiveTextLayout
@testable import LiveTextSwiftUI
import SwiftUI
import UniformTypeIdentifiers
import XCTest

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

@MainActor
final class InlineImageAdapterTests: XCTestCase {
  func testOnePayloadCanServeDifferentThumbnailPlacements() throws {
    let payload = try makeThumbnailPayload()
    let store = try InlineImageAssetStore(payloads: [payload])
    let firstMetrics = try InlineMetrics(advance: 12, ascent: 8, descent: 4)
    let secondMetrics = try InlineMetrics(advance: 24, ascent: 16, descent: 8)
    let first = try InlineImageAtom(
      id: "small",
      reference: payload.reference,
      metrics: firstMetrics,
      presentation: .thumbnail(contentMode: .fit),
      accessibility: .label("Small")
    )
    let second = try InlineImageAtom(
      id: "large",
      reference: payload.reference,
      metrics: secondMetrics,
      presentation: .thumbnail(contentMode: .fill),
      accessibility: .label("Large")
    )
    let document = try InlineDocument(atoms: [.image(first), .image(second)])

    XCTAssertNoThrow(try validateInlineImageAssets(document: document, store: store))
    XCTAssertEqual(store.payload(for: payload.reference), payload)
    XCTAssertEqual(payload.rendition.pixelWidth, 1)
    XCTAssertEqual(payload.rendition.pixelHeight, 1)
  }

  func testThumbnailFillPaintBoundsAndDrawAreClippedToItsCell() throws {
    let data = try XCTUnwrap(Data(base64Encoded: Self.twoByOnePNG))
    let rendition = try InlineImageRendition(
      encoding: .png, encodedBytes: data, pixelWidth: 2, pixelHeight: 1)
    let assetID = try InlineAssetID(rawValue: "fill-thumbnail")
    let reference = try InlineImageReference(
      assetID: assetID, version: 1, digest: InlineAssetDigest(data: data))
    let payload = try InlineImagePayload(reference: reference, rendition: rendition)
    let metrics = try InlineMetrics(advance: 10, ascent: 8, descent: 4)
    let atom = try InlineImageAtom(
      id: "fill-thumbnail",
      reference: reference,
      metrics: metrics,
      presentation: .thumbnail(contentMode: .fill),
      accessibility: .label("Fill thumbnail")
    )
    let document = try InlineDocument(atoms: [.image(atom)])
    let prepared = try InlinePreparation(shaper: NoopImageShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 100)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let positioned = try XCTUnwrap(layout.lines.first?.atoms.first)
    let paint = try XCTUnwrap(
      InlineImagePaintCompiler.compile(
        geometry: plan.geometry,
        assets: try InlineImageAssetStore(payloads: [payload])
      )[positioned]
    )

    // A 2:1 image in a 10x12 cell has a fill draw rect wider than the cell.
    // The paint command's effective bounds must nevertheless remain the cell;
    // the command itself applies the same clip before drawing.
    XCTAssertEqual(paint.localPaintBounds, CGRect(x: 0, y: 0, width: 10, height: 12))
    XCTAssertLessThanOrEqual(paint.localPaintBounds.width, 10)
    XCTAssertLessThanOrEqual(paint.localPaintBounds.height, 12)
  }

  func testImagePaintCompilationFailureDoesNotPublishCacheCandidate() throws {
    let first = try makeThumbnailPayload(id: "cache-first")
    let second = try makeThumbnailPayload(id: "cache-second")
    let missingData = try XCTUnwrap(Data(base64Encoded: Self.transparentPNG))
    let missingReference = try InlineImageReference(
      assetID: try InlineAssetID(rawValue: "cache-missing"),
      version: 1,
      digest: InlineAssetDigest(data: missingData)
    )
    let metrics = try InlineMetrics(advance: 12, ascent: 8, descent: 4)
    let missingAtom = try InlineImageAtom(
      id: "cache-missing",
      reference: missingReference,
      metrics: metrics,
      presentation: .thumbnail(contentMode: .fit),
      accessibility: .label("Missing")
    )
    let firstAtom = try InlineImageAtom(
      id: "cache-first",
      reference: first.reference,
      metrics: metrics,
      presentation: .thumbnail(contentMode: .fit),
      accessibility: .label("First")
    )
    let secondAtom = try InlineImageAtom(
      id: "cache-second",
      reference: second.reference,
      metrics: metrics,
      presentation: .thumbnail(contentMode: .fit),
      accessibility: .label("Second")
    )
    let document = try InlineDocument(
      atoms: [.image(firstAtom), .image(secondAtom), .image(missingAtom)])
    let prepared = try InlinePreparation(shaper: NoopImageShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 100)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let image = try XCTUnwrap(Self.decodeImage(missingData))
    let estimatedBytes = max(1, image.bytesPerRow) * image.height
    let cache = try InlineImageRenderCache(maximumBytes: estimatedBytes * 2)
    let firstKey = try InlineImageRenderCache.Key(
      reference: first.reference, presentation: firstAtom.presentation)
    let evictionSentinel = try InlineImageReference(
      assetID: try InlineAssetID(rawValue: "cache-sentinel"),
      version: 1,
      digest: InlineAssetDigest(data: missingData)
    )
    let sentinelKey = try InlineImageRenderCache.Key(
      reference: evictionSentinel, presentation: firstAtom.presentation)
    _ = try cache.image(for: sentinelKey) { image }
    _ = try cache.image(for: firstKey) { image }
    let beforeCount = cache.count
    let beforeBytes = cache.byteCount

    let imageStore = try InlineImageAssetStore(payloads: [first, second])
    XCTAssertThrowsError(
      try InlineImagePaintCompiler.compile(
        geometry: plan.geometry, assets: imageStore, cache: cache)
    ) { error in
      XCTAssertEqual(
        error as? InlineImageAssetError,
        .missingImage(missingAtom.assetID, version: missingAtom.assetVersion)
      )
    }
    XCTAssertEqual(cache.count, beforeCount)
    XCTAssertEqual(cache.byteCount, beforeBytes)

    // The staged second entry must not have leaked into the cache. Publishing
    // it now evicts the untouched sentinel, proving the pre-failure LRU order
    // (first, sentinel) survived the failed candidate.
    var secondLoads = 0
    let secondKey = try InlineImageRenderCache.Key(
      reference: second.reference, presentation: secondAtom.presentation)
    _ = try cache.image(for: secondKey) {
      secondLoads += 1
      return image
    }
    XCTAssertEqual(secondLoads, 1)
    var firstLoads = 0
    _ = try cache.image(for: firstKey) {
      firstLoads += 1
      return image
    }
    XCTAssertEqual(firstLoads, 0)
    var sentinelLoads = 0
    _ = try cache.image(for: sentinelKey) {
      sentinelLoads += 1
      return image
    }
    XCTAssertEqual(sentinelLoads, 1)
  }

  func testFrozenAdaptiveArtifactBindsFallbackRasterAndDigest() throws {
    let artifact = try makeAdaptiveArtifact()
    guard case .adaptiveGlyph(let configuration) = artifact.atom.presentation else {
      return XCTFail("expected explicit adaptive presentation")
    }
    let adaptivePayload = try XCTUnwrap(artifact.payload.adaptivePayload)
    XCTAssertEqual(configuration.font, adaptivePayload.font)
    XCTAssertEqual(configuration.fontFingerprint, adaptivePayload.fontFingerprint)
    XCTAssertEqual(artifact.asset.reference.digest, try adaptivePayload.canonicalDigest())
    XCTAssertEqual(artifact.asset.totalByteCount, artifact.payload.byteCount)
    XCTAssertEqual(artifact.imageStore.payload(for: artifact.atom.reference), artifact.payload)

    let registry = try InlineAssetRegistry(records: [try InlineAssetRecord(image: artifact.asset)])
    let document = try InlineDocument(atoms: [.image(artifact.atom)])
    XCTAssertNoThrow(try registry.validate(document: document))
    XCTAssertNoThrow(try validateInlineImageAssets(document: document, store: registry.imageStore))
  }

  func testAdaptivePayloadTamperAndFallbackRasterCapsFailWithTypedErrors() throws {
    let artifact = try makeAdaptiveArtifact()
    let payload = try XCTUnwrap(artifact.payload.adaptivePayload)
    let tampered = try InlineAdaptiveImagePayload(
      content: payload.content,
      fallbackRaster: payload.fallbackRaster,
      metrics: payload.metrics,
      font: payload.font,
      fontFingerprint: payload.fontFingerprint + "-tampered"
    )
    XCTAssertThrowsError(
      try InlineImagePayload(
        reference: artifact.atom.reference,
        adaptivePayload: tampered
      )
    ) { error in
      guard case .digestMismatch = error as? InlineImageAssetError else {
        return XCTFail("expected adaptive digest tamper rejection")
      }
    }

    let smallContent = try InlineImageRendition(
      encoding: .heic, encodedBytes: Data([0x01]), pixelWidth: 1, pixelHeight: 1)
    let oversizedFallback = try InlineImageRendition(
      encoding: .png, encodedBytes: Data([0x02, 0x03]), pixelWidth: 1, pixelHeight: 1)
    let fallbackRaster = try InlineAdaptiveFallbackRaster(
      png: oversizedFallback,
      paintBounds: try InlineBaselinePaintBounds(
        minX: 0, maxX: 1.0 / 3.0, minY: 0, maxY: 1.0 / 3.0
      )
    )
    let limits = try InlineImageAssetLimits(
      maximumEncodedBytes: 1,
      maximumPixelWidth: 1,
      maximumPixelHeight: 1,
      maximumPixels: 1
    )
    XCTAssertThrowsError(
      try InlineAdaptiveImagePayload(
        content: smallContent,
        fallbackRaster: fallbackRaster,
        metrics: payload.metrics,
        font: payload.font,
        fontFingerprint: payload.fontFingerprint,
        limits: limits
      )
    ) { error in
      guard case .encodedBytesLimitExceeded = error as? InlineImageAssetError else {
        return XCTFail("expected fallback-raster resource cap rejection")
      }
    }
  }

  func testAdaptiveV2FallbackRasterRejectsNonCanonicalPixelsPerPoint() throws {
    let data = try XCTUnwrap(Data(base64Encoded: Self.transparentPNG))
    let rendition = try InlineImageRendition(
      encoding: .png, encodedBytes: data, pixelWidth: 1, pixelHeight: 1)
    XCTAssertThrowsError(
      try InlineAdaptiveFallbackRaster(
        png: rendition,
        paintBounds: try InlineBaselinePaintBounds(
          minX: 0, maxX: 0.5, minY: 0, maxY: 0.5
        ),
        pixelsPerPoint: 2
      )
    ) { error in
      XCTAssertEqual(
        error as? InlineImageAssetError,
        .fallbackRasterPixelsPerPointUnsupported(actual: 2, expected: 3)
      )
    }
  }

  func testPNGPreflightRejectsForgedUTIAndOversizedHeaderBeforeDecode() throws {
    let jpegData = try Self.makeRasterData(type: .jpeg, width: 1, height: 1)
    let forgedUTIRendition = try InlineImageRendition(
      encoding: .png,
      encodedBytes: jpegData,
      pixelWidth: 1,
      pixelHeight: 1
    )
    let forgedUTIFixture = try makeImageCompileFixture(
      rendition: forgedUTIRendition, rawID: "forged-uti")
    XCTAssertThrowsError(
      try InlineImagePaintCompiler.compile(
        geometry: forgedUTIFixture.plan.geometry,
        assets: forgedUTIFixture.store
      )
    ) { error in
      guard
        case .encodedImageTypeMismatch(
          let assetID, let expected, let actual
        ) = error as? InlineImageAssetError
      else {
        return XCTFail("expected the source UTI to be rejected before decode, received \(error)")
      }
      XCTAssertEqual(assetID, try? InlineAssetID(rawValue: "forged-uti"))
      XCTAssertEqual(expected, .png)
      XCTAssertEqual(actual, UTType.jpeg.identifier)
    }

    // The PNG body remains a tiny, valid 1x1 payload; only its IHDR header is
    // forged to advertise a huge image. The dimension cap must win before
    // ImageIO is asked for a decoded CGImage, so malformed compressed data can
    // never allocate a large pixel buffer or fall through to a generic decode
    // error.
    let tinyPNG = try XCTUnwrap(Data(base64Encoded: Self.transparentPNG))
    let oversizedHeader = Self.forgedPNGHeader(
      from: tinyPNG, width: 100_000, height: 100_000)
    let bombRendition = try InlineImageRendition(
      encoding: .png,
      encodedBytes: oversizedHeader,
      pixelWidth: 1,
      pixelHeight: 1
    )
    let bombFixture = try makeImageCompileFixture(
      rendition: bombRendition, rawID: "compressed-header-bomb")
    XCTAssertThrowsError(
      try InlineImagePaintCompiler.compile(
        geometry: bombFixture.plan.geometry,
        assets: bombFixture.store
      )
    ) { error in
      guard
        case .pixelDimensionLimitExceeded(
          let width, let height, let maximumWidth, let maximumHeight
        ) = error as? InlineImageAssetError
      else {
        return XCTFail(
          "expected the forged dimensions to be rejected before decode, received \(error)")
      }
      XCTAssertEqual(width, 100_000)
      XCTAssertEqual(height, 100_000)
      XCTAssertEqual(maximumWidth, InlineImageAssetLimits.default.maximumPixelWidth)
      XCTAssertEqual(maximumHeight, InlineImageAssetLimits.default.maximumPixelHeight)
    }
  }

  func testJPEGThumbnailPreflightAcceptsMatchingTypeAndDimensions() throws {
    let data = try Self.makeRasterData(type: .jpeg, width: 1, height: 1)
    let fixture = try makeImageCompileFixture(
      rendition: try InlineImageRendition(
        encoding: .jpeg,
        encodedBytes: data,
        pixelWidth: 1,
        pixelHeight: 1
      ),
      rawID: "jpeg-thumbnail"
    )

    let entries = try InlineImagePaintCompiler.compile(
      geometry: fixture.plan.geometry,
      assets: fixture.store
    )
    XCTAssertEqual(entries.count, 1)
  }

  func testHEICThumbnailPreflightAcceptsMatchingTypeAndDimensions() throws {
    let data = try XCTUnwrap(Data(base64Encoded: Self.adaptiveHEIC))
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetType(source) as String? == UTType.heic.identifier,
      Self.decodeImage(data) != nil
    else {
      throw XCTSkip("HEIC ImageIO decoding is unavailable in this environment")
    }
    let fixture = try makeImageCompileFixture(
      rendition: try InlineImageRendition(
        encoding: .heic,
        encodedBytes: data,
        pixelWidth: 32,
        pixelHeight: 32
      ),
      rawID: "heic-thumbnail"
    )

    let entries = try InlineImagePaintCompiler.compile(
      geometry: fixture.plan.geometry,
      assets: fixture.store
    )
    XCTAssertEqual(entries.count, 1)
  }

  func testThumbnailPreflightRejectsForgedDeclaredEncodingAcrossFormats() throws {
    let png = try XCTUnwrap(Data(base64Encoded: Self.transparentPNG))
    let jpeg = try Self.makeRasterData(type: .jpeg, width: 1, height: 1)
    let heic = try XCTUnwrap(Data(base64Encoded: Self.adaptiveHEIC))
    let heicIsAvailable =
      CGImageSourceCreateWithData(heic as CFData, nil).map {
        (CGImageSourceGetType($0) as String?) == UTType.heic.identifier
      } ?? false
    let cases: [(InlineImageEncoding, Data, Int, Int, String, String)] =
      [
        (.png, jpeg, 1, 1, "declared-png-actual-jpeg", UTType.jpeg.identifier),
        (.jpeg, png, 1, 1, "declared-jpeg-actual-png", UTType.png.identifier),
        (.heic, png, 1, 1, "declared-heic-actual-png", UTType.png.identifier),
      ]
      + (heicIsAvailable
        ? [
          (.png, heic, 32, 32, "declared-png-actual-heic", UTType.heic.identifier),
          (.jpeg, heic, 32, 32, "declared-jpeg-actual-heic", UTType.heic.identifier),
        ] : [])

    for (encoding, data, width, height, rawID, actualType) in cases {
      let fixture = try makeImageCompileFixture(
        rendition: try InlineImageRendition(
          encoding: encoding,
          encodedBytes: data,
          pixelWidth: width,
          pixelHeight: height
        ),
        rawID: rawID
      )
      XCTAssertThrowsError(
        try InlineImagePaintCompiler.compile(
          geometry: fixture.plan.geometry,
          assets: fixture.store
        )
      ) { error in
        guard
          case .encodedImageTypeMismatch(
            let assetID, let expected, let actual
          ) = error as? InlineImageAssetError
        else {
          return XCTFail(
            "expected declared encoding " + String(describing: encoding)
              + " to reject " + actualType + ", received " + String(reflecting: error)
          )
        }
        XCTAssertEqual(assetID.rawValue, rawID)
        XCTAssertEqual(expected, encoding)
        XCTAssertEqual(actual, actualType)
      }
    }
  }

  func testWarmCacheRevalidatesTypeAndDeclaredDimensionsBeforeReturningHit() throws {
    let data = try Self.makeRasterData(type: .jpeg, width: 1, height: 1)
    let validFixture = try makeImageCompileFixture(
      rendition: try InlineImageRendition(
        encoding: .jpeg,
        encodedBytes: data,
        pixelWidth: 1,
        pixelHeight: 1
      ),
      rawID: "warm-cache"
    )
    let cache = try InlineImageRenderCache()
    XCTAssertEqual(
      try InlineImagePaintCompiler.compile(
        geometry: validFixture.plan.geometry,
        assets: validFixture.store,
        cache: cache
      ).count,
      1
    )
    XCTAssertEqual(cache.count, 1)
    let cachedByteCount = cache.byteCount

    // The digest and cache key remain identical: only the declared encoding
    // changes. Preflight must run before the cache lookup and reject the
    // forged declaration instead of returning the warm JPEG entry.
    let forgedEncodingFixture = try makeImageCompileFixture(
      rendition: try InlineImageRendition(
        encoding: .png,
        encodedBytes: data,
        pixelWidth: 1,
        pixelHeight: 1
      ),
      rawID: "warm-cache"
    )
    XCTAssertThrowsError(
      try InlineImagePaintCompiler.compile(
        geometry: forgedEncodingFixture.plan.geometry,
        assets: forgedEncodingFixture.store,
        cache: cache
      )
    ) { error in
      XCTAssertEqual(
        error as? InlineImageAssetError,
        .encodedImageTypeMismatch(
          forgedEncodingFixture.atom.reference.assetID,
          expected: .png,
          actual: UTType.jpeg.identifier
        )
      )
    }
    XCTAssertEqual(cache.count, 1)
    XCTAssertEqual(cache.byteCount, cachedByteCount)

    // Keep the same reference, presentation, and scale again, while lying
    // about declared dimensions. The actual header is still 1x1 and must
    // fail before the warm entry can be returned.
    let forgedDimensionsFixture = try makeImageCompileFixture(
      rendition: try InlineImageRendition(
        encoding: .jpeg,
        encodedBytes: data,
        pixelWidth: 2,
        pixelHeight: 1
      ),
      rawID: "warm-cache"
    )
    XCTAssertThrowsError(
      try InlineImagePaintCompiler.compile(
        geometry: forgedDimensionsFixture.plan.geometry,
        assets: forgedDimensionsFixture.store,
        cache: cache
      )
    ) { error in
      XCTAssertEqual(
        error as? InlineImageAssetError,
        .encodedImageDimensionsMismatch(
          forgedDimensionsFixture.atom.reference.assetID,
          expectedWidth: 2,
          expectedHeight: 1,
          actualWidth: 1,
          actualHeight: 1
        )
      )
    }
    XCTAssertEqual(cache.count, 1)
    XCTAssertEqual(cache.byteCount, cachedByteCount)
  }

  func testJPEGThumbnailPreflightRejectsOversizedHeaderBeforeDecode() throws {
    let data = try Self.makeRasterData(type: .jpeg, width: 1, height: 1)
    let forged = Self.forgedJPEGHeader(from: data, width: 10_000, height: 10_000)
    let fixture = try makeImageCompileFixture(
      rendition: try InlineImageRendition(
        encoding: .jpeg,
        encodedBytes: forged,
        pixelWidth: 1,
        pixelHeight: 1
      ),
      rawID: "jpeg-header-bomb"
    )

    XCTAssertThrowsError(
      try InlineImagePaintCompiler.compile(
        geometry: fixture.plan.geometry,
        assets: fixture.store
      )
    ) { error in
      guard
        case .pixelDimensionLimitExceeded(
          let width, let height, let maximumWidth, let maximumHeight
        ) = error as? InlineImageAssetError
      else {
        return XCTFail(
          "expected forged JPEG dimensions to be rejected before decode, received "
            + String(reflecting: error)
        )
      }
      XCTAssertEqual(width, 10_000)
      XCTAssertEqual(height, 10_000)
      XCTAssertEqual(maximumWidth, InlineImageAssetLimits.default.maximumPixelWidth)
      XCTAssertEqual(maximumHeight, InlineImageAssetLimits.default.maximumPixelHeight)
    }
  }

  func testHEICThumbnailPreflightRejectsOversizedHeaderBeforeDecode() throws {
    let data = try XCTUnwrap(Data(base64Encoded: Self.adaptiveHEIC))
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetType(source) as String? == UTType.heic.identifier,
      Self.decodeImage(data) != nil
    else {
      throw XCTSkip("HEIC ImageIO decoding is unavailable in this environment")
    }
    let forged = Self.forgedHEICHeader(from: data, width: 100_000, height: 100_000)
    let fixture = try makeImageCompileFixture(
      rendition: try InlineImageRendition(
        encoding: .heic,
        encodedBytes: forged,
        pixelWidth: 32,
        pixelHeight: 32
      ),
      rawID: "heic-header-bomb"
    )

    XCTAssertThrowsError(
      try InlineImagePaintCompiler.compile(
        geometry: fixture.plan.geometry,
        assets: fixture.store
      )
    ) { error in
      guard
        case .pixelDimensionLimitExceeded(
          let width, let height, let maximumWidth, let maximumHeight
        ) = error as? InlineImageAssetError
      else {
        return XCTFail(
          "expected forged HEIC dimensions to be rejected before decode, received "
            + String(reflecting: error)
        )
      }
      XCTAssertEqual(width, 100_000)
      XCTAssertEqual(height, 100_000)
      XCTAssertEqual(maximumWidth, InlineImageAssetLimits.default.maximumPixelWidth)
      XCTAssertEqual(maximumHeight, InlineImageAssetLimits.default.maximumPixelHeight)
    }
  }

  func testAdaptiveV2DigestBindsEveryPersistedField() throws {
    let artifact = try makeAdaptiveArtifact()
    let payload = try XCTUnwrap(artifact.payload.adaptivePayload)
    let baseline = payload.fallbackRaster.paintBounds
    let changedFallback = try InlineAdaptiveFallbackRaster(
      png: payload.fallbackRaster.png,
      paintBounds: try InlineBaselinePaintBounds(
        minX: baseline.minX + 1,
        maxX: baseline.maxX + 1,
        minY: baseline.minY,
        maxY: baseline.maxY
      ),
      pixelsPerPoint: payload.fallbackRaster.pixelsPerPoint,
      colorSpace: payload.fallbackRaster.colorSpace
    )
    let variants: [InlineAdaptiveImagePayload] = [
      try InlineAdaptiveImagePayload(
        content: payload.content,
        fallbackRaster: changedFallback,
        metrics: payload.metrics,
        font: payload.font,
        fontFingerprint: payload.fontFingerprint
      ),
      try InlineAdaptiveImagePayload(
        content: payload.content,
        fallbackRaster: payload.fallbackRaster,
        metrics: try InlineMetrics(
          advance: payload.metrics.advance + 1,
          ascent: payload.metrics.ascent,
          descent: payload.metrics.descent
        ),
        font: payload.font,
        fontFingerprint: payload.fontFingerprint
      ),
      try InlineAdaptiveImagePayload(
        content: payload.content,
        fallbackRaster: payload.fallbackRaster,
        metrics: payload.metrics,
        font: FontDescriptor(
          postScriptName: payload.font.postScriptName,
          pointSize: payload.font.pointSize + 1
        ),
        fontFingerprint: payload.fontFingerprint
      ),
      try InlineAdaptiveImagePayload(
        content: try InlineImageRendition(
          encoding: .heic,
          encodedBytes: Data([0x01]),
          pixelWidth: 1,
          pixelHeight: 1
        ),
        fallbackRaster: payload.fallbackRaster,
        metrics: payload.metrics,
        font: payload.font,
        fontFingerprint: payload.fontFingerprint
      ),
    ]
    for variant in variants {
      XCTAssertNotEqual(try variant.canonicalDigest(), artifact.atom.reference.digest)
      XCTAssertThrowsError(
        try InlineImagePayload(
          reference: artifact.atom.reference,
          adaptivePayload: variant
        )
      ) { error in
        guard case .digestMismatch = error as? InlineImageAssetError else {
          return XCTFail("expected v2 digest rejection, received \(error)")
        }
      }
    }
  }

  func testModernCompilerRejectsFrozenMetricsThatDifferFromCoreText() throws {
    #if os(macOS)
      guard #available(macOS 15.0, *) else {
        throw XCTSkip("adaptive provider APIs require macOS 15 or newer")
      }
    #elseif os(iOS)
      guard #available(iOS 18.0, *) else {
        throw XCTSkip("adaptive provider APIs require iOS 18 or newer")
      }
    #else
      throw XCTSkip("adaptive provider test is only configured for macOS/iOS")
    #endif

    let contentData = try XCTUnwrap(Data(base64Encoded: Self.adaptiveHEIC))
    let fallbackData = try XCTUnwrap(Data(base64Encoded: Self.transparentPNG))
    let content = try InlineImageRendition(
      encoding: .heic,
      encodedBytes: contentData,
      pixelWidth: 32,
      pixelHeight: 32
    )
    let fallbackRaster = try makeFallbackRaster(data: fallbackData)
    let artifact = try InlineAdaptiveImageGlyphFactory.makeWithFrozenAdaptivePayload(
      id: "mismatched-metrics",
      assetID: try InlineAssetID(rawValue: "mismatched-metrics"),
      adaptiveContent: content,
      fallbackRaster: fallbackRaster,
      metrics: try InlineMetrics(advance: 100, ascent: 100, descent: 100),
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
      accessibility: .label("Mismatched metrics")
    )
    let document = try InlineDocument(atoms: [.image(artifact.atom)])
    let prepared = try InlinePreparation(shaper: NoopImageShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 400)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)

    XCTAssertThrowsError(
      try InlineImagePaintCompiler.compile(
        geometry: plan.geometry,
        assets: artifact.imageStore
      )
    ) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .adaptiveGlyphMetricsMismatch(try! InlineAssetID(rawValue: "mismatched-metrics"))
      )
    }
  }

  func testModernAdaptivePreflightRejectsHEICDeclarationWithPNGBytes() throws {
    #if os(macOS)
      guard #available(macOS 15.0, *) else {
        throw XCTSkip("adaptive provider APIs require macOS 15 or newer")
      }
    #elseif os(iOS)
      guard #available(iOS 18.0, *) else {
        throw XCTSkip("adaptive provider APIs require iOS 18 or newer")
      }
    #else
      throw XCTSkip("adaptive provider test is only configured for macOS/iOS")
    #endif

    let base = try makeAdaptiveArtifact()
    let basePayload = try XCTUnwrap(base.payload.adaptivePayload)
    let pngData = try XCTUnwrap(Data(base64Encoded: Self.transparentPNG))
    let forgedContent = try InlineImageRendition(
      encoding: .heic,
      encodedBytes: pngData,
      pixelWidth: basePayload.content.pixelWidth,
      pixelHeight: basePayload.content.pixelHeight
    )
    let forgedAdaptivePayload = try InlineAdaptiveImagePayload(
      content: forgedContent,
      fallbackRaster: basePayload.fallbackRaster,
      metrics: basePayload.metrics,
      font: basePayload.font,
      fontFingerprint: basePayload.fontFingerprint
    )
    let reference = try InlineImageReference(
      assetID: base.atom.reference.assetID,
      version: base.atom.reference.version,
      digest: try forgedAdaptivePayload.canonicalDigest()
    )
    let payload = try InlineImagePayload(
      reference: reference,
      adaptivePayload: forgedAdaptivePayload
    )
    let atom = try InlineImageAtom(
      id: base.atom.id,
      reference: reference,
      metrics: base.atom.metrics,
      presentation: base.atom.presentation,
      accessibility: .label("Forged adaptive image")
    )
    let document = try InlineDocument(atoms: [.image(atom)])
    let prepared = try InlinePreparation(shaper: NoopImageShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 32)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let store = try InlineImageAssetStore(payloads: [payload])
    let cache = try InlineImageRenderCache()

    XCTAssertThrowsError(
      try InlineImagePaintCompiler.compile(
        geometry: plan.geometry,
        assets: store,
        cache: cache
      )
    ) { error in
      XCTAssertEqual(
        error as? InlineImageAssetError,
        .encodedImageTypeMismatch(
          atom.reference.assetID,
          expected: .heic,
          actual: UTType.png.identifier
        )
      )
    }
    XCTAssertEqual(cache.count, 0)
    XCTAssertEqual(cache.byteCount, 0)
  }

  func testModernAdaptivePreflightRejectsOversizedHEICBeforeProviderAndPreservesCache() throws {
    #if os(macOS)
      guard #available(macOS 15.0, *) else {
        throw XCTSkip("adaptive provider APIs require macOS 15 or newer")
      }
    #elseif os(iOS)
      guard #available(iOS 18.0, *) else {
        throw XCTSkip("adaptive provider APIs require iOS 18 or newer")
      }
    #else
      throw XCTSkip("adaptive provider test is only configured for macOS/iOS")
    #endif

    let base = try makeAdaptiveArtifact()
    let basePayload = try XCTUnwrap(base.payload.adaptivePayload)
    let forgedContent = try InlineImageRendition(
      encoding: .heic,
      encodedBytes: Self.forgedHEICHeader(
        from: basePayload.content.encodedBytes,
        width: 100_000,
        height: 100_000
      ),
      pixelWidth: basePayload.content.pixelWidth,
      pixelHeight: basePayload.content.pixelHeight
    )
    let forgedAdaptivePayload = try InlineAdaptiveImagePayload(
      content: forgedContent,
      fallbackRaster: basePayload.fallbackRaster,
      metrics: basePayload.metrics,
      font: basePayload.font,
      fontFingerprint: basePayload.fontFingerprint
    )
    let reference = try InlineImageReference(
      assetID: base.atom.reference.assetID,
      version: base.atom.reference.version,
      digest: try forgedAdaptivePayload.canonicalDigest()
    )
    let payload = try InlineImagePayload(
      reference: reference,
      adaptivePayload: forgedAdaptivePayload
    )
    let atom = try InlineImageAtom(
      id: base.atom.id,
      reference: reference,
      metrics: base.atom.metrics,
      presentation: base.atom.presentation,
      accessibility: .label("Forged oversized adaptive image")
    )
    let document = try InlineDocument(atoms: [.image(atom)])
    let prepared = try InlinePreparation(shaper: NoopImageShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 32)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let store = try InlineImageAssetStore(payloads: [payload])
    let cache = try InlineImageRenderCache()

    XCTAssertThrowsError(
      try InlineImagePaintCompiler.compile(
        geometry: plan.geometry,
        assets: store,
        cache: cache
      )
    ) { error in
      guard
        case .pixelDimensionLimitExceeded(
          let width, let height, let maximumWidth, let maximumHeight
        ) = error as? InlineImageAssetError
      else {
        return XCTFail(
          "expected oversized adaptive HEIC metadata to be rejected before provider, received "
            + String(reflecting: error)
        )
      }
      XCTAssertEqual(width, 100_000)
      XCTAssertEqual(height, 100_000)
      XCTAssertEqual(maximumWidth, InlineImageAssetLimits.default.maximumPixelWidth)
      XCTAssertEqual(maximumHeight, InlineImageAssetLimits.default.maximumPixelHeight)
    }
    XCTAssertEqual(cache.count, 0)
    XCTAssertEqual(cache.byteCount, 0)
    XCTAssertEqual(payload.adaptivePayload?.fallbackRaster, basePayload.fallbackRaster)
  }

  func testMinimumOSCompilerUsesOnlyTheStoredFallbackRaster() throws {
    let artifact = try makeAdaptiveArtifact()
    let document = try InlineDocument(atoms: [.image(artifact.atom)])
    let prepared = try InlinePreparation(shaper: NoopImageShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 32)
    let positioned = try XCTUnwrap(layout.lines.first?.atoms.first)
    let cache = try InlineImageRenderCache(maximumBytes: 1_024 * 1_024)

    let paint = try InlineImagePaintCompiler.compileMinimumOSForTesting(
      positioned: positioned,
      atom: artifact.atom,
      payload: artifact.payload,
      cache: cache
    )
    XCTAssertEqual(paint.kind, .adaptiveGlyph)
    let fallback = try XCTUnwrap(artifact.payload.adaptivePayload?.fallbackRaster)
    XCTAssertEqual(
      paint.localPaintBounds,
      CGRect(
        x: fallback.paintBounds.minX,
        y: artifact.atom.metrics.ascent - fallback.paintBounds.maxY,
        width: fallback.paintBounds.width,
        height: fallback.paintBounds.height
      )
    )
    XCTAssertEqual(cache.count, 1)
    XCTAssertGreaterThan(cache.byteCount, 0)
  }

  func testModernFactoryAndCompilerUseAdaptiveProviderWhenAvailable() throws {
    #if os(macOS)
      guard #available(macOS 15.0, *) else {
        throw XCTSkip("adaptive provider APIs require macOS 15 or newer")
      }
    #elseif os(iOS)
      guard #available(iOS 18.0, *) else {
        throw XCTSkip("adaptive provider APIs require iOS 18 or newer")
      }
    #else
      throw XCTSkip("adaptive provider test is only configured for macOS/iOS")
    #endif

    let data = try XCTUnwrap(Data(base64Encoded: Self.adaptiveHEIC))
    let font = FontDescriptor(postScriptName: "Helvetica", pointSize: 12)
    let glyph = NSAdaptiveImageGlyph(imageContent: data)
    let artifact = try InlineAdaptiveImageGlyphFactory.make(
      id: "modern-adaptive",
      assetID: try InlineAssetID(rawValue: "modern-adaptive"),
      adaptiveGlyph: glyph,
      font: font,
      accessibility: .label("Modern adaptive image")
    )
    let document = try InlineDocument(atoms: [.image(artifact.atom)])
    let prepared = try InlinePreparation(shaper: NoopImageShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 64)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let paints = try InlineImagePaintCompiler.compile(
      geometry: plan.geometry,
      assets: artifact.imageStore
    )
    let positioned = try XCTUnwrap(layout.lines.first?.atoms.first)
    let paint = try XCTUnwrap(paints[positioned])
    XCTAssertEqual(paint.kind, .adaptiveGlyph)
    XCTAssertGreaterThan(paint.localPaintBounds.width, 0)
    XCTAssertGreaterThan(paint.localPaintBounds.height, 0)
  }

  func testModernFactoryProducesDeterministicBaselineAwareFallbackRaster() throws {
    #if os(macOS)
      guard #available(macOS 15.0, *) else {
        throw XCTSkip("adaptive provider APIs require macOS 15 or newer")
      }
    #elseif os(iOS)
      guard #available(iOS 18.0, *) else {
        throw XCTSkip("adaptive provider APIs require iOS 18 or newer")
      }
    #else
      throw XCTSkip("adaptive provider test is only configured for macOS/iOS")
    #endif

    let data = try XCTUnwrap(Data(base64Encoded: Self.adaptiveHEIC))
    let glyph = NSAdaptiveImageGlyph(imageContent: data)
    let font = FontDescriptor(postScriptName: "Helvetica", pointSize: 12)
    let assetID = try InlineAssetID(rawValue: "captured-adaptive")
    let first = try InlineAdaptiveImageGlyphFactory.make(
      id: "captured-adaptive",
      assetID: assetID,
      adaptiveGlyph: glyph,
      font: font,
      accessibility: .label("Captured adaptive image")
    )
    let second = try InlineAdaptiveImageGlyphFactory.make(
      id: "captured-adaptive",
      assetID: assetID,
      adaptiveGlyph: glyph,
      font: font,
      accessibility: .label("Captured adaptive image")
    )
    let fallback = try XCTUnwrap(first.payload.adaptivePayload?.fallbackRaster)
    XCTAssertEqual(fallback.pixelsPerPoint, 3)
    XCTAssertEqual(fallback.colorSpace, .sRGB)
    XCTAssertEqual(fallback.png.encoding, .png)
    XCTAssertEqual(first.payload, second.payload)
    XCTAssertEqual(
      fallback.paintBounds.width,
      Double(fallback.png.pixelWidth) / fallback.pixelsPerPoint,
      accuracy: 1.0 / 3_000.0)
    XCTAssertEqual(
      fallback.paintBounds.height,
      Double(fallback.png.pixelHeight) / fallback.pixelsPerPoint,
      accuracy: 1.0 / 3_000.0)
    XCTAssertGreaterThan(fallback.png.encodedBytes.count, 0)

    // The crop keeps a transparent one-pixel border around detected alpha;
    // checking all four corners catches a zero-margin or inverted crop.
    let image = try XCTUnwrap(Self.decodeImage(fallback.png.encodedBytes))
    let providerData = try XCTUnwrap(image.dataProvider?.data)
    let bytes = try XCTUnwrap(CFDataGetBytePtr(providerData))
    let bytesPerRow = image.bytesPerRow
    XCTAssertEqual(bytes[3], 0)
    XCTAssertEqual(bytes[(image.width - 1) * 4 + 3], 0)
    XCTAssertEqual(bytes[(image.height - 1) * bytesPerRow + 3], 0)
    XCTAssertEqual(
      bytes[(image.height - 1) * bytesPerRow + (image.width - 1) * 4 + 3],
      0
    )
  }

  func testModernFactoryDerivesOrRejectsAccessibilityDescription() throws {
    #if os(macOS)
      guard #available(macOS 15.0, *) else {
        throw XCTSkip("adaptive provider APIs require macOS 15 or newer")
      }
    #elseif os(iOS)
      guard #available(iOS 18.0, *) else {
        throw XCTSkip("adaptive provider APIs require iOS 18 or newer")
      }
    #else
      throw XCTSkip("adaptive provider test is only configured for macOS/iOS")
    #endif

    let data = try XCTUnwrap(Data(base64Encoded: Self.adaptiveHEIC))
    let glyph = NSAdaptiveImageGlyph(imageContent: data)
    XCTAssertThrowsError(
      try InlineAdaptiveImageGlyphFactory.make(
        id: "description-required",
        assetID: try InlineAssetID(rawValue: "description-required"),
        adaptiveGlyph: glyph,
        font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12)
      )
    ) { error in
      XCTAssertEqual(
        error as? InlineImageAssetError,
        .adaptiveGlyphDescriptionEmpty(
          try! InlineAssetID(rawValue: "description-required")
        )
      )
    }
  }

  func testMinimumOSRasterMatchesModernAdaptiveCaptureWithinTolerance() throws {
    #if os(macOS)
      guard #available(macOS 15.0, *) else {
        throw XCTSkip("adaptive provider APIs require macOS 15 or newer")
      }
    #elseif os(iOS)
      guard #available(iOS 18.0, *) else {
        throw XCTSkip("adaptive provider APIs require iOS 18 or newer")
      }
    #else
      throw XCTSkip("adaptive provider test is only configured for macOS/iOS")
    #endif

    let data = try XCTUnwrap(Data(base64Encoded: Self.adaptiveHEIC))
    let glyph = NSAdaptiveImageGlyph(imageContent: data)
    let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    let artifact = try InlineAdaptiveImageGlyphFactory.make(
      id: "capture-match",
      assetID: try InlineAssetID(rawValue: "capture-match"),
      adaptiveGlyph: glyph,
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
      accessibility: .label("Capture match")
    )
    let fallbackRaster = try XCTUnwrap(artifact.payload.adaptivePayload?.fallbackRaster)
    let fallbackImage = try XCTUnwrap(Self.decodeImage(fallbackRaster.png.encodedBytes))
    let baseline = CGPoint(x: 64, y: 64)
    let modern = try Self.renderPixels(width: 384, height: 384) { context in
      context.scaleBy(x: 3, y: 3)
      CTFontDrawImageFromAdaptiveImageProviderAtPoint(font, glyph, baseline, context)
    }
    let fallbackCapture = try Self.renderPixels(width: 384, height: 384) { context in
      context.scaleBy(x: 3, y: 3)
      let bounds = fallbackRaster.paintBounds
      context.draw(
        fallbackImage,
        in: CGRect(
          x: baseline.x + CGFloat(bounds.minX),
          y: baseline.y + CGFloat(bounds.minY),
          width: CGFloat(bounds.width),
          height: CGFloat(bounds.height)
        )
      )
    }
    let parity = Self.pixelParity(modern, fallbackCapture, width: 384, height: 384)
    XCTAssertEqual(
      parity.leftAlphaBounds,
      parity.rightAlphaBounds,
      "modern and minimum-OS fallback paths must retain the same visible alpha bounds"
    )
    XCTAssertLessThanOrEqual(
      parity.differingPixelRatio,
      0.01,
      "captured PNG must differ in at most 1% of visible comparison pixels"
    )
    XCTAssertLessThanOrEqual(
      parity.maxChannelDelta,
      8,
      "captured PNG channel deltas must remain far below the former 96-level bound"
    )
    XCTAssertLessThanOrEqual(
      parity.meanChannelDelta,
      0.5,
      "captured PNG mean channel delta must remain subpixel-level"
    )
  }

  func testAdaptivePayloadRequiresCanonicalFallbackRasterField() throws {
    let artifact = try makeAdaptiveArtifact()
    let encoded = try JSONEncoder().encode(artifact.payload.adaptivePayload!)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "fallbackRaster")
    let malformedData = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(
      try JSONDecoder().decode(InlineAdaptiveImagePayload.self, from: malformedData)
    ) { error in
      guard case DecodingError.keyNotFound(let key, _) = error else {
        return XCTFail("expected required-field decoding failure, got \(error)")
      }
      XCTAssertEqual(key.stringValue, "fallbackRaster")
    }
  }

  func testAdaptivePaintProtrusionExpandsCullingButNotHitSemantics() throws {
    #if os(macOS)
      guard #available(macOS 15.0, *) else {
        throw XCTSkip("adaptive provider APIs require macOS 15 or newer")
      }
    #elseif os(iOS)
      guard #available(iOS 18.0, *) else {
        throw XCTSkip("adaptive provider APIs require iOS 18 or newer")
      }
    #else
      throw XCTSkip("adaptive provider test is only configured for macOS/iOS")
    #endif

    let data = try XCTUnwrap(Data(base64Encoded: Self.adaptiveHEIC))
    let glyph = NSAdaptiveImageGlyph(imageContent: data)
    let base = try InlineAdaptiveImageGlyphFactory.make(
      id: "adaptive-protrusion-base",
      assetID: try InlineAssetID(rawValue: "adaptive-protrusion-base"),
      adaptiveGlyph: glyph,
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
      accessibility: .label("Adaptive protrusion")
    )
    let configuration = try XCTUnwrap(base.atom.presentation.adaptiveConfiguration)
    let artifact = try InlineAdaptiveImageGlyphFactory.makeWithFrozenAdaptivePayload(
      id: "adaptive-protrusion",
      assetID: try InlineAssetID(rawValue: "adaptive-protrusion"),
      adaptiveContent: base.payload.rendition,
      fallbackRaster: try makeFallbackRaster(
        data: try XCTUnwrap(Data(base64Encoded: Self.transparentPNG)),
        minX: -1
      ),
      metrics: base.atom.metrics,
      font: configuration.font,
      fontFingerprint: configuration.fontFingerprint,
      accessibility: .label("Adaptive protrusion")
    )
    let document = try InlineDocument(atoms: [.image(artifact.atom)])
    let prepared = try InlinePreparation(shaper: NoopImageShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 32)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let positioned = try XCTUnwrap(layout.lines.first?.atoms.first)
    let fallback = try XCTUnwrap(artifact.payload.adaptivePayload?.fallbackRaster)
    let paints = try InlineImagePaintCompiler.compile(
      geometry: plan.geometry,
      assets: artifact.imageStore
    )
    let paint = try XCTUnwrap(paints[positioned])
    XCTAssertLessThan(paint.localPaintBounds.minX, 0)

    let viewport = try InlineRenderViewport(x: -1, y: 0, width: 0.5, height: 32)
    let swiftUI = try InlineSwiftUIRenderContent(
      plan: plan,
      assets: NoopGeometryProvider(),
      imageAssets: artifact.imageStore
    )
    let canvas = try InlineCanvasRenderContent(
      plan: plan,
      assets: NoopGeometryProvider(),
      imageAssets: artifact.imageStore
    )
    let swiftUIRenderer = InlineSwiftUIRenderer(content: swiftUI, viewport: viewport)
    let canvasRenderer = InlineCanvasRenderer(content: canvas, viewport: viewport)
    XCTAssertEqual(swiftUIRenderer.visibleAtomIDsForTesting(in: viewport), [artifact.atom.id])
    XCTAssertEqual(canvasRenderer.visibleAtomIDsForTesting(in: viewport), [artifact.atom.id])

    let outsideCell = try InlineHitPoint(
      x: -0.8,
      y: positioned.baselineY - positioned.metrics.baselineOffset
        - positioned.metrics.ascent + 1
    )
    XCTAssertEqual(plan.hitIndex.hitTest(outsideCell), .none)
    XCTAssertGreaterThanOrEqual(fallback.paintBounds.minX, -1)
  }

  func testStaticRenderersKeepAdaptiveOverhangAndViewportCrop() throws {
    #if os(macOS)
      guard #available(macOS 15.0, *) else {
        throw XCTSkip("adaptive provider APIs require macOS 15 or newer")
      }
    #elseif os(iOS)
      guard #available(iOS 18.0, *) else {
        throw XCTSkip("adaptive provider APIs require iOS 18 or newer")
      }
    #else
      throw XCTSkip("adaptive provider test is only configured for macOS/iOS")
    #endif

    let contentData = try XCTUnwrap(Data(base64Encoded: Self.adaptiveHEIC))
    let base = try InlineAdaptiveImageGlyphFactory.make(
      id: "visible-overhang-base",
      assetID: try InlineAssetID(rawValue: "visible-overhang-base"),
      adaptiveGlyph: NSAdaptiveImageGlyph(imageContent: contentData),
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
      accessibility: .label("Visible overhang")
    )
    let configuration = try XCTUnwrap(base.atom.presentation.adaptiveConfiguration)
    let fallbackData = try Self.makeRasterData(type: .png, width: 6, height: 6)
    let fallbackRendition = try InlineImageRendition(
      encoding: .png,
      encodedBytes: fallbackData,
      pixelWidth: 6,
      pixelHeight: 6
    )
    // Two points of opaque paint sit two points to the left of the cell and
    // above its typographic top. This is intentionally visible, unlike the
    // transparent 1x1 fixtures used by metadata-only tests.
    let fallbackBounds = try InlineBaselinePaintBounds(
      minX: -2, maxX: 0, minY: 20, maxY: 22)
    let artifact = try InlineAdaptiveImageGlyphFactory.makeWithFrozenAdaptivePayload(
      id: "visible-overhang",
      assetID: try InlineAssetID(rawValue: "visible-overhang"),
      adaptiveContent: base.payload.rendition,
      fallbackRaster: try InlineAdaptiveFallbackRaster(
        png: fallbackRendition,
        paintBounds: fallbackBounds
      ),
      metrics: base.atom.metrics,
      font: configuration.font,
      fontFingerprint: configuration.fontFingerprint,
      accessibility: .label("Visible overhang")
    )
    let document = try InlineDocument(atoms: [.image(artifact.atom)])
    let prepared = try InlinePreparation(shaper: NoopImageShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 100)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let positioned = try XCTUnwrap(layout.lines.first?.atoms.first)
    let originY =
      positioned.baselineY - positioned.metrics.baselineOffset
      - positioned.metrics.ascent
    let cellBounds = CGRect(
      x: CGFloat(positioned.originX),
      y: CGFloat(originY),
      width: CGFloat(positioned.width),
      height: CGFloat(positioned.height)
    )
    let paintBounds = CGRect(
      x: CGFloat(positioned.originX + fallbackBounds.minX),
      y: CGFloat(originY + positioned.metrics.ascent - fallbackBounds.maxY),
      width: CGFloat(fallbackBounds.width),
      height: CGFloat(fallbackBounds.height)
    )
    let fullBounds = cellBounds.union(paintBounds)
    let viewport = try InlineRenderViewport(
      x: Double(fullBounds.minX) - 1,
      y: Double(fullBounds.minY) - 1,
      width: Double(fullBounds.width) + 2,
      height: Double(fullBounds.height) + 2
    )
    let swiftUIContent = try InlineSwiftUIRenderContent(
      plan: plan,
      assets: NoopGeometryProvider(),
      imageAssets: artifact.imageStore,
      imageScale: 3,
      forceMinimumOSImageRendering: true
    )
    let canvasContent = try InlineCanvasRenderContent(
      plan: plan,
      assets: NoopGeometryProvider(),
      imageAssets: artifact.imageStore,
      imageScale: 3,
      forceMinimumOSImageRendering: true
    )
    let swiftImage = try Self.renderImage(
      InlineSwiftUIRenderer(content: swiftUIContent, viewport: viewport),
      viewport: viewport,
      scale: 3
    )
    let canvasImage = try Self.renderImage(
      InlineCanvasRenderer(content: canvasContent, viewport: viewport),
      viewport: viewport,
      scale: 3
    )
    let swiftAlpha = try XCTUnwrap(Self.alphaBounds(swiftImage))
    let canvasAlpha = try XCTUnwrap(Self.alphaBounds(canvasImage))
    XCTAssertGreaterThan(swiftAlpha.width, 0)
    XCTAssertGreaterThan(canvasAlpha.width, 0)

    let expectedPaint = CGRect(
      x: (paintBounds.minX - CGFloat(viewport.x)) * 3,
      y: (paintBounds.minY - CGFloat(viewport.y)) * 3,
      width: paintBounds.width * 3,
      height: paintBounds.height * 3
    )
    let expectedCell = CGRect(
      x: (cellBounds.minX - CGFloat(viewport.x)) * 3,
      y: (cellBounds.minY - CGFloat(viewport.y)) * 3,
      width: cellBounds.width * 3,
      height: cellBounds.height * 3
    )
    // The left/top pixels are outside the logical cell. A per-atom Canvas
    // clipped to that cell would fail these assertions.
    XCTAssertLessThanOrEqual(swiftAlpha.minX, expectedPaint.minX + 1)
    XCTAssertLessThanOrEqual(canvasAlpha.minX, expectedPaint.minX + 1)
    XCTAssertLessThanOrEqual(swiftAlpha.minY, expectedPaint.minY + 1)
    XCTAssertLessThanOrEqual(canvasAlpha.minY, expectedPaint.minY + 1)
    XCTAssertLessThan(swiftAlpha.minX, expectedCell.minX)
    XCTAssertLessThan(canvasAlpha.minX, expectedCell.minX)
    XCTAssertLessThan(swiftAlpha.minY, expectedCell.minY)
    XCTAssertLessThan(canvasAlpha.minY, expectedCell.minY)

    // Culling must use the same paint protrusion. Crop entirely within the
    // overhang, where the typographic cell has no intersection.
    let crop = try InlineRenderViewport(
      x: Double(paintBounds.minX + 0.25),
      y: Double(paintBounds.minY + 0.25),
      width: 0.5,
      height: 0.5
    )
    let croppedSwiftImage = try Self.renderImage(
      InlineSwiftUIRenderer(content: swiftUIContent, viewport: crop),
      viewport: crop,
      scale: 3
    )
    let croppedCanvasImage = try Self.renderImage(
      InlineCanvasRenderer(content: canvasContent, viewport: crop),
      viewport: crop,
      scale: 3
    )
    XCTAssertNotNil(Self.alphaBounds(croppedSwiftImage))
    XCTAssertNotNil(Self.alphaBounds(croppedCanvasImage))
  }

  func testModernFactoryRejectsOrdinaryImageBytesInsteadOfPublishingAPlaceholder() throws {
    #if os(macOS)
      guard #available(macOS 15.0, *) else {
        throw XCTSkip("adaptive provider APIs require macOS 15 or newer")
      }
    #elseif os(iOS)
      guard #available(iOS 18.0, *) else {
        throw XCTSkip("adaptive provider APIs require iOS 18 or newer")
      }
    #else
      throw XCTSkip("adaptive provider test is only configured for macOS/iOS")
    #endif

    let pngData = try XCTUnwrap(Data(base64Encoded: Self.transparentPNG))
    let font = FontDescriptor(postScriptName: "Helvetica", pointSize: 12)
    let cases: [(InlineImageEncoding, Data, String)] = [
      (.png, pngData, "ordinary-png"),
      (.jpeg, Data([0xff, 0xd8, 0xff]), "ordinary-jpeg"),
    ]
    for (encoding, data, rawID) in cases {
      let rendition = try InlineImageRendition(
        encoding: encoding, encodedBytes: data, pixelWidth: 1, pixelHeight: 1)
      XCTAssertThrowsError(
        try InlineAdaptiveImageGlyphFactory.make(
          id: rawID,
          assetID: try InlineAssetID(rawValue: rawID),
          adaptiveGlyph: NSAdaptiveImageGlyph(imageContent: data),
          font: font,
          accessibility: .label("Ordinary image")
        )
      ) { error in
        guard let typed = error as? InlineImageAssetError else {
          return XCTFail("expected a typed adaptive-content rejection")
        }
        switch typed {
        case .emptyEncodedBytes, .adaptiveContentTypeMismatch:
          break
        default:
          XCTFail("unexpected ordinary-image rejection: \(typed)")
        }
      }
      XCTAssertThrowsError(
        try InlineAdaptiveImageGlyphFactory.makeWithFrozenAdaptivePayload(
          id: rawID,
          assetID: try InlineAssetID(rawValue: rawID),
          adaptiveContent: rendition,
          fallbackRaster: try makeFallbackRaster(data: pngData),
          metrics: try InlineMetrics(advance: 1, ascent: 1, descent: 1),
          font: font,
          accessibility: .label("Ordinary image")
        )
      ) { error in
        XCTAssertEqual(
          error as? InlineImageAssetError,
          .invalidAdaptiveContentEncoding
        )
      }
    }
  }

  func testBothStaticRenderersPrepareImagePaintsBeforeDrawing() throws {
    let artifact = try makeThumbnailArtifact()
    let document = try InlineDocument(atoms: [.image(artifact.atom)])
    let prepared = try InlinePreparation(shaper: NoopImageShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 32)
    let plan = try InlineRenderPlan(prepared: prepared, layout: layout)
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 32, height: 32)
    let provider = NoopGeometryProvider()

    let swiftUI = try InlineSwiftUIRenderContent(
      plan: plan,
      assets: provider,
      imageAssets: artifact.store
    )
    let canvas = try InlineCanvasRenderContent(
      plan: plan,
      assets: provider,
      imageAssets: artifact.store
    )
    let swiftUIRenderer = InlineSwiftUIRenderer(
      content: swiftUI, viewport: viewport)
    let canvasRenderer = InlineCanvasRenderer(
      content: canvas, viewport: viewport)

    XCTAssertEqual(swiftUIRenderer.visibleAtomIDsForTesting(in: viewport), ["thumbnail"])
    XCTAssertEqual(canvasRenderer.visibleAtomIDsForTesting(in: viewport), ["thumbnail"])
  }

  func testSwiftUIAppendAccessibilityHidesDecorativeImages() throws {
    let artifact = try makeThumbnailArtifact()
    let decorative = try InlineImageAtom(
      id: "decorative-thumbnail",
      reference: artifact.atom.reference,
      metrics: artifact.atom.metrics,
      presentation: artifact.atom.presentation,
      accessibility: .decorative
    )
    let streamID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let reducer = try InlineAppendReducer(
      streamID: streamID,
      preparation: InlinePreparation(shaper: NoopImageShaper()),
      engine: InlineLayoutEngine(),
      width: 32
    )
    let session = try InlineAppleAppendSession(
      reducer: reducer,
      assets: NoopGeometryProvider(),
      imageAssets: artifact.store
    )
    let sealed = try InlineSealedAppendAtom(
      sealingCompleteSemanticAtom: .image(decorative))
    let event = InlineAppendEvent.append(
      InlineAppendBatch(
        streamID: streamID,
        sequence: session.snapshot.nextSequence,
        baseRevision: session.snapshot.revision,
        atoms: [sealed]
      ))
    try session.send(event)

    XCTAssertEqual(session.accessibilityEntries.count, 1)
    XCTAssertTrue(session.accessibilityEntries[0].isDecorative)
  }

  private func makeThumbnailPayload(id rawID: String = "shared-thumbnail") throws
    -> InlineImagePayload
  {
    let id = try InlineAssetID(rawValue: rawID)
    let data = try XCTUnwrap(Data(base64Encoded: Self.transparentPNG))
    let rendition = try InlineImageRendition(
      encoding: .png, encodedBytes: data, pixelWidth: 1, pixelHeight: 1)
    let reference = try InlineImageReference(
      assetID: id, version: 1, digest: InlineAssetDigest(data: data))
    return try InlineImagePayload(reference: reference, rendition: rendition)
  }

  private func makeImageCompileFixture(
    rendition: InlineImageRendition,
    rawID: String
  ) throws -> (plan: InlineRenderPlan, store: InlineImageAssetStore, atom: InlineImageAtom) {
    let assetID = try InlineAssetID(rawValue: rawID)
    let reference = try InlineImageReference(
      assetID: assetID,
      version: 1,
      digest: InlineAssetDigest(data: rendition.encodedBytes)
    )
    let payload = try InlineImagePayload(reference: reference, rendition: rendition)
    let metrics = try InlineMetrics(advance: 12, ascent: 8, descent: 4)
    let atom = try InlineImageAtom(
      id: rawID,
      reference: reference,
      metrics: metrics,
      presentation: .thumbnail(contentMode: .fit),
      accessibility: .label(rawID)
    )
    let document = try InlineDocument(atoms: [.image(atom)])
    let prepared = try InlinePreparation(shaper: NoopImageShaper()).prepare(document: document)
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 100)
    return (
      try InlineRenderPlan(prepared: prepared, layout: layout),
      try InlineImageAssetStore(payloads: [payload]),
      atom
    )
  }

  private func makeFallbackRaster(
    data: Data,
    minX: Double = 0,
    minY: Double = 0
  ) throws -> InlineAdaptiveFallbackRaster {
    let rendition = try InlineImageRendition(
      encoding: .png,
      encodedBytes: data,
      pixelWidth: 1,
      pixelHeight: 1
    )
    return try InlineAdaptiveFallbackRaster(
      png: rendition,
      paintBounds: try InlineBaselinePaintBounds(
        minX: minX,
        maxX: minX + 1.0 / 3.0,
        minY: minY,
        maxY: minY + 1.0 / 3.0
      )
    )
  }

  private static func makeRasterData(type: UTType, width: Int, height: Int) throws -> Data {
    guard width > 0, height > 0,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw InlineImageAssetError.invalidFallbackRaster
    }
    context.setFillColor(CGColor(red: 0.15, green: 0.65, blue: 0.95, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let filledImage = context.makeImage() else {
      throw InlineImageAssetError.invalidFallbackRaster
    }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, type.identifier as CFString, 1, nil
      )
    else {
      throw InlineImageAssetError.invalidFallbackRaster
    }
    CGImageDestinationAddImage(destination, filledImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw InlineImageAssetError.invalidFallbackRaster
    }
    return output as Data
  }

  private static func forgedPNGHeader(
    from data: Data,
    width: Int,
    height: Int
  ) -> Data {
    var bytes = Array(data)
    precondition(bytes.count >= 33)
    writeBigEndian(UInt32(width), into: &bytes, at: 16)
    writeBigEndian(UInt32(height), into: &bytes, at: 20)
    let crc = pngCRC32(bytes[12..<29])
    writeBigEndian(crc, into: &bytes, at: 29)
    return Data(bytes)
  }

  private static func forgedJPEGHeader(
    from data: Data,
    width: Int,
    height: Int
  ) -> Data {
    var bytes = Array(data)
    precondition(width > 0 && height > 0)
    var cursor = 2  // JPEG SOI
    while cursor + 3 < bytes.count {
      guard bytes[cursor] == 0xff else {
        cursor += 1
        continue
      }
      while cursor < bytes.count, bytes[cursor] == 0xff { cursor += 1 }
      guard cursor < bytes.count else { break }
      let marker = bytes[cursor]
      cursor += 1
      guard marker != 0xd8, marker != 0xd9 else { continue }
      guard cursor + 1 < bytes.count else { break }
      let segmentLength = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
      guard segmentLength >= 2, cursor + segmentLength <= bytes.count else { break }
      let isStartOfFrame =
        (0xc0...0xc3).contains(marker)
        || (0xc5...0xc7).contains(marker)
        || (0xc9...0xcb).contains(marker)
        || (0xcd...0xcf).contains(marker)
      if isStartOfFrame {
        precondition(cursor + 6 < bytes.count)
        writeBigEndian(UInt32(height), into: &bytes, at: cursor + 3, byteCount: 2)
        writeBigEndian(UInt32(width), into: &bytes, at: cursor + 5, byteCount: 2)
        return Data(bytes)
      }
      cursor += segmentLength
    }
    preconditionFailure("generated JPEG did not contain a SOF segment")
  }

  private static func forgedHEICHeader(
    from data: Data,
    width: Int,
    height: Int
  ) -> Data {
    var bytes = Array(data)
    precondition(width > 0 && height > 0)
    let marker = Array("ispe".utf8)
    guard
      let markerIndex = bytes.indices.dropLast(marker.count - 1).first(where: {
        Array(bytes[$0..<$0 + marker.count]) == marker
      })
    else {
      preconditionFailure("generated HEIC did not contain an ispe box")
    }
    let widthOffset = markerIndex + 8
    let heightOffset = markerIndex + 12
    precondition(heightOffset + 4 <= bytes.count)
    writeBigEndian(UInt32(width), into: &bytes, at: widthOffset)
    writeBigEndian(UInt32(height), into: &bytes, at: heightOffset)
    return Data(bytes)
  }

  private static func writeBigEndian(
    _ value: UInt32,
    into bytes: inout [UInt8],
    at offset: Int,
    byteCount: Int = 4
  ) {
    precondition(byteCount == 2 || byteCount == 4)
    if byteCount == 2 {
      bytes[offset] = UInt8((value >> 8) & 0xff)
      bytes[offset + 1] = UInt8(value & 0xff)
      return
    }
    bytes[offset] = UInt8((value >> 24) & 0xff)
    bytes[offset + 1] = UInt8((value >> 16) & 0xff)
    bytes[offset + 2] = UInt8((value >> 8) & 0xff)
    bytes[offset + 3] = UInt8(value & 0xff)
  }

  private static func pngCRC32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        if (crc & 1) == 1 {
          crc = (crc >> 1) ^ 0xedb8_8320
        } else {
          crc >>= 1
        }
      }
    }
    return crc ^ 0xffff_ffff
  }

  private func makeThumbnailArtifact() throws -> ThumbnailArtifact {
    let payload = try makeThumbnailPayload()
    let metrics = try InlineMetrics(advance: 12, ascent: 8, descent: 4)
    let atom = try InlineImageAtom(
      id: "thumbnail",
      reference: payload.reference,
      metrics: metrics,
      presentation: .thumbnail(contentMode: .fit),
      accessibility: .label("Thumbnail")
    )
    return ThumbnailArtifact(atom: atom, store: try InlineImageAssetStore(payloads: [payload]))
  }

  private func makeAdaptiveArtifact(
    fallbackMinX: Double = 0,
    fallbackMinY: Double = 0
  ) throws -> InlineAdaptiveImageGlyphArtifact {
    let contentData = try XCTUnwrap(Data(base64Encoded: Self.adaptiveHEIC))
    let fallbackData = try XCTUnwrap(Data(base64Encoded: Self.transparentPNG))
    let contentRendition = try InlineImageRendition(
      encoding: .heic,
      encodedBytes: contentData,
      pixelWidth: 32,
      pixelHeight: 32
    )
    let font = FontDescriptor(postScriptName: "Helvetica", pointSize: 12)
    let metrics = try InlineMetrics(advance: 12, ascent: 9, descent: 3)
    return try InlineAdaptiveImageGlyphFactory.makeWithFrozenAdaptivePayload(
      id: "adaptive",
      assetID: try InlineAssetID(rawValue: "adaptive"),
      adaptiveContent: contentRendition,
      fallbackRaster: try makeFallbackRaster(
        data: fallbackData,
        minX: fallbackMinX,
        minY: fallbackMinY
      ),
      metrics: metrics,
      font: font,
      accessibility: .label("Adaptive image")
    )
  }

  private struct ThumbnailArtifact {
    let atom: InlineImageAtom
    let store: InlineImageAssetStore
  }

  private struct NoopGeometryProvider: InlineAssetGeometryProvider {
    func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
      throw InlineAssetResolutionError.missingGeometry(assetID, version: version)
    }
  }

  private struct NoopImageShaper: InlineTextShaping {
    func shape(
      text: String,
      style: InlineTextStyle,
      sourceRange: InlineSourceRange
    ) throws -> InlineShapedText {
      try InlineShapedText(
        graphemeRanges: [],
        graphemeAdvances: [],
        runs: [],
        metrics: InlineMetrics(advance: 0, ascent: style.font.pointSize, descent: 0)
      )
    }
  }

  private static let transparentPNG =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

  private static let twoByOnePNG =
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADUlEQVR4nGP4z8AAQgAL/AL+XdyCPwAAAABJRU5ErkJggg=="

  private static func decodeImage(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private static func renderImage<V: View>(
    _ content: V,
    viewport: InlineRenderViewport,
    scale: Double
  ) throws -> CGImage {
    let renderer = ImageRenderer(
      content:
        content
        .environment(\.colorScheme, .light)
        .background(Color.clear)
    )
    renderer.proposedSize = ProposedViewSize(
      width: viewport.width, height: viewport.height)
    renderer.scale = scale
    guard let image = renderer.cgImage else {
      throw XCTSkip("ImageRenderer did not produce a static render-back image")
    }
    return image
  }

  private static func alphaBounds(_ image: CGImage) -> CGRect? {
    guard let pixels = normalizedRGBA(for: image) else { return nil }
    var minX = image.width
    var minY = image.height
    var maxX = 0
    var maxY = 0
    var found = false
    for y in 0..<image.height {
      for x in 0..<image.width {
        let alpha = pixels[(y * image.width + x) * 4 + 3]
        guard alpha > 0 else { continue }
        found = true
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x + 1)
        maxY = max(maxY, y + 1)
      }
    }
    guard found else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  private static func normalizedRGBA(for image: CGImage) -> [UInt8]? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      ),
      let data = context.data
    else { return nil }
    context.interpolationQuality = .none
    context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    return Array(
      UnsafeBufferPointer(
        start: data.assumingMemoryBound(to: UInt8.self),
        count: image.width * image.height * 4
      )
    )
  }

  private static func renderPixels(
    width: Int,
    height: Int,
    draw: (CGContext) -> Void
  ) throws -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw InlineImageAssetError.invalidFallbackRaster
    }
    var data = Data(repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return }
      draw(context)
    }
    return data
  }

  private struct PixelParity {
    let leftAlphaBounds: CGRect?
    let rightAlphaBounds: CGRect?
    let differingPixelRatio: Double
    let maxChannelDelta: Int
    let meanChannelDelta: Double
  }

  private static func pixelParity(
    _ lhs: Data,
    _ rhs: Data,
    width: Int,
    height: Int
  ) -> PixelParity {
    guard lhs.count == rhs.count, lhs.count == width * height * 4,
      width > 0, height > 0
    else {
      return PixelParity(
        leftAlphaBounds: nil,
        rightAlphaBounds: nil,
        differingPixelRatio: 1,
        maxChannelDelta: 255,
        meanChannelDelta: 255
      )
    }
    let left = Array(lhs)
    let right = Array(rhs)
    var differingPixels = 0
    var maxChannelDelta = 0
    var totalChannelDelta = 0
    for pixel in 0..<(width * height) {
      let offset = pixel * 4
      var differs = false
      for channel in 0..<4 {
        let delta = abs(Int(left[offset + channel]) - Int(right[offset + channel]))
        if delta > 0 { differs = true }
        maxChannelDelta = max(maxChannelDelta, delta)
        totalChannelDelta += delta
      }
      if differs { differingPixels += 1 }
    }
    return PixelParity(
      leftAlphaBounds: alphaBounds(lhs, width: width, height: height),
      rightAlphaBounds: alphaBounds(rhs, width: width, height: height),
      differingPixelRatio: Double(differingPixels) / Double(width * height),
      maxChannelDelta: maxChannelDelta,
      meanChannelDelta: Double(totalChannelDelta) / Double(lhs.count)
    )
  }

  private static func alphaBounds(_ data: Data, width: Int, height: Int) -> CGRect? {
    let bytes = Array(data)
    var minX = width
    var minY = height
    var maxX = 0
    var maxY = 0
    var found = false
    for y in 0..<height {
      for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 0 {
        found = true
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x + 1)
        maxY = max(maxY, y + 1)
      }
    }
    guard found else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  private static let adaptiveHEIC =
    "AAAAJGZ0eXBoZWljAAAAAG1pZjFNaVBybWlhZk1pSEJoZWljAAABw21ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAHBpY3QAAAAAAAAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAADnBpdG0AAAAAAAEAAAA4aWluZgAAAAAAAgAAABVpbmZlAgAAAAABAABodmMxAAAAABVpbmZlAgAAAQACAABFeGlmAAAAABppcmVmAAAAAAAAAA5jZHNjAAIAAQABAAAA5mlwcnAAAADFaXBjbwAAABNjb2xybmNseAACAAIABoAAAAAMY2xsaQDLAEAAAAAUaXNwZQAAAAAAAAAgAAAAIAAAAAlpcm90AAAAABBwaXhpAAAAAAMICAgAAABxaHZjQwEDcAAAALAAAAAAAB7wAPz9+PgAAAsDoAABABdAAQwB//8DcAAAAwCwAAADAAADAB5wJKEAAQAjQgEBA3AAAAMAsAAAAwAAAwAeoBQgQcCDCOIe5FlU3AgIGAKiAAEACUQBwGFyyEBTJAAAABlpcG1hAAAAAAAAAAEAAQaBAgMFhoQAAAAsaWxvYwAAAABEAAACAAEAAAABAAACQQAAAD4AAgAAAAEAAAH3AAAASgAAAAFtZGF0AAAAAAAAAJgAAAAGRXhpZgAATU0AKgAAAAgAAQENAAIAAAAlAAAAGgAAAAAwMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDEAAAAAADooAa+i+kaBfP/8ZIf/+I77L8d3vVf/gIfI+t/i/5ZI90yyZ/og+cI5xu1DrAW/1T0IvYV+CtwhJsiu"
}
