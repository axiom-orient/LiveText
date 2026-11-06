import LiveTextCore
import LiveTextLayout
import LiveTextWritingUI
import Testing

@MainActor
struct SceneFlowCompatibilityTests {
  @Test
  func explicitInlineAndCurrentMagazinePoliciesRemainDistinct() throws {
    let publishedInitializer: (
      Double, Double, UInt64, InlineOversizedVectorPolicy, InlineMagazineStyle
    ) throws -> InlineLiveTextLayoutConfiguration = InlineLiveTextLayoutConfiguration.init
    let originalInitializer: (
      Double, Double, UInt64, InlineOversizedVectorPolicy
    ) throws -> InlineLiveTextLayoutConfiguration = InlineLiveTextLayoutConfiguration.init
    let inline = try InlineLiveTextLayoutConfiguration(width: 1, layoutStyle: .inline)
    let defaultConfiguration = try InlineLiveTextLayoutConfiguration(width: 1)
    let explicitMagazine = try InlineLiveTextLayoutConfiguration(
      width: 1, magazineStyle: .standard)
    #expect(inline.layoutStyle == .inline)
    #expect(inline.magazineStyle == .standard)
    #expect(defaultConfiguration == explicitMagazine)
    #expect(try originalInitializer(1, 0, 0, .reject) == defaultConfiguration)
    #expect(try publishedInitializer(1, 0, 0, .reject, .standard) == defaultConfiguration)
    #expect(defaultConfiguration.layoutStyle == .magazine(.standard))

    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let document = try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "text", text: "A", style: style))
    ])
    let scene = try InlineLiveTextScene(
      document: document, assets: InlineEmptyAssetGeometryProvider(), configuration: inline)
    #expect(!scene.layout.lines.isEmpty)
    #expect(throws: InlineLayoutError.self) {
      _ = try InlineLiveTextScene(
        document: document, assets: InlineEmptyAssetGeometryProvider(),
        configuration: defaultConfiguration)
    }
  }
}
