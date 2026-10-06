import LiveTextChalkRendering
import LiveTextEffects
import SwiftUI

extension ChalkWritingRenderPlan.Stroke: ChalkWritingTimedStroke {}

/// Reveals the semantic Latin/Hangul catalog over its prepared timeline.
/// The catalog is a teaching profile, not an author's original pen trajectory.
public struct ChalkWritingText: View {
  /// A view cannot simultaneously contain a partial plan and a failure.
  private enum PreparedState {
    case ready(
      plan: ChalkWritingRenderPlan,
      contactPlan: ChalkPreparedContactPlan?,
      identity: ChalkWritingPlaybackIdentity
    )
    case failed(String)
  }

  private let state: PreparedState
  private let style: ChalkWritingStyle
  private let animation: ChalkWritingAnimation
  private let motion: ChalkWritingMotionStyle
  private let fixedProgress: Double?
  private let onCompletion: (() -> Void)?

  /// Invalid input or material preparation failure becomes an accessible error
  /// view. Use `ChalkWritingPreparation` for throwing semantic preparation.
  public init(
    _ text: String,
    layout: WritingLayoutOptions = .default,
    timing: WritingTimingOptions = .default,
    limits: WritingResourceLimits = .default,
    style: ChalkWritingStyle = .chalk,
    animation: ChalkWritingAnimation = .write,
    motion: ChalkWritingMotionStyle = .varied,
    progress: Double? = nil,
    onCompletion: (() -> Void)? = nil
  ) {
    self.init(
      prepare: { try ChalkWritingPreparation(text: text, layout: layout, timing: timing, limits: limits) },
      style: style, animation: animation, motion: motion,
      progress: progress, onCompletion: onCompletion)
  }

  /// Labeled convenience form for call sites that prefer `text:`.
  public init(
    text: String,
    layout: WritingLayoutOptions = .default,
    timing: WritingTimingOptions = .default,
    limits: WritingResourceLimits = .default,
    style: ChalkWritingStyle = .chalk,
    animation: ChalkWritingAnimation = .write,
    motion: ChalkWritingMotionStyle = .varied,
    progress: Double? = nil,
    onCompletion: (() -> Void)? = nil
  ) {
    self.init(
      text, layout: layout, timing: timing, limits: limits,
      style: style, animation: animation, motion: motion,
      progress: progress, onCompletion: onCompletion)
  }

  /// Semantic validation does not prove that a later style-specific contact
  /// plan fits its resource budget. Both public entry paths share one result.
  public init(
    preparation: ChalkWritingPreparation,
    style: ChalkWritingStyle = .chalk,
    animation: ChalkWritingAnimation = .write,
    motion: ChalkWritingMotionStyle = .varied,
    progress: Double? = nil,
    onCompletion: (() -> Void)? = nil
  ) {
    self.init(
      prepare: { preparation },
      style: style, animation: animation, motion: motion,
      progress: progress, onCompletion: onCompletion)
  }

  private init(
    prepare: () throws -> ChalkWritingPreparation,
    style: ChalkWritingStyle,
    animation: ChalkWritingAnimation,
    motion: ChalkWritingMotionStyle,
    progress: Double?,
    onCompletion: (() -> Void)?
  ) {
    self.style = style
    self.animation = animation
    self.motion = motion
    self.onCompletion = onCompletion
    if let progress, !progress.isFinite || !(0...1).contains(progress) {
      fixedProgress = nil
      state = .failed(ChalkLineEffectsError.invalidProgress(progress).localizedDescription)
      return
    }
    fixedProgress = progress
    do {
      let preparation = try prepare()
      let plan = preparation.renderPlanCache.renderPlan
      let contacts = try preparation.renderPlanCache.contactPlan(style: style)
      state = .ready(
        plan: plan, contactPlan: contacts,
        identity: ChalkWritingPlaybackIdentity(
          preparation: preparation, plan: plan, style: style,
          animation: animation, motion: motion))
    } catch {
      state = .failed(String(describing: error))
    }
  }

  var isShowingPreparationFailure: Bool {
    if case .failed = state { return true }
    return false
  }

  private var accessibilityDescription: String {
    switch state {
    case .ready(_, _, let identity): identity.sceneText
    case .failed(let message): "Unable to prepare writing: \(message)"
    }
  }

  public var body: some View {
    Group {
      switch state {
      case .ready(let plan, let contacts, let identity):
        if let fixedProgress {
          ChalkWritingCanvas(
            plan: plan, contactPlan: contacts, style: style,
            animation: animation, motion: motion, progress: fixedProgress)
        } else {
          ChalkWritingTimeline(
            plan: plan, contactPlan: contacts, style: style,
            animation: animation, motion: motion, onCompletion: onCompletion)
            .id(identity)
        }
      case .failed(let message):
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityDescription)
  }
}

private struct ChalkWritingTimeline: View {
  let plan: ChalkWritingRenderPlan
  let contactPlan: ChalkPreparedContactPlan?
  let style: ChalkWritingStyle
  let animation: ChalkWritingAnimation
  let motion: ChalkWritingMotionStyle
  let onCompletion: (() -> Void)?
  @State private var playback: ChalkWritingPlaybackState

  init(
    plan: ChalkWritingRenderPlan,
    contactPlan: ChalkPreparedContactPlan?,
    style: ChalkWritingStyle,
    animation: ChalkWritingAnimation,
    motion: ChalkWritingMotionStyle,
    onCompletion: (() -> Void)?
  ) {
    self.plan = plan
    self.contactPlan = contactPlan
    self.style = style
    self.animation = animation
    self.motion = motion
    self.onCompletion = onCompletion
    _playback = State(
      initialValue: ChalkWritingPlaybackState(
        duration: plan.duration,
        startedAt: Date().timeIntervalSinceReferenceDate
      )
    )
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: playback.isPaused)) { context in
      let now = context.date.timeIntervalSinceReferenceDate
      let progress = playback.progress(at: now)
      ChalkWritingCanvas(
        plan: plan,
        contactPlan: contactPlan,
        style: style,
        animation: animation,
        motion: motion,
        progress: progress
      )
      .onChangeCompatible(of: progress) { value in
        guard value >= 1, !playback.isPaused else { return }
        playback.markComplete(at: now)
        onCompletion?()
      }
    }
    .onAppear {
      playback.reset(at: Date().timeIntervalSinceReferenceDate)
    }
  }
}

struct ChalkWritingPlaybackIdentity: Hashable {
  let sceneText: String
  let sceneWidth: Double
  let sceneHeight: Double
  let timelineStrokeIDs: [String]
  let timelineStartTimes: [Double]
  let timelineEndTimes: [Double]
  let timelineDuration: Double
  let style: ChalkWritingStyle
  let animation: ChalkWritingAnimation
  let motion: ChalkWritingMotionStyle

  init(
    preparation: ChalkWritingPreparation,
    plan: ChalkWritingRenderPlan,
    style: ChalkWritingStyle,
    animation: ChalkWritingAnimation = .write,
    motion: ChalkWritingMotionStyle = .varied
  ) {
    sceneText = preparation.scene.text
    sceneWidth = preparation.scene.size.width
    sceneHeight = preparation.scene.size.height
    // The render plan is built from the same scene/timeline pair, so one
    // ordered ID list is sufficient for identity without retaining a
    // duplicate array.
    timelineStrokeIDs = plan.strokes.map(\.timing.strokeID)
    timelineStartTimes = preparation.timeline.strokes.map(\.startTime)
    timelineEndTimes = preparation.timeline.strokes.map(\.endTime)
    timelineDuration = plan.duration
    self.style = style
    self.animation = animation
    self.motion = motion
  }
}

/// The constant-work playback decision made for one Canvas frame.
///
/// `WritingTimeline` guarantees sorted, non-overlapping intervals. That means
/// a frame can have at most one stroke whose fraction is neither zero nor one.
/// Keep that decision separate from geometry drawing so both the semantic text
/// and exact-path renderers share the same boundary behavior without asking
/// every stroke to recompute its slice on every frame.
protocol ChalkWritingTimedStroke {
  var timing: WritingStrokeTiming { get }
}

private struct ChalkWritingTimingStroke: ChalkWritingTimedStroke {
  let timing: WritingStrokeTiming
}

struct ChalkWritingFramePlan: Equatable {
  struct PartialStroke: Equatable {
    let index: Int
    let fraction: Double
  }

  /// `true` means the visible interval is a prefix (`write` and
  /// `eraseReverse`); `false` means it is a suffix (`eraseForward`).
  let isPrefix: Bool
  let fullRange: Range<Int>
  let hiddenRange: Range<Int>
  let partialStroke: PartialStroke?

  /// Evidence used by package-level scaling tests. A frame evaluates the
  /// easing function zero times in a gap and once only when a stroke is active.
  let fractionEvaluationCount: Int
  /// Binary search work used to locate the active interval. This is not a
  /// timing metric; it makes the logarithmic classification contract directly
  /// testable without relying on wall-clock noise.
  let timelineComparisonCount: Int

  init<S: ChalkWritingTimedStroke>(
    animation: ChalkWritingAnimation,
    progress: Double,
    duration: Double,
    strokes: [S],
    motion: ChalkWritingMotionStyle,
    seed: UInt64
  ) {
    let clampedProgress = min(1, max(0, progress))
    let timelineTime: Double
    switch animation {
    case .write, .eraseForward:
      timelineTime = clampedProgress * duration
    case .eraseReverse:
      timelineTime = (1 - clampedProgress) * duration
    }

    var low = 0
    var high = strokes.count
    var comparisons = 0
    // The first interval with endTime > time is either the active stroke or
    // the first future stroke when the frame is in a timeline gap.
    while low < high {
      comparisons += 1
      let middle = low + (high - low) / 2
      if strokes[middle].timing.endTime <= timelineTime {
        low = middle + 1
      } else {
        high = middle
      }
    }

    let boundary = low
    let activeIndex: Int?
    if boundary < strokes.count, strokes[boundary].timing.startTime <= timelineTime {
      activeIndex = boundary
    } else {
      activeIndex = nil
    }

    var active: PartialStroke?
    var evaluationCount = 0
    if let activeIndex {
      let fraction = WritingPlayback.strokeFraction(
        at: timelineTime,
        timing: strokes[activeIndex].timing,
        motion: motion,
        seed: seed
      )
      active = PartialStroke(index: activeIndex, fraction: fraction)
      evaluationCount = 1
    } else {
      active = nil
    }

    let prefix = animation != .eraseForward
    self.isPrefix = prefix
    self.partialStroke = active
    self.fractionEvaluationCount = evaluationCount
    self.timelineComparisonCount = comparisons
    if prefix {
      let fullEnd = active?.index ?? boundary
      fullRange = 0..<fullEnd
      let hiddenStart = active.map { $0.index + 1 } ?? boundary
      hiddenRange = hiddenStart..<strokes.count
    } else {
      let hiddenEnd = active?.index ?? boundary
      hiddenRange = 0..<hiddenEnd
      let fullStart = active.map { $0.index + 1 } ?? boundary
      fullRange = fullStart..<strokes.count
    }
  }

  /// Array-backed timing input kept for deterministic package tests. Canvas
  /// callers use the generic stroke initializer above so no timing array is
  /// copied or mapped on the frame hot path.
  init(
    animation: ChalkWritingAnimation,
    progress: Double,
    duration: Double,
    timings: [WritingStrokeTiming],
    motion: ChalkWritingMotionStyle,
    seed: UInt64
  ) {
    self.init(
      animation: animation,
      progress: progress,
      duration: duration,
      strokes: timings.map(ChalkWritingTimingStroke.init),
      motion: motion,
      seed: seed
    )
  }
}

private struct ChalkWritingCanvas: View {
  let plan: ChalkWritingRenderPlan
  let contactPlan: ChalkPreparedContactPlan?
  let style: ChalkWritingStyle
  let animation: ChalkWritingAnimation
  let motion: ChalkWritingMotionStyle
  let progress: Double

  var body: some View {
    Canvas { context, size in
      let sceneWidth = max(plan.sceneSize.width, 1)
      let sceneHeight = max(plan.sceneSize.height, 1)
      let widthScale = Double(size.width) / sceneWidth
      let heightScale = Double(size.height) / sceneHeight
      let scale = min(widthScale, heightScale)
      guard scale.isFinite, scale > 0 else { return }

      let offsetX = (Double(size.width) - sceneWidth * scale) * 0.5
      let offsetY = (Double(size.height) - sceneHeight * scale) * 0.5
      let frame = ChalkWritingFramePlan(
        animation: animation,
        progress: progress,
        duration: plan.duration,
        strokes: plan.strokes,
        motion: motion,
        seed: style.configuration.seed
      )
      let color = style.color.swiftUIColor

      // Draw all geometry in source coordinates under one frame transform.
      // The old implementation transformed each visible Path separately.
      context.translateBy(x: CGFloat(offsetX), y: CGFloat(offsetY))
      context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

      if let contactPlan {
        var visibility = Array(
          repeating: ChalkContactVisibility.hidden,
          count: plan.strokes.count
        )
        for index in frame.fullRange { visibility[index] = .full }
        if let partial = frame.partialStroke {
          visibility[partial.index] = frame.isPrefix
            ? .prefix(partial.fraction)
            : .suffix(partial.fraction)
        }
        ChalkContactRenderer.paint(
          plan: contactPlan,
          visibility: visibility,
          color: color,
          documentOriginAtContextZero: .zero,
          clipBounds: CGRect(x: 0, y: 0, width: sceneWidth, height: sceneHeight),
          in: &context
        )
        return
      }

      func sourceLineWidth(for renderStroke: ChalkWritingRenderPlan.Stroke) -> Double {
        // Keep the final-pixel minimum of 0.5 while drawing in source space.
        max(0.5 / scale, renderStroke.averageWidth * style.lineWidthMultiplier)
      }

      func drawDot(
        at point: CGPoint,
        radius: CGFloat
      ) {
        context.fill(
          Path(
            ellipseIn: CGRect(
              x: point.x - radius,
              y: point.y - radius,
              width: radius * 2,
              height: radius * 2
            )
          ),
          with: .color(color)
        )
      }

      func drawFull(_ renderStroke: ChalkWritingRenderPlan.Stroke) {
        let lineWidth = sourceLineWidth(for: renderStroke)
        if renderStroke.rendersAsDot(at: 1) {
          drawDot(
            at: CGPoint(x: renderStroke.points[0].x, y: renderStroke.points[0].y),
            radius: CGFloat(lineWidth * 0.5)
          )
          return
        }
        guard let path = renderStroke.fullPath else { return }
        context.stroke(
          path,
          with: .color(color),
          style: StrokeStyle(
            lineWidth: CGFloat(lineWidth),
            lineCap: .round,
            lineJoin: .round
          )
        )
      }

      if frame.isPrefix {
        for index in frame.fullRange {
          drawFull(plan.strokes[index])
        }
      }

      func drawPartial(_ partial: ChalkWritingFramePlan.PartialStroke) {
        let renderStroke = plan.strokes[partial.index]
        let fraction = partial.fraction
        let lineWidth = sourceLineWidth(for: renderStroke)
        if frame.isPrefix {
          guard fraction > 0 else { return }
          if renderStroke.rendersAsDot(at: fraction) {
            drawDot(
              at: CGPoint(x: renderStroke.points[0].x, y: renderStroke.points[0].y),
              radius: CGFloat(lineWidth * 0.5)
            )
            return
          }
          let path: Path?
          if fraction >= 1 {
            path = renderStroke.fullPath
          } else {
            do {
              path = try renderStroke.path(upTo: fraction)
            } catch {
              preconditionFailure("validated writing prefix path failed: \(error)")
            }
          }
          guard let path else { return }
          context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(
              lineWidth: CGFloat(lineWidth),
              lineCap: .round,
              lineJoin: .round
            )
          )
        } else {
          guard fraction < 1 else { return }
          if renderStroke.points.count == 1 || renderStroke.length <= 0 {
            drawDot(
              at: CGPoint(x: renderStroke.points[0].x, y: renderStroke.points[0].y),
              radius: CGFloat(lineWidth * 0.5)
            )
            return
          }
          let path: Path?
          if fraction <= 0 {
            path = renderStroke.fullPath
          } else {
            do {
              path = try renderStroke.path(from: fraction)
            } catch {
              preconditionFailure("validated writing suffix path failed: \(error)")
            }
          }
          guard let path else { return }
          context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(
              lineWidth: CGFloat(lineWidth),
              lineCap: .round,
              lineJoin: .round
            )
          )
        }
      }

      if let partial = frame.partialStroke {
        drawPartial(partial)
      }

      // Suffix playback must paint the active stroke before its future full
      // strokes, matching the original ascending timeline order.
      if !frame.isPrefix {
        for index in frame.fullRange {
          drawFull(plan.strokes[index])
        }
      }
    }
    .modifier(
      ChalkConditionalSurfaceModifier(
        configuration: style.configuration,
        isEnabled: contactPlan == nil
      )
    )
    .accessibilityLabel("Chalk writing playback")
  }
}

private struct ChalkConditionalSurfaceModifier: ViewModifier {
  let configuration: WritingChalkConfiguration
  let isEnabled: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.chalkEffect(configuration)
    } else {
      content
    }
  }
}
