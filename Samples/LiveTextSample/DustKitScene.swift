import DustKit
import LiveTextPresentation
import LiveTextWritingUI
import SwiftUI

struct DustKitScene: View {
  @Environment(SampleModel.self) private var model
  @Environment(SampleTheme.self) private var theme
  @Environment(\.displayScale) private var displayScale
  @State private var playback = SamplePlayback(duration: 3.0)
  @State private var transition: DustTransition = .disintegrate
  @State private var failure: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("LiveText owns preparation, layout, reveal, material, interaction, and accessibility. DustKit receives only one terminal raster revision.")
          .font(.callout)
          .foregroundStyle(theme.secondaryText)

        Picker("Transition", selection: $transition) {
          Text("Disintegrate").tag(DustTransition.disintegrate)
          Text("Assemble").tag(DustTransition.assemble)
        }
        .pickerStyle(.segmented)

        if let bundle = model.writingBundle {
          SamplePlaybackSurface(playback: playback) { snapshot in
            LiveTextWritingDustRenderer(
              content: bundle.swiftUI,
              livePhase: .complete,
              sourcePhase: .complete,
              viewport: bundle.viewport,
              configuration: .chalk,
              terminal: InlineDustPresentationConfiguration(
                progress: dustProgress(snapshot.phase),
                preset: .softDust,
                transition: transition,
                layoutPolicy: .effectBounds),
              terminalBlendMode: .replaceWhenReady(),
              sourceScale: displayScale,
              semanticLabel: bundle.documentText,
              sourceIdentity: AnyHashable(bundle.plan.prepared.revision),
              onSourceFailure: { failure = $0 },
              onDustFailure: { failure = $0.localizedDescription },
              onDustPresented: { failure = nil }
            )
            .frame(
              width: CGFloat(bundle.viewport.width),
              height: max(80, CGFloat(bundle.viewport.height)))
            .background(theme.renderSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
              RoundedRectangle(cornerRadius: 12)
                .stroke(theme.renderSurfaceBorder, lineWidth: 1)
            }
          }

          Text("Particle progress changes do not re-prepare or re-layout LiveText.")
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
        } else {
          Text(model.setupError ?? "Sample setup failed")
            .foregroundStyle(.red)
        }

        if let failure {
          Text(failure).font(.caption.monospaced()).foregroundStyle(.red)
        }
      }
      .padding()
    }
    .foregroundStyle(theme.primaryText)
    .background(theme.background.ignoresSafeArea())
    .preferredColorScheme(.dark)
    .navigationTitle("Dust terminal effect")
    .navigationBarTitleDisplayMode(.inline)
    .samplePlaybackLifecycle(playback)
  }

  private func dustProgress(_ phase: Double) -> Double {
    switch transition {
    case .disintegrate: return phase
    case .assemble: return 1 - phase
    }
  }
}
