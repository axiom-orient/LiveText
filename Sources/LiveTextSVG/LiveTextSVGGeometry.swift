import Foundation

/// SVG-only geometry primitives. They deliberately do not import writing or UI modules.
public struct LiveTextSVGPoint: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) throws {
    guard x.isFinite, y.isFinite else {
      throw LiveTextSVGImportError.invalidPathData("point is not finite")
    }
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

public enum LiveTextSVGCommand: Codable, Equatable, Sendable {
  case move(to: LiveTextSVGPoint)
  case line(to: LiveTextSVGPoint)
  case quadratic(control: LiveTextSVGPoint, to: LiveTextSVGPoint)
  case cubic(control1: LiveTextSVGPoint, control2: LiveTextSVGPoint, to: LiveTextSVGPoint)
  case close
}

public enum LiveTextSVGLineCap: String, Codable, Equatable, Hashable, Sendable {
  case butt, round, square
}

public enum LiveTextSVGLineJoin: String, Codable, Equatable, Hashable, Sendable {
  case miter, round, bevel
}

public struct LiveTextSVGColor: Codable, Equatable, Hashable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case red, green, blue, alpha
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      red: values.decode(Double.self, forKey: .red),
      green: values.decode(Double.self, forKey: .green),
      blue: values.decode(Double.self, forKey: .blue),
      alpha: values.decode(Double.self, forKey: .alpha)
    )
  }

  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) throws {
    for value in [red, green, blue, alpha] where !value.isFinite || !(0...1).contains(value) {
      throw LiveTextSVGImportError.invalidColor("component outside 0...1")
    }
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public static let black = LiveTextSVGColor(uncheckedRed: 0, green: 0, blue: 0, alpha: 1)

  private init(uncheckedRed red: Double, green: Double, blue: Double, alpha: Double) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }
}

public struct LiveTextSVGStrokeStyle: Codable, Equatable, Hashable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case color, width, lineCap, lineJoin, miterLimit
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      color: values.decodeIfPresent(LiveTextSVGColor.self, forKey: .color),
      width: values.decode(Double.self, forKey: .width),
      lineCap: values.decode(LiveTextSVGLineCap.self, forKey: .lineCap),
      lineJoin: values.decode(LiveTextSVGLineJoin.self, forKey: .lineJoin),
      miterLimit: values.decode(Double.self, forKey: .miterLimit)
    )
  }

  public let color: LiveTextSVGColor?
  public let width: Double
  public let lineCap: LiveTextSVGLineCap
  public let lineJoin: LiveTextSVGLineJoin
  public let miterLimit: Double

  public init(
    color: LiveTextSVGColor? = nil,
    width: Double = 1,
    lineCap: LiveTextSVGLineCap = .round,
    lineJoin: LiveTextSVGLineJoin = .round,
    miterLimit: Double = 4
  ) throws {
    guard width.isFinite, width > 0 else {
      throw LiveTextSVGImportError.invalidDocument("stroke width must be positive")
    }
    guard miterLimit.isFinite, miterLimit >= 1 else {
      throw LiveTextSVGImportError.invalidDocument("stroke miter limit must be at least 1")
    }
    self.color = color
    self.width = width
    self.lineCap = lineCap
    self.lineJoin = lineJoin
    self.miterLimit = miterLimit
  }

  public static let `default` = try! LiveTextSVGStrokeStyle()
}

public struct LiveTextSVGSize: Codable, Equatable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case width, height
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      width: values.decode(Double.self, forKey: .width),
      height: values.decode(Double.self, forKey: .height)
    )
  }

  public let width: Double
  public let height: Double

  public init(width: Double, height: Double) throws {
    guard width.isFinite, height.isFinite, width > 0, height > 0 else {
      throw LiveTextSVGImportError.invalidDocument("viewport size must be positive")
    }
    self.width = width
    self.height = height
  }
}

public struct LiveTextSVGRect: Codable, Equatable, Sendable {
  public let minX: Double
  public let minY: Double
  public let maxX: Double
  public let maxY: Double

  public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
    self.minX = minX
    self.minY = minY
    self.maxX = maxX
    self.maxY = maxY
  }
}
