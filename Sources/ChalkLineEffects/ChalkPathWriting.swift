import SwiftUI

extension ChalkPathRenderPlan.Stroke: ChalkWritingTimedStroke {}

/// A SwiftUI view that writes or erases an exact `ChalkPathScene`.
///
/// Preparation performs XML-independent geometry validation, cubic conversion,
/// arc-length indexing, and timeline construction once. The mounted view only
/// selects precomputed slices and applies the existing chalk compositor.
public struct ChalkPathWriting: View {
  private let preparation: ChalkPathPreparation?
  private let renderPlan: ChalkPathRenderPlan?
  private let playbackIdentity: ChalkPathPlaybackIdentity?
  private let failureDescription: String?
  private let style: ChalkWritingStyle
  private let colorPolicy: ChalkPathColorPolicy
  private let animation: ChalkWritingAnimation
  private let motion: ChalkWritingMotionStyle
  private let fixedProgress: Double?
  private let onCompletion: (() -> Void)?

  public init(
    preparation: ChalkPathPreparation,
    style: ChalkWritingStyle = .chalk,
    colorPolicy: ChalkPathColorPolicy = .style,
    animation: ChalkWritingAnimation = .write,
    motion: ChalkWritingMotionStyle = .varied,
    progress: Double? = nil,
    onCompletion: (() -> Void)? = nil
  ) {
    self.style = style
    self.colorPolicy = colorPolicy
    self.animation = animation
    self.motion = motion
    self.onCompletion = onCompletion
    if let progress, !progress.isFinite || !(0...1).contains(progress) {
      self.preparation = nil
      self.renderPlan = nil
      self.playbackIdentity = nil
      self.failureDescription = ChalkLineEffectsError.invalidProgress(progress).localizedDescription
      self.fixedProgress = nil
      return
    }
    self.fixedProgress = progress
    self.preparation = preparation
    self.renderPlan = preparation.renderPlan
    self.playbackIdentity = ChalkPathPlaybackIdentity(
      preparation: preparation,
      plan: preparation.renderPlan,
      style: style,
      colorPolicy: colorPolicy,
      animation: animation,
      motion: motion
    )
    self.failureDescription = nil
  }

  var isShowingPreparationFailure: Bool {
    preparation == nil && failureDescription != nil
  }

  public var body: some View {
    Group {
      if let renderPlan, let playbackIdentity {
        if let fixedProgress {
          ChalkPathCanvas(
            plan: renderPlan,
            style: style,
            colorPolicy: colorPolicy,
            animation: animation,
            motion: motion,
            progress: fixedProgress
          )
        } else {
          ChalkPathTimeline(
            plan: renderPlan,
            style: style,
            colorPolicy: colorPolicy,
            animation: animation,
            motion: motion,
            onCompletion: onCompletion
          )
          .id(playbackIdentity)
        }
      } else {
        Text(failureDescription ?? "Unable to prepare chalk path")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Unable to prepare chalk path")
      }
    }
  }
}

struct ChalkPathPlaybackIdentity: Hashable {
  let sceneWidth: Double
  let sceneHeight: Double
  let strokeIDs: [String]
  let timelineStartTimes: [Double]
  let timelineEndTimes: [Double]
  let duration: Double
  let style: ChalkWritingStyle
  let colorPolicy: ChalkPathColorPolicy
  let animation: ChalkWritingAnimation
  let motion: ChalkWritingMotionStyle

  init(
    preparation: ChalkPathPreparation,
    plan: ChalkPathRenderPlan,
    style: ChalkWritingStyle,
    colorPolicy: ChalkPathColorPolicy,
    animation: ChalkWritingAnimation,
    motion: ChalkWritingMotionStyle
  ) {
    sceneWidth = preparation.scene.size.width
    sceneHeight = preparation.scene.size.height
    strokeIDs = plan.strokes.map { $0.timing.strokeID }
    timelineStartTimes = preparation.timeline.strokes.map(\.startTime)
    timelineEndTimes = preparation.timeline.strokes.map(\.endTime)
    duration = preparation.timeline.duration
    self.style = style
    self.colorPolicy = colorPolicy
    self.animation = animation
    self.motion = motion
  }
}

private struct ChalkPathTimeline: View {
  let plan: ChalkPathRenderPlan
  let style: ChalkWritingStyle
  let colorPolicy: ChalkPathColorPolicy
  let animation: ChalkWritingAnimation
  let motion: ChalkWritingMotionStyle
  let onCompletion: (() -> Void)?
  @State private var playback: ChalkWritingPlaybackState

  init(
    plan: ChalkPathRenderPlan,
    style: ChalkWritingStyle,
    colorPolicy: ChalkPathColorPolicy,
    animation: ChalkWritingAnimation,
    motion: ChalkWritingMotionStyle,
    onCompletion: (() -> Void)?
  ) {
    self.plan = plan
    self.style = style
    self.colorPolicy = colorPolicy
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
      ChalkPathCanvas(
        plan: plan,
        style: style,
        colorPolicy: colorPolicy,
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

private struct ChalkPathCanvas: View {
  let plan: ChalkPathRenderPlan
  let style: ChalkWritingStyle
  let colorPolicy: ChalkPathColorPolicy
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

      // Draw source-space paths under one frame transform. This preserves the
      // existing centered fit while avoiding a transformed Path allocation for
      // every visible stroke on every frame.
      context.translateBy(x: CGFloat(offsetX), y: CGFloat(offsetY))
      context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

      let styleColor = style.color.swiftUIColor
      let selectedColorPolicy = colorPolicy
      func resolvedColor(for stroke: ChalkPathRenderPlan.Stroke) -> Color {
        switch selectedColorPolicy {
        case .style:
          return styleColor
        case .source:
          return (stroke.style.color ?? style.color).swiftUIColor
        }
      }

      func sourceLineWidth(for renderStroke: ChalkPathRenderPlan.Stroke) -> Double {
        // Keep the final-pixel minimum of 0.5 while drawing in source space.
        max(0.5 / scale, renderStroke.style.width * style.lineWidthMultiplier)
      }

      func drawDot(at point: CGPoint, radius: CGFloat, strokeColor: Color) {
        context.fill(
          Path(
            ellipseIn: CGRect(
              x: point.x - radius,
              y: point.y - radius,
              width: radius * 2,
              height: radius * 2
            )
          ),
          with: .color(strokeColor)
        )
      }

      func drawFull(_ renderStroke: ChalkPathRenderPlan.Stroke) {
        let strokeColor = resolvedColor(for: renderStroke)
        let lineWidth = sourceLineWidth(for: renderStroke)
        if renderStroke.rendersAsDot {
          drawDot(
            at: CGPoint(x: renderStroke.startPoint.x, y: renderStroke.startPoint.y),
            radius: CGFloat(lineWidth * 0.5),
            strokeColor: strokeColor
          )
          return
        }
        context.stroke(
          renderStroke.fullPath,
          with: .color(strokeColor),
          style: StrokeStyle(
            lineWidth: CGFloat(lineWidth),
            lineCap: renderStroke.style.lineCap.swiftUIValue,
            lineJoin: renderStroke.style.lineJoin.swiftUIValue,
            miterLimit: CGFloat(renderStroke.style.miterLimit)
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
        let strokeColor = resolvedColor(for: renderStroke)
        let fraction = partial.fraction
        let lineWidth = sourceLineWidth(for: renderStroke)
        if frame.isPrefix {
          guard fraction > 0 else { return }
          if renderStroke.rendersAsDot {
            drawDot(
              at: CGPoint(x: renderStroke.startPoint.x, y: renderStroke.startPoint.y),
              radius: CGFloat(lineWidth * 0.5),
              strokeColor: strokeColor
            )
            return
          }
          let path = fraction >= 1 ? renderStroke.fullPath : renderStroke.path(upTo: fraction)
          guard let path else { return }
          context.stroke(
            path,
            with: .color(strokeColor),
            style: StrokeStyle(
              lineWidth: CGFloat(lineWidth),
              lineCap: renderStroke.style.lineCap.swiftUIValue,
              lineJoin: renderStroke.style.lineJoin.swiftUIValue,
              miterLimit: CGFloat(renderStroke.style.miterLimit)
            )
          )
        } else {
          guard fraction < 1 else { return }
          if renderStroke.rendersAsDot {
            drawDot(
              at: CGPoint(x: renderStroke.startPoint.x, y: renderStroke.startPoint.y),
              radius: CGFloat(lineWidth * 0.5),
              strokeColor: strokeColor
            )
            return
          }
          let path = fraction <= 0 ? renderStroke.fullPath : renderStroke.path(from: fraction)
          guard let path else { return }
          context.stroke(
            path,
            with: .color(strokeColor),
            style: StrokeStyle(
              lineWidth: CGFloat(lineWidth),
              lineCap: renderStroke.style.lineCap.swiftUIValue,
              lineJoin: renderStroke.style.lineJoin.swiftUIValue,
              miterLimit: CGFloat(renderStroke.style.miterLimit)
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
    .chalkEffect(style.configuration)
    .accessibilityLabel("Chalk path playback")
  }
}

extension ChalkPathLineCap {
  fileprivate var swiftUIValue: CGLineCap {
    switch self {
    case .butt: return .butt
    case .round: return .round
    case .square: return .square
    }
  }
}

extension ChalkPathLineJoin {
  fileprivate var swiftUIValue: CGLineJoin {
    switch self {
    case .miter: return .miter
    case .round: return .round
    case .bevel: return .bevel
    }
  }
}
