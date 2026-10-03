import Foundation

public enum LiveTextSVGFillRule: String, Codable, Equatable, Hashable, Sendable {
  case nonZero
  case evenOdd
}

/// The visible paint of one imported document. The renderer owns the final
/// pigment; the importer only accepts opaque black source paint so no source
/// color is silently lost.
public enum LiveTextSVGCoveragePaint: Codable, Equatable, Sendable {
  case fill(LiveTextSVGFillRule)
  case stroke(LiveTextSVGStrokeStyle)
}

/// A bounded, colour-preserving SVG result for static artwork.
///
/// Live text keeps its historical single-pigment contract. Sticker artwork
/// uses this separate representation so a pack can contain a few deliberate
/// colour layers without changing the meaning of the live-text importer.
public enum LiveTextSVGArtworkPaint: Codable, Equatable, Sendable {
  case fill(color: LiveTextSVGColor, rule: LiveTextSVGFillRule)
  case stroke(style: LiveTextSVGStrokeStyle)
  case fillAndStroke(
    color: LiveTextSVGColor,
    rule: LiveTextSVGFillRule,
    stroke: LiveTextSVGStrokeStyle
  )
}

public struct LiveTextSVGArtworkPath: Codable, Equatable, Sendable {
  public let commands: [LiveTextSVGCommand]
  public let paint: LiveTextSVGArtworkPaint

  public init(commands: [LiveTextSVGCommand], paint: LiveTextSVGArtworkPaint) throws {
    guard !commands.isEmpty, case .move = commands[0], commands.dropFirst().contains(where: {
      switch $0 {
      case .move: return false
      case .line, .quadratic, .cubic, .close: return true
      }
    }) else {
      throw LiveTextSVGImportError.invalidPathData("artwork path is empty")
    }
    self.commands = commands
    self.paint = paint
  }
}

public struct LiveTextSVGArtworkDocument: Codable, Equatable, Sendable {
  public static let maximumOutputCommands = LiveTextSVGImportedDocument.maximumOutputCommands

  public let size: LiveTextSVGSize
  public let coordinateBounds: LiveTextSVGRect
  public let paths: [LiveTextSVGArtworkPath]

  public init(
    size: LiveTextSVGSize,
    coordinateBounds: LiveTextSVGRect,
    paths: [LiveTextSVGArtworkPath]
  ) throws {
    guard coordinateBounds.minX == 0, coordinateBounds.minY == 0,
      coordinateBounds.maxX == size.width, coordinateBounds.maxY == size.height
    else {
      throw LiveTextSVGImportError.invalidDocument("coordinate bounds must match the viewport")
    }
    guard !paths.isEmpty else {
      throw LiveTextSVGImportError.invalidPathData("artwork contains no visible path")
    }
    let commandCount = paths.reduce(0) { $0 + $1.commands.count }
    guard commandCount <= Self.maximumOutputCommands else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "artwork output commands", actual: commandCount,
        limit: Self.maximumOutputCommands
      )
    }
    for path in paths {
      for command in path.commands {
        func contained(_ point: LiveTextSVGPoint) -> Bool {
          let epsilon = 1e-9
          return point.x >= -epsilon && point.y >= -epsilon
            && point.x <= size.width + epsilon && point.y <= size.height + epsilon
        }
        let valid: Bool
        switch command {
        case .move(let point), .line(let point): valid = contained(point)
        case .quadratic(let control, let point): valid = contained(control) && contained(point)
        case .cubic(let control1, let control2, let point):
          valid = contained(control1) && contained(control2) && contained(point)
        case .close: valid = true
        }
        guard valid else {
          throw LiveTextSVGImportError.unsupportedSemantic("artwork path extends outside the viewport")
        }
      }
    }
    self.size = size
    self.coordinateBounds = coordinateBounds
    self.paths = paths
  }

  private enum CodingKeys: String, CodingKey { case size, coordinateBounds, paths }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      size: values.decode(LiveTextSVGSize.self, forKey: .size),
      coordinateBounds: values.decode(LiveTextSVGRect.self, forKey: .coordinateBounds),
      paths: values.decode([LiveTextSVGArtworkPath].self, forKey: .paths)
    )
  }
}

/// Canonical renderer-neutral SVG result. One source document produces one
/// coverage path and one ordered writing trajectory in the same post-viewBox
/// coordinate system.
public struct LiveTextSVGImportedDocument: Codable, Equatable, Sendable {
  /// Matches the canonical InlinePathData command bound without importing
  /// the layout module into this importer target.
  public static let maximumOutputCommands = 16_384

  public let size: LiveTextSVGSize
  public let coordinateBounds: LiveTextSVGRect
  public let coverageCommands: [LiveTextSVGCommand]
  public let coveragePaint: LiveTextSVGCoveragePaint
  public let trajectoryCommands: [LiveTextSVGCommand]
  public let trajectoryStyle: LiveTextSVGStrokeStyle

  private enum CodingKeys: String, CodingKey {
    case size, coordinateBounds, coverageCommands, coveragePaint, trajectoryCommands,
      trajectoryStyle
  }

  public init(
    size: LiveTextSVGSize,
    coordinateBounds: LiveTextSVGRect,
    coverageCommands: [LiveTextSVGCommand],
    coveragePaint: LiveTextSVGCoveragePaint,
    trajectoryCommands: [LiveTextSVGCommand],
    trajectoryStyle: LiveTextSVGStrokeStyle
  ) throws {
    guard coordinateBounds.minX == 0, coordinateBounds.minY == 0,
      coordinateBounds.maxX == size.width, coordinateBounds.maxY == size.height
    else {
      throw LiveTextSVGImportError.invalidDocument("coordinate bounds must match the viewport")
    }
    guard coverageCommands.count <= Self.maximumOutputCommands else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "coverage output commands",
        actual: coverageCommands.count,
        limit: Self.maximumOutputCommands
      )
    }
    guard trajectoryCommands.count <= Self.maximumOutputCommands else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "trajectory output commands",
        actual: trajectoryCommands.count,
        limit: Self.maximumOutputCommands
      )
    }
    try Self.validatePath(coverageCommands, name: "coverage")
    try Self.validatePath(trajectoryCommands, name: "trajectory")
    func contained(_ command: LiveTextSVGCommand) -> Bool {
      let epsilon = 1e-9
      func point(_ value: LiveTextSVGPoint) -> Bool {
        value.x >= -epsilon && value.y >= -epsilon
          && value.x <= size.width + epsilon && value.y <= size.height + epsilon
      }
      switch command {
      case .move(let value), .line(let value): return point(value)
      case .quadratic(let control, let value): return point(control) && point(value)
      case .cubic(let control1, let control2, let value):
        return point(control1) && point(control2) && point(value)
      case .close: return true
      }
    }
    guard coverageCommands.allSatisfy(contained), trajectoryCommands.allSatisfy(contained) else {
      throw LiveTextSVGImportError.unsupportedSemantic("path extends outside the viewport")
    }
    self.size = size
    self.coordinateBounds = coordinateBounds
    self.coverageCommands = coverageCommands
    self.coveragePaint = coveragePaint
    self.trajectoryCommands = trajectoryCommands
    self.trajectoryStyle = trajectoryStyle
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      size: values.decode(LiveTextSVGSize.self, forKey: .size),
      coordinateBounds: values.decode(LiveTextSVGRect.self, forKey: .coordinateBounds),
      coverageCommands: values.decode([LiveTextSVGCommand].self, forKey: .coverageCommands),
      coveragePaint: values.decode(LiveTextSVGCoveragePaint.self, forKey: .coveragePaint),
      trajectoryCommands: values.decode([LiveTextSVGCommand].self, forKey: .trajectoryCommands),
      trajectoryStyle: values.decode(LiveTextSVGStrokeStyle.self, forKey: .trajectoryStyle)
    )
  }

  private static func validatePath(_ commands: [LiveTextSVGCommand], name: String) throws {
    guard !commands.isEmpty, case .move = commands[0] else {
      throw LiveTextSVGImportError.invalidPathData("\(name) path must begin with move")
    }
    var drawable = false
    for command in commands.dropFirst() {
      switch command {
      case .move:
        continue
      case .line, .quadratic, .cubic, .close:
        drawable = true
      }
    }
    guard drawable else { throw LiveTextSVGImportError.invalidPathData("\(name) path is empty") }
  }
}
