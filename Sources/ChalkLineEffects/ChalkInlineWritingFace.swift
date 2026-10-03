import Foundation
import LiveTextLayout

/// Adapts the existing semantic Latin/Hangul catalog to the renderer-neutral
/// preparation contract. Catalog data remains owned by ChalkLineEffects;
/// prepared documents retain only validated normalized stroke values.
public struct ChalkInlineWritingFace: InlineWritingFace, Sendable {
  public let id: String
  public let version: String
  private let catalog: BuiltinStrokeOrderCatalog

  public init(
    id: String = "chalkline.semantic.stroke-order",
    version: String = "2.0.0",
    catalog: BuiltinStrokeOrderCatalog = BuiltinStrokeOrderCatalog()
  ) throws {
    guard !id.isEmpty, !version.isEmpty else {
      throw InlineLayoutError.invalidWritingFace(faceID: id, reason: "id/version is empty")
    }
    self.id = id
    self.version = version
    self.catalog = catalog
  }

  public func glyph(for character: Character) throws -> InlineWritingGlyph? {
    guard let template = try catalog.template(for: character) else { return nil }
    do {
      let sourcePoints = template.strokes.flatMap(\.points)
      let minimumX = sourcePoints.map(\.x).min() ?? 0
      let maximumX = sourcePoints.map(\.x).max() ?? 1
      let minimumY = sourcePoints.map(\.y).min() ?? 0
      let maximumY = sourcePoints.map(\.y).max() ?? 1
      let strokes = try template.strokes.map { stroke in
        try InlineWritingStroke(
          points: try stroke.points.map {
            try InlineNormalizedWritingPoint(
              x: normalized($0.x, minimum: minimumX, maximum: maximumX),
              y: normalized($0.y, minimum: minimumY, maximum: maximumY),
              width: $0.width)
          }
        )
      }
      return try InlineWritingGlyph(
        character: String(character), advance: template.advance, strokes: strokes
      )
    } catch {
      throw InlineLayoutError.malformedWritingFace(
        faceID: id,
        glyph: String(character),
        reason: String(describing: error)
      )
    }
  }

  /// The source semantic catalog intentionally includes small ascender and
  /// descender overshoots. The inline contract is stricter, so adapt an axis
  /// into its canonical unit cell only when that source axis exceeds it.
  private func normalized(_ value: Double, minimum: Double, maximum: Double) -> Double {
    guard minimum < 0 || maximum > 1 else { return value }
    let extent = maximum - minimum
    guard extent > 0 else { return 0.5 }
    return min(1, max(0, (value - minimum) / extent))
  }
}
