import ChalkLineEffects
import LiveTextApple
import LiveTextEffects
import LiveTextWritingUI
import SwiftUI

/// The host owns input, progress, and I/O. Library preparation stays immutable.
@MainActor
struct DemoContent {
  let preparation: ChalkWritingPreparation
  let scene: InlineLiveTextScene<InlineEmptyAssetGeometryProvider>
  let style: ChalkWritingStyle
  let configuration: InlineWritingConfiguration

  init(
    text: String = "한글 ABC",
    height: Double = 72,
    chalk: WritingChalkStyle = .dryBrush,
    texture: WritingChalkTextureStyle = .fineGrain
  ) throws {
    let material = try WritingChalkConfiguration(textureStyle: texture, style: chalk)
    style = try ChalkWritingStyle(color: .warmWhite, configuration: material)
    configuration = InlineWritingConfiguration(effect: .chalk(material), color: .warmWhite)
    preparation = try ChalkWritingPreparation(text: text, layout: WritingLayoutOptions(
      glyphHeight: height, tracking: height * 0.12, lineSpacing: height * 0.25,
      margin: 24, baseStrokeWidth: height * 0.065, maximumLineWidth: 680))
    let atom = try InlineTextAtom(
      id: "demo-text", text: text,
      style: InlineTextStyle(font: FontDescriptor(postScriptName: "Helvetica", pointSize: height * 0.6)))
    scene = try InlineLiveTextScene(
      document: InlineDocument(atoms: [.text(atom)]),
      assets: InlineEmptyAssetGeometryProvider(),
      configuration: InlineLiveTextLayoutConfiguration(width: 680), foregroundColor: .white)
  }
}

struct DemoBoard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(24)
      .background(Color(red: 0.065, green: 0.115, blue: 0.10))
      .clipShape(RoundedRectangle(cornerRadius: 16))
  }
}

@MainActor
struct DemoSample: View {
  let content: DemoContent
  let progress: Double
  var animation: ChalkWritingAnimation = .write

  var body: some View {
    DemoBoard {
      ChalkWritingText(preparation: content.preparation, style: content.style,
                       animation: animation, motion: .uniform, progress: progress)
        .frame(width: 680, height: 200)
    }
  }
}
