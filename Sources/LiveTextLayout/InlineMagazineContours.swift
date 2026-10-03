import Foundation

/// A finite point in the same absolute layout coordinates as the text container.
/// Runtime media geometry is deliberately separate from persisted document data.
public struct InlineFlowPoint: Sendable, Hashable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) throws {
    guard x.isFinite, y.isFinite else {
      throw InlineLayoutError.invalidFlowRegion("contour points must be finite")
    }
    self.x = x
    self.y = y
  }
}

/// One convex, non-self-intersecting media footprint, clockwise or counterclockwise.
/// Points are absolute coordinates; the closing first point must not be repeated.
public struct InlineFlowContour: Sendable, Hashable {
  public let id: String
  public let points: [InlineFlowPoint]
  public let bounds: InlineFlowRect

  public init(id: String, points: [InlineFlowPoint]) throws {
    guard !id.isEmpty else { throw InlineLayoutError.invalidIdentifier }
    guard points.count >= 3, Set(points).count == points.count else {
      throw InlineLayoutError.invalidFlowRegion("a contour needs at least three distinct points")
    }
    let minX = points.map(\.x).min()!
    let maxX = points.map(\.x).max()!
    let minY = points.map(\.y).min()!
    let maxY = points.map(\.y).max()!
    let bounds = try InlineFlowRect(
      x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    guard bounds.width > 0, bounds.height > 0 else {
      throw InlineLayoutError.invalidFlowRegion("a contour must have positive area")
    }

    // Normalize before cross products so validation is invariant under uniform
    // scaling and finite but large absolute coordinates do not overflow.
    let extent = max(bounds.width, bounds.height)
    let normalized = points.map { (( $0.x - minX) / extent, ($0.y - minY) / extent) }
    var orientation = 0.0
    for index in normalized.indices {
      let start = normalized[index]
      let end = normalized[(index + 1) % normalized.count]
      for point in normalized {
        let cross = (end.0 - start.0) * (point.1 - start.1)
          - (end.1 - start.1) * (point.0 - start.0)
        guard cross.isFinite else {
          throw InlineLayoutError.invalidFlowRegion("contour geometry overflowed")
        }
        if cross == 0 { continue }
        if orientation == 0 { orientation = cross }
        guard (orientation > 0) == (cross > 0) else {
          throw InlineLayoutError.invalidFlowRegion("a contour must be convex and non-self-intersecting")
        }
      }
    }
    guard orientation != 0 else {
      throw InlineLayoutError.invalidFlowRegion("a contour must have positive area")
    }
    self.id = id
    self.points = points
    self.bounds = bounds
  }

  /// Creates a footprint rotated around the rectangle's center. `rotation` is
  /// radians. Clearance expands the rectangle in its own axes before rotation;
  /// callers may derive it from container width without changing saved placement.
  public static func rotatedRectangle(
    id: String,
    rect: InlineFlowRect,
    rotation: Double = 0,
    clearance: Double = 0
  ) throws -> InlineFlowContour {
    guard rect.width > 0, rect.height > 0, rotation.isFinite,
      clearance.isFinite, clearance >= 0
    else {
      throw InlineLayoutError.invalidFlowRegion("rotated media geometry must be finite and positive")
    }
    let halfWidth = rect.width / 2 + clearance
    let halfHeight = rect.height / 2 + clearance
    let centerX = rect.minX + rect.width / 2
    let centerY = rect.minY + rect.height / 2
    let cosine = cos(rotation)
    let sine = sin(rotation)
    let corners = [(-halfWidth, -halfHeight), (halfWidth, -halfHeight),
                   (halfWidth, halfHeight), (-halfWidth, halfHeight)]
    return try InlineFlowContour(id: id, points: corners.map { x, y in
      try InlineFlowPoint(x: centerX + x * cosine - y * sine,
                          y: centerY + x * sine + y * cosine)
    })
  }

  fileprivate func blockedInterval(minY: Double, maxY: Double)
    -> (minX: Double, maxX: Double)?
  {
    guard bounds.minY < maxY, bounds.maxY > minY else { return nil }
    // Clip against the whole line-height band, not just its baseline. Projecting
    // the clipped polygon retains space beside rotated corners without allowing
    // ascenders or descenders to collide with the media.
    var clipped = points.map { (x: $0.x, y: $0.y) }
    clipped = Self.clip(clipped, atY: minY, keepingAbove: true)
    clipped = Self.clip(clipped, atY: maxY, keepingAbove: false)
    guard let left = clipped.map(\.x).min(), let right = clipped.map(\.x).max(),
      left < right
    else { return nil }
    return (left, right)
  }

  private static func clip(
    _ polygon: [(x: Double, y: Double)], atY boundary: Double, keepingAbove: Bool
  ) -> [(x: Double, y: Double)] {
    guard var previous = polygon.last else { return [] }
    var result: [(x: Double, y: Double)] = []
    var previousInside = keepingAbove ? previous.y >= boundary : previous.y <= boundary
    for point in polygon {
      let inside = keepingAbove ? point.y >= boundary : point.y <= boundary
      if inside != previousInside {
        let fraction = (boundary - previous.y) / (point.y - previous.y)
        result.append((previous.x + (point.x - previous.x) * fraction, boundary))
      }
      if inside { result.append(point) }
      previous = point
      previousInside = inside
    }
    return result
  }
}

/// Runtime magazine geometry for freely positioned media. It uses the same
/// interval subtraction as `InlineFlowRegion`, without changing Codable schemas.
public struct InlineMagazineFlow: Sendable, Hashable {
  public let contentRect: InlineFlowRect
  public let contours: [InlineFlowContour]
  public let minimumFragmentFraction: Double

  public init(
    contentRect: InlineFlowRect,
    contours: [InlineFlowContour] = [],
    minimumFragmentFraction: Double = 0
  ) throws {
    guard contentRect.width > 0, contentRect.height > 0 else {
      throw InlineLayoutError.invalidFlowRegion("magazine content must have positive size")
    }
    guard minimumFragmentFraction.isFinite,
      (0...1).contains(minimumFragmentFraction)
    else {
      throw InlineLayoutError.invalidFlowRegion("minimum fragment fraction must be between zero and one")
    }
    guard Set(contours.map(\.id)).count == contours.count else {
      throw InlineLayoutError.invalidFlowRegion("duplicate contour identifier")
    }
    self.contentRect = contentRect
    self.contours = contours
    self.minimumFragmentFraction = minimumFragmentFraction
  }

  /// Available intervals across the entire proposed line band, in physical x
  /// order. The optional floor is a fraction of content width, independent of
  /// font size. Its default is zero: native shaping decides whether glyphs fit.
  public func fragments(forLine line: InlineFlowRect) throws -> [InlineFlowFragment] {
    guard line.width > 0, line.height > 0 else {
      throw InlineLayoutError.invalidFlowRegion("line geometry must have positive size")
    }
    guard line.minY < contentRect.maxY, line.maxY > contentRect.minY else { return [] }
    let minX = max(contentRect.minX, line.minX)
    let maxX = min(contentRect.maxX, line.maxX)
    let blocked = contours.compactMap {
      $0.blockedInterval(minY: max(contentRect.minY, line.minY),
                         maxY: min(contentRect.maxY, line.maxY))
    }
    return try InlineFlowIntervals.fragments(
      minX: minX, maxX: maxX, blocked: blocked,
      minimumWidth: contentRect.width * minimumFragmentFraction)
  }
}
