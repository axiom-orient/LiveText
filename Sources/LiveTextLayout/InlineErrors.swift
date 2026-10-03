import Foundation

public typealias InlineCancellationCheck = @Sendable () throws -> Void

/// Failures raised while validating, preparing, or laying out inline content.
public enum InlineLayoutError: Error, Equatable, LocalizedError, Sendable {
  case invalidIdentifier
  case duplicateIdentifier(String)
  case unsupportedSchemaVersion(expected: Int, actual: Int)
  case invalidMetric(name: String, value: Double)
  case invalidWidth(Double)
  case invalidSourceRange
  case sourceRangeNotAtGraphemeBoundary(InlineSourceRange)
  case invalidCursor(InlineCursor)
  case invalidContinuation
  case emptyFontName
  case invalidFontSize(Double)
  case invalidTracking(Double)
  case invalidBaselineOffset(Double)
  case invalidWritingPoint(field: String, value: Double)
  case invalidWritingStroke(String)
  case invalidWritingGlyph(String)
  case invalidWritingFace(faceID: String, reason: String)
  case duplicateWritingFace(String)
  case missingWritingFace(faceID: String, atomID: String, glyph: String)
  case unsupportedWritingGlyph(faceID: String, glyph: String)
  case malformedWritingFace(faceID: String, glyph: String, reason: String)
  case invalidWritingLimit(resource: String, value: Int)
  case invalidImageAccessibility
  case adaptiveGlyphFallbackUnavailable(InlineAssetID)
  case adaptiveGlyphMetricsMismatch(InlineAssetID)
  case unsupportedShaping(String)
  case missingAsset(InlineAssetID)
  case oversizedVector(id: String, advance: Double, width: Double)
  case oversizedImage(id: String, advance: Double, width: Double)
  case invalidOversizedVectorPolicy
  case invalidRenderPlan
  case invalidFlowRegion(String)
  case flowContentExceedsRegion
  case cancelled
  case resourceLimitExceeded(resource: String, actual: Int, limit: Int)
  case streamIdentityMismatch(expected: UUID, actual: UUID)
  case streamSequenceMismatch(expected: UInt64, actual: UInt64)
  case streamRevisionMismatch(expected: String, actual: String)
  case conflictingStreamReplay(sequence: UInt64)
  case streamAlreadyFinished
  case streamNotFinished
  case invalidSVGPath(String)
  case emptySVGPath
  case nonFiniteSVGPath
  case svgPathLimitExceeded(actual: Int, limit: Int)
  case assetCacheLimitExceeded(actual: Int, limit: Int)
  case streamingBackpressureExceeded

  public var errorDescription: String? {
    switch self {
    case .invalidIdentifier:
      return "Inline identifiers must not be empty."
    case .duplicateIdentifier(let id):
      return "Duplicate inline atom identifier: \(id)."
    case .unsupportedSchemaVersion(let expected, let actual):
      return "Unsupported inline document schema version: expected \(expected), received \(actual)."
    case .invalidMetric(let name, let value):
      return "Invalid inline metric \(name): \(value)."
    case .invalidWidth(let width):
      return "Inline layout width must be finite and positive: \(width)."
    case .invalidSourceRange:
      return "The UTF-16 source range is invalid."
    case .sourceRangeNotAtGraphemeBoundary(let range):
      return "The source range is not aligned to extended grapheme boundaries: \(range)."
    case .invalidCursor(let cursor):
      return "The inline cursor is invalid: \(cursor)."
    case .invalidContinuation:
      return "The inline layout continuation does not match the prepared document."
    case .emptyFontName:
      return "An inline text font name must not be empty."
    case .invalidFontSize(let size):
      return "An inline text font size must be finite and positive: \(size)."
    case .invalidTracking(let tracking):
      return "Inline tracking must be finite: \(tracking)."
    case .invalidBaselineOffset(let offset):
      return "Inline baseline offset must be finite: \(offset)."
    case .invalidWritingPoint(let field, let value):
      return "Invalid normalized writing point \(field): \(value)."
    case .invalidWritingStroke(let reason):
      return "Invalid writing stroke: \(reason)."
    case .invalidWritingGlyph(let glyph):
      return "Invalid writing glyph template: \(glyph)."
    case .invalidWritingFace(let faceID, let reason):
      return "Invalid writing face \(faceID): \(reason)."
    case .duplicateWritingFace(let faceID):
      return "Duplicate writing face: \(faceID)."
    case .missingWritingFace(let faceID, let atomID, let glyph):
      return "Writing face \(faceID) required by text atom \(atomID) is missing for '\(glyph)'."
    case .unsupportedWritingGlyph(let faceID, let glyph):
      return "Writing face \(faceID) does not support '\(glyph)'."
    case .malformedWritingFace(let faceID, let glyph, let reason):
      return "Writing face \(faceID) returned malformed data for '\(glyph)': \(reason)."
    case .invalidWritingLimit(let resource, let value):
      return
        "Inline writing \(resource) limit must be positive and within the supported ceiling: \(value)."
    case .invalidImageAccessibility:
      return "An inline image must provide a non-empty accessibility label or be decorative."
    case .adaptiveGlyphFallbackUnavailable(let id):
      return
        "Adaptive inline image \(id.rawValue) cannot render on this OS because its deterministic fallback raster is unavailable."
    case .adaptiveGlyphMetricsMismatch(let id):
      return
        "Adaptive inline image metrics do not match the frozen Core Text metrics for \(id.rawValue)."
    case .unsupportedShaping(let reason):
      return "Inline text shaping is unsupported: \(reason)."
    case .missingAsset(let id):
      return "The inline asset is missing: \(id.rawValue)."
    case .oversizedVector(let id, let advance, let width):
      return "Inline vector \(id) is wider than the available line (\(advance) > \(width))."
    case .oversizedImage(let id, let advance, let width):
      return "Inline image \(id) is wider than the available line (\(advance) > \(width))."
    case .invalidOversizedVectorPolicy:
      return "The oversized vector policy contains an invalid scale."
    case .invalidRenderPlan:
      return "The inline render plan does not match the prepared document."
    case .invalidFlowRegion(let reason):
      return "The inline flow region is invalid: \(reason)."
    case .flowContentExceedsRegion:
      return "Inline content cannot fit inside the finite flow region."
    case .cancelled:
      return "Inline preparation or layout was cancelled."
    case .resourceLimitExceeded(let resource, let actual, let limit):
      return "Inline \(resource) limit exceeded: \(actual) > \(limit)."
    case .streamIdentityMismatch(let expected, let actual):
      return "Inline stream identity mismatch: expected \(expected), received \(actual)."
    case .streamSequenceMismatch(let expected, let actual):
      return "Inline stream sequence mismatch: expected \(expected), received \(actual)."
    case .streamRevisionMismatch(let expected, let actual):
      return "Inline stream revision mismatch: expected \(expected), received \(actual)."
    case .conflictingStreamReplay(let sequence):
      return "Inline stream replay conflicts with the receipt at sequence \(sequence)."
    case .streamAlreadyFinished:
      return "The inline append stream has already finished."
    case .streamNotFinished:
      return "The inline append stream must finish before it can be finalized."
    case .invalidSVGPath(let message):
      return "Invalid SVG path data: \(message)."
    case .emptySVGPath:
      return "SVG path data must contain a drawable command."
    case .nonFiniteSVGPath:
      return "SVG path coordinates must be finite."
    case .svgPathLimitExceeded(let actual, let limit):
      return "SVG path command limit exceeded: \(actual) > \(limit)."
    case .assetCacheLimitExceeded(let actual, let limit):
      return "Inline asset cache limit exceeded: \(actual) > \(limit)."
    case .streamingBackpressureExceeded:
      return "Inline streaming consumer did not accept the next bounded result."
    }
  }
}
