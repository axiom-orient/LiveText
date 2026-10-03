/// Default values owned by the magazine flow policy.
public enum InlineMagazineDefaults {
  public static let mediaGap: Double = 8
  public static let minimumTextWidth: Double = 72
}

/// Host-owned media geometry anchored to one physical horizontal edge of a flow region.
///
/// The media remains outside the semantic inline document. `InlineMagazineStyle` projects
/// it into flow exclusions before layout so the existing line-fragment solver remains the
/// sole line-breaking authority.
public struct InlineMagazineMedia: Sendable, Hashable {
  public let id: String
  public let rect: InlineFlowRect

  public init(id: String, rect: InlineFlowRect) throws {
    guard !id.isEmpty else { throw InlineLayoutError.invalidIdentifier }
    guard rect.width > 0, rect.height > 0 else {
      throw InlineLayoutError.invalidFlowRegion("magazine media must have positive size")
    }
    self.id = id
    self.rect = rect
  }

}

/// Opt-in magazine composition policy.
///
/// `minimumXMedia` must be physically anchored to the content rectangle's `minX` edge and
/// `maximumXMedia` to its `maxX` edge. These names intentionally describe physical layout
/// coordinates rather than writing direction; text bidi/shaping remains a separate concern.
public struct InlineMagazineStyle: Sendable, Hashable {
  public let minimumXMedia: [InlineMagazineMedia]
  public let maximumXMedia: [InlineMagazineMedia]
  public let mediaGap: Double
  public let minimumTextWidth: Double

  /// The empty magazine style is the package default. It keeps ordinary text
  /// rectangular until a host supplies media, while using the same validated
  /// flow policy as image-backed layouts.
  public static var standard: Self {
    do { return try Self() }
    catch { preconditionFailure("Invalid LiveText magazine defaults: \(error)") }
  }

  public init(
    minimumXMedia: [InlineMagazineMedia] = [],
    maximumXMedia: [InlineMagazineMedia] = [],
    mediaGap: Double = InlineMagazineDefaults.mediaGap,
    minimumTextWidth: Double = InlineMagazineDefaults.minimumTextWidth
  ) throws {
    guard mediaGap.isFinite, mediaGap >= 0 else {
      throw InlineLayoutError.invalidFlowRegion(
        "magazine media gap must be finite and non-negative")
    }
    guard minimumTextWidth.isFinite, minimumTextWidth > 0 else {
      throw InlineLayoutError.invalidFlowRegion(
        "magazine minimum text width must be finite and positive")
    }
    var ids = Set<String>()
    for media in minimumXMedia + maximumXMedia {
      guard ids.insert(media.id).inserted else {
        throw InlineLayoutError.invalidFlowRegion(
          "duplicate magazine media identifier: \(media.id)")
      }
    }
    self.minimumXMedia = minimumXMedia
    self.maximumXMedia = maximumXMedia
    self.mediaGap = mediaGap
    self.minimumTextWidth = minimumTextWidth
  }

  fileprivate func projectedExclusions(in contentRect: InlineFlowRect) throws
    -> [InlineFlowExclusion]
  {
    let epsilon = 1.0 / 65_536.0
    guard contentRect.width >= minimumTextWidth else {
      throw InlineLayoutError.invalidFlowRegion(
        "magazine minimum text width exceeds the content width")
    }

    for media in minimumXMedia {
      guard abs(media.rect.minX - contentRect.minX) <= epsilon else {
        throw InlineLayoutError.invalidFlowRegion(
          "minimum-x magazine media must be anchored to content minX")
      }
    }
    for media in maximumXMedia {
      guard abs(media.rect.maxX - contentRect.maxX) <= epsilon else {
        throw InlineLayoutError.invalidFlowRegion(
          "maximum-x magazine media must be anchored to content maxX")
      }
    }

    try validateTextWidth(in: contentRect)

    var projected: [InlineFlowExclusion] = []
    projected.reserveCapacity(minimumXMedia.count + maximumXMedia.count)
    for media in minimumXMedia {
      let width = media.rect.width + mediaGap
      guard width.isFinite else {
        throw InlineLayoutError.invalidFlowRegion("magazine exclusion width overflowed")
      }
      projected.append(
        try InlineFlowExclusion(
          id: "$livetext.magazine.minimum-x.\(media.id)",
          rect: InlineFlowRect(
            x: media.rect.minX,
            y: media.rect.minY,
            width: width,
            height: media.rect.height)))
    }
    for media in maximumXMedia {
      let x = media.rect.minX - mediaGap
      let width = media.rect.width + mediaGap
      guard x.isFinite, width.isFinite else {
        throw InlineLayoutError.invalidFlowRegion("magazine exclusion geometry overflowed")
      }
      projected.append(
        try InlineFlowExclusion(
          id: "$livetext.magazine.maximum-x.\(media.id)",
          rect: InlineFlowRect(
            x: x,
            y: media.rect.minY,
            width: width,
            height: media.rect.height)))
    }
    return projected
  }

  private func validateTextWidth(in contentRect: InlineFlowRect) throws {
    let allMedia = minimumXMedia + maximumXMedia
    guard !allMedia.isEmpty else { return }

    var yBreaks = [contentRect.minY, contentRect.maxY]
    yBreaks.reserveCapacity(2 + allMedia.count * 2)
    for media in allMedia {
      let minY = max(contentRect.minY, media.rect.minY)
      let maxY = min(contentRect.maxY, media.rect.maxY)
      if minY < maxY {
        yBreaks.append(minY)
        yBreaks.append(maxY)
      }
    }
    yBreaks = Array(Set(yBreaks)).sorted()

    for index in 0..<(yBreaks.count - 1) {
      let minY = yBreaks[index]
      let maxY = yBreaks[index + 1]
      guard minY < maxY else { continue }
      let probeY = minY + (maxY - minY) / 2

      var minimumXBlockedTo = contentRect.minX
      for media in minimumXMedia where media.rect.minY < probeY && media.rect.maxY > probeY {
        let bound = media.rect.maxX + mediaGap
        guard bound.isFinite else {
          throw InlineLayoutError.invalidFlowRegion("magazine minimum-x geometry overflowed")
        }
        minimumXBlockedTo = max(minimumXBlockedTo, bound)
      }

      var maximumXBlockedFrom = contentRect.maxX
      for media in maximumXMedia where media.rect.minY < probeY && media.rect.maxY > probeY {
        let bound = media.rect.minX - mediaGap
        guard bound.isFinite else {
          throw InlineLayoutError.invalidFlowRegion("magazine maximum-x geometry overflowed")
        }
        maximumXBlockedFrom = min(maximumXBlockedFrom, bound)
      }

      guard maximumXBlockedFrom - minimumXBlockedTo >= minimumTextWidth else {
        throw InlineLayoutError.invalidFlowRegion(
          "magazine media leave less than the minimum text width")
      }
    }
  }
}

/// Container-level composition mode. `.inline` preserves the legacy flow geometry;
/// `.magazine` adds validated host-media exclusions before the same layout engine runs.
public enum InlineFlowLayoutStyle: Sendable, Hashable {
  case inline
  case magazine(InlineMagazineStyle)

  /// New LiveText scenes use the magazine policy by default.
  public static var standard: Self { .magazine(.standard) }
}

extension InlineFlowRegion {
  /// Creates a flow region using an explicit container composition style.
  ///
  /// The style is projected to ordinary exclusions and is not persisted as a second geometry
  /// authority. Existing `InlineFlowRegion` Codable data therefore keeps the same schema.
  public init(
    rect: InlineFlowRect,
    insets: InlineFlowInsets = .zero,
    exclusions: [InlineFlowExclusion] = [],
    revision: UInt64 = 0,
    layoutStyle: InlineFlowLayoutStyle
  ) throws {
    try insets.validate()
    let contentRect = try rect.inset(by: insets)
    let styleExclusions: [InlineFlowExclusion]
    switch layoutStyle {
    case .inline:
      styleExclusions = []
    case .magazine(let style):
      styleExclusions = try style.projectedExclusions(in: contentRect)
    }
    try self.init(
      rect: rect,
      insets: insets,
      exclusions: exclusions + styleExclusions,
      revision: revision)
  }
}
