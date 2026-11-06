import Foundation
import LiveTextCore
import XCTest

@testable import LiveTextLayout

final class PreparedAdmissionTests: XCTestCase {
  private struct Shaper: CancellableInlineTextShaping {
    func shape(text: String, style: InlineTextStyle, sourceRange: InlineSourceRange) throws
      -> InlineShapedText
    {
      var offset = sourceRange.startUTF16
      var ranges: [InlineSourceRange] = []
      var runs: [InlineShapedRun] = []
      for character in text {
        let range = try InlineSourceRange(
          startUTF16: offset, endUTF16: offset + String(character).utf16.count)
        ranges.append(range)
        runs.append(
          try InlineShapedRun(
            glyphs: [
              InlineGlyph(
                glyphID: 1, positionX: 0, positionY: 0, sourceUTF16Index: offset,
                sourceRange: range)
            ],
            font: style.font, sourceRange: range, advance: 1, ascent: 10, descent: 2))
        offset = range.endUTF16
      }
      return try InlineShapedText(
        graphemeRanges: ranges, graphemeAdvances: Array(repeating: 1, count: ranges.count),
        runs: runs, metrics: InlineMetrics(advance: Double(ranges.count), ascent: 10, descent: 2))
    }

    func shape(
      text: String, style: InlineTextStyle, sourceRange: InlineSourceRange,
      cancellation: InlineCancellationCheck
    ) throws -> InlineShapedText {
      try cancellation()
      return try shape(text: text, style: style, sourceRange: sourceRange)
    }
  }

  private struct Face: InlineWritingFace {
    let id = "admission-face"
    let version = "1"
    func glyph(for character: Character) throws -> InlineWritingGlyph? {
      let stroke = try InlineWritingStroke(points: [
        InlineNormalizedWritingPoint(x: 0, y: 0), InlineNormalizedWritingPoint(x: 1, y: 1),
      ])
      return try InlineWritingGlyph(
        character: String(character), advance: 1, strokes: [stroke, stroke])
    }
  }

  private func limits(_ overrides: [String: Int]) throws -> InlinePreparationLimits {
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(InlinePreparationLimits.default))
        as? [String: Any])
    for (key, value) in overrides { json[key] = value }
    return try JSONDecoder().decode(
      InlinePreparationLimits.self, from: JSONSerialization.data(withJSONObject: json))
  }

  private func textFixture(handwriting: Bool = false) throws -> PreparedInlineDocument {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
      revealMode: handwriting ? .handwriting(faceID: "admission-face") : .native)
    let document = try InlineDocument(
      atoms: (0..<2).map {
        .text(try InlineTextAtom(id: "text-\($0)", text: "AA", style: style))
      })
    return try preparation().prepare(document: document, cancellation: {})
  }

  private func preparation(limits: InlinePreparationLimits = .default) throws -> InlinePreparation {
    try InlinePreparation(
      shaper: Shaper(), limits: limits, writingFaceStore: InlineWritingFaceStore(faces: [Face()]))
  }

  private func vectorFixture() throws -> PreparedInlineDocument {
    let vector = try InlineVectorAtom(
      id: "vector", assetID: InlineAssetID(rawValue: "asset"),
      metrics: InlineMetrics(advance: 10, ascent: 8, descent: 2))
    return try preparation().prepare(document: InlineDocument(atoms: [.vector(vector)]))
  }

  private func imageFixture() throws -> PreparedInlineDocument {
    let atoms = try (0..<2).map { index in
      InlineAtom.image(
        try InlineImageAtom(
          id: "image-\(index)", assetID: InlineAssetID(rawValue: "image"),
          digest: InlineAssetDigest(data: Data([1])),
          metrics: InlineMetrics(advance: 10, ascent: 8, descent: 2), isDecorative: true))
    }
    return try preparation().prepare(document: InlineDocument(atoms: atoms))
  }

  private func rebuild(
    _ prepared: PreparedInlineDocument, context: InlinePreparationIdentityContext,
    revision: String? = nil
  ) throws -> PreparedInlineDocument {
    if let revision {
      return try PreparedInlineDocument(
        document: prepared.document, atoms: prepared.atoms, revision: revision,
        identityContext: context, totalTextUTF16Units: prepared.totalTextUTF16Units,
        totalGraphemes: prepared.totalGraphemes, totalGlyphs: prepared.totalGlyphs,
        totalRuns: prepared.totalRuns, totalImageAtoms: prepared.totalImageAtoms)
    }
    return try PreparedInlineDocument(
      document: prepared.document, atoms: prepared.atoms, identityContext: context,
      totalTextUTF16Units: prepared.totalTextUTF16Units, totalGraphemes: prepared.totalGraphemes,
      totalGlyphs: prepared.totalGlyphs, totalRuns: prepared.totalRuns,
      totalImageAtoms: prepared.totalImageAtoms)
  }

  // Build decoder input independently of the public constructor under test.
  // A valid canonical digest must not make over-budget contents admissible.
  private func encodedFixture(
    _ prepared: PreparedInlineDocument, context: InlinePreparationIdentityContext,
    includeContext: Bool = true
  ) throws -> Data {
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared)) as? [String: Any])
    json["revision"] = try canonicalInlinePreparationRevision(
      document: prepared.document, preparedAtoms: prepared.atoms, identityContext: context)
    if includeContext {
      json["identityContext"] = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(context))
    } else {
      json.removeValue(forKey: "identityContext")
    }
    return try JSONSerialization.data(withJSONObject: json)
  }

  private func assertRejectedAtEveryBoundary(
    _ prepared: PreparedInlineDocument, context: InlinePreparationIdentityContext,
    expected: InlineLayoutError, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let revision = try canonicalInlinePreparationRevision(
      document: prepared.document, preparedAtoms: prepared.atoms, identityContext: context)
    let payload = try encodedFixture(prepared, context: context)
    let operations: [() throws -> PreparedInlineDocument] = [
      { try self.rebuild(prepared, context: context) },
      { try self.rebuild(prepared, context: context, revision: revision) },
      { try JSONDecoder().decode(PreparedInlineDocument.self, from: payload) },
      {
        let preparation = try self.preparation(limits: context.limits)
        return context.mode == .full
          ? try preparation.prepare(document: prepared.document)
          : try preparation.prepare(document: prepared.document, cancellation: {})
      },
    ]
    for operation in operations {
      XCTAssertThrowsError(try operation(), file: file, line: line) {
        XCTAssertEqual($0 as? InlineLayoutError, expected, file: file, line: line)
      }
    }
  }

  func testZeroAtomBudgetRejectsPublicInitializersAndIndependentDecode() throws {
    try assertRejectedAtEveryBoundary(
      vectorFixture(), context: .full(limits: limits(["maximumAtoms": 0])),
      expected: .resourceLimitExceeded(resource: "atoms", actual: 1, limit: 0))
  }

  func testAggregateTextBudgetsRejectAcrossAtoms() throws {
    let fixture = try textFixture()
    for (key, resource) in [
      ("maximumTextUTF16Units", "text UTF-16 units"), ("maximumGraphemes", "graphemes"),
      ("maximumGlyphs", "glyphs"), ("maximumRuns", "runs"),
    ] {
      try assertRejectedAtEveryBoundary(
        fixture, context: .cancellationAware(limits: limits([key: 3])),
        expected: .resourceLimitExceeded(resource: resource, actual: 4, limit: 3))
    }
  }

  func testCancellationModeEnforcesPerAtomBudgets() throws {
    let fixture = try textFixture()
    for (key, resource) in [
      ("maximumCancellableAtomUTF16Units", "cancellable text atom UTF-16 units"),
      ("maximumCancellableAtomGlyphs", "cancellable atom glyphs"),
      ("maximumCancellableAtomRuns", "cancellable atom runs"),
    ] {
      let limits = try limits([key: 1])
      try assertRejectedAtEveryBoundary(
        fixture, context: .cancellationAware(limits: limits),
        expected: .resourceLimitExceeded(resource: resource, actual: 2, limit: 1))
      // Full preparation intentionally does not apply cancellation-unit bounds.
      let full = try rebuild(fixture, context: .full(limits: limits))
      XCTAssertEqual(
        try JSONDecoder().decode(PreparedInlineDocument.self, from: JSONEncoder().encode(full)),
        full)
    }
  }

  func testImageBudgetRejectsPublicInitializersAndIndependentDecode() throws {
    try assertRejectedAtEveryBoundary(
      imageFixture(), context: .full(limits: limits(["maximumImageAtoms": 1])),
      expected: .resourceLimitExceeded(resource: "image atoms", actual: 2, limit: 1))
  }

  func testWritingBudgetsCountStrokesAndPointsAcrossAtoms() throws {
    let fixture = try textFixture(handwriting: true)
    try assertRejectedAtEveryBoundary(
      fixture, context: .cancellationAware(limits: limits(["maximumWritingStrokes": 7])),
      expected: .resourceLimitExceeded(resource: "writing strokes", actual: 8, limit: 7))
    try assertRejectedAtEveryBoundary(
      fixture, context: .cancellationAware(limits: limits(["maximumWritingPoints": 15])),
      expected: .resourceLimitExceeded(resource: "writing points", actual: 16, limit: 15))
  }

  func testExactLimitsPreserveRevisionRoundTripAndRenderPlan() throws {
    let fixture = try textFixture(handwriting: true)
    let context = try InlinePreparationIdentityContext.cancellationAware(
      limits: limits([
        "maximumAtoms": 2, "maximumTextUTF16Units": 4, "maximumGraphemes": 4,
        "maximumGlyphs": 4, "maximumRuns": 4, "maximumWritingStrokes": 8,
        "maximumWritingPoints": 16, "maximumCancellableAtomUTF16Units": 2,
        "maximumCancellableAtomGlyphs": 2, "maximumCancellableAtomRuns": 2,
      ]))
    let expectedRevision = try canonicalInlinePreparationRevision(
      document: fixture.document, preparedAtoms: fixture.atoms, identityContext: context)
    let admitted = try rebuild(fixture, context: context, revision: expectedRevision)
    XCTAssertEqual(admitted.revision, expectedRevision)
    XCTAssertEqual(
      try JSONDecoder().decode(
        PreparedInlineDocument.self, from: encodedFixture(fixture, context: context)),
      admitted)
    XCTAssertEqual(
      try preparation(limits: context.limits).prepare(document: fixture.document, cancellation: {}),
      admitted)
    _ = try InlineRenderPlan(
      prepared: admitted, layout: InlineLayoutEngine().layout(prepared: admitted, width: 100))
  }

  func testLegacyDefaultProfilesRemainVerifiable() throws {
    let fixture = try textFixture()
    for context in [InlinePreparationIdentityContext.full(), .cancellationAware()] {
      let decoded = try JSONDecoder().decode(
        PreparedInlineDocument.self,
        from: encodedFixture(fixture, context: context, includeContext: false))
      XCTAssertEqual(decoded, try rebuild(fixture, context: context))
    }
  }

  func testLegacyDigestDoesNotBypassContentCounterValidation() throws {
    let fixture = try textFixture()
    let data = try encodedFixture(fixture, context: .full(), includeContext: false)
    var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    payload["totalGraphemes"] = fixture.totalGraphemes + 1
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        PreparedInlineDocument.self,
        from: JSONSerialization.data(withJSONObject: payload))
    )
  }
}
