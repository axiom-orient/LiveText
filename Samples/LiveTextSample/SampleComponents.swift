import Foundation
import Observation
import SwiftUI

enum SampleCopy {
  static let writingKoreanPrefix = "한글 손글씨는 \""
  static let writingKoreanGlyph = "\u{D68D}"
  static let writingKoreanSuffix = "\"을 따라 \"씁\"니다."
  static let writingMessage = writingKoreanPrefix + writingKoreanGlyph + writingKoreanSuffix
  static let writingEnglishMessage = "LiveText follows every stroke."
}

@MainActor
@Observable
final class SampleTheme {
  let background = Color(red: 0.055, green: 0.063, blue: 0.11)
  let surface = Color.white.opacity(0.075)
  let elevatedSurface = Color.white.opacity(0.12)
  let primaryText = Color.white
  let secondaryText = Color.white.opacity(0.72)
  let renderSurface = Color(red: 0.018, green: 0.024, blue: 0.045)
  let renderSurfaceBorder = Color.white.opacity(0.18)
  let accent = Color(red: 0.45, green: 0.82, blue: 0.98)
  let secondaryAccent = Color(red: 0.98, green: 0.68, blue: 0.34)
  let success = Color(red: 0.40, green: 0.88, blue: 0.63)
}

/// Sample-only host playback. LiveText renderers remain clock-free; this
/// controller owns the repeat policy. TimelineView samples the clock at the
/// display cadence instead of publishing a model mutation for every frame.
struct SamplePlaybackSnapshot: Equatable, Sendable {
  let phase: Double
  let cycle: Int
  let isPlaying: Bool
}

@MainActor
@Observable
final class SamplePlayback {
  private(set) var phase = 0.0
  private(set) var isPlaying = false
  private(set) var cycle = 0
  private(set) var duration: Double
  var repeats = true

  @ObservationIgnored private var anchorDate = Date()
  @ObservationIgnored private var anchorPhase = 0.0
  @ObservationIgnored private(set) var reducedMotion = false

  init(duration: Double) {
    precondition(duration.isFinite && duration > 0, "sample playback duration must be positive")
    self.duration = duration
  }

  func setDuration(_ duration: Double, restart: Bool = true) {
    guard duration.isFinite, duration > 0 else { return }
    let snapshot = snapshot(at: Date())
    let wasPlaying = snapshot.isPlaying
    self.duration = duration
    phase = snapshot.phase
    cycle = snapshot.cycle
    if wasPlaying {
      play(restarting: restart)
    }
  }

  func play(restarting: Bool = false) {
    guard !reducedMotion else {
      phase = 1
      isPlaying = false
      return
    }
    let current = snapshot(at: Date())
    let startPhase = restarting || current.phase >= 1 ? 0 : current.phase
    anchorDate = Date()
    anchorPhase = startPhase
    phase = startPhase
    if restarting { cycle = 0 }
    isPlaying = true
  }

  func pause() {
    let current = snapshot(at: Date())
    phase = current.phase
    cycle = current.cycle
    anchorPhase = phase
    anchorDate = Date()
    isPlaying = false
  }

  func replay() {
    play(restarting: true)
  }

  func setPhase(_ phase: Double) {
    guard phase.isFinite else { return }
    isPlaying = false
    anchorDate = Date()
    self.phase = min(1, max(0, phase))
    anchorPhase = self.phase
    cycle = 0
  }

  func setReducedMotion(_ enabled: Bool) {
    guard reducedMotion != enabled else { return }
    reducedMotion = enabled
    if enabled {
      pause()
      phase = 1
      anchorPhase = 1
    }
  }

  func snapshot(at date: Date) -> SamplePlaybackSnapshot {
    guard isPlaying, !reducedMotion else {
      return SamplePlaybackSnapshot(phase: phase, cycle: cycle, isPlaying: false)
    }

    let elapsed = max(0, date.timeIntervalSince(anchorDate))
    let absoluteProgress = anchorPhase * duration + elapsed
    if repeats {
      let completedCycles = max(0, Int(floor(absoluteProgress / duration)))
      let remainder = absoluteProgress.truncatingRemainder(dividingBy: duration)
      return SamplePlaybackSnapshot(
        phase: min(1, max(0, remainder / duration)),
        cycle: completedCycles,
        isPlaying: true)
    }

    return SamplePlaybackSnapshot(
      phase: min(1, max(0, absoluteProgress / duration)),
      cycle: min(1, max(0, Int(floor(absoluteProgress / duration)))),
      isPlaying: absoluteProgress < duration)
  }

  var timelinePaused: Bool {
    !snapshot(at: Date()).isPlaying
  }
}

struct SamplePlaybackBar: View {
  @Environment(SampleTheme.self) private var theme
  let playback: SamplePlayback

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: playback.timelinePaused)) {
      context in
      SamplePlaybackBarContent(
        playback: playback,
        snapshot: playback.snapshot(at: context.date),
        theme: theme)
    }
  }
}

private struct SamplePlaybackBarContent: View {
  @Bindable var playback: SamplePlayback
  let snapshot: SamplePlaybackSnapshot
  let theme: SampleTheme

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Button {
          snapshot.isPlaying ? playback.pause() : playback.play()
        } label: {
          Label(
            snapshot.isPlaying ? "Pause" : "Play",
            systemImage: snapshot.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.borderedProminent)

        Button("Replay", systemImage: "arrow.clockwise") {
          playback.replay()
        }
        .buttonStyle(.bordered)

        Spacer(minLength: 0)

        Text("cycle \(snapshot.cycle)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(theme.secondaryText)
      }

      Toggle("Auto-repeat", isOn: $playback.repeats)
        .font(.subheadline)
        .disabled(playback.reducedMotion)
        .accessibilityHint(
          playback.reducedMotion
            ? "Disabled while Reduce Motion is enabled"
            : "Repeats the animation after it completes")

      HStack(spacing: 10) {
        Slider(
          value: Binding(
            get: { snapshot.phase },
            set: { playback.setPhase($0) }
          ),
          in: 0...1
        ) {
          Text("Animation progress")
        }
        Text(String(format: "%.2f", snapshot.phase))
          .font(.caption.monospacedDigit())
          .frame(width: 42, alignment: .trailing)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Animation progress")
      .accessibilityValue(String(format: "%.0f percent", snapshot.phase * 100))
    }
    .padding(12)
    .background(theme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .stroke(theme.renderSurfaceBorder, lineWidth: 1)
    }
  }
}

struct SamplePlaybackSurface<Content: View>: View {
  @Environment(SampleTheme.self) private var theme
  let playback: SamplePlayback
  let content: (SamplePlaybackSnapshot) -> Content

  init(
    playback: SamplePlayback,
    @ViewBuilder content: @escaping (SamplePlaybackSnapshot) -> Content
  ) {
    self.playback = playback
    self.content = content
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: playback.timelinePaused)) {
      context in
      let snapshot = playback.snapshot(at: context.date)
      VStack(alignment: .leading, spacing: 12) {
        SamplePlaybackBarContent(
          playback: playback,
          snapshot: snapshot,
          theme: theme)
        content(snapshot)
      }
    }
  }
}

private struct SamplePlaybackLifecycle: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let playback: SamplePlayback

  func body(content: Content) -> some View {
    content
      .task {
        playback.setReducedMotion(reduceMotion)
        if !reduceMotion { playback.play(restarting: true) }
      }
      .onChange(of: reduceMotion) { _, value in
        playback.setReducedMotion(value)
        if !value { playback.replay() }
      }
      .onDisappear { playback.pause() }
  }
}

extension View {
  func samplePlaybackLifecycle(_ playback: SamplePlayback) -> some View {
    modifier(SamplePlaybackLifecycle(playback: playback))
  }
}

struct SampleFeatureCard<Destination: View>: View {
  @Environment(SampleTheme.self) private var theme
  let icon: String
  let title: String
  let detail: String
  let tint: Color
  let destination: Destination

  init(
    icon: String,
    title: String,
    detail: String,
    tint: Color,
    @ViewBuilder destination: () -> Destination
  ) {
    self.icon = icon
    self.title = title
    self.detail = detail
    self.tint = tint
    self.destination = destination()
  }

  var body: some View {
    NavigationLink { destination } label: {
      VStack(alignment: .leading, spacing: 12) {
        Image(systemName: icon)
          .font(.title2.weight(.semibold))
          .foregroundStyle(tint)
          .frame(width: 42, height: 42)
          .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
          .accessibilityHidden(true)

        Text(title)
          .font(.headline)
          .foregroundStyle(theme.primaryText)
          .multilineTextAlignment(.leading)

        Text(detail)
          .font(.caption)
          .foregroundStyle(theme.secondaryText)
          .multilineTextAlignment(.leading)
          .lineLimit(3)
      }
      .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
      .padding(16)
      .background(theme.surface, in: RoundedRectangle(cornerRadius: 22))
      .overlay {
        RoundedRectangle(cornerRadius: 22)
          .stroke(theme.renderSurfaceBorder, lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 22))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityElement(children: .combine)
    .accessibilityHint("Opens this LiveText sample")
  }
}

struct SampleHero: View {
  @Environment(SampleTheme.self) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Text("LiveText")
            .font(.system(size: 38, weight: .bold, design: .rounded))
          Text("A playground for semantic text, handwriting, motion, and effects.")
            .font(.subheadline)
            .foregroundStyle(theme.secondaryText)
        }
        Spacer(minLength: 12)
        Image(systemName: "text.magnifyingglass")
          .font(.title2.weight(.semibold))
          .foregroundStyle(theme.accent)
          .frame(width: 48, height: 48)
          .background(theme.accent.opacity(0.16), in: Circle())
          .accessibilityHidden(true)
      }

      Text("Prepare once. Explore every renderer.")
        .font(.headline)
        .foregroundStyle(theme.secondaryAccent)
    }
    .padding(20)
    .background(
      LinearGradient(
        colors: [theme.accent.opacity(0.22), theme.secondaryAccent.opacity(0.12)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ),
      in: RoundedRectangle(cornerRadius: 28)
    )
  }
}
