import LiveTextLayout
import SwiftUI

/// Semantic companion for both positioned SwiftUI views and Canvas output.
public struct InlineAccessibilityRepresentation: View {
  private let prepared: PreparedInlineDocument
  private let assetLabels: [InlineAssetKey: String]
  private let units: [InlineTextUnitAccessibilityElement]
  private let onTextUnitActivation: InlineTextUnitActivationHandler?

  public init(
    prepared: PreparedInlineDocument,
    registry: InlineAssetRegistry = .empty,
    resolvedAssetLabels: [InlineAssetKey: String] = [:],
    onTextUnitActivation: InlineTextUnitActivationHandler? = nil
  ) {
    self.prepared = prepared
    self.assetLabels = Self.makeAssetLabels(
      registry: registry, resolvedAssetLabels: resolvedAssetLabels)
    self.units = []
    self.onTextUnitActivation = onTextUnitActivation
  }

  /// Throwing constructor for hosts that want synthetic word-level
  /// accessibility. The hit index and optional selection are validated before
  /// the view is created; stale input is returned as a typed error rather than
  /// trapping while SwiftUI builds the view.
  public init(
    validating prepared: PreparedInlineDocument,
    registry: InlineAssetRegistry = .empty,
    resolvedAssetLabels: [InlineAssetKey: String] = [:],
    hitIndex: InlineHitTestIndex,
    selection: InlineSelectionKey? = nil,
    onTextUnitActivation: InlineTextUnitActivationHandler? = nil
  ) throws {
    self.prepared = prepared
    self.assetLabels = Self.makeAssetLabels(
      registry: registry, resolvedAssetLabels: resolvedAssetLabels)
    self.units = try InlineTextUnitAccessibilitySemantics(
      prepared: prepared, hitIndex: hitIndex, selection: selection).elements
    self.onTextUnitActivation = onTextUnitActivation
  }

  internal init(
    prepared: PreparedInlineDocument,
    assetLabels: [InlineAssetKey: String],
    onTextUnitActivation: InlineTextUnitActivationHandler? = nil
  ) {
    self.prepared = prepared
    self.assetLabels = assetLabels
    self.units = []
    self.onTextUnitActivation = onTextUnitActivation
  }

  internal func resolvedAccessibilityLabel(
    vector: InlineVectorAtom, fallback: String
  ) -> String {
    accessibilityLabel(for: vector, fallback: fallback)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(prepared.document.atoms.enumerated()), id: \.offset) { _, atom in
        switch atom {
        case .text(let text):
          let atomUnits = units.filter { $0.atomID == text.id }
          textView(label: text.text, units: atomUnits)
        case .vector(let vector):
          Text(accessibilityLabel(for: vector, fallback: vector.id))
        case .image(let image):
          if image.isDecorative {
            EmptyView()
          } else {
            Text(image.accessibilityLabel ?? image.id)
          }
        }
      }
    }
    // Word elements are synthetic logical nodes; combining children would
    // collapse wrapped fragments back into one atom-level element.
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func textView(
    label: String,
    units: [InlineTextUnitAccessibilityElement]
  ) -> some View {
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

  private func accessibilityLabel(for vector: InlineVectorAtom, fallback: String) -> String {
    vector.accessibilityLabel
      ?? assetLabels[InlineAssetKey(id: vector.assetID, version: vector.assetVersion)]
      ?? fallback
  }

  private static func makeAssetLabels(
    registry: InlineAssetRegistry,
    resolvedAssetLabels: [InlineAssetKey: String]
  ) -> [InlineAssetKey: String] {
    var labels: [InlineAssetKey: String] = [:]
    labels.reserveCapacity(registry.records.count + resolvedAssetLabels.count)
    for record in registry.records {
      guard let label = record.accessibilityLabel else { continue }
      labels[InlineAssetKey(id: record.id, version: record.version)] = label
    }
    for (key, label) in resolvedAssetLabels where labels[key] == nil {
      labels[key] = label
    }
    return labels
  }
}
