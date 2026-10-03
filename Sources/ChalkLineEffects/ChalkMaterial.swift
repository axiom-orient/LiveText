import Foundation
import LiveTextChalkRendering
import LiveTextEffects

/// Standalone chalk facade over the same `WritingChalkConfiguration` used by LiveText.
///
/// `textureStyle` is the standalone-facing name for the canonical topology. The authoritative
/// value is `configuration.style`; the initializer normalizes the two immediately.
public struct ChalkMaterial: Codable, Equatable, Hashable, Sendable {
  public var textureStyle: WritingChalkStyle { configuration.style }
  public let configuration: WritingChalkConfiguration

  public init(
    textureStyle: WritingChalkStyle,
    configuration: WritingChalkConfiguration = .default
  ) {
    self.configuration = configuration.withStyle(textureStyle)
  }

  private enum CodingKeys: String, CodingKey {
    case textureStyle, configuration
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let style = try values.decode(WritingChalkStyle.self, forKey: .textureStyle)
    let configuration = try values.decode(WritingChalkConfiguration.self, forKey: .configuration)
    self.init(textureStyle: style, configuration: configuration)
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(textureStyle, forKey: .textureStyle)
    try values.encode(configuration, forKey: .configuration)
  }

  public static let fineLine = ChalkMaterial(
    textureStyle: .fineLine,
    configuration: .fineLine
  )
  public static let dryBrush = ChalkMaterial(
    textureStyle: .dryBrush,
    configuration: .dryBrush
  )
  public static let powderFill = ChalkMaterial(
    textureStyle: .powderFill,
    configuration: .powderFill
  )
  public static let diagonalHatch = ChalkMaterial(
    textureStyle: .diagonalHatch,
    configuration: .diagonalHatch
  )
  public static let crossHatch = ChalkMaterial(
    textureStyle: .crossHatch,
    configuration: .crossHatch
  )
  public static let smudged = ChalkMaterial(
    textureStyle: .smudged,
    configuration: .smudged
  )
  public static let `default` = fineLine

  package var renderMaterial: ChalkRenderMaterial {
    .liveText(configuration)
  }
}
