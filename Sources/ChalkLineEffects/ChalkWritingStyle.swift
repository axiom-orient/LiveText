import Foundation
import LiveTextEffects

/// Errors returned by the public ChalkLineEffects preparation and style APIs.
public enum ChalkLineEffectsError: Error, Equatable, LocalizedError, Sendable {
  case invalidConfiguration(field: String, value: Double)
  case invalidColorComponent(field: String, value: Double)
  case invalidProgress(Double)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let field, let value):
      return "Invalid ChalkLineEffects configuration '\(field)': \(value)."
    case .invalidColorComponent(let field, let value):
      return "Invalid chalk color component '\(field)': \(value)."
    case .invalidProgress(let value):
      return "Writing progress must be finite and between 0 and 1: \(value)."
    }
  }
}

/// Controls how semantic stroke paths appear or disappear over time.
public enum ChalkWritingAnimation: String, Codable, CaseIterable, Hashable, Sendable {
  /// Reveals strokes from the first stroke's start to the last stroke's end.
  case write

  /// Removes strokes from the first stroke's start to the last stroke's end.
  case eraseForward

  /// Removes strokes from the last stroke's end back to the first stroke's start.
  case eraseReverse
}

/// Selects constant or deterministic per-glyph/per-stroke motion character.
public enum ChalkWritingMotionStyle: String, Codable, CaseIterable, Hashable, Sendable {
  /// Uses the same minimum-jerk curve for every stroke.
  case uniform

  /// Deterministically varies apparent speed and easing from the style seed.
  case varied
}

/// A platform-independent RGBA color used by the writing renderer.
///
/// Keeping color data in Foundation makes preparation and configuration
/// deterministic. The SwiftUI adapter converts this value to `Color` only at
/// render time.
public struct ChalkColor: Codable, Equatable, Hashable, Sendable {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) throws {
    for (field, value) in [
      ("red", red), ("green", green), ("blue", blue), ("alpha", alpha),
    ] {
      guard value.isFinite, (0...1).contains(value) else {
        throw ChalkLineEffectsError.invalidColorComponent(field: field, value: value)
      }
    }
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

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

  public static let white = ChalkColor(uncheckedRed: 1, green: 1, blue: 1, alpha: 1)
  public static let black = ChalkColor(uncheckedRed: 0, green: 0, blue: 0, alpha: 1)
  public static let warmWhite = ChalkColor(
    uncheckedRed: 0.98, green: 0.96, blue: 0.90, alpha: 1
  )
  public static let chalkYellow = ChalkColor(
    uncheckedRed: 1, green: 0.86, blue: 0.32, alpha: 1
  )
  public static let chalkPink = ChalkColor(
    uncheckedRed: 1, green: 0.48, blue: 0.65, alpha: 1
  )
  public static let chalkBlue = ChalkColor(
    uncheckedRed: 0.42, green: 0.78, blue: 1, alpha: 1
  )
  public static let chalkGreen = ChalkColor(
    uncheckedRed: 0.46, green: 0.88, blue: 0.58, alpha: 1
  )

  private init(uncheckedRed red: Double, green: Double, blue: Double, alpha: Double) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }
}

/// Appearance settings for `ChalkWritingText`.
public struct ChalkWritingStyle: Codable, Equatable, Hashable, Sendable {
  public static let maximumLineWidthMultiplier = 8.0

  public let color: ChalkColor
  public let lineWidthMultiplier: Double
  public let configuration: WritingChalkConfiguration

  public init(
    color: ChalkColor = .white,
    lineWidthMultiplier: Double = 1,
    configuration: WritingChalkConfiguration = .default
  ) throws {
    guard lineWidthMultiplier.isFinite,
      lineWidthMultiplier > 0,
      lineWidthMultiplier <= Self.maximumLineWidthMultiplier
    else {
      throw ChalkLineEffectsError.invalidConfiguration(
        field: "lineWidthMultiplier", value: lineWidthMultiplier
      )
    }
    self.color = color
    self.lineWidthMultiplier = lineWidthMultiplier
    self.configuration = configuration
  }

  private enum CodingKeys: String, CodingKey {
    case color, lineWidthMultiplier, configuration
  }

  private enum DecodingKeys: String, CodingKey {
    case color, lineWidthMultiplier, configuration, edgeColor
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: DecodingKeys.self)
    guard !values.contains(.edgeColor) else {
      throw DecodingError.dataCorruptedError(
        forKey: .edgeColor,
        in: values,
        debugDescription: "edgeColor is no longer supported; use color for the face and edge"
      )
    }
    try self.init(
      color: values.decode(ChalkColor.self, forKey: .color),
      lineWidthMultiplier: values.decode(Double.self, forKey: .lineWidthMultiplier),
      configuration: values.decode(WritingChalkConfiguration.self, forKey: .configuration)
    )
  }

  public static let chalk = ChalkWritingStyle(
    uncheckedColor: .white,
    lineWidthMultiplier: 1,
    configuration: .default
  )

  private init(
    uncheckedColor color: ChalkColor,
    lineWidthMultiplier: Double,
    configuration: WritingChalkConfiguration
  ) {
    self.color = color
    self.lineWidthMultiplier = lineWidthMultiplier
    self.configuration = configuration
  }
}
