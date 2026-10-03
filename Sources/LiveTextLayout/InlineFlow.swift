import Foundation

/// A finite, axis-aligned rectangle in layout coordinates.
public struct InlineFlowRect: Sendable, Hashable, Codable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) throws {
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
      width >= 0, height >= 0,
      (x + width).isFinite, (y + height).isFinite
    else {
      throw InlineLayoutError.invalidFlowRegion("rectangle must be finite and non-negative")
    }
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var minX: Double { x }
  public var minY: Double { y }
  public var maxX: Double { x + width }
  public var maxY: Double { y + height }

  private enum CodingKeys: String, CodingKey { case x, y, width, height }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      x: values.decode(Double.self, forKey: .x),
      y: values.decode(Double.self, forKey: .y),
      width: values.decode(Double.self, forKey: .width),
      height: values.decode(Double.self, forKey: .height)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(x, forKey: .x)
    try values.encode(y, forKey: .y)
    try values.encode(width, forKey: .width)
    try values.encode(height, forKey: .height)
  }

  func inset(by insets: InlineFlowInsets) throws -> InlineFlowRect {
    let newX = x + insets.leading
    let newY = y + insets.top
    let newWidth = width - insets.leading - insets.trailing
    let newHeight = height - insets.top - insets.bottom
    guard newWidth >= 0, newHeight >= 0 else {
      throw InlineLayoutError.invalidFlowRegion("content insets exceed container bounds")
    }
    return try InlineFlowRect(x: newX, y: newY, width: newWidth, height: newHeight)
  }

  func outset(by insets: InlineFlowInsets) throws -> InlineFlowRect {
    let newX = x - insets.leading
    let newY = y - insets.top
    let newWidth = width + insets.leading + insets.trailing
    let newHeight = height + insets.top + insets.bottom
    return try InlineFlowRect(x: newX, y: newY, width: newWidth, height: newHeight)
  }
}

/// Clearance applied around a rectangular exclusion or inside a flow region.
public struct InlineFlowInsets: Sendable, Hashable, Codable {
  public let top: Double
  public let leading: Double
  public let bottom: Double
  public let trailing: Double

  public static let zero = InlineFlowInsets(uncheckedTop: 0, leading: 0, bottom: 0, trailing: 0)

  public init(top: Double, leading: Double, bottom: Double, trailing: Double) throws {
    guard top.isFinite, leading.isFinite, bottom.isFinite, trailing.isFinite,
      top >= 0, leading >= 0, bottom >= 0, trailing >= 0
    else {
      throw InlineLayoutError.invalidFlowRegion("insets must be finite and non-negative")
    }
    self.init(uncheckedTop: top, leading: leading, bottom: bottom, trailing: trailing)
  }

  private init(uncheckedTop top: Double, leading: Double, bottom: Double, trailing: Double) {
    self.top = top
    self.leading = leading
    self.bottom = bottom
    self.trailing = trailing
  }

  func validate() throws {
    guard top.isFinite, leading.isFinite, bottom.isFinite, trailing.isFinite,
      top >= 0, leading >= 0, bottom >= 0, trailing >= 0
    else {
      throw InlineLayoutError.invalidFlowRegion("insets must be finite and non-negative")
    }
  }

  private enum CodingKeys: String, CodingKey { case top, leading, bottom, trailing }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      top: values.decode(Double.self, forKey: .top),
      leading: values.decode(Double.self, forKey: .leading),
      bottom: values.decode(Double.self, forKey: .bottom),
      trailing: values.decode(Double.self, forKey: .trailing)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(top, forKey: .top)
    try values.encode(leading, forKey: .leading)
    try values.encode(bottom, forKey: .bottom)
    try values.encode(trailing, forKey: .trailing)
  }
}

/// External geometry that is removed from the available text-flow area.
public struct InlineFlowExclusion: Sendable, Hashable, Codable {
  public let id: String
  public let rect: InlineFlowRect
  public let insets: InlineFlowInsets
  private let expandedRect: InlineFlowRect

  public init(
    id: String,
    rect: InlineFlowRect,
    insets: InlineFlowInsets = .zero
  ) throws {
    guard !id.isEmpty else { throw InlineLayoutError.invalidIdentifier }
    try insets.validate()
    let expandedRect = try rect.outset(by: insets)
    self.id = id
    self.rect = rect
    self.insets = insets
    self.expandedRect = expandedRect
  }

  var bounds: InlineFlowRect {
    expandedRect
  }

  private enum CodingKeys: String, CodingKey { case id, rect, insets }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(String.self, forKey: .id),
      rect: values.decode(InlineFlowRect.self, forKey: .rect),
      insets: values.decode(InlineFlowInsets.self, forKey: .insets)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(rect, forKey: .rect)
    try values.encode(insets, forKey: .insets)
  }
}

/// One available horizontal interval in a row of a flow region.
public struct InlineFlowFragment: Sendable, Hashable, Codable {
  public let originX: Double
  public let maxWidth: Double

  public init(originX: Double, maxWidth: Double) throws {
    guard originX.isFinite, maxWidth.isFinite, maxWidth > 0,
      (originX + maxWidth).isFinite
    else {
      throw InlineLayoutError.invalidFlowRegion("flow fragment must be finite and positive")
    }
    self.originX = originX
    self.maxWidth = maxWidth
  }

  var maxX: Double { originX + maxWidth }

  private enum CodingKeys: String, CodingKey { case originX, maxWidth }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      originX: values.decode(Double.self, forKey: .originX),
      maxWidth: values.decode(Double.self, forKey: .maxWidth)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(originX, forKey: .originX)
    try values.encode(maxWidth, forKey: .maxWidth)
  }
}

/// Immutable rectangular flow input. Exclusions are external geometry; they
/// are never inserted into the prepared inline document.
public struct InlineFlowRegion: Sendable, Hashable, Codable {
  public let rect: InlineFlowRect
  public let insets: InlineFlowInsets
  public let exclusions: [InlineFlowExclusion]
  public let revision: UInt64
  private let contentRectValue: InlineFlowRect

  public init(
    rect: InlineFlowRect,
    insets: InlineFlowInsets = .zero,
    exclusions: [InlineFlowExclusion] = [],
    revision: UInt64 = 0
  ) throws {
    try insets.validate()
    let contentRect = try rect.inset(by: insets)
    var ids = Set<String>()
    for exclusion in exclusions {
      guard ids.insert(exclusion.id).inserted else {
        throw InlineLayoutError.invalidFlowRegion("duplicate exclusion identifier: \(exclusion.id)")
      }
    }
    self.rect = rect
    self.insets = insets
    self.exclusions = exclusions
    self.revision = revision
    self.contentRectValue = contentRect
  }

  var contentRect: InlineFlowRect {
    contentRectValue
  }

  private enum CodingKeys: String, CodingKey { case rect, insets, exclusions, revision }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      rect: values.decode(InlineFlowRect.self, forKey: .rect),
      insets: values.decode(InlineFlowInsets.self, forKey: .insets),
      exclusions: values.decode([InlineFlowExclusion].self, forKey: .exclusions),
      revision: values.decode(UInt64.self, forKey: .revision)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(rect, forKey: .rect)
    try values.encode(insets, forKey: .insets)
    try values.encode(exclusions, forKey: .exclusions)
    try values.encode(revision, forKey: .revision)
  }

  /// Computes the positive intervals not occupied by exclusions for a line
  /// rectangle. Intervals are clipped to the content rectangle and sorted by
  /// their x origin, making the result deterministic for any exclusion order.
  func fragments(atY y: Double, height: Double) throws -> [InlineFlowFragment] {
    guard y.isFinite, height.isFinite, height > 0, (y + height).isFinite else {
      throw InlineLayoutError.invalidFlowRegion("line geometry must be finite and positive")
    }
    let content = contentRect
    guard content.width > 0, content.height > 0,
      y < content.maxY, y + height > content.minY
    else { return [] }

    var blocked: [(minX: Double, maxX: Double)] = []
    for exclusion in exclusions {
      let bounds = exclusion.bounds
      guard bounds.minY < y + height, bounds.maxY > y,
        bounds.maxX > content.minX, bounds.minX < content.maxX
      else { continue }
      blocked.append((
        minX: max(content.minX, bounds.minX),
        maxX: min(content.maxX, bounds.maxX)
      ))
    }
    return try InlineFlowIntervals.fragments(
      minX: content.minX, maxX: content.maxX, blocked: blocked)
  }
}

/// Shared interval subtraction for rectangular and contour-based flow inputs.
enum InlineFlowIntervals {
  static func fragments(
    minX: Double,
    maxX: Double,
    blocked: [(minX: Double, maxX: Double)],
    minimumWidth: Double = 0
  ) throws -> [InlineFlowFragment] {
    guard minX < maxX else { return [] }
    let intervals = blocked.compactMap { interval -> (minX: Double, maxX: Double)? in
      let lower = max(minX, interval.minX)
      let upper = min(maxX, interval.maxX)
      return lower < upper ? (lower, upper) : nil
    }.sorted {
      if $0.minX == $1.minX { return $0.maxX < $1.maxX }
      return $0.minX < $1.minX
    }
    var result: [InlineFlowFragment] = []
    var cursor = minX
    for interval in intervals {
      if interval.minX > cursor, interval.minX - cursor >= minimumWidth {
        result.append(try InlineFlowFragment(
          originX: cursor, maxWidth: interval.minX - cursor))
      }
      cursor = max(cursor, interval.maxX)
    }
    if cursor < maxX, maxX - cursor >= minimumWidth {
      result.append(try InlineFlowFragment(originX: cursor, maxWidth: maxX - cursor))
    }
    return result
  }
}
