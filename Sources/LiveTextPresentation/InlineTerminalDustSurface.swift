#if os(iOS)
import DustKit
import SwiftUI

public enum InlineTerminalDustBlendMode: Hashable, Sendable {
  case overlay(liveOpacity: Double = 1, dustOpacity: Double = 1)
  case replaceWhenReady(dustOpacity: Double = 1)
  case dustOnly(dustOpacity: Double = 1)
}

/// Generic presentation wrapper that keeps LiveText (or any other composed SwiftUI surface)
/// authoritative, while optionally handing one rendered visual revision to DustKit.
///
/// This is intentionally a composition boundary rather than a second layout engine:
/// - `liveContent` remains the semantic/accessibility authority in every blend mode.
/// - `.overlay` keeps the live visual and direct hit-testing surface mounted.
/// - `.replaceWhenReady` and `.dustOnly` may replace the live visual/direct-touch surface,
///   but expose `liveContent` through SwiftUI's accessibility representation instead of
///   degrading the document to one raster label.
/// - `sourceContent` is rasterized only when the supplied revision changes.
/// - DustKit consumes the raster result and never re-lays out text.
@MainActor
public struct InlineTerminalDustSurface<LiveContent: View, SourceContent: View>: View {
  private let liveContent: LiveContent
  private let sourceContent: SourceContent
  private let revision: AnyHashable
  private let sourceSize: CGSize
  private let sourceScale: CGFloat
  private let semanticLabel: String?
  private let debounce: Duration
  private let progress: CGFloat
  private let preset: DustPreset
  private let configuration: DustConfiguration
  private let transition: DustTransition
  private let layoutPolicy: DustLayoutPolicy
  private let blendMode: InlineTerminalDustBlendMode
  private let onSourceFailure: (@MainActor (String) -> Void)?
  private let onDustFailure: (@MainActor (DustRenderingError) -> Void)?
  private let onDustPresented: (@MainActor () -> Void)?

  @StateObject private var controller = InlineTerminalDustSourceController()

  public init(
    revision: AnyHashable,
    sourceSize: CGSize,
    sourceScale: CGFloat = 1,
    semanticLabel: String? = nil,
    debounce: Duration = .milliseconds(120),
    progress: CGFloat,
    preset: DustPreset = .softDust,
    configuration: DustConfiguration = .default,
    transition: DustTransition = .disintegrate,
    layoutPolicy: DustLayoutPolicy = .sourceBounds,
    blendMode: InlineTerminalDustBlendMode = .overlay(),
    onSourceFailure: (@MainActor (String) -> Void)? = nil,
    onDustFailure: (@MainActor (DustRenderingError) -> Void)? = nil,
    onDustPresented: (@MainActor () -> Void)? = nil,
    @ViewBuilder liveContent: () -> LiveContent,
    @ViewBuilder sourceContent: () -> SourceContent
  ) {
    self.liveContent = liveContent()
    self.sourceContent = sourceContent()
    self.revision = revision
    self.sourceSize = sourceSize
    self.sourceScale = sourceScale
    self.semanticLabel = semanticLabel
    self.debounce = debounce
    self.progress = progress.isFinite ? min(max(progress, 0), 1) : 0
    self.preset = preset
    self.configuration = configuration
    self.transition = transition
    self.layoutPolicy = layoutPolicy
    self.blendMode = blendMode
    self.onSourceFailure = onSourceFailure
    self.onDustFailure = onDustFailure
    self.onDustPresented = onDustPresented
  }

  public var body: some View {
    if showLiveContent {
      terminalStack
    } else {
      terminalStack
        .accessibilityRepresentation {
          liveContent
        }
    }
  }

  @ViewBuilder
  private var terminalStack: some View {
    ZStack {
      if showLiveContent {
        liveContent.opacity(liveOpacity)
      }
      if let source = controller.state.source, showDustContent {
        DustView(
          source: source,
          progress: progress,
          preset: preset,
          configuration: configuration,
          transition: transition,
          layoutPolicy: layoutPolicy,
          onFailure: onDustFailure,
          onPresented: onDustPresented
        )
        .opacity(dustOpacity)
        // Dust is only a visual projection at this composition boundary.
        // The live semantic hierarchy above, or its accessibility
        // representation when visually replaced, remains authoritative.
        .accessibilityHidden(true)
      }
    }
    .onAppear { refreshTerminalSource() }
    .onChangeCompatible(of: refreshToken) { _ in refreshTerminalSource() }
    .onChangeCompatible(of: controller.lastErrorMessage) { message in
      guard let message else { return }
      onSourceFailure?(message)
    }
    .onDisappear { controller.cancel() }
  }

  private var refreshToken: RefreshToken {
    RefreshToken(
      revision: revision,
      width: sourceSize.width,
      height: sourceSize.height,
      scale: sourceScale,
      semanticLabel: semanticLabel
    )
  }

  private var showLiveContent: Bool {
    switch blendMode {
    case .overlay:
      return true
    case .replaceWhenReady:
      return controller.state.source == nil
    case .dustOnly:
      return false
    }
  }

  private var showDustContent: Bool {
    controller.state.source != nil
  }

  private var liveOpacity: Double {
    switch blendMode {
    case .overlay(let liveOpacity, _):
      return liveOpacity
    case .replaceWhenReady, .dustOnly:
      return 1
    }
  }

  private var dustOpacity: Double {
    switch blendMode {
    case .overlay(_, let dustOpacity), .replaceWhenReady(let dustOpacity), .dustOnly(let dustOpacity):
      return dustOpacity
    }
  }

  private func refreshTerminalSource() {
    controller.prepare(
      revision: revision,
      size: sourceSize,
      scale: sourceScale,
      semanticLabel: semanticLabel,
      debounce: debounce
    ) {
      sourceContent
    }
  }
}

private struct RefreshToken: Hashable {
  let revision: AnyHashable
  let width: CGFloat
  let height: CGFloat
  let scale: CGFloat
  let semanticLabel: String?
}
#endif
