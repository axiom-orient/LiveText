import Foundation

/// The semantic role of one inline atom exposed to an accessibility adapter.
public enum InlineAccessibilityElementKind: String, Sendable, Hashable, Codable {
  case text
  case vector
  case image
}

/// Renderer-neutral semantic data. Coordinates and platform accessibility
/// nodes remain adapter concerns; source order and image decoration intent are
/// preserved here so adapters cannot accidentally invent a label.
public struct InlineAccessibilityElement: Sendable, Hashable, Codable {
  public let atomID: String
  public let kind: InlineAccessibilityElementKind
  public let label: String?
  public let isDecorative: Bool

  public init(
    atomID: String,
    kind: InlineAccessibilityElementKind,
    label: String?,
    isDecorative: Bool = false
  ) throws {
    guard !atomID.isEmpty else { throw InlineLayoutError.invalidIdentifier }
    if let label {
      guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw InlineLayoutError.invalidImageAccessibility
      }
    }
    guard !(isDecorative && label != nil) else {
      throw InlineLayoutError.invalidImageAccessibility
    }
    self.atomID = atomID
    self.kind = kind
    self.label = label
    self.isDecorative = isDecorative
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      atomID: values.decode(String.self, forKey: .atomID),
      kind: values.decode(InlineAccessibilityElementKind.self, forKey: .kind),
      label: values.decodeIfPresent(String.self, forKey: .label),
      isDecorative: values.decode(Bool.self, forKey: .isDecorative)
    )
  }

  private enum CodingKeys: String, CodingKey { case atomID, kind, label, isDecorative }
}

/// Source-ordered accessibility semantics for a prepared document.
public struct InlineAccessibilitySemantics: Sendable, Hashable, Codable {
  public let elements: [InlineAccessibilityElement]

  public init(elements: [InlineAccessibilityElement]) throws {
    var identifiers = Set<String>()
    for element in elements {
      guard identifiers.insert(element.atomID).inserted else {
        throw InlineLayoutError.duplicateIdentifier(element.atomID)
      }
    }
    self.elements = elements
  }

  public init(prepared: PreparedInlineDocument) throws {
    var elements: [InlineAccessibilityElement] = []
    elements.reserveCapacity(prepared.atoms.count)
    for atom in prepared.atoms {
      switch atom {
      case .text(let text):
        elements.append(
          try InlineAccessibilityElement(
            atomID: text.atom.id,
            kind: .text,
            label: text.atom.text
          ))
      case .vector(let vector):
        elements.append(
          try InlineAccessibilityElement(
            atomID: vector.atom.id,
            kind: .vector,
            label: vector.atom.accessibilityLabel
          ))
      case .image(let image):
        elements.append(
          try InlineAccessibilityElement(
            atomID: image.atom.id,
            kind: .image,
            label: image.atom.accessibilityLabel,
            isDecorative: image.atom.isDecorative
          ))
      }
    }
    try self.init(elements: elements)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(elements: values.decode(
      [InlineAccessibilityElement].self, forKey: .elements))
  }

  private enum CodingKeys: String, CodingKey { case elements }

  public func element(forAtomID atomID: String) -> InlineAccessibilityElement? {
    elements.first { $0.atomID == atomID }
  }
}

/// One synthetic accessibility element for a logical word. Wrapped visual
/// fragments deliberately share one identity and one representative hit;
/// geometry remains derived from the authoritative hit index rather than being
/// stored in host selection state.
public struct InlineTextUnitAccessibilityElement:
  Sendable, Hashable, Codable, Identifiable
{
  public let hit: InlineTextUnitHit
  public let label: String
  public let isSelected: Bool

  public var atomID: String { hit.atomID }
  public var sourceRange: InlineSourceRange { hit.sourceRange }

  public var id: String {
    "\(hit.atomID):\(hit.unitKind.rawValue):\(hit.customID ?? "-"):\(hit.sourceRange.startUTF16):\(hit.sourceRange.endUTF16)"
  }

  public var accessibilityValue: String? {
    isSelected ? "Selected text unit" : nil
  }

  /// Every synthetic word node has an activation callback surface in the
  /// renderer adapters, so accessibility exposes button semantics even when
  /// the current host has not installed a callback.
  public var isButton: Bool { true }

  public init(hit: InlineTextUnitHit, label: String, isSelected: Bool = false) throws {
    guard !label.isEmpty else { throw InlineLayoutError.invalidRenderPlan }
    self.hit = hit
    self.label = label
    self.isSelected = isSelected
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      hit: values.decode(InlineTextUnitHit.self, forKey: .hit),
      label: values.decode(String.self, forKey: .label),
      isSelected: values.decode(Bool.self, forKey: .isSelected)
    )
  }

  private enum CodingKeys: String, CodingKey { case hit, label, isSelected }
}

/// Hit-index-derived, source-ordered text-unit semantics shared by both drawing
/// adapters. A wrapped unit is deduplicated by atom/source identity.
public struct InlineTextUnitAccessibilitySemantics: Sendable, Hashable, Codable {
  public let elements: [InlineTextUnitAccessibilityElement]

  public init(elements: [InlineTextUnitAccessibilityElement]) throws {
    var identifiers = Set<String>()
    for element in elements {
      guard identifiers.insert(element.id).inserted else {
        throw InlineLayoutError.duplicateIdentifier(element.id)
      }
    }
    self.elements = elements
  }

  public init(
    prepared: PreparedInlineDocument,
    hitIndex: InlineHitTestIndex,
    selection: InlineSelectionKey? = nil
  ) throws {
    guard hitIndex.preparationRevision == prepared.revision else {
      throw InlineSelectionTransitionError(
        operation: "accessibility.textUnits",
        targetID: "",
        preparationRevision: prepared.revision,
        cause: "hit index belongs to a stale preparation revision")
    }
    if let selection {
      guard selection.preparationRevision == prepared.revision,
        selection.hitProfile == hitIndex.profile else {
        throw InlineSelectionTransitionError(
          operation: "accessibility.textUnits",
          targetID: selection.atomID,
          preparationRevision: prepared.revision,
          cause: "selection belongs to a different accessibility revision/profile")
      }
    }

    var textByID: [String: PreparedInlineText] = [:]
    for atom in prepared.atoms {
      if case .text(let text) = atom { textByID[text.atom.id] = text }
    }

    var seen = Set<String>()
    var elements: [InlineTextUnitAccessibilityElement] = []
    for hit in hitIndex.allTextUnitHits {
      let identity = "\(hit.atomID):\(hit.unitKind.rawValue):\(hit.customID ?? "-"):\(hit.sourceRange.startUTF16):\(hit.sourceRange.endUTF16)"
      guard seen.insert(identity).inserted else { continue }
      guard let text = textByID[hit.atomID],
        hit.sourceRange.startUTF16 >= text.sourceRange.startUTF16,
        hit.sourceRange.endUTF16 <= text.sourceRange.endUTF16
      else {
        throw InlineLayoutError.invalidRenderPlan
      }
      let localStart = hit.sourceRange.startUTF16 - text.sourceRange.startUTF16
      let localLength = hit.sourceRange.lengthUTF16
      guard let range = Range(
        NSRange(location: localStart, length: localLength), in: text.atom.text)
      else {
        throw InlineLayoutError.invalidSourceRange
      }
      let label = String(text.atom.text[range])
      let isSelected = selection?.atomID == hit.atomID
        && selection?.unitKind == hit.unitKind
        && selection?.customID == hit.customID
        && selection?.sourceRange == hit.sourceRange
      elements.append(try InlineTextUnitAccessibilityElement(
        hit: hit, label: label, isSelected: isSelected))
    }
    try self.init(elements: elements)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(elements: values.decode(
      [InlineTextUnitAccessibilityElement].self, forKey: .elements))
  }

  private enum CodingKeys: String, CodingKey { case elements }
}

/// Complete immutable accessibility projection consumed by SwiftUI and
/// Canvas. Text atoms carry their complete source label while `units` supplies
/// deduplicated logical targets; vector/image metadata remains available for
/// their labels and decoration intent.
public struct InlineAccessibilityProjection: Sendable, Hashable, Codable {
  public let atoms: [InlineAccessibilityElement]
  public let units: [InlineTextUnitAccessibilityElement]

  public init(
    atoms: [InlineAccessibilityElement],
    units: [InlineTextUnitAccessibilityElement]
  ) throws {
    try _ = InlineAccessibilitySemantics(elements: atoms)
    try _ = InlineTextUnitAccessibilitySemantics(elements: units)
    self.atoms = atoms
    self.units = units
  }

  public init(
    prepared: PreparedInlineDocument,
    hitIndex: InlineHitTestIndex,
    selection: InlineSelectionKey? = nil
  ) throws {
    try self.init(
      atoms: InlineAccessibilitySemantics(prepared: prepared).elements,
      units: InlineTextUnitAccessibilitySemantics(
        prepared: prepared, hitIndex: hitIndex, selection: selection).elements)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      atoms: values.decode([InlineAccessibilityElement].self, forKey: .atoms),
      units: values.decode([InlineTextUnitAccessibilityElement].self, forKey: .units))
  }

  private enum CodingKeys: String, CodingKey { case atoms, units }
}
