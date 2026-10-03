public import LiveTextLayout
import SwiftUI

/// Shared accessibility view used by both static drawing adapters. The
/// projection is built from one hit index, so visual renderer choice cannot
/// change logical word identity, selection value, or activation target.
@MainActor
package struct InlineAppleAccessibilityRepresentation: View {
  private let projection: InlineAccessibilityProjection
  private let atomLabels: [String: String]
  private let onTextUnitActivation: InlineTextUnitActivationHandler?

  public init(
    projection: InlineAccessibilityProjection,
    atomLabels: [String: String] = [:],
    onTextUnitActivation: InlineTextUnitActivationHandler? = nil
  ) {
    self.projection = projection
    self.atomLabels = atomLabels
    self.onTextUnitActivation = onTextUnitActivation
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(projection.atoms.enumerated()), id: \.offset) { _, atom in
        switch atom.kind {
        case .text:
          textView(
            label: atom.label,
            units: projection.units.filter { $0.atomID == atom.atomID })
        case .vector:
          Text(atomLabels[atom.atomID] ?? atom.label ?? atom.atomID)
        case .image:
          if atom.isDecorative {
            EmptyView()
          } else {
            Text(atomLabels[atom.atomID] ?? atom.label ?? atom.atomID)
          }
        }
      }
    }
    // Keep each synthetic logical word independently navigable. Combining
    // children here would collapse wrapped units back into one atom-level
    // accessibility node and discard the hit-index identity.
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func textView(
    label: String?,
    units: [InlineTextUnitAccessibilityElement]
  ) -> some View {
    if let label {
      // Publish the complete atom text as a concrete element. Keeping it
      // separate from the virtual word-child host is required on iOS 26,
      // where accessibilityChildren can suppress the host's implicit Text
      // label. Word targets remain independently navigable, so punctuation
      // and whitespace are not lost when the hit profile excludes them.
      VStack(alignment: .leading, spacing: 0) {
        Text(label)
          .accessibilityLabel(Text(label))
          .accessibilityElement(children: .ignore)
          ForEach(units) { word in
            unitView(word)
          }
      }
      .accessibilityElement(children: .contain)
    } else {
      ForEach(units) { word in
        unitView(word)
      }
    }
  }

  @ViewBuilder
  private func unitView(_ word: InlineTextUnitAccessibilityElement) -> some View {
    if let onTextUnitActivation {
      Text(word.label)
        .accessibilityIdentifier(word.id)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(word.isSelected ? .isSelected : [])
        .accessibilityValue(word.accessibilityValue ?? "")
        .accessibilityAction { onTextUnitActivation(word.hit) }
    } else {
      Text(word.label)
        .accessibilityIdentifier(word.id)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(word.isSelected ? .isSelected : [])
        .accessibilityValue(word.accessibilityValue ?? "")
    }
  }
}
