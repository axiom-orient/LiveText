import Foundation

/// One drawable command in a validated path's semantic writing order.
public struct InlinePathRevealUnit: Sendable, Hashable, Codable {
  public let assetID: InlineAssetID
  public let assetVersion: Int
  public let commandIndex: Int
  public let duration: Double

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      assetID: values.decode(InlineAssetID.self, forKey: .assetID),
      assetVersion: values.decode(Int.self, forKey: .assetVersion),
      commandIndex: values.decode(Int.self, forKey: .commandIndex),
      duration: values.decode(Double.self, forKey: .duration)
    )
  }

  private enum CodingKeys: String, CodingKey { case assetID, assetVersion, commandIndex, duration }

  public init(
    assetID: InlineAssetID,
    assetVersion: Int,
    commandIndex: Int,
    duration: Double
  ) throws {
    guard assetVersion >= 0, commandIndex >= 0, duration.isFinite, duration > 0 else {
      throw InlineLayoutError.invalidMetric(name: "path reveal unit", value: duration)
    }
    self.assetID = assetID
    self.assetVersion = assetVersion
    self.commandIndex = commandIndex
    self.duration = duration
  }
}

/// Builds deterministic semantic path reveal units without flattening curves.
public struct InlinePathRevealPlan: Sendable, Hashable, Codable {
  public static let maximumUnits = 16_384
  public let units: [InlinePathRevealUnit]
  public let duration: Double

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let unitValues = try values.nestedUnkeyedContainer(forKey: .units)
    guard let count = unitValues.count, count <= Self.maximumUnits else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "path reveal units", actual: unitValues.count ?? .max, limit: Self.maximumUnits)
    }
    try self.init(units: values.decode([InlinePathRevealUnit].self, forKey: .units))
  }

  private enum CodingKeys: String, CodingKey { case units }

  public init(units: [InlinePathRevealUnit]) throws {
    guard !units.isEmpty else { throw InlineLayoutError.emptySVGPath }
    guard units.count <= Self.maximumUnits else {
      throw InlineLayoutError.resourceLimitExceeded(
        resource: "path reveal units", actual: units.count, limit: Self.maximumUnits)
    }
    let first = units[0]
    guard
      units.allSatisfy({
        $0.assetID == first.assetID && $0.assetVersion == first.assetVersion
      }),
      units.dropFirst().enumerated().allSatisfy({ index, unit in
        unit.commandIndex > units[index].commandIndex
      })
    else {
      throw InlineLayoutError.invalidRenderPlan
    }
    self.units = units
    let duration = units.reduce(0) { $0 + $1.duration }
    guard duration.isFinite, duration > 0 else {
      throw InlineLayoutError.invalidMetric(name: "path reveal duration", value: duration)
    }
    self.duration = duration
  }

  public func validate(for asset: InlineSVGAsset) throws {
    var expectedCommandIndices: Set<Int> = []
    var current = InlinePathPoint.unchecked(x: 0, y: 0)
    var subpathStart = current
    for (index, command) in asset.trajectoryPath.commands.enumerated() {
      switch command {
      case .move(let point):
        current = point
        subpathStart = point
      case .line(let point):
        if current != point { expectedCommandIndices.insert(index) }
        current = point
      case .quadratic(let control, let point):
        if current != control || control != point { expectedCommandIndices.insert(index) }
        current = point
      case .cubic(let control1, let control2, let point):
        if current != control1 || control1 != control2 || control2 != point {
          expectedCommandIndices.insert(index)
        }
        current = point
      case .close:
        if current != subpathStart { expectedCommandIndices.insert(index) }
        current = subpathStart
      }
    }
    guard
      units.allSatisfy({ unit in
        guard unit.assetID == asset.id,
          unit.assetVersion == asset.version,
          asset.trajectoryPath.commands.indices.contains(unit.commandIndex)
        else { return false }
        switch asset.trajectoryPath.commands[unit.commandIndex] {
        case .move: return false
        case .line, .quadratic, .cubic, .close: return true
        }
      })
        && Set(units.map(\.commandIndex)) == expectedCommandIndices
    else {
      throw InlineLayoutError.invalidRenderPlan
    }
  }
}

public struct InlinePathRevealPlanBuilder: Sendable, Hashable, Codable {
  public let secondsPerUnit: Double
  public let maximumUnits: Int

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      secondsPerUnit: values.decode(Double.self, forKey: .secondsPerUnit),
      maximumUnits: values.decode(Int.self, forKey: .maximumUnits)
    )
  }

  private enum CodingKeys: String, CodingKey { case secondsPerUnit, maximumUnits }

  public init(secondsPerUnit: Double = 0.1, maximumUnits: Int = 16_384) throws {
    guard secondsPerUnit.isFinite, secondsPerUnit > 0, maximumUnits > 0 else {
      throw InlineLayoutError.invalidMetric(name: "secondsPerUnit", value: secondsPerUnit)
    }
    self.secondsPerUnit = secondsPerUnit
    self.maximumUnits = min(maximumUnits, 16_384)
  }

  public func plan(
    asset: InlineSVGAsset,
    cancellation: InlineCancellationCheck = {}
  ) throws -> InlinePathRevealPlan {
    var units: [InlinePathRevealUnit] = []
    units.reserveCapacity(asset.trajectoryPath.commands.count)
    var current = InlinePathPoint.unchecked(x: 0, y: 0)
    var subpathStart = current
    for (index, command) in asset.trajectoryPath.commands.enumerated() {
      try cancellation()
      let length: Double
      switch command {
      case .move(let point):
        current = point
        subpathStart = point
        continue
      case .line(let point):
        length = Self.distance(current, point)
        current = point
      case .quadratic(let control, let point):
        length = Self.quadraticLength(from: current, control: control, to: point)
        current = point
      case .cubic(let control1, let control2, let point):
        length = Self.cubicLength(
          from: current, control1: control1, control2: control2, to: point)
        current = point
      case .close:
        length = Self.distance(current, subpathStart)
        current = subpathStart
      }
      guard length > 0 else { continue }
      let duration = max(length, 0.000_001) * secondsPerUnit
      units.append(
        try InlinePathRevealUnit(
          assetID: asset.id,
          assetVersion: asset.version,
          commandIndex: index,
          duration: duration
        ))
      guard units.count <= maximumUnits else {
        throw InlineLayoutError.resourceLimitExceeded(
          resource: "path reveal units", actual: units.count, limit: maximumUnits)
      }
    }
    return try InlinePathRevealPlan(units: units)
  }

  private static func distance(_ lhs: InlinePathPoint, _ rhs: InlinePathPoint) -> Double {
    hypot(rhs.x - lhs.x, rhs.y - lhs.y)
  }

  private static func quadraticLength(
    from start: InlinePathPoint, control: InlinePathPoint, to end: InlinePathPoint
  ) -> Double {
    var total = 0.0
    var previous = start
    for step in 1...32 {
      let t = Double(step) / 32
      let oneMinusT = 1 - t
      let point = InlinePathPoint.unchecked(
        x: oneMinusT * oneMinusT * start.x
          + 2 * oneMinusT * t * control.x + t * t * end.x,
        y: oneMinusT * oneMinusT * start.y
          + 2 * oneMinusT * t * control.y + t * t * end.y
      )
      total += distance(previous, point)
      previous = point
    }
    return total
  }

  private static func cubicLength(
    from start: InlinePathPoint,
    control1: InlinePathPoint,
    control2: InlinePathPoint,
    to end: InlinePathPoint
  ) -> Double {
    var total = 0.0
    var previous = start
    for step in 1...32 {
      let t = Double(step) / 32
      let oneMinusT = 1 - t
      let point = InlinePathPoint.unchecked(
        x: oneMinusT * oneMinusT * oneMinusT * start.x
          + 3 * oneMinusT * oneMinusT * t * control1.x
          + 3 * oneMinusT * t * t * control2.x + t * t * t * end.x,
        y: oneMinusT * oneMinusT * oneMinusT * start.y
          + 3 * oneMinusT * oneMinusT * t * control1.y
          + 3 * oneMinusT * t * t * control2.y + t * t * t * end.y
      )
      total += distance(previous, point)
      previous = point
    }
    return total
  }
}
