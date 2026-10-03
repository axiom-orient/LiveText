import Foundation

/// Renderer-neutral path primitives. No Core Graphics or UI types cross this boundary.
public struct InlinePathPoint: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double
  public init(x: Double, y: Double) throws {
    guard x.isFinite && y.isFinite else { throw InlineLayoutError.nonFiniteSVGPath }
    self.x = x
    self.y = y
  }

  package init(validatedX x: Double, y: Double) {
    precondition(x.isFinite && y.isFinite)
    self.x = x
    self.y = y
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      x: values.decode(Double.self, forKey: .x),
      y: values.decode(Double.self, forKey: .y)
    )
  }

  private enum CodingKeys: String, CodingKey { case x, y }
}

public enum InlinePathCommand: Codable, Equatable, Hashable, Sendable {
  case move(InlinePathPoint)
  case line(InlinePathPoint)
  case quadratic(control: InlinePathPoint, to: InlinePathPoint)
  case cubic(control1: InlinePathPoint, control2: InlinePathPoint, to: InlinePathPoint)
  case close
}

public struct InlinePathBounds: Codable, Equatable, Hashable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case minX, minY, maxX, maxY
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      minX: values.decode(Double.self, forKey: .minX),
      minY: values.decode(Double.self, forKey: .minY),
      maxX: values.decode(Double.self, forKey: .maxX),
      maxY: values.decode(Double.self, forKey: .maxY)
    )
  }

  public let minX: Double
  public let minY: Double
  public let maxX: Double
  public let maxY: Double

  public init(minX: Double, minY: Double, maxX: Double, maxY: Double) throws {
    guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite,
      minX <= maxX, minY <= maxY
    else { throw InlineLayoutError.nonFiniteSVGPath }
    self.minX = minX
    self.minY = minY
    self.maxX = maxX
    self.maxY = maxY
  }

  fileprivate init(uncheckedMinX minX: Double, minY: Double, maxX: Double, maxY: Double) {
    self.minX = minX
    self.minY = minY
    self.maxX = maxX
    self.maxY = maxY
  }

  public var width: Double { maxX - minX }
  public var height: Double { maxY - minY }
}

public struct InlinePathData: Codable, Equatable, Hashable, Sendable {
  public static let defaultMaximumCommands = 16_384
  public let commands: [InlinePathCommand]
  private let cachedBounds: InlinePathBounds

  public var bounds: InlinePathBounds { cachedBounds }

  private static func computeBounds(for commands: [InlinePathCommand]) -> InlinePathBounds {
    var minX = Double.greatestFiniteMagnitude
    var minY = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude
    var maxY = -Double.greatestFiniteMagnitude
    func include(_ point: InlinePathPoint) {
      minX = min(minX, point.x)
      minY = min(minY, point.y)
      maxX = max(maxX, point.x)
      maxY = max(maxY, point.y)
    }
    func quadraticPoint(
      _ start: InlinePathPoint, _ control: InlinePathPoint, _ end: InlinePathPoint, _ t: Double
    ) -> InlinePathPoint {
      let u = 1 - t
      return InlinePathPoint.unchecked(
        x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
        y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
      )
    }
    func includeQuadratic(
      _ start: InlinePathPoint, _ control: InlinePathPoint, _ end: InlinePathPoint
    ) {
      include(start)
      include(end)
      for (startValue, controlValue, endValue) in [
        (start.x, control.x, end.x), (start.y, control.y, end.y),
      ] {
        let denominator = startValue - 2 * controlValue + endValue
        guard denominator != 0 else { continue }
        let t = (startValue - controlValue) / denominator
        guard t > 0, t < 1 else { continue }
        include(quadraticPoint(start, control, end, t))
      }
    }
    func cubicPoint(
      _ start: InlinePathPoint,
      _ control1: InlinePathPoint,
      _ control2: InlinePathPoint,
      _ end: InlinePathPoint,
      _ t: Double
    ) -> InlinePathPoint {
      let u = 1 - t
      return InlinePathPoint.unchecked(
        x: u * u * u * start.x + 3 * u * u * t * control1.x
          + 3 * u * t * t * control2.x + t * t * t * end.x,
        y: u * u * u * start.y + 3 * u * u * t * control1.y
          + 3 * u * t * t * control2.y + t * t * t * end.y
      )
    }
    func includeCubic(
      _ start: InlinePathPoint,
      _ control1: InlinePathPoint,
      _ control2: InlinePathPoint,
      _ end: InlinePathPoint
    ) {
      include(start)
      include(end)
      for (p0, p1, p2, p3) in [
        (start.x, control1.x, control2.x, end.x),
        (start.y, control1.y, control2.y, end.y),
      ] {
        let a = -p0 + 3 * p1 - 3 * p2 + p3
        let b = 2 * (p0 - 2 * p1 + p2)
        let c = p1 - p0
        let discriminant = b * b - 4 * a * c
        if a == 0 {
          if b != 0 {
            let t = -c / b
            if t > 0, t < 1 { include(cubicPoint(start, control1, control2, end, t)) }
          }
        } else if discriminant >= 0 {
          let root = sqrt(discriminant)
          for t in [(-b + root) / (2 * a), (-b - root) / (2 * a)] {
            if t > 0, t < 1 { include(cubicPoint(start, control1, control2, end, t)) }
          }
        }
      }
    }
    var current: InlinePathPoint?
    var subpathStart: InlinePathPoint?
    for command in commands {
      switch command {
      case .move(let point):
        include(point)
        current = point
        subpathStart = point
      case .line(let point):
        include(point)
        current = point
      case .quadratic(let control, let point):
        if let current { includeQuadratic(current, control, point) }
        current = point
      case .cubic(let control1, let control2, let point):
        if let current { includeCubic(current, control1, control2, point) }
        current = point
      case .close:
        if let subpathStart {
          include(subpathStart)
          current = subpathStart
        }
      }
    }
    // Construction guarantees at least one move, so these values are finite.
    return InlinePathBounds(uncheckedMinX: minX, minY: minY, maxX: maxX, maxY: maxY)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(commands: values.decode([InlinePathCommand].self, forKey: .commands))
  }

  private enum CodingKeys: String, CodingKey { case commands }

  public init(
    commands: [InlinePathCommand], maximumCommands: Int = InlinePathData.defaultMaximumCommands
  ) throws {
    let maximumCommands = min(maximumCommands, Self.defaultMaximumCommands)
    guard maximumCommands > 0 else {
      throw InlineLayoutError.svgPathLimitExceeded(actual: commands.count, limit: maximumCommands)
    }
    guard !commands.isEmpty else { throw InlineLayoutError.emptySVGPath }
    guard commands.count <= maximumCommands else {
      throw InlineLayoutError.svgPathLimitExceeded(actual: commands.count, limit: maximumCommands)
    }
    guard case .move = commands[0] else {
      throw InlineLayoutError.invalidSVGPath(
        "path must begin with move and contain a drawable command")
    }
    var drawable = false
    var current: InlinePathPoint?
    var subpathStart: InlinePathPoint?
    for command in commands {
      switch command {
      case .move(let point):
        current = point
        subpathStart = point
      case .line(let point):
        if let current, current != point { drawable = true }
        current = point
      case .quadratic(let control, let point):
        if let current, current != control || control != point { drawable = true }
        current = point
      case .cubic(let control1, let control2, let point):
        if let current, current != control1 || control1 != control2 || control2 != point {
          drawable = true
        }
        current = point
      case .close:
        if let current, let subpathStart, current != subpathStart { drawable = true }
        current = subpathStart
      }
    }
    guard drawable else { throw InlineLayoutError.emptySVGPath }
    let cachedBounds = Self.computeBounds(for: commands)
    self.commands = commands
    self.cachedBounds = cachedBounds
  }
}

/// A validated asset payload suitable for registration by any renderer.
/// Winding rule used when a coverage path is painted as a fill.
public enum InlineSVGFillRule: String, Codable, Equatable, Hashable, Sendable {
  case nonZero
  case evenOdd
}

/// Line cap used by stroked coverage and reveal masks.
public enum InlineSVGLineCap: String, Codable, Equatable, Hashable, Sendable {
  case butt
  case round
  case square
}

/// Line join used by stroked coverage and reveal masks.
public enum InlineSVGLineJoin: String, Codable, Equatable, Hashable, Sendable {
  case miter
  case round
  case bevel
}

/// Renderer-neutral stroke parameters. The values are validated before they
/// can cross into an adapter, so Core Graphics and SwiftUI never need to
/// decide what malformed geometry means.
public struct InlineSVGStrokeStyle: Codable, Equatable, Hashable, Sendable {
  public let width: Double
  public let cap: InlineSVGLineCap
  public let join: InlineSVGLineJoin
  public let miterLimit: Double

  public init(
    width: Double,
    cap: InlineSVGLineCap = .butt,
    join: InlineSVGLineJoin = .miter,
    miterLimit: Double = 4
  ) throws {
    guard width.isFinite, width > 0 else {
      throw InlineLayoutError.invalidMetric(name: "SVG stroke width", value: width)
    }
    guard miterLimit.isFinite, miterLimit > 0 else {
      throw InlineLayoutError.invalidMetric(name: "SVG miter limit", value: miterLimit)
    }
    self.width = width
    self.cap = cap
    self.join = join
    self.miterLimit = miterLimit
  }

  package init(
    validatedWidth width: Double,
    cap: InlineSVGLineCap,
    join: InlineSVGLineJoin,
    miterLimit: Double
  ) {
    precondition(width.isFinite && width > 0 && miterLimit.isFinite && miterLimit > 0)
    self.width = width
    self.cap = cap
    self.join = join
    self.miterLimit = miterLimit
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      width: values.decode(Double.self, forKey: .width),
      cap: values.decode(InlineSVGLineCap.self, forKey: .cap),
      join: values.decode(InlineSVGLineJoin.self, forKey: .join),
      miterLimit: values.decode(Double.self, forKey: .miterLimit)
    )
  }

  private enum CodingKeys: String, CodingKey { case width, cap, join, miterLimit }
}

/// The paint semantics of the final visible coverage geometry. The
/// trajectory is always separate and never changes these semantics.
public enum InlineSVGCoveragePaint: Codable, Equatable, Hashable, Sendable {
  case fill(InlineSVGFillRule)
  case stroke(InlineSVGStrokeStyle)
}

/// A validated asset payload suitable for registration by any renderer.
/// `coveragePath` is the final visible geometry; `trajectoryPath` is only the
/// ordered source for timing and the partial reveal mask.
public struct InlineSVGAsset: Codable, Equatable, Hashable, Sendable {
  public let id: InlineAssetID
  public let version: Int
  public let metrics: InlineMetrics
  /// Shared source coordinate system (the SVG viewBox) for both paths.
  /// Coverage and trajectory may have different extents but are never
  /// independently rescaled into the destination rectangle.
  public let coordinateBounds: InlinePathBounds
  public let coveragePath: InlinePathData
  public let coveragePaint: InlineSVGCoveragePaint
  public let trajectoryPath: InlinePathData
  public let trajectoryStyle: InlineSVGStrokeStyle
  public let accessibilityLabel: String?

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(InlineAssetID.self, forKey: .id),
      version: values.decode(Int.self, forKey: .version),
      metrics: values.decode(InlineMetrics.self, forKey: .metrics),
      coordinateBounds: values.decode(InlinePathBounds.self, forKey: .coordinateBounds),
      coveragePath: values.decode(InlinePathData.self, forKey: .coveragePath),
      coveragePaint: values.decode(InlineSVGCoveragePaint.self, forKey: .coveragePaint),
      trajectoryPath: values.decode(InlinePathData.self, forKey: .trajectoryPath),
      trajectoryStyle: values.decode(InlineSVGStrokeStyle.self, forKey: .trajectoryStyle),
      accessibilityLabel: values.decodeIfPresent(String.self, forKey: .accessibilityLabel)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id, version, metrics, coordinateBounds, coveragePath, coveragePaint, trajectoryPath,
      trajectoryStyle, accessibilityLabel
  }

  public init(
    id: InlineAssetID,
    version: Int = 1,
    metrics: InlineMetrics,
    coordinateBounds: InlinePathBounds,
    coveragePath: InlinePathData,
    coveragePaint: InlineSVGCoveragePaint,
    trajectoryPath: InlinePathData,
    trajectoryStyle: InlineSVGStrokeStyle,
    accessibilityLabel: String? = nil
  ) throws {
    guard version >= 0 else {
      throw InlineLayoutError.invalidMetric(name: "assetVersion", value: Double(version))
    }
    func contains(_ pathBounds: InlinePathBounds) -> Bool {
      pathBounds.minX >= coordinateBounds.minX
        && pathBounds.minY >= coordinateBounds.minY
        && pathBounds.maxX <= coordinateBounds.maxX
        && pathBounds.maxY <= coordinateBounds.maxY
    }
    guard contains(coveragePath.bounds), contains(trajectoryPath.bounds) else {
      throw InlineLayoutError.invalidSVGPath("path is outside coordinate bounds")
    }
    self.id = id
    self.version = version
    self.metrics = metrics
    self.coordinateBounds = coordinateBounds
    self.coveragePath = coveragePath
    self.coveragePaint = coveragePaint
    self.trajectoryPath = trajectoryPath
    self.trajectoryStyle = trajectoryStyle
    self.accessibilityLabel = accessibilityLabel
  }
}

public enum InlineSVGBridge {
  public static let defaultMaximumCoordinateMagnitude = 1_000_000.0

  /// Parses SVG path `d` data, preserving curves and rejecting unsupported syntax.
  public static func parsePath(
    _ source: String,
    maximumCommands: Int = InlinePathData.defaultMaximumCommands,
    maximumCoordinateMagnitude: Double = defaultMaximumCoordinateMagnitude
  ) throws -> InlinePathData {
    let maximumCommands = min(maximumCommands, InlinePathData.defaultMaximumCommands)
    guard maximumCommands > 0,
      maximumCoordinateMagnitude.isFinite, maximumCoordinateMagnitude > 0
    else {
      throw InlineLayoutError.svgPathLimitExceeded(actual: 0, limit: maximumCommands)
    }
    let scanner = Scanner(string: source)
    scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\t\n\r")
    var commands: [InlinePathCommand] = []
    var current = InlinePathPoint.unchecked(x: 0, y: 0)
    var start = current
    var command: Character?
    var expectsMove = false
    var hasOpenSubpath = false
    var drawable = false
    var subpathDrawable = false
    var lastCubicControl: InlinePathPoint?
    var lastQuadraticControl: InlinePathPoint?
    func number() throws -> Double {
      guard let n = scanner.scanDouble(), n.isFinite,
        abs(n) <= maximumCoordinateMagnitude
      else {
        throw InlineLayoutError.invalidSVGPath("expected finite number")
      }
      return n
    }
    func point(_ relative: Bool) throws -> InlinePathPoint {
      let x = try number()
      let y = try number()
      return try InlinePathPoint(x: relative ? current.x + x : x, y: relative ? current.y + y : y)
    }
    func arcFlag() throws -> Double {
      if scanner.scanString("0") != nil { return 0 }
      if scanner.scanString("1") != nil { return 1 }
      throw InlineLayoutError.invalidSVGPath("arc flags must be 0 or 1")
    }
    func approximateArc(
      from start: InlinePathPoint, to end: InlinePathPoint, radiusX: Double, radiusY: Double,
      rotation: Double, largeArc: Bool, sweep: Bool
    ) throws -> [InlinePathCommand] {
      guard radiusX.isFinite, radiusY.isFinite, rotation.isFinite else {
        throw InlineLayoutError.nonFiniteSVGPath
      }
      if start == end { return [] }
      let rx0 = abs(radiusX)
      let ry0 = abs(radiusY)
      if rx0 == 0 || ry0 == 0 { return [.line(end)] }
      let phi = rotation.truncatingRemainder(dividingBy: 360) * .pi / 180
      let cosPhi = cos(phi)
      let sinPhi = sin(phi)
      let dx = (start.x - end.x) / 2
      let dy = (start.y - end.y) / 2
      let xPrime = cosPhi * dx + sinPhi * dy
      let yPrime = -sinPhi * dx + cosPhi * dy
      var rx = rx0
      var ry = ry0
      let lambda = xPrime * xPrime / (rx * rx) + yPrime * yPrime / (ry * ry)
      guard lambda.isFinite else { throw InlineLayoutError.nonFiniteSVGPath }
      if lambda > 1 {
        let scale = sqrt(lambda)
        rx *= scale
        ry *= scale
      }
      let rx2 = rx * rx
      let ry2 = ry * ry
      let numerator = max(0, (rx2 * ry2 - rx2 * yPrime * yPrime - ry2 * xPrime * xPrime))
      let denominator = rx2 * yPrime * yPrime + ry2 * xPrime * xPrime
      guard rx.isFinite, ry.isFinite, rx2.isFinite, ry2.isFinite,
        numerator.isFinite, denominator.isFinite, denominator > 0
      else { throw InlineLayoutError.nonFiniteSVGPath }
      let factor = (largeArc == sweep ? -1.0 : 1.0) * sqrt(numerator / denominator)
      let cxPrime = factor * (rx * yPrime / ry)
      let cyPrime = factor * (-ry * xPrime / rx)
      let cx = cosPhi * cxPrime - sinPhi * cyPrime + (start.x + end.x) / 2
      let cy = sinPhi * cxPrime + cosPhi * cyPrime + (start.y + end.y) / 2
      func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        atan2(ux * vy - uy * vx, ux * vx + uy * vy)
      }
      let ux = (xPrime - cxPrime) / rx
      let uy = (yPrime - cyPrime) / ry
      let vx = (-xPrime - cxPrime) / rx
      let vy = (-yPrime - cyPrime) / ry
      var delta = angle(ux, uy, vx, vy)
      if !sweep && delta > 0 { delta -= 2 * .pi }
      if sweep && delta < 0 { delta += 2 * .pi }
      guard delta.isFinite else { throw InlineLayoutError.nonFiniteSVGPath }
      let count = max(1, Int(ceil(abs(delta) / (.pi / 2))))
      let step = delta / Double(count)
      var result: [InlinePathCommand] = []
      var theta = 0.0
      for index in 0..<count {
        let next = theta + step
        let alpha = 4.0 / 3.0 * tan((next - theta) / 4.0)
        func ellipsePoint(_ t: Double) -> InlinePathPoint {
          InlinePathPoint.unchecked(
            x: cx + cosPhi * rx * cos(t) - sinPhi * ry * sin(t),
            y: cy + sinPhi * rx * cos(t) + cosPhi * ry * sin(t)
          )
        }
        let p0 = ellipsePoint(theta)
        let p3 = index == count - 1 ? end : ellipsePoint(next)
        let c1 = InlinePathPoint.unchecked(
          x: p0.x + alpha * (-cosPhi * rx * sin(theta) - sinPhi * ry * cos(theta)),
          y: p0.y + alpha * (-sinPhi * rx * sin(theta) + cosPhi * ry * cos(theta))
        )
        let c2 = InlinePathPoint.unchecked(
          x: p3.x - alpha * (-cosPhi * rx * sin(next) - sinPhi * ry * cos(next)),
          y: p3.y - alpha * (-sinPhi * rx * sin(next) + cosPhi * ry * cos(next))
        )
        guard [p0, c1, c2, p3].allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
          throw InlineLayoutError.nonFiniteSVGPath
        }
        result.append(.cubic(control1: c1, control2: c2, to: p3))
        theta = next
      }
      return result
    }
    while !scanner.isAtEnd {
      for candidate in "MmLlHhVvCcQqSsTtZzAa" {
        if scanner.scanString(String(candidate)) != nil {
          command = candidate
          expectsMove = candidate == "M" || candidate == "m"
          break
        }
      }
      guard let c = command else { throw InlineLayoutError.invalidSVGPath("missing command") }
      let relative = c.isLowercase
      let upper = Character(c.uppercased())
      if upper != "M" && !hasOpenSubpath {
        throw InlineLayoutError.invalidSVGPath("path command must follow a move")
      }
      if upper == "Z" {
        guard hasOpenSubpath else {
          throw InlineLayoutError.invalidSVGPath("close command has no open subpath")
        }
        commands.append(.close)
        current = start
        command = nil
        hasOpenSubpath = false
        lastCubicControl = nil
        lastQuadraticControl = nil
        continue
      }
      let p: InlinePathPoint
      switch upper {
      case "M", "L":
        p = try point(relative)
        if upper == "M" && expectsMove {
          if hasOpenSubpath && !subpathDrawable {
            throw InlineLayoutError.emptySVGPath
          }
          commands.append(.move(p))
          start = p
          expectsMove = false
          command = relative ? "l" : "L"
          hasOpenSubpath = true
          subpathDrawable = false
          lastCubicControl = nil
          lastQuadraticControl = nil
        } else {
          commands.append(.line(p))
          subpathDrawable = subpathDrawable || p != current
          drawable = drawable || p != current
          lastCubicControl = nil
          lastQuadraticControl = nil
        }
        current = p
      case "H":
        let x = try number()
        p = try InlinePathPoint(x: relative ? current.x + x : x, y: current.y)
        commands.append(.line(p))
        subpathDrawable = subpathDrawable || p != current
        drawable = drawable || p != current
        lastCubicControl = nil
        lastQuadraticControl = nil
        current = p
        drawable = true
      case "V":
        let y = try number()
        p = try InlinePathPoint(x: current.x, y: relative ? current.y + y : y)
        commands.append(.line(p))
        subpathDrawable = subpathDrawable || p != current
        drawable = drawable || p != current
        lastCubicControl = nil
        lastQuadraticControl = nil
        current = p
        drawable = true
      case "Q":
        let control = try point(relative)
        let end = try point(relative)
        commands.append(.quadratic(control: control, to: end))
        subpathDrawable = subpathDrawable || control != current || end != current
        drawable = drawable || control != current || end != current
        lastCubicControl = nil
        lastQuadraticControl = control
        current = end
      case "C":
        let c1 = try point(relative)
        let c2 = try point(relative)
        let end = try point(relative)
        commands.append(.cubic(control1: c1, control2: c2, to: end))
        subpathDrawable = subpathDrawable || c1 != current || c2 != current || end != current
        drawable = drawable || c1 != current || c2 != current || end != current
        lastCubicControl = c2
        lastQuadraticControl = nil
        current = end
      case "S":
        let c1 =
          lastCubicControl.map {
            InlinePathPoint.unchecked(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
          } ?? current
        let c2 = try point(relative)
        let end = try point(relative)
        commands.append(.cubic(control1: c1, control2: c2, to: end))
        subpathDrawable = subpathDrawable || c1 != current || c2 != current || end != current
        drawable = drawable || c1 != current || c2 != current || end != current
        lastCubicControl = c2
        lastQuadraticControl = nil
        current = end
      case "T":
        let control =
          lastQuadraticControl.map {
            InlinePathPoint.unchecked(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
          } ?? current
        let end = try point(relative)
        commands.append(.quadratic(control: control, to: end))
        subpathDrawable = subpathDrawable || control != current || end != current
        drawable = drawable || control != current || end != current
        lastCubicControl = nil
        lastQuadraticControl = control
        current = end
      case "A":
        let radiusX = try number()
        let radiusY = try number()
        let rotation = try number()
        let largeArcValue = try arcFlag()
        let sweepValue = try arcFlag()
        let end = try point(relative)
        let arc = try approximateArc(
          from: current, to: end, radiusX: radiusX, radiusY: radiusY,
          rotation: rotation, largeArc: largeArcValue == 1, sweep: sweepValue == 1
        )
        for cubic in arc {
          commands.append(cubic)
          if commands.count > maximumCommands {
            throw InlineLayoutError.svgPathLimitExceeded(
              actual: commands.count, limit: maximumCommands)
          }
        }
        if !arc.isEmpty || end != current {
          subpathDrawable = true
          drawable = true
        }
        lastCubicControl = nil
        lastQuadraticControl = nil
        current = end
      default: throw InlineLayoutError.invalidSVGPath("unsupported command \(c)")
      }
      if commands.count > maximumCommands {
        throw InlineLayoutError.svgPathLimitExceeded(actual: commands.count, limit: maximumCommands)
      }
    }
    guard drawable, !hasOpenSubpath || subpathDrawable else {
      throw InlineLayoutError.emptySVGPath
    }
    return try InlinePathData(commands: commands, maximumCommands: maximumCommands)
  }
}

extension InlinePathPoint {
  init(uncheckedX x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  static func unchecked(x: Double, y: Double) -> Self {
    .init(uncheckedX: x, y: y)
  }
}
