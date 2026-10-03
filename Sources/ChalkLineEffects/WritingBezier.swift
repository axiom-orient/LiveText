import Foundation

public struct WritingCoordinate: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) throws {
    guard x.isFinite else { throw WritingCoreError.invalidNumber(field: "coordinate.x", value: x) }
    guard y.isFinite else { throw WritingCoreError.invalidNumber(field: "coordinate.y", value: y) }
    self.x = x
    self.y = y
  }

  private enum CodingKeys: String, CodingKey { case x, y }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      x: values.decode(Double.self, forKey: .x),
      y: values.decode(Double.self, forKey: .y)
    )
  }
}

public struct WritingCubicSegment: Codable, Equatable, Sendable {
  public let start: WritingPoint
  public let control1: WritingCoordinate
  public let control2: WritingCoordinate
  public let end: WritingPoint
}

public enum WritingBezierPath {
  public static func segments(for points: [WritingPoint], tension: Double = 1) throws
    -> [WritingCubicSegment]
  {
    guard points.count > 1 else { return [] }
    guard tension.isFinite, tension >= 0 else {
      throw WritingCoreError.invalidNumber(field: "bezier.tension", value: tension)
    }
    var result: [WritingCubicSegment] = []
    result.reserveCapacity(points.count - 1)
    let factor = tension / 6
    for index in 0..<(points.count - 1) {
      let p0 = points[max(0, index - 1)]
      let p1 = points[index]
      let p2 = points[index + 1]
      let p3 = points[min(points.count - 1, index + 2)]
      let c1 = try WritingCoordinate(
        x: p1.x + (p2.x - p0.x) * factor,
        y: p1.y + (p2.y - p0.y) * factor
      )
      let c2 = try WritingCoordinate(
        x: p2.x - (p3.x - p1.x) * factor,
        y: p2.y - (p3.y - p1.y) * factor
      )
      result.append(WritingCubicSegment(start: p1, control1: c1, control2: c2, end: p2))
    }
    return result
  }
}
