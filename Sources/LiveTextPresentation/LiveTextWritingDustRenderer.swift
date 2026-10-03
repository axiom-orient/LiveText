#if os(iOS)
import DustKit
import LiveTextLayout
import LiveTextSwiftUI
import LiveTextWritingUI
import SwiftUI

public struct InlineDustPresentationConfiguration {
  public let progress: CGFloat
  public let preset: DustPreset
  public let configuration: DustConfiguration
  public let transition: DustTransition
  public let layoutPolicy: DustLayoutPolicy

  public init(
    progress: CGFloat,
    preset: DustPreset = .softDust,
    configuration: DustConfiguration = .default,
    transition: DustTransition = .disintegrate,
    layoutPolicy: DustLayoutPolicy = .sourceBounds
  ) {
    self.progress = progress
    self.preset = preset
    self.configuration = configuration
    self.transition = transition
    self.layoutPolicy = layoutPolicy
  }
}

/// Convenience renderer for the common LiveText + DustKit composition.
///
/// LiveText remains the authority for document preparation, layout, reveal, material, and
/// accessibility. DustKit receives only a single terminal raster snapshot built from the supplied
/// `sourcePhase` visual revision.
@MainActor
public struct LiveTextWritingDustRenderer: View {
  private struct Revision: Hashable {
    let contentID: ObjectIdentifier
    let viewport: InlineRenderViewport
    let configuration: InlineWritingConfiguration
    let sourcePhaseBits: UInt64
    let customIdentity: AnyHashable?
  }

  private let content: InlineSwiftUIRenderContent
  private let livePhase: InlineRenderRevealPhase
  private let sourcePhase: InlineRenderRevealPhase
  private let viewport: InlineRenderViewport
  private let configuration: InlineWritingConfiguration
  private let terminal: InlineDustPresentationConfiguration?
  private let terminalBlendMode: InlineTerminalDustBlendMode
  private let sourceScale: CGFloat
  private let sourceDebounce: Duration
  private let semanticLabel: String?
  private let sourceIdentity: AnyHashable?
  private let onSourceFailure: (@MainActor (String) -> Void)?
  private let onDustFailure: (@MainActor (DustRenderingError) -> Void)?
  private let onDustPresented: (@MainActor () -> Void)?

  public init(
    content: InlineSwiftUIRenderContent,
    livePhase: InlineRenderRevealPhase = .complete,
    sourcePhase: InlineRenderRevealPhase = .complete,
    viewport: InlineRenderViewport,
    configuration: InlineWritingConfiguration = .default,
    terminal: InlineDustPresentationConfiguration? = nil,
    terminalBlendMode: InlineTerminalDustBlendMode = .overlay(),
    sourceScale: CGFloat = 1,
    sourceDebounce: Duration = .milliseconds(120),
    semanticLabel: String? = nil,
    sourceIdentity: AnyHashable? = nil,
    onSourceFailure: (@MainActor (String) -> Void)? = nil,
    onDustFailure: (@MainActor (DustRenderingError) -> Void)? = nil,
    onDustPresented: (@MainActor () -> Void)? = nil
  ) {
    self.content = content
    self.livePhase = livePhase
    self.sourcePhase = sourcePhase
    self.viewport = viewport
    self.configuration = configuration
    self.terminal = terminal
    self.terminalBlendMode = terminalBlendMode
    self.sourceScale = sourceScale
    self.sourceDebounce = sourceDebounce
    self.semanticLabel = semanticLabel
    self.sourceIdentity = sourceIdentity
    self.onSourceFailure = onSourceFailure
    self.onDustFailure = onDustFailure
    self.onDustPresented = onDustPresented
  }

  public var body: some View {
    if let terminal {
      InlineTerminalDustSurface(
        revision: AnyHashable(revision),
        sourceSize: CGSize(width: viewport.width, height: viewport.height),
        sourceScale: sourceScale,
        semanticLabel: semanticLabel,
        debounce: sourceDebounce,
        progress: terminal.progress,
        preset: terminal.preset,
        configuration: terminal.configuration,
        transition: terminal.transition,
        layoutPolicy: terminal.layoutPolicy,
        blendMode: terminalBlendMode,
        onSourceFailure: onSourceFailure,
        onDustFailure: onDustFailure,
        onDustPresented: onDustPresented
      ) {
        LiveTextWritingRenderer(
          content: content,
          phase: livePhase,
          viewport: viewport,
          configuration: configuration
        )
      } sourceContent: {
        LiveTextWritingRenderer(
          content: content,
          phase: sourcePhase,
          viewport: viewport,
          configuration: configuration
        )
      }
    } else {
      LiveTextWritingRenderer(
        content: content,
        phase: livePhase,
        viewport: viewport,
        configuration: configuration
      )
    }
  }

  private var revision: Revision {
    Revision(
      contentID: ObjectIdentifier(content),
      viewport: viewport,
      configuration: configuration,
      sourcePhaseBits: sourcePhase.bitPattern,
      customIdentity: sourceIdentity
    )
  }
}

private extension InlineRenderRevealPhase {
  var bitPattern: UInt64 {
    rawValue.bitPattern
  }
}
#endif
