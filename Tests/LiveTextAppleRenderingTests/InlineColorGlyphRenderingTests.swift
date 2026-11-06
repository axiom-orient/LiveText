import CoreGraphics
import CoreText
import LiveTextCore
@testable import LiveTextAppleRendering
@testable import LiveTextCanvas
import LiveTextLayout
@testable import LiveTextSwiftUI
import SwiftUI
import XCTest

private struct NoAssets: InlineAssetGeometryProvider {
  func resolveGeometry(assetID: InlineAssetID, version: Int) throws -> InlineSVGAsset {
    throw InlineAssetResolutionError.missingGeometry(assetID, version: version)
  }
}

private enum ForgedEmojiField: CaseIterable, Equatable {
  case glyphID
  case sourceIndex
  case position
  case runAdvance
}

private struct ForgedEmojiShaper: InlineTextShaping {
  let field: ForgedEmojiField

  func shape(
    text: String,
    style: InlineTextStyle,
    sourceRange: InlineSourceRange
  ) throws -> InlineShapedText {
    let baseline = try CoreTextInlineShaper().shape(
      text: text, style: style, sourceRange: sourceRange)
    guard let baselineRun = baseline.runs.first,
      let baselineGlyph = baselineRun.glyphs.first
    else {
      throw InlineLayoutError.unsupportedShaping("emoji fixture has no glyph")
    }
    let forgedGlyph = try InlineGlyph(
      glyphID: field == .glyphID ? baselineGlyph.glyphID ^ 1 : baselineGlyph.glyphID,
      positionX: field == .position ? baselineGlyph.positionX + 1 : baselineGlyph.positionX,
      positionY: baselineGlyph.positionY,
      sourceUTF16Index: field == .sourceIndex
        ? baselineGlyph.sourceUTF16Index + 1
        : baselineGlyph.sourceUTF16Index,
      sourceRange: baselineGlyph.sourceRange
    )
    let forgedRun = try InlineShapedRun(
      glyphs: [forgedGlyph],
      font: baselineRun.font,
      sourceRange: baselineRun.sourceRange,
      advance: field == .runAdvance ? baselineRun.advance + 1 : baselineRun.advance,
      ascent: baselineRun.ascent,
      descent: baselineRun.descent
    )
    return try InlineShapedText(
      graphemeRanges: baseline.graphemeRanges,
      graphemeAdvances: baseline.graphemeAdvances,
      runs: [forgedRun],
      metrics: baseline.metrics
    )
  }
}

@MainActor
final class InlineColorGlyphRenderingTests: XCTestCase {
  private func emojiStyle() throws -> InlineTextStyle {
    try InlineTextStyle(
      font: FontDescriptor(postScriptName: "AppleColorEmoji", pointSize: 32))
  }

  private func makePlan(
    text: String,
    shaper: any InlineTextShaping = CoreTextInlineShaper()
  ) throws -> InlineRenderPlan {
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "emoji", text: text, style: emojiStyle()))
    let prepared = try InlinePreparation(shaper: shaper).prepare(
      document: InlineDocument(atoms: [atom]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 240)
    return try InlineRenderPlan(prepared: prepared, layout: layout)
  }

  private func makeMixedPlan() throws -> InlineRenderPlan {
    let prefixStyle = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 18))
    let prefix = try InlineAtom.text(
      InlineTextAtom(id: "prefix", text: "prefix ", style: prefixStyle))
    let emoji = try InlineAtom.text(
      InlineTextAtom(id: "emoji", text: "🧪✨👩‍💻", style: emojiStyle()))
    let prepared = try InlinePreparation().prepare(
      document: InlineDocument(atoms: [prefix, emoji]))
    let layout = try InlineLayoutEngine().layout(prepared: prepared, width: 240)
    return try InlineRenderPlan(prepared: prepared, layout: layout)
  }

  private func requireColorEmojiFont() throws {
    let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 32, nil)
    guard CTFontCopyPostScriptName(font) as String? == "AppleColorEmoji" else {
      throw XCTSkip("AppleColorEmoji is unavailable on this platform")
    }
  }

  private func assertDirectCoreTextEvidence(
    _ entry: InlineTextPaintEntry,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    guard entry.kind == .coreText,
      entry.coreTextRun != nil,
      let glyphIndex = entry.coreTextGlyphIndex,
      glyphIndex >= 0
    else {
      return XCTFail("expected a retained direct Core Text entry", file: file, line: line)
    }
    XCTAssertNil(entry.outlinePath, file: file, line: line)
    XCTAssertGreaterThan(entry.localPaintBounds.width, 0, file: file, line: line)
    XCTAssertGreaterThan(entry.localPaintBounds.height, 0, file: file, line: line)
  }

  private func assertRenderedEvidence<V: View>(
    _ view: V,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let image = ImageRenderer(content: view).cgImage,
      let data = image.dataProvider?.data,
      let bytes = CFDataGetBytePtr(data)
    else {
      return XCTFail("renderer must produce an image", file: file, line: line)
    }
    let channels = image.bitsPerPixel / 8
    guard channels >= 4 else {
      return XCTFail("renderer image must contain RGBA pixels", file: file, line: line)
    }
    var hasAlpha = false
    var hasChromaticPixel = false
    for index in 0..<(image.width * image.height) {
      let offset = index * channels
      let alpha = bytes[offset + channels - 1]
      guard alpha > 0 else { continue }
      hasAlpha = true
      if bytes[offset] != bytes[offset + 1] || bytes[offset + 1] != bytes[offset + 2] {
        hasChromaticPixel = true
      }
    }
    XCTAssertTrue(hasAlpha, "renderer output must contain nonempty alpha", file: file, line: line)
    XCTAssertTrue(hasChromaticPixel, "renderer output must retain color pixels", file: file, line: line)
  }

  private func appendEvent(
    reducer: InlineAppendReducer,
    atom: InlineAtom
  ) throws -> InlineAppendEvent {
    .append(
      InlineAppendBatch(
        streamID: reducer.streamID,
        sequence: reducer.nextSequence,
        baseRevision: reducer.revision,
        atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: atom)]
      )
    )
  }

  func testStaticColorAndZWJEmojiProduceDirectCoreTextEntriesForBothAdapters() throws {
    try requireColorEmojiFont()
    let plan = try makePlan(text: "🧪✨👩‍💻")
    let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: NoAssets())
    let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: NoAssets())
    let swift = InlineSwiftUIRenderer(
      content: swiftContent,
      viewport: try InlineRenderViewport(x: 0, y: 0, width: 240, height: 64))
    let canvas = InlineCanvasRenderer(
      content: canvasContent,
      viewport: try InlineRenderViewport(x: 0, y: 0, width: 240, height: 64))
    let swiftEntries = swift.renderedTextPaintEntriesForTesting.values.flatMap { $0 }
    let canvasEntries = canvas.renderedTextPaintEntriesForTesting.values.flatMap { $0 }
    XCTAssertEqual(swiftEntries.count, 3)
    XCTAssertEqual(canvasEntries.count, swiftEntries.count)
    XCTAssertTrue(swiftEntries.allSatisfy { $0.kind == .coreText })
    XCTAssertTrue(canvasEntries.allSatisfy { $0.kind == .coreText })
    XCTAssertEqual(
      swiftEntries.map(\.sourceRange),
      [
        try InlineSourceRange(startUTF16: 0, endUTF16: 2),
        try InlineSourceRange(startUTF16: 2, endUTF16: 3),
        try InlineSourceRange(startUTF16: 3, endUTF16: 8),
      ]
    )
    for entry in swiftEntries { try assertDirectCoreTextEvidence(entry) }
    for entry in canvasEntries { try assertDirectCoreTextEvidence(entry) }
    assertRenderedEvidence(swift)
    assertRenderedEvidence(canvas)
    for (swiftEntry, canvasEntry) in zip(swiftEntries, canvasEntries) {
      XCTAssertEqual(swiftEntry.sourceRange, canvasEntry.sourceRange)
      XCTAssertEqual(swiftEntry.localDrawRect, canvasEntry.localDrawRect)
      XCTAssertEqual(swiftEntry.localPaintBounds, canvasEntry.localPaintBounds)
    }
  }

  func testDirectColorGlyphPathCoversVariationSkinToneZWJFlagAndKeycap() throws {
    try requireColorEmojiFont()
    let samples = ["❤️", "👍🏽", "👩‍💻", "🇺🇸", "1️⃣"]
    for sample in samples {
      let plan = try makePlan(text: sample)
      let swiftContent = try InlineSwiftUIRenderContent(plan: plan, assets: NoAssets())
      let canvasContent = try InlineCanvasRenderContent(plan: plan, assets: NoAssets())
      let viewport = try InlineRenderViewport(x: 0, y: 0, width: 240, height: 64)
      let swiftRenderer = InlineSwiftUIRenderer(content: swiftContent, viewport: viewport)
      let canvasRenderer = InlineCanvasRenderer(content: canvasContent, viewport: viewport)
      let swiftEntries = swiftRenderer.renderedTextPaintEntriesForTesting.values.flatMap { $0 }
      let canvasEntries = canvasRenderer.renderedTextPaintEntriesForTesting.values.flatMap { $0 }
      XCTAssertFalse(swiftEntries.isEmpty, "sample \(sample) must produce a paint entry")
      XCTAssertEqual(swiftEntries.count, canvasEntries.count)
      XCTAssertTrue(swiftEntries.allSatisfy { $0.kind == .coreText })
      XCTAssertTrue(canvasEntries.allSatisfy { $0.kind == .coreText })
      for entry in swiftEntries { try assertDirectCoreTextEvidence(entry) }
      for entry in canvasEntries { try assertDirectCoreTextEvidence(entry) }
      assertRenderedEvidence(swiftRenderer)
      assertRenderedEvidence(canvasRenderer)
    }
  }

  func testDirectCoreTextDrawBenchmarkComparesRunAndFontPayloads() throws {
    try requireColorEmojiFont()
    let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 32, nil)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: "🧪✨👩‍💻",
        attributes: [NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font]
      )
    )
    guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else {
      return XCTFail("benchmark fixture must contain a Core Text run")
    }
    let count = CTRunGetGlyphCount(run)
    XCTAssertGreaterThan(count, 0)
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
    let context = CGContext(
      data: nil,
      width: 256,
      height: 64,
      bitsPerComponent: 8,
      bytesPerRow: 256 * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    let iterations = 1_000
    let runStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
      context.clear(CGRect(x: 0, y: 0, width: 256, height: 64))
      context.saveGState()
      context.translateBy(x: 0, y: 48)
      context.scaleBy(x: 1, y: -1)
      CTRunDraw(run, context, CFRange(location: 0, length: count))
      context.restoreGState()
    }
    let runNanoseconds = DispatchTime.now().uptimeNanoseconds - runStart

    let fontStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
      context.clear(CGRect(x: 0, y: 0, width: 256, height: 64))
      context.saveGState()
      context.translateBy(x: 0, y: 48)
      context.scaleBy(x: 1, y: -1)
      glyphs.withUnsafeBufferPointer { glyphBuffer in
        positions.withUnsafeBufferPointer { positionBuffer in
          CTFontDrawGlyphs(
            font,
            glyphBuffer.baseAddress!,
            positionBuffer.baseAddress!,
            count,
            context
          )
        }
      }
      context.restoreGState()
    }
    let fontNanoseconds = DispatchTime.now().uptimeNanoseconds - fontStart
    print(
      "InlineTextPaintBenchmark iterations=\(iterations) "
        + "CTRunDraw_ns=\(runNanoseconds) "
        + "CTFontDrawGlyphs_ns=\(fontNanoseconds)"
    )
    XCTAssertGreaterThan(runNanoseconds, 0)
    XCTAssertGreaterThan(fontNanoseconds, 0)
  }

  func testColorGlyphReconstructionPreservesGlobalSourceRanges() throws {
    try requireColorEmojiFont()
    let plan = try makeMixedPlan()
    let content = try InlineSwiftUIRenderContent(plan: plan, assets: NoAssets())
    let renderer = InlineSwiftUIRenderer(
      content: content,
      viewport: try InlineRenderViewport(x: 0, y: 0, width: 240, height: 100))
    let entries = renderer.renderedTextPaintEntriesForTesting.values.flatMap { $0 }
    let emojiEntries = entries.filter { $0.kind == .coreText }
    XCTAssertEqual(emojiEntries.count, 3)
    XCTAssertEqual(
      emojiEntries.map(\.sourceRange),
      [
        try InlineSourceRange(startUTF16: 7, endUTF16: 9),
        try InlineSourceRange(startUTF16: 9, endUTF16: 10),
        try InlineSourceRange(startUTF16: 10, endUTF16: 15),
      ]
    )
  }

  func testAppendColorAndZWJEmojiRenderThroughBothAdapters() throws {
    try requireColorEmojiFont()
    let style = try emojiStyle()
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "emoji-append", text: "🧪✨👩‍💻", style: style))
    let streamID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let reducer = try InlineAppendReducer(
      streamID: streamID, preparation: InlinePreparation(), engine: InlineLayoutEngine(), width: 240)
    let session = try InlineAppleAppendSession(reducer: reducer, assets: NoAssets())
    let event = InlineAppendEvent.append(
      InlineAppendBatch(
        streamID: streamID, sequence: session.snapshot.nextSequence,
        baseRevision: session.snapshot.revision,
        atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: atom)]))
    try session.send(event)
    let viewport = try InlineRenderViewport(x: 0, y: 0, width: 240, height: 80)
    assertRenderedEvidence(
      try InlineSwiftUIAppendRenderer(session: session, viewport: viewport))
    assertRenderedEvidence(
      try InlineCanvasAppendRenderer(session: session, viewport: viewport))
  }

  func testColorGlyphCompilationUsesDirectPayloadWithoutRasterImages() throws {
    try requireColorEmojiFont()
    let plan = try makePlan(text: "🧪")
    let entries = try InlineTextPaintCompiler.compile(geometry: plan.geometry)
      .values.flatMap { $0 }
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.kind, .coreText)
    XCTAssertNotNil(entries.first?.coreTextRun)
    XCTAssertNil(entries.first?.outlinePath)
  }

  func testNonRenderingPathlessGlyphWithEmptyPaintFailsTyped() throws {
    try requireColorEmojiFont()
    // U+FE0F is a valid pathless Core Text glyph with no visible paint. It is
    // not whitespace, so the compiler must reject it rather than omitting it.
    let plan = try makePlan(text: "\u{FE0F}")
    XCTAssertThrowsError(
      try InlineSwiftUIRenderContent(plan: plan, assets: NoAssets())
    ) { error in
      guard case .unsupportedShaping = error as? InlineLayoutError else {
        return XCTFail("empty visible color glyph must remain a typed shaping failure")
      }
    }
    XCTAssertThrowsError(
      try InlineCanvasRenderContent(plan: plan, assets: NoAssets())
    ) { error in
      guard case .unsupportedShaping = error as? InlineLayoutError else {
        return XCTFail("empty visible color glyph must remain a typed shaping failure")
      }
    }
  }

  func testColorGlyphRevealKeepsDirectEntryParityAtZeroMidAndComplete() throws {
    try requireColorEmojiFont()
    let plan = try makePlan(text: "🧪✨👩‍💻")
    let textPlan = try InlineRevealPlanBuilder().graphemePlan(prepared: plan.prepared)
    let schedule = try InlineRenderRevealSchedule(
      plan: plan, assets: InlineAssetStore(), textPlan: textPlan)
    for phase in [
      InlineRenderRevealPhase.zero,
      try InlineRenderRevealPhase(rawValue: 0.5),
      InlineRenderRevealPhase.complete,
    ] {
      let swiftContent = try InlineSwiftUIRenderContent(
        plan: plan, assets: NoAssets(), schedule: schedule)
      let canvasContent = try InlineCanvasRenderContent(
        plan: plan, assets: NoAssets(), schedule: schedule)
      let swift = InlineSwiftUIRenderer(
        content: swiftContent,
        phase: phase,
        viewport: try InlineRenderViewport(x: 0, y: 0, width: 240, height: 64))
      let canvas = InlineCanvasRenderer(
        content: canvasContent,
        phase: phase,
        viewport: try InlineRenderViewport(x: 0, y: 0, width: 240, height: 64))
      let swiftEntries = swift.visibleTextPaintEntriesForTesting.values.flatMap { $0 }
      let canvasEntries = canvas.visibleTextPaintEntriesForTesting.values.flatMap { $0 }
      XCTAssertEqual(swiftEntries.count, canvasEntries.count)
      XCTAssertTrue(swiftEntries.allSatisfy { $0.kind == .coreText })
      XCTAssertTrue(canvasEntries.allSatisfy { $0.kind == .coreText })
      for (swiftEntry, canvasEntry) in zip(swiftEntries, canvasEntries) {
        XCTAssertEqual(swiftEntry.sourceRange, canvasEntry.sourceRange)
        XCTAssertEqual(swiftEntry.localDrawRect, canvasEntry.localDrawRect)
        XCTAssertEqual(swiftEntry.localPaintBounds, canvasEntry.localPaintBounds)
      }
    }
  }

  func testPathlessGlyphReconstructionRejectsForgedPreparedFields() throws {
    try requireColorEmojiFont()
    for field in ForgedEmojiField.allCases {
      let plan = try makePlan(
        text: "🧪",
        shaper: ForgedEmojiShaper(field: field))
      XCTAssertThrowsError(
        try InlineSwiftUIRenderContent(plan: plan, assets: NoAssets())
      ) { error in
        guard case .unsupportedShaping = error as? InlineLayoutError else {
          return XCTFail("forged \(field) must fail typed Core Text reconstruction")
        }
      }
      XCTAssertThrowsError(
        try InlineCanvasRenderContent(plan: plan, assets: NoAssets())
      ) { error in
        guard case .unsupportedShaping = error as? InlineLayoutError else {
          return XCTFail("forged \(field) must fail typed Core Text reconstruction")
        }
      }
    }
  }

  func testAppendEmptyPaintFailureLeavesSessionUnchanged() throws {
    try requireColorEmojiFont()
    let style = try emojiStyle()
    let atom = try InlineAtom.text(
      InlineTextAtom(id: "empty-color-glyph", text: "\u{FE0F}", style: style))
    let streamID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let reducer = try InlineAppendReducer(
      streamID: streamID, preparation: InlinePreparation(), engine: InlineLayoutEngine(), width: 240)
    let session = try InlineAppleAppendSession(reducer: reducer, assets: NoAssets())
    let before = session.snapshot
    let event = InlineAppendEvent.append(
      InlineAppendBatch(
        streamID: streamID, sequence: session.snapshot.nextSequence,
        baseRevision: session.snapshot.revision,
        atoms: [try InlineSealedAppendAtom(sealingCompleteSemanticAtom: atom)]))
    XCTAssertThrowsError(try session.send(event)) { error in
      guard case .unsupportedShaping = error as? InlineLayoutError else {
        return XCTFail("empty append color glyph must remain a typed shaping failure")
      }
    }
    XCTAssertEqual(session.snapshot, before)
  }
}
