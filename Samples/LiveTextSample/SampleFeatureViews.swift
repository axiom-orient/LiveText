import ChalkLineEffects
import LiveTextApple
import LiveTextLayout
import LiveTextWritingUI
import SwiftUI

struct SampleRootView: View {
  @Environment(SampleModel.self) private var model
  @Environment(SampleTheme.self) private var theme

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        SampleHero()

        HStack(spacing: 12) {
          Image(systemName: model.setupError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(model.setupError == nil ? theme.success : .orange)
          VStack(alignment: .leading, spacing: 3) {
            Text(model.setupError == nil ? "Sample is ready" : "Sample needs attention")
              .font(.headline)
            Text(model.setupError == nil
              ? "All prepared bundles and renderer adapters are available."
              : model.setupError ?? "Unknown setup error")
              .font(.caption)
              .foregroundStyle(theme.secondaryText)
              .lineLimit(2)
          }
          Spacer(minLength: 0)
          if model.setupError != nil {
            Button("Retry") { model.retrySetup() }
              .buttonStyle(.bordered)
          }
        }
        .padding(14)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 18))

        VStack(alignment: .leading, spacing: 4) {
          Text("Explore the pipeline")
            .font(.title2.bold())
          Text("Each case isolates one LiveText capability while keeping the same prepared geometry.")
            .font(.subheadline)
            .foregroundStyle(theme.secondaryText)
        }

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 155), spacing: 12)],
          spacing: 12
        ) {
          SampleFeatureCard(
            icon: "pencil.and.outline",
            title: "Writing + materials",
            detail: "Auto-loop reveal with seven native writing materials.",
            tint: theme.accent
          ) { WritingMaterialCase() }

          SampleFeatureCard(
            icon: "square.split.2x1",
            title: "Renderer parity",
            detail: "SwiftUI and Canvas share one immutable render plan.",
            tint: theme.secondaryAccent
          ) { RendererParityCase() }

          SampleFeatureCard(
            icon: "sparkles",
            title: "Expressive motion",
            detail: "Loop squash, stretch, tilt, and overshoot without relayout.",
            tint: .pink
          ) { ExpressiveMotionCase() }

          SampleFeatureCard(
            icon: "arrow.left.and.right",
            title: "Responsive reflow",
            detail: "Reuse preparation and rebuild only layout on width changes.",
            tint: .mint
          ) { ResponsiveLayoutCase() }

          SampleFeatureCard(
            icon: "rectangle.3.group",
            title: "Mixed inline flow",
            detail: "Text, images, SVG, and host exclusions in one flow.",
            tint: .orange
          ) { MixedFlowCase() }

          SampleFeatureCard(
            icon: "wand.and.stars",
            title: "SVG composition",
            detail: "Loop artwork, erase masks, and combined composition.",
            tint: .purple
          ) { SVGCompositionCase() }

          SampleFeatureCard(
            icon: "text.append",
            title: "Append stream",
            detail: "Commit sealed atoms with sequence and revision authority.",
            tint: .teal
          ) { AppendStreamCase() }

          SampleFeatureCard(
            icon: "paintbrush.pointed",
            title: "Standalone chalk",
            detail: "Apply chalk texture to ordinary SwiftUI content.",
            tint: .yellow
          ) { StandaloneChalkCase() }

          SampleFeatureCard(
            icon: "aqi.medium",
            title: "Dust terminal effect",
            detail: "Auto-loop disintegrate and assemble from one raster source.",
            tint: .indigo
          ) { DustKitScene() }
        }

        Text("Input → Layout → Render → Material → Effect → Output")
          .font(.caption.monospaced())
          .foregroundStyle(theme.secondaryText)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.top, 4)
      }
      .padding(20)
    }
    .foregroundStyle(theme.primaryText)
    .scrollIndicators(.hidden)
    .background(theme.background.ignoresSafeArea())
    .preferredColorScheme(.dark)
    .navigationTitle("LiveText")
    .navigationBarTitleDisplayMode(.large)
  }
}

private enum SampleMaterial: String, CaseIterable, Identifiable {
  case chalk
  case brush
  case pen
  case ink
  case marker
  case knockout
  case coloredPencil

  var id: String { rawValue }

  var title: String {
    switch self {
    case .chalk: return "Chalk"
    case .brush: return "Brush"
    case .pen: return "Pen"
    case .ink: return "Ink"
    case .marker: return "Marker"
    case .knockout: return "Knockout"
    case .coloredPencil: return "Pencil"
    }
  }

  var configuration: InlineWritingConfiguration {
    switch self {
    case .chalk: return .chalk
    case .brush:
      return InlineWritingConfiguration(effect: .brush(.default), color: .white)
    case .pen: return .pen
    case .ink:
      return InlineWritingConfiguration(effect: .ink(.default), color: .white)
    case .marker: return .marker
    case .knockout: return .knockout
    case .coloredPencil: return .coloredPencil
    }
  }
}

private enum SampleRenderer: String, CaseIterable, Identifiable {
  case swiftUI = "SwiftUI"
  case canvas = "Canvas"
  var id: String { rawValue }
}

private struct WritingMaterialCase: View {
  @Environment(SampleModel.self) private var model
  @State private var playback = SamplePlayback(duration: 2.8)
  @State private var material: SampleMaterial = .chalk

  var body: some View {
    SamplePage(
      title: "Writing + materials",
      explanation: "Layout and reveal stay fixed. Only the material selection changes."
    ) {
      if let bundle = model.writingBundle {
        Picker("Material", selection: $material) {
          ForEach(SampleMaterial.allCases) { value in
            Text(value.title).tag(value)
          }
        }
        .pickerStyle(.menu)

        SamplePlaybackSurface(playback: playback) { snapshot in
          LiveTextWritingRenderer(
            content: bundle.swiftUI,
            phase: revealPhase(snapshot.phase),
            viewport: bundle.viewport,
            configuration: material.configuration
          )
          .sampleSurface(bundle.viewport)
        }
      } else {
        SampleSetupError()
      }
    }
    .samplePlaybackLifecycle(playback)
  }
}

private struct RendererParityCase: View {
  @Environment(SampleModel.self) private var model
  @Environment(SampleTheme.self) private var theme
  @State private var progress = 1.0
  @State private var lastHit = "Tap either surface"

  var body: some View {
    SamplePage(
      title: "Renderer parity",
      explanation: "Both adapters receive the same render plan, reveal phase, viewport, and material."
    ) {
      Slider(value: $progress, in: 0...1)
      Text(lastHit).font(.caption.monospaced()).foregroundStyle(theme.secondaryText)

      if let bundle = model.writingBundle {
        let swiftUIRenderer = InlineSwiftUIRenderer(
          content: bundle.swiftUI,
          phase: revealPhase(progress),
          viewport: bundle.viewport,
          material: .chalk(.fineLine))
        let canvasRenderer = InlineCanvasRenderer(
          content: bundle.canvas,
          phase: revealPhase(progress),
          viewport: bundle.viewport,
          material: .chalk(.fineLine))

        VStack(alignment: .leading, spacing: 6) {
          Text("SwiftUI").font(.caption.bold())
          swiftUIRenderer
            .sampleSurface(bundle.viewport)
            .contentShape(Rectangle())
            .onTapGesture { point in
              lastHit = describeHit(swiftUIRenderer.activate(
                atViewportPoint: hitPoint(point)))
            }
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Canvas").font(.caption.bold())
          canvasRenderer
            .sampleSurface(bundle.viewport)
            .contentShape(Rectangle())
            .onTapGesture { point in
              lastHit = describeHit(canvasRenderer.activate(
                atViewportPoint: hitPoint(point)))
            }
        }
      } else {
        SampleSetupError()
      }
    }
  }
}

private enum SampleMotion: String, CaseIterable, Identifiable {
  case happy
  case curious
  case surprised
  case thinking
  case excited

  var id: String { rawValue }

  var title: String {
    switch self {
    case .happy: return "Happy"
    case .curious: return "Curious"
    case .surprised: return "Surprised"
    case .thinking: return "Thinking"
    case .excited: return "Excited"
    }
  }

  var motion: InlineMotionConfiguration {
    switch self {
    case .happy: return .happy
    case .curious: return .curious
    case .surprised: return .surprised
    case .thinking: return .thinking
    case .excited: return .excited
    }
  }

  var duration: Double {
    switch self {
    case .happy: return 0.72
    case .curious: return 0.90
    case .surprised: return 0.56
    case .thinking: return 1.08
    case .excited: return 0.70
    }
  }
}

private struct ExpressiveMotionCase: View {
  @Environment(SampleModel.self) private var model
  @State private var motion: SampleMotion = .excited
  @State private var renderer: SampleRenderer = .swiftUI
  @State private var playback = SamplePlayback(duration: SampleMotion.excited.duration)

  var body: some View {
    SamplePage(
      title: "Expressive motion",
      explanation:
        "Presentation-only motion adds grounded squash/stretch, anticipation, overshoot, semantic staggering, and tilt. "
        + "Source identity, layout, hit geometry, and accessibility remain canonical; Reduce Motion suppresses spatial transforms."
    ) {
      Picker("Expression", selection: $motion) {
        ForEach(SampleMotion.allCases) { value in
          Text(value.title).tag(value)
        }
      }
      .pickerStyle(.segmented)

      Picker("Renderer", selection: $renderer) {
        ForEach(SampleRenderer.allCases) { value in
          Text(value.rawValue).tag(value)
        }
      }
      .pickerStyle(.segmented)

      if let bundle = model.writingBundle {
        SamplePlaybackSurface(playback: playback) { snapshot in
          switch renderer {
          case .swiftUI:
            LiveTextWritingRenderer(
              content: bundle.swiftUI,
              phase: .complete,
              viewport: bundle.viewport,
              configuration: .ink,
              motion: motion.motion,
              motionPhase: motionPhase(snapshot.phase)
            )
            .sampleSurface(bundle.viewport)
          case .canvas:
            LiveTextCanvasWritingRenderer(
              content: bundle.canvas,
              phase: .complete,
              viewport: bundle.viewport,
              configuration: .ink,
              motion: motion.motion,
              motionPhase: motionPhase(snapshot.phase)
            )
            .sampleSurface(bundle.viewport)
          }
        }
      } else {
        SampleSetupError()
      }
    }
    .samplePlaybackLifecycle(playback)
    .onChange(of: motion) { _, value in
      playback.setDuration(value.duration)
      playback.play(restarting: true)
    }
  }
}

private struct ResponsiveLayoutCase: View {
  @Environment(SampleModel.self) private var model
  @Environment(SampleTheme.self) private var theme
  @State private var requestedWidth = 260.0
  @State private var bundle: SampleRenderBundle?
  @State private var error: String?

  var body: some View {
    SamplePage(
      title: "Responsive reflow",
      explanation: "Preparation and reveal schedule are reused. A width change rebuilds only layout and render projection."
    ) {
      HStack {
        Slider(value: $requestedWidth, in: 180...340, step: 10)
        Text("\(Int(requestedWidth)) pt").monospacedDigit().frame(width: 64)
      }
      Button("Apply width") { applyWidth() }
        .buttonStyle(.borderedProminent)

      if let bundle = bundle ?? model.writingBundle {
        InlineCanvasRenderer(
          content: bundle.canvas,
          phase: .complete,
          viewport: bundle.viewport,
          material: .chalk(.dryBrush)
        )
        .sampleSurface(bundle.viewport)
        Text("lines: \(bundle.layout.lines.count) · viewport: \(Int(bundle.viewport.width))×\(Int(bundle.viewport.height))")
          .font(.caption.monospaced())
          .foregroundStyle(theme.secondaryText)
      }
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
    .onAppear { applyWidth() }
  }

  private func applyWidth() {
    do {
      bundle = try model.reflowWritingBundle(width: requestedWidth)
      error = nil
    } catch {
      self.error = String(describing: error)
    }
  }
}

private struct MixedFlowCase: View {
  @Environment(SampleModel.self) private var model
  @Environment(SampleTheme.self) private var theme
  @State private var layoutMode: SampleCompositionLayoutMode = .inline

  var body: some View {
    SamplePage(
      title: "Mixed inline flow",
      explanation:
        "Inline preserves ordinary media flow. Magazine projects host media into the same exclusion solver so text can wrap across multiple rows."
    ) {
      Picker("Flow style", selection: $layoutMode) {
        ForEach(SampleCompositionLayoutMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      if layoutMode == .inline {
        Button("Move exclusions") { model.toggleCompositionPosition() }
          .buttonStyle(.borderedProminent)
      }

      if let bundle = model.compositionBundle(for: layoutMode) {
        ZStack(alignment: .topLeading) {
          InlineCanvasRenderer(
            content: bundle.canvas,
            phase: .complete,
            viewport: bundle.viewport,
            material: .none)

          if let photo = bundle.photoExclusion, let image = bundle.thumbnail {
            Image(uiImage: image)
              .resizable()
              .scaledToFill()
              .frame(width: CGFloat(photo.width), height: CGFloat(photo.height))
              .clipped()
              .offset(x: CGFloat(photo.x), y: CGFloat(photo.y))
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }

          if let button = bundle.buttonExclusion {
            Button("Host") {}
              .buttonStyle(.borderedProminent)
              .frame(width: CGFloat(button.width), height: CGFloat(button.height))
              .offset(x: CGFloat(button.x), y: CGFloat(button.y))
          }

          if let image = bundle.thumbnail {
            magazineMedia(bundle.magazineMinimumXMedia, image: image)
            magazineMedia(bundle.magazineMaximumXMedia, image: image)
          }
        }
        .sampleSurface(bundle.viewport)
        Text(
          layoutMode == .inline
            ? "position: \(model.compositionPosition.title)"
            : "media: minX / maxX · multi-line text flow"
        )
        .font(.caption.monospaced())
        .foregroundStyle(theme.secondaryText)
      } else {
        SampleSetupError()
      }
    }
  }

  @ViewBuilder
  private func magazineMedia(_ rect: InlineFlowRect?, image: UIImage) -> some View {
    if let rect {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: CGFloat(rect.width), height: CGFloat(rect.height))
        .clipped()
        .offset(x: CGFloat(rect.x), y: CGFloat(rect.y))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}

private struct SVGCompositionCase: View {
  @Environment(SampleModel.self) private var model
  @State private var mode: SampleSVGMode = .combined
  @State private var playback = SamplePlayback(duration: 2.6)

  var body: some View {
    SamplePage(
      title: "SVG composition",
      explanation: "The same SVG asset can be visible artwork, an erase mask targeting an image, or both."
    ) {
      Picker("Composition", selection: $mode) {
        ForEach(SampleSVGMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      if let bundle = model.svgBundle(for: mode) {
        SamplePlaybackSurface(playback: playback) { snapshot in
          InlineSwiftUIRenderer(
            content: bundle.swiftUI,
            phase: revealPhase(snapshot.phase),
            viewport: bundle.viewport,
            material: .chalk(.fineLine)
          )
          .sampleSurface(bundle.viewport)
        }
      } else {
        SampleSetupError()
      }
    }
    .samplePlaybackLifecycle(playback)
  }
}

private struct StandaloneChalkCase: View {
  @State private var rough = false

  var body: some View {
    SamplePage(
      title: "Standalone chalk",
      explanation: "ChalkLineEffects can texture ordinary SwiftUI content. It changes paint only; it does not own LiveText semantics or layout."
    ) {
      Toggle("Dry brush", isOn: $rough)
      Text("CHALK SURFACE")
        .font(.system(size: 42, weight: .black, design: .rounded))
        .padding(24)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
        .chalkEffect(rough ? ChalkMaterial.dryBrush : ChalkMaterial.fineLine)
        .background(.black, in: RoundedRectangle(cornerRadius: 12))
    }
  }
}

private struct AppendStreamCase: View {
  @Environment(SampleModel.self) private var model

  var body: some View {
    SamplePage(
      title: "Append stream",
      explanation: "The reducer owns sequence/revision state. The Apple session publishes renderer-ready snapshots."
    ) {
      if let stream = model.stream {
        AppendStreamBody(stream: stream, restart: model.restartStream)
          .id(ObjectIdentifier(stream))
      } else {
        SampleSetupError()
      }
    }
  }
}

private struct AppendStreamBody: View {
  @Environment(SampleTheme.self) private var theme
  @ObservedObject var stream: SampleModel.SampleStream
  let restart: () -> Void

  var body: some View {
    HStack {
      Button("Next atom") { stream.sendNext() }
        .buttonStyle(.borderedProminent)
        .disabled(stream.isFinished)
      Button("Restart", action: restart).buttonStyle(.bordered)
    }

    Text(stream.headline)
      .font(.caption.monospaced())
      .foregroundStyle(theme.secondaryText)

    switch Result(catching: { try InlineRenderViewport.wholeLayout(for: stream.session.snapshot) }) {
    case .success(let viewport):
      switch Result(catching: { try InlineSwiftUIAppendRenderer(session: stream.session, viewport: viewport) }) {
      case .success(let renderer):
        renderer.sampleSurface(viewport)
      case .failure(let error):
        SampleErrorText(error)
      }
    case .failure(let error):
      Text(stream.session.snapshot.atomCount == 0 ? "Send the first atom to create layout." : String(describing: error))
        .font(.caption)
        .foregroundStyle(theme.secondaryText)
    }

    if let error = stream.lastError {
      Text(error).font(.caption.monospaced()).foregroundStyle(.red)
    }
  }
}

private struct SamplePage<Content: View>: View {
  @Environment(SampleTheme.self) private var theme
  let title: String
  let explanation: String
  let content: Content

  init(
    title: String,
    explanation: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.explanation = explanation
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(explanation).font(.callout).foregroundStyle(theme.secondaryText)
        content
      }
      .padding()
    }
    .foregroundStyle(theme.primaryText)
    .background(theme.background.ignoresSafeArea())
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct SampleSetupError: View {
  @Environment(SampleModel.self) private var model

  var body: some View {
    ContentUnavailableView {
      Label("Sample setup failed", systemImage: "exclamationmark.triangle")
    } description: {
      Text(model.setupError ?? "Unknown setup error")
    } actions: {
      Button("Retry") { model.retrySetup() }
    }
  }
}

private struct SampleErrorText: View {
  let error: Error
  init(_ error: Error) { self.error = error }
  var body: some View {
    Text(String(describing: error)).font(.caption.monospaced()).foregroundStyle(.red)
  }
}

private struct SampleSurfaceModifier: ViewModifier {
  @Environment(SampleTheme.self) private var theme
  let viewport: InlineRenderViewport

  func body(content: Content) -> some View {
    content
      .frame(
        width: CGFloat(viewport.width),
        height: max(80, CGFloat(viewport.height)),
        alignment: .topLeading)
      .background(theme.renderSurface, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(theme.renderSurfaceBorder, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 12))
  }
}

private extension View {
  func sampleSurface(_ viewport: InlineRenderViewport) -> some View {
    modifier(SampleSurfaceModifier(viewport: viewport))
  }
}

private func revealPhase(_ progress: Double) -> InlineRenderRevealPhase {
  do {
    return try InlineRenderRevealPhase(rawValue: progress)
  } catch {
    preconditionFailure("sample reveal slider escaped its validated 0...1 range: \(progress)")
  }
}

private func motionPhase(_ progress: Double) -> InlineMotionPhase {
  do {
    return try InlineMotionPhase(rawValue: progress)
  } catch {
    preconditionFailure("sample motion slider escaped its validated 0...1 range: \(progress)")
  }
}

private func hitPoint(_ point: CGPoint) -> InlineHitPoint {
  (try? InlineHitPoint(x: Double(point.x), y: Double(point.y))) ?? (try! InlineHitPoint(x: 0, y: 0))
}

private func describeHit(_ result: InlineHitResult) -> String {
  String(describing: result)
}
