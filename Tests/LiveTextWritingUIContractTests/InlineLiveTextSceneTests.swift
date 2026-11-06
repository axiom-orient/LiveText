import ChalkLineEffects
import LiveTextCore
import LiveTextLayout
import LiveTextWritingUI
import XCTest

@MainActor
final class InlineLiveTextSceneTests: XCTestCase {
  func testScenePreservesMagazineDefaultAndAcceptsExplicitInlinePolicy() throws {
    let existingInitializer: (Double, Double, UInt64, InlineOversizedVectorPolicy) throws
      -> InlineLiveTextLayoutConfiguration = InlineLiveTextLayoutConfiguration.init
    XCTAssertEqual(try existingInitializer(1, 0, 0, .reject).layoutStyle, .magazine(.standard))
    let existing = try InlineLiveTextLayoutConfiguration(width: 1)
    let explicitInline = try InlineLiveTextLayoutConfiguration(width: 1, layoutStyle: .inline)
    XCTAssertEqual(existing.layoutStyle, .magazine(.standard))
    XCTAssertNotEqual(existing, explicitInline)
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let document = try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "text", text: "A", style: style))
    ])
    let inline = try InlineLiveTextScene(
      document: document, assets: InlineEmptyAssetGeometryProvider(), configuration: explicitInline)
    XCTAssertFalse(inline.layout.lines.isEmpty)
    let magazine = try InlineLiveTextLayoutConfiguration(
      width: 1, layoutStyle: .magazine(InlineMagazineStyle()))
    XCTAssertThrowsError(
      try InlineLiveTextScene(
        document: document, assets: InlineEmptyAssetGeometryProvider(), configuration: magazine)
    )
  }

  func testSceneBuildsPreparedLayoutAndRendererProjections() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 22))
    let document = try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "body", text: "Hello LiveText", style: style))
    ])
    let configuration = try InlineLiveTextLayoutConfiguration(
      width: 240,
      leading: 4,
      revision: 7)

    let scene = try InlineLiveTextScene(
      document: document,
      assets: InlineEmptyAssetGeometryProvider(),
      configuration: configuration)

    XCTAssertEqual(scene.document, document)
    XCTAssertEqual(scene.prepared.document, document)
    XCTAssertFalse(scene.layout.lines.isEmpty)
    XCTAssertFalse(scene.plan.geometry.isEmpty)
    XCTAssertGreaterThan(scene.animationDuration, 0)
    XCTAssertEqual(try scene.phase(for: 0.5).rawValue, 0.5)

    _ = scene.renderer(phase: .complete)
    _ = scene.writingRenderer(phase: .complete, configuration: .chalk)
    _ = scene.canvasRenderer(phase: .complete)
  }

  func testSceneRejectsInvalidProgressBeforeRendererConstruction() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 18))
    let document = try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "body", text: "Progress", style: style))
    ])
    let scene = try InlineLiveTextScene(
      document: document,
      assets: InlineEmptyAssetGeometryProvider(),
      configuration: try InlineLiveTextLayoutConfiguration(width: 180))

    XCTAssertThrowsError(try scene.phase(for: -0.01))
    XCTAssertThrowsError(try scene.phase(for: 1.01))
    XCTAssertThrowsError(
      try InlineLiveTextLayoutConfiguration(width: .infinity)
    )
  }

  func testKoreanWritingCopyPreservesQuotedStrokeSemantics() throws {
    let face = try ChalkInlineWritingFace()
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 28),
      revealMode: .handwriting(faceID: face.id))
    let message = "한글 손글씨는 \"획\"을 따라 \"씁\"니다."
    let document = try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "korean-copy", text: message, style: style))
    ])
    let prepared = try InlinePreparation(
      writingFaceStore: InlineWritingFaceStore(faces: [face])
    ).prepare(document: document)

    guard case .text(let preparedText) = try XCTUnwrap(prepared.atoms.first) else {
      return XCTFail("expected the Korean copy to remain a text atom")
    }
    XCTAssertEqual(preparedText.atom.text, message)
    XCTAssertEqual(preparedText.graphemes.joined(), message)
    let semanticStrokeCount = preparedText.writingUnits.reduce(into: 0) { count, unit in
      if case .semanticStroke = unit.kind { count += 1 }
    }
    let timingOnlyCount = preparedText.writingUnits.reduce(into: 0) { count, unit in
      if case .timingOnly = unit.kind { count += 1 }
    }
    XCTAssertGreaterThan(semanticStrokeCount, 0)
    XCTAssertEqual(timingOnlyCount, message.filter { $0 == " " || $0 == "\t" }.count)
    XCTAssertEqual(semanticStrokeCount + timingOnlyCount, preparedText.writingUnits.count)
  }

  func testMixedVowelHangulRemainsOnePrecomposedGlyph() throws {
    let face = try ChalkInlineWritingFace()
    let glyph = try XCTUnwrap(face.glyph(for: Character("획")))

    XCTAssertEqual(glyph.character, "획")
    XCTAssertEqual(glyph.character.unicodeScalars.map(\.value), [0xD68D])
    XCTAssertGreaterThan(glyph.strokes.count, 0)
  }
}
