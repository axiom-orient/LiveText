import Foundation
import LiveTextChalkRendering
import LiveTextEffects

/// Ensures that the timeline addresses exactly the semantic stroke storage
/// carried by the scene. `WritingTimeline` remains responsible for validating
/// timing values and temporal ordering; this boundary validates ownership.
func validateChalkWritingTimelineOwnership(
  scene: StrokeWritingScene,
  timeline: WritingTimeline
) throws {
  let expectedCount = scene.glyphs.reduce(0) { $0 + $1.strokes.count }
  guard timeline.strokes.count == expectedCount else {
    throw WritingCoreError.invalidTimeline
  }

  var flattenedIndex = 0
  for glyph in scene.glyphs {
    for (strokeIndex, stroke) in glyph.strokes.enumerated() {
      let timing = timeline.strokes[flattenedIndex]
      guard timing.layerIndex == flattenedIndex,
        timing.glyphIndex == glyph.index,
        timing.strokeIndex == strokeIndex,
        timing.strokeID == stroke.id
      else {
        throw WritingCoreError.invalidTimeline
      }
      flattenedIndex += 1
    }
  }
}

/// Validated semantic writing data ready for a SwiftUI renderer.
///
/// Preparation is deliberately throwing. Unsupported Unicode scalars, empty
/// scenes, and resource-limit violations remain visible to the caller instead
/// of silently falling back to a different glyph source.
final class ChalkWritingPreparationCache: @unchecked Sendable {
  let renderPlan: ChalkWritingRenderPlan
  // Path storage is immutable. The only mutable derivative is protected by
  // this lock and retains at most one material/width result per preparation.
  private let contactLock = NSLock()
  private var contactEntry: ContactEntry?

  private struct ContactEntry {
    let configuration: WritingChalkConfiguration
    let lineWidthMultiplier: Double
    let result: Result<ChalkPreparedContactPlan?, Error>
  }

  init(scene: StrokeWritingScene, timeline: WritingTimeline) throws {
    renderPlan = try ChalkWritingRenderPlan(scene: scene, timeline: timeline)
  }

  func contactPlan(style: ChalkWritingStyle) throws -> ChalkPreparedContactPlan? {
    contactLock.lock()
    defer { contactLock.unlock() }
    if let entry = contactEntry,
      entry.configuration == style.configuration,
      entry.lineWidthMultiplier == style.lineWidthMultiplier {
      return try entry.result.get()
    }
    let result = Result { try makeContactPlan(style: style) }
    contactEntry = ContactEntry(
      configuration: style.configuration, lineWidthMultiplier: style.lineWidthMultiplier, result: result)
    return try result.get()
  }

  private func makeContactPlan(style: ChalkWritingStyle) throws -> ChalkPreparedContactPlan? {
    let configuration = style.configuration
    if configuration.grainAmount == 0, configuration.erosionAmount == 0,
      configuration.edgeRoughness == 0 { return nil }
    let material = ChalkRenderMaterial.liveText(configuration)
    guard material.executionTopology(for: .strokeGeometry) == .contactDabs else { return nil }
    let strokes = renderPlan.strokes.map { stroke in
      ChalkRenderStrokeGeometry(id: stroke.timing.strokeID, points: stroke.points.map {
        ChalkRenderStrokePoint(x: $0.x, y: $0.y, width: $0.width * style.lineWidthMultiplier)
      })
    }
    return try ChalkPreparedContactPlan.prepare(strokes: strokes, material: material)
  }
}

public struct ChalkWritingPreparation: Codable, Equatable, Sendable {
  public let scene: StrokeWritingScene
  public let timeline: WritingTimeline
  let renderPlanCache: ChalkWritingPreparationCache

  public init(
    text: String,
    layout: WritingLayoutOptions = .default,
    timing: WritingTimingOptions = .default,
    limits: WritingResourceLimits = .default
  ) throws {
    let scene = try SemanticWritingPlanner.makeScene(
      text: text,
      options: layout,
      limits: limits
    )
    let timeline = try WritingTimelinePlanner.makeTimeline(scene: scene, options: timing)
    try validateChalkWritingTimelineOwnership(scene: scene, timeline: timeline)
    self.scene = scene
    self.timeline = timeline
    self.renderPlanCache = try ChalkWritingPreparationCache(
      scene: scene, timeline: timeline)
  }

  private enum CodingKeys: String, CodingKey { case scene, timeline }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let scene = try values.decode(StrokeWritingScene.self, forKey: .scene)
    let timeline = try values.decode(WritingTimeline.self, forKey: .timeline)
    // Validate the semantic boundary before constructing the renderer-owned
    // geometry cache. A valid timeline can still point at the wrong scene.
    try validateChalkWritingTimelineOwnership(scene: scene, timeline: timeline)
    self.scene = scene
    self.timeline = timeline
    self.renderPlanCache = try ChalkWritingPreparationCache(scene: scene, timeline: timeline)
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(scene, forKey: .scene)
    try values.encode(timeline, forKey: .timeline)
  }

  public static func == (lhs: ChalkWritingPreparation, rhs: ChalkWritingPreparation) -> Bool {
    lhs.scene == rhs.scene && lhs.timeline == rhs.timeline
  }

  /// The total animation duration in seconds.
  public var duration: Double { timeline.duration }

  /// A named form useful at call sites that make preparation explicit.
  public static func prepare(
    text: String,
    layout: WritingLayoutOptions = .default,
    timing: WritingTimingOptions = .default,
    limits: WritingResourceLimits = .default
  ) throws -> ChalkWritingPreparation {
    try ChalkWritingPreparation(text: text, layout: layout, timing: timing, limits: limits)
  }
}
