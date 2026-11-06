import LiveTextCore
import LiveTextLayout
import LiveTextWritingUI
import ProductConsumer
import Testing

@MainActor
struct FlowConsumerTests {
  @Test
  func inlineAndMagazineRemainAvailableToExternalClients() throws {
    let inline = try makeInlineRegion()
    #expect(inline.rect.width == 320)
    let explicitMagazine = try InlineLiveTextLayoutConfiguration(
      width: 1, magazineStyle: .standard)
    let defaultPolicy = try InlineLiveTextLayoutConfiguration(width: 1)
    #expect(defaultPolicy == explicitMagazine)

    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let document = try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "text", text: "A", style: style))
    ])
    let oldPolicy = try InlineLiveTextLayoutConfiguration(width: 1, layoutStyle: .inline)
    let scene = try InlineLiveTextScene(
      document: document, assets: InlineEmptyAssetGeometryProvider(), configuration: oldPolicy)
    #expect(!scene.layout.lines.isEmpty)
    #expect(throws: InlineLayoutError.self) {
      _ = try InlineLiveTextScene(
        document: document, assets: InlineEmptyAssetGeometryProvider(),
        configuration: defaultPolicy)
    }
  }
}
