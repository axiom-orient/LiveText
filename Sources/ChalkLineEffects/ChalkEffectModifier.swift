import LiveTextChalkRendering
import LiveTextEffects
import SwiftUI

extension ChalkColor {
  var swiftUIColor: Color {
    Color(red: red, green: green, blue: blue, opacity: alpha)
  }
}

/// Configuration-based entry point into the same six-style chalk engine as
/// `ChalkMaterialEffectModifier`; there is one rendering authority.
public struct ChalkEffectModifier: ViewModifier {
  public let configuration: WritingChalkConfiguration
  public let color: ChalkColor?

  public init(
    configuration: WritingChalkConfiguration = .default,
    color: ChalkColor? = nil
  ) {
    self.configuration = configuration
    self.color = color
  }

  public func body(content: Content) -> some View {
    content.modifier(
      ChalkRenderSurfaceModifier(
        material: .liveText(configuration),
        color: color.map(\.swiftUIColor)
      )
    )
  }
}

/// Standalone facade over the canonical LiveText chalk configuration.
public struct ChalkMaterialEffectModifier: ViewModifier {
  public let material: ChalkMaterial
  public let color: ChalkColor?

  public init(material: ChalkMaterial, color: ChalkColor? = nil) {
    self.material = material
    self.color = color
  }

  public func body(content: Content) -> some View {
    content.modifier(
      ChalkRenderSurfaceModifier(
        material: material.renderMaterial,
        color: color.map(\.swiftUIColor)
      )
    )
  }
}

extension View {
  /// Applies the chalk style contained in `WritingChalkConfiguration` without changing layout.
  public func chalkEffect(
    _ configuration: WritingChalkConfiguration = .default,
    color: ChalkColor? = nil
  ) -> some View {
    modifier(ChalkEffectModifier(configuration: configuration, color: color))
  }

  /// Applies the same chalk engine to arbitrary SwiftUI content.
  public func chalkEffect(
    _ material: ChalkMaterial,
    color: ChalkColor? = nil
  ) -> some View {
    modifier(ChalkMaterialEffectModifier(material: material, color: color))
  }
}
