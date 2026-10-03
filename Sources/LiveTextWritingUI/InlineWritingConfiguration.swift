import ChalkLineEffects
import Foundation
import LiveTextEffects

/// Configuration for the one writing effect applied by `LiveTextWritingRenderer`.
///
/// Common presentation data lives at this level. The `effect` value carries
/// exactly one active renderer-native payload, so UI and renderer validation
/// cannot drift.
public struct InlineWritingConfiguration: Codable, Equatable, Hashable, Sendable {
  public typealias BrushConfiguration = WritingBrushConfiguration
  public typealias PenConfiguration = WritingPenConfiguration
  public typealias InkConfiguration = WritingInkConfiguration
  public typealias MarkerConfiguration = WritingMarkerConfiguration
  public typealias KnockoutConfiguration = WritingKnockoutConfiguration
  public typealias ColoredPencilConfiguration = LiveTextEffects.ColoredPencilConfiguration

  public let color: ChalkColor?
  /// The canonical renderer material. Writing configurations reject `.none`
  /// because a writing renderer always has exactly one ordinary material.
  public let effect: InlineRendererMaterial

  public init(effect: InlineRendererMaterial = .chalk(.default), color: ChalkColor? = nil) {
    precondition(effect != .none, "writing configuration requires an ordinary material")
    self.effect = effect
    self.color = color
  }

  private enum CodingKeys: String, CodingKey { case color, effect }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let effect = try values.decode(InlineRendererMaterial.self, forKey: .effect)
    guard effect != .none else {
      throw DecodingError.dataCorruptedError(
        forKey: .effect, in: values,
        debugDescription: "writing configuration requires an ordinary material")
    }
    self.effect = effect
    self.color = try values.decodeIfPresent(ChalkColor.self, forKey: .color)
  }

  public static let chalk = InlineWritingConfiguration(
    effect: .chalk(.default), color: .warmWhite)
  public static let brush = InlineWritingConfiguration(
    effect: .brush(.default), color: .black)
  public static let pen = InlineWritingConfiguration(
    effect: .pen(.default), color: .chalkBlue)
  public static let ink = InlineWritingConfiguration(
    effect: .ink(.default), color: .black)
  public static let marker = InlineWritingConfiguration(
    effect: .marker(.default), color: .chalkPink)
  public static let knockout = InlineWritingConfiguration(
    effect: .knockout(.default), color: nil)
  /// Uses the surrounding renderer's foreground color. The shared `color`
  /// field is intentionally ignored for this effect so it follows current
  /// color in both renderer adapters.
  public static let coloredPencil = InlineWritingConfiguration(
    effect: .coloredPencil(.default), color: nil)
  public static let `default` = InlineWritingConfiguration.chalk
}

/// Convenience export for callers that prefer a top-level configuration.
public typealias ColoredPencilConfiguration = LiveTextEffects.ColoredPencilConfiguration
