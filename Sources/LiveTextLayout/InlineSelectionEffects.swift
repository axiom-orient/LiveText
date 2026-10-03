import Foundation

/// The stable identity of a host-owned word selection.
///
/// Geometry is deliberately absent. A selection survives relayout by its
/// logical atom/source identity and preparation profile; visual fragments are
/// derived again from the one authoritative hit index.
public struct InlineSelectionKey: Sendable, Hashable, Codable {
  public let atomID: String
  public let unitKind: InlineTextUnitKind
  public let customID: String?
  public let sourceRange: InlineSourceRange
  public let preparationRevision: String
  public let hitProfile: InlineTextUnitHitProfile

  public init(
    atomID: String,
    unitKind: InlineTextUnitKind = .word,
    customID: String? = nil,
    sourceRange: InlineSourceRange,
    preparationRevision: String,
    hitProfile: InlineTextUnitHitProfile
  ) throws {
    guard !atomID.isEmpty, !preparationRevision.isEmpty,
      sourceRange.startUTF16 >= 0,
      sourceRange.endUTF16 > sourceRange.startUTF16,
      (unitKind == .custom) == (customID != nil),
      customID?.isEmpty != true
    else {
      throw InlineSelectionTransitionError(
        operation: "selection.key",
        targetID: atomID,
        preparationRevision: preparationRevision,
        cause: "selection identity is empty or its source range is invalid")
    }
    self.atomID = atomID
    self.unitKind = unitKind
    self.customID = customID
    self.sourceRange = sourceRange
    self.preparationRevision = preparationRevision
    self.hitProfile = hitProfile
  }

  public init(
    hit: InlineTextUnitHit,
    preparationRevision: String,
    hitProfile: InlineTextUnitHitProfile
  ) throws {
    try self.init(
      atomID: hit.atomID,
      unitKind: hit.unitKind,
      customID: hit.customID,
      sourceRange: hit.sourceRange,
      preparationRevision: preparationRevision,
      hitProfile: hitProfile
    )
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      atomID: values.decode(String.self, forKey: .atomID),
      unitKind: values.decode(InlineTextUnitKind.self, forKey: .unitKind),
      customID: values.decodeIfPresent(String.self, forKey: .customID),
      sourceRange: values.decode(InlineSourceRange.self, forKey: .sourceRange),
      preparationRevision: values.decode(String.self, forKey: .preparationRevision),
      hitProfile: values.decode(InlineTextUnitHitProfile.self, forKey: .hitProfile)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case atomID, unitKind, customID, sourceRange, preparationRevision, hitProfile
  }
}

/// A structured failure at the host-selection/effect boundary. The fields are
/// intentionally stable so an app can log the operation and retry cause
/// without parsing a localized error string.
public struct InlineSelectionTransitionError: Error, Equatable, LocalizedError, Sendable {
  public let operation: String
  public let targetID: String
  public let preparationRevision: String
  public let cause: String

  public init(
    operation: String,
    targetID: String,
    preparationRevision: String,
    cause: String
  ) {
    self.operation = operation
    self.targetID = targetID
    self.preparationRevision = preparationRevision
    self.cause = cause
  }

  public var errorDescription: String? {
    "Inline \(operation) failed for target '\(targetID)' at revision '\(preparationRevision)': \(cause)."
  }
}

/// Events emitted by an adapter/host boundary. The renderer never mutates a
/// selection state; it only reports a hit and the host sends this event back
/// through its own state transition.
public enum InlineTextUnitSelectionEvent: Sendable, Hashable, Codable {
  case select(InlineSelectionKey)
  case clear(preparationRevision: String, hitProfile: InlineTextUnitHitProfile)
}

/// The single host-owned selection state for one prepared hit profile.
public struct InlineTextUnitSelectionState: Sendable, Hashable, Codable {
  public let preparationRevision: String
  public let hitProfile: InlineTextUnitHitProfile
  public let selected: InlineSelectionKey?

  public init(
    preparationRevision: String,
    hitProfile: InlineTextUnitHitProfile = .default,
    selected: InlineSelectionKey? = nil
  ) throws {
    guard !preparationRevision.isEmpty else {
      throw InlineSelectionTransitionError(
        operation: "selection.state",
        targetID: "",
        preparationRevision: preparationRevision,
        cause: "preparation revision is empty")
    }
    if let selected {
      guard selected.preparationRevision == preparationRevision,
        selected.hitProfile == hitProfile
      else {
        throw InlineSelectionTransitionError(
          operation: "selection.state",
          targetID: selected.atomID,
          preparationRevision: preparationRevision,
          cause: "selected identity does not match the state revision/profile")
      }
    }
    self.preparationRevision = preparationRevision
    self.hitProfile = hitProfile
    self.selected = selected
  }

  public static func empty(
    preparationRevision: String,
    hitProfile: InlineTextUnitHitProfile = .default
  ) throws -> InlineTextUnitSelectionState {
    try InlineTextUnitSelectionState(
      preparationRevision: preparationRevision,
      hitProfile: hitProfile)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      preparationRevision: values.decode(String.self, forKey: .preparationRevision),
      hitProfile: values.decode(InlineTextUnitHitProfile.self, forKey: .hitProfile),
      selected: values.decodeIfPresent(InlineSelectionKey.self, forKey: .selected)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case preparationRevision, hitProfile, selected
  }

  /// Converts one renderer hit into a host event without storing the hit's
  /// rectangle or line in the selection state.
  public func activationEvent(for hit: InlineTextUnitHit) throws -> InlineTextUnitSelectionEvent {
    guard hitProfile.includeWhitespace || hit.sourceRange.lengthUTF16 > 0 else {
      throw InlineSelectionTransitionError(
        operation: "selection.activate",
        targetID: hit.atomID,
        preparationRevision: preparationRevision,
        cause: "hit target is not selectable under the active profile")
    }
    let key = try InlineSelectionKey(
      hit: hit,
      preparationRevision: preparationRevision,
      hitProfile: hitProfile)
    return .select(key)
  }

  /// Pure, deterministic host transition. A mismatched revision/profile is a
  /// stale event and cannot alter the current selection.
  public func applying(_ event: InlineTextUnitSelectionEvent)
    throws -> InlineTextUnitSelectionState {
    switch event {
    case .select(let key):
      guard key.preparationRevision == preparationRevision,
        key.hitProfile == hitProfile
      else {
        throw InlineSelectionTransitionError(
          operation: "selection.select",
          targetID: key.atomID,
          preparationRevision: preparationRevision,
          cause: "stale selection revision or hit profile")
      }
      return try InlineTextUnitSelectionState(
        preparationRevision: preparationRevision,
        hitProfile: hitProfile,
        selected: key)
    case .clear(let revision, let profile):
      guard revision == preparationRevision, profile == hitProfile else {
        throw InlineSelectionTransitionError(
          operation: "selection.clear",
          targetID: selected?.atomID ?? "",
          preparationRevision: preparationRevision,
          cause: "stale clear revision or hit profile")
      }
      return try InlineTextUnitSelectionState(
        preparationRevision: preparationRevision,
        hitProfile: hitProfile)
    }
  }
}

/// Host callback emitted by both drawing adapters after the shared viewport
/// hit test identifies a selectable text unit. The callback does not mutate
/// renderer state; the host sends the hit into its own transition reducer.
public typealias InlineTextUnitActivationHandler = @MainActor (InlineTextUnitHit) -> Void

/// Renderer-neutral RGBA color used by highlight styles.
public struct InlineHighlightColor: Sendable, Hashable, Codable {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) throws {
    let values = [red, green, blue, alpha]
    guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
      throw InlineLayoutError.invalidRenderPlan
    }
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public static let yellow = try! InlineHighlightColor(red: 1, green: 0.86, blue: 0.15)
  public static let blue = try! InlineHighlightColor(red: 0.24, green: 0.55, blue: 1)

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      red: values.decode(Double.self, forKey: .red),
      green: values.decode(Double.self, forKey: .green),
      blue: values.decode(Double.self, forKey: .blue),
      alpha: values.decode(Double.self, forKey: .alpha)
    )
  }

  private enum CodingKeys: String, CodingKey { case red, green, blue, alpha }
}

/// A replaceable renderer-neutral presentation policy. None of these values
/// affect layout, hit testing, source ranges, or reveal timing.
public enum InlineHighlightStyle: Sendable, Hashable, Codable {
  case highlighter(color: InlineHighlightColor, opacity: Double, cornerRadius: Double)
  case underline(color: InlineHighlightColor, thickness: Double, offset: Double)
  case outline(color: InlineHighlightColor, thickness: Double)

  public static var defaultHighlighter: InlineHighlightStyle {
    .highlighter(color: .yellow, opacity: 0.38, cornerRadius: 2)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(String.self, forKey: .kind) {
    case "highlighter":
      try self.init(
        highlighterColor: values.decode(InlineHighlightColor.self, forKey: .color),
        opacity: values.decode(Double.self, forKey: .opacity),
        cornerRadius: values.decode(Double.self, forKey: .cornerRadius))
    case "underline":
      try self.init(
        underlineColor: values.decode(InlineHighlightColor.self, forKey: .color),
        thickness: values.decode(Double.self, forKey: .thickness),
        offset: values.decode(Double.self, forKey: .offset))
    case "outline":
      try self.init(
        outlineColor: values.decode(InlineHighlightColor.self, forKey: .color),
        thickness: values.decode(Double.self, forKey: .thickness))
    default:
      throw InlineLayoutError.invalidRenderPlan
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .highlighter(let color, let opacity, let cornerRadius):
      try values.encode("highlighter", forKey: .kind)
      try values.encode(color, forKey: .color)
      try values.encode(opacity, forKey: .opacity)
      try values.encode(cornerRadius, forKey: .cornerRadius)
    case .underline(let color, let thickness, let offset):
      try values.encode("underline", forKey: .kind)
      try values.encode(color, forKey: .color)
      try values.encode(thickness, forKey: .thickness)
      try values.encode(offset, forKey: .offset)
    case .outline(let color, let thickness):
      try values.encode("outline", forKey: .kind)
      try values.encode(color, forKey: .color)
      try values.encode(thickness, forKey: .thickness)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind, color, opacity, cornerRadius, thickness, offset
  }

  private init(
    highlighterColor color: InlineHighlightColor,
    opacity: Double,
    cornerRadius: Double
  ) throws {
    guard opacity.isFinite, (0...1).contains(opacity), cornerRadius.isFinite, cornerRadius >= 0 else {
      throw InlineLayoutError.invalidRenderPlan
    }
    self = .highlighter(color: color, opacity: opacity, cornerRadius: cornerRadius)
  }

  private init(
    underlineColor color: InlineHighlightColor,
    thickness: Double,
    offset: Double
  ) throws {
    guard thickness.isFinite, thickness > 0, offset.isFinite else {
      throw InlineLayoutError.invalidRenderPlan
    }
    self = .underline(color: color, thickness: thickness, offset: offset)
  }

  private init(outlineColor color: InlineHighlightColor, thickness: Double) throws {
    guard thickness.isFinite, thickness > 0 else {
      throw InlineLayoutError.invalidRenderPlan
    }
    self = .outline(color: color, thickness: thickness)
  }

  fileprivate func validate() throws {
    switch self {
    case .highlighter(_, let opacity, let cornerRadius):
      guard opacity.isFinite, (0...1).contains(opacity), cornerRadius.isFinite,
        cornerRadius >= 0 else { throw InlineLayoutError.invalidRenderPlan }
    case .underline(_, let thickness, let offset):
      guard thickness.isFinite, thickness > 0, offset.isFinite else {
        throw InlineLayoutError.invalidRenderPlan
      }
    case .outline(_, let thickness):
      guard thickness.isFinite, thickness > 0 else {
        throw InlineLayoutError.invalidRenderPlan
      }
    }
  }
}

/// One visual decoration fragment. A wrapped word has one fragment per line;
/// all geometry is derived from the shared hit index.
public struct InlineHighlightFragment: Sendable, Hashable, Codable {
  public let atomID: String
  public let sourceRange: InlineSourceRange
  public let lineIndex: Int
  public let rect: InlineHitRect

  public init(
    atomID: String,
    sourceRange: InlineSourceRange,
    lineIndex: Int,
    rect: InlineHitRect
  ) throws {
    guard !atomID.isEmpty, lineIndex >= 0 else {
      throw InlineLayoutError.invalidRenderPlan
    }
    self.atomID = atomID
    self.sourceRange = sourceRange
    self.lineIndex = lineIndex
    self.rect = rect
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      atomID: values.decode(String.self, forKey: .atomID),
      sourceRange: values.decode(InlineSourceRange.self, forKey: .sourceRange),
      lineIndex: values.decode(Int.self, forKey: .lineIndex),
      rect: values.decode(InlineHitRect.self, forKey: .rect)
    )
  }

  private enum CodingKeys: String, CodingKey { case atomID, sourceRange, lineIndex, rect }
}

/// Immutable effect plan derived from one render plan and one host selection.
public struct InlineHighlightPlan: Sendable, Hashable, Codable {
  public let preparationRevision: String
  public let selection: InlineSelectionKey
  public let style: InlineHighlightStyle
  public let fragments: [InlineHighlightFragment]

  public init(
    renderPlan: InlineRenderPlan,
    selection: InlineSelectionKey,
    style: InlineHighlightStyle = .defaultHighlighter,
    cancellation: @escaping InlineCancellationCheck = {}
  ) throws {
    try cancellation()
    guard selection.preparationRevision == renderPlan.prepared.revision else {
      throw InlineSelectionTransitionError(
        operation: "highlight.plan",
        targetID: selection.atomID,
        preparationRevision: renderPlan.prepared.revision,
        cause: "selection belongs to a stale preparation revision")
    }
    guard selection.hitProfile == renderPlan.hitIndex.profile else {
      throw InlineSelectionTransitionError(
        operation: "highlight.plan",
        targetID: selection.atomID,
        preparationRevision: renderPlan.prepared.revision,
        cause: "selection belongs to a different hit profile")
    }
    try style.validate()
    let hits = renderPlan.hitIndex.textUnitHits(
      atomID: selection.atomID,
      unitKind: selection.unitKind,
      customID: selection.customID,
      sourceRange: selection.sourceRange)
    guard !hits.isEmpty else {
      throw InlineSelectionTransitionError(
        operation: "highlight.plan",
        targetID: selection.atomID,
        preparationRevision: renderPlan.prepared.revision,
        cause: "selected word is absent from the authoritative hit index")
    }
    var fragments: [InlineHighlightFragment] = []
    fragments.reserveCapacity(hits.count)
    for hit in hits {
      try cancellation()
      guard hit.sourceRange == selection.sourceRange else { continue }
      fragments.append(try InlineHighlightFragment(
        atomID: hit.atomID,
        sourceRange: hit.sourceRange,
        lineIndex: hit.lineIndex,
        rect: hit.rect))
    }
    guard !fragments.isEmpty else {
      throw InlineSelectionTransitionError(
        operation: "highlight.plan",
        targetID: selection.atomID,
        preparationRevision: renderPlan.prepared.revision,
        cause: "selected word has no visual fragments")
    }
    self.preparationRevision = renderPlan.prepared.revision
    self.selection = selection
    self.style = style
    self.fragments = fragments
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let revision = try values.decode(String.self, forKey: .preparationRevision)
    let selection = try values.decode(InlineSelectionKey.self, forKey: .selection)
    let style = try values.decode(InlineHighlightStyle.self, forKey: .style)
    let fragments = try values.decode([InlineHighlightFragment].self, forKey: .fragments)
    guard !revision.isEmpty, revision == selection.preparationRevision, !fragments.isEmpty else {
      throw InlineSelectionTransitionError(
        operation: "highlight.decode",
        targetID: selection.atomID,
        preparationRevision: revision,
        cause: "decoded highlight plan is incomplete")
    }
    try style.validate()
    guard fragments.allSatisfy({
      $0.atomID == selection.atomID && $0.sourceRange == selection.sourceRange
    }), Set(fragments).count == fragments.count else {
      throw InlineSelectionTransitionError(
        operation: "highlight.decode",
        targetID: selection.atomID,
        preparationRevision: revision,
        cause: "decoded highlight fragments do not match the selected identity")
    }
    self.preparationRevision = revision
    self.selection = selection
    self.style = style
    self.fragments = fragments
  }

  /// Revalidates a decoded or externally retained plan before an adapter
  /// consumes it. This closes the immutable handoff at the render-plan
  /// boundary rather than trusting revision/profile fields alone.
  public func validate(for renderPlan: InlineRenderPlan) throws {
    guard preparationRevision == renderPlan.prepared.revision,
      selection.preparationRevision == renderPlan.prepared.revision else {
      throw InlineSelectionTransitionError(
        operation: "highlight.validate",
        targetID: selection.atomID,
        preparationRevision: renderPlan.prepared.revision,
        cause: "highlight plan belongs to a stale preparation revision")
    }
    guard selection.hitProfile == renderPlan.hitIndex.profile else {
      throw InlineSelectionTransitionError(
        operation: "highlight.validate",
        targetID: selection.atomID,
        preparationRevision: renderPlan.prepared.revision,
        cause: "highlight plan belongs to a different hit profile")
    }
    try style.validate()
    let expected = renderPlan.hitIndex.textUnitHits(
      atomID: selection.atomID,
      unitKind: selection.unitKind,
      customID: selection.customID,
      sourceRange: selection.sourceRange)
    guard fragments.count == expected.count,
      fragments.enumerated().allSatisfy({ index, fragment in
        fragment.atomID == selection.atomID
          && fragment.sourceRange == selection.sourceRange
          && fragment.lineIndex == expected[index].lineIndex
          && fragment.rect == expected[index].rect
      }) else {
      throw InlineSelectionTransitionError(
        operation: "highlight.validate",
        targetID: selection.atomID,
        preparationRevision: renderPlan.prepared.revision,
        cause: "highlight fragments do not match the authoritative hit index")
    }
  }

  private enum CodingKeys: String, CodingKey {
    case preparationRevision, selection, style, fragments
  }
}
