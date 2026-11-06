import LiveTextCore
import LiveTextLayout
import XCTest

final class InlineModelTests: XCTestCase {
  func testMetricsRejectNonFiniteValues() {
    XCTAssertThrowsError(try InlineMetrics(advance: .infinity, ascent: 1, descent: 1))
  }

  func testDocumentRejectsDuplicateIDs() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let first = try InlineAtom.text(InlineTextAtom(id: "same", text: "a", style: style))
    let second = try InlineAtom.text(InlineTextAtom(id: "same", text: "b", style: style))
    XCTAssertThrowsError(try InlineDocument(atoms: [first, second]))
  }

  func testDecodedEmptyAssetIDIsRejected() {
    let data = Data("\"\"".utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(InlineAssetID.self, from: data))
  }

  func testDecodedPreparationLimitsRejectNoncanonicalValuesInsteadOfClamping() throws {
    let canonical = InlinePreparationLimits.default
    let canonicalData = try JSONEncoder().encode(canonical)
    XCTAssertEqual(
      try JSONDecoder().decode(InlinePreparationLimits.self, from: canonicalData),
      canonical
    )

    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: canonicalData) as? [String: Any])
    object["maximumAtoms"] = 99_999_999
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlinePreparationLimits.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    )

    object = try XCTUnwrap(JSONSerialization.jsonObject(with: canonicalData) as? [String: Any])
    object["maximumWritingPoints"] = 0
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlinePreparationLimits.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    ) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .invalidWritingLimit(resource: "points", value: 0))
    }
  }

  func testDocumentSchemaIsVersionedAndRejectsUnversionedOrUnknownPayloads() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let document = try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "text", text: "a", style: style))
    ])
    let encoded = try JSONEncoder().encode(document)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(object["schemaVersion"] as? Int, InlineDocument.schemaVersion)
    XCTAssertNotNil(object["atoms"] as? [[String: Any]])

    let unversioned = try JSONSerialization.data(withJSONObject: object["atoms"] as Any)
    XCTAssertThrowsError(try JSONDecoder().decode(InlineDocument.self, from: unversioned))

    var future = object
    future["schemaVersion"] = InlineDocument.schemaVersion + 1
    let futureData = try JSONSerialization.data(withJSONObject: future)
    XCTAssertThrowsError(try JSONDecoder().decode(InlineDocument.self, from: futureData)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .unsupportedSchemaVersion(
          expected: InlineDocument.schemaVersion,
          actual: InlineDocument.schemaVersion + 1
        )
      )
    }
  }

  func testDocumentSchemaV3RejectsV2AndMissingCustomTextUnits() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let document = try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "text", text: "a", style: style))
    ])
    let encoded = try JSONEncoder().encode(document)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    var v2 = object
    v2["schemaVersion"] = 2
    let v2Data = try JSONSerialization.data(withJSONObject: v2)
    XCTAssertThrowsError(try JSONDecoder().decode(InlineDocument.self, from: v2Data)) { error in
      XCTAssertEqual(
        error as? InlineLayoutError,
        .unsupportedSchemaVersion(expected: InlineDocument.schemaVersion, actual: 2))
    }

    var missing = object
    var atoms = try XCTUnwrap(missing["atoms"] as? [[String: Any]])
    var textAtom = try XCTUnwrap(atoms[0]["text"] as? [String: Any])
    XCTAssertNotNil(textAtom.removeValue(forKey: "customTextUnits"))
    atoms[0]["text"] = textAtom
    missing["atoms"] = atoms
    let missingData = try JSONSerialization.data(withJSONObject: missing)
    XCTAssertThrowsError(try JSONDecoder().decode(InlineDocument.self, from: missingData)) {
      error in
      guard case DecodingError.keyNotFound(let key, _) = error else {
        return XCTFail("expected missing custom text units rejection, received \(error)")
      }
      XCTAssertEqual(key.stringValue, "customTextUnits")
    }
  }

  func testRequiredSchemaFieldsDoNotSilentlyDefault() throws {
    let defaultLimits = InlinePreparationLimits.default
    let encodedLimits = try JSONEncoder().encode(defaultLimits)
    var limits = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedLimits) as? [String: Any])
    limits.removeValue(forKey: "maximumImageAtoms")
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlinePreparationLimits.self,
        from: JSONSerialization.data(withJSONObject: limits)
      )
    )

    let profile = InlineTextUnitHitProfile.default
    var profileObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    profileObject.removeValue(forKey: "includeImages")
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlineTextUnitHitProfile.self,
        from: JSONSerialization.data(withJSONObject: profileObject)
      )
    )
  }

  func testSourceRangeRejectsInteriorGraphemeBoundary() throws {
    let range = try InlineSourceRange(startUTF16: 1, endUTF16: 2)
    XCTAssertThrowsError(try range.validateGraphemeBoundaries(in: "e\u{301}"))
  }

  func testPreparedDocumentRejectsNoncontiguousGlobalSourceRanges() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let firstAtom = try InlineTextAtom(id: "first", text: "a", style: style)
    let secondAtom = try InlineTextAtom(id: "second", text: "b", style: style)
    let shaper = ModelFixedShaper()

    func preparedText(_ atom: InlineTextAtom, start: Int) throws -> PreparedInlineText {
      let range = try InlineSourceRange(
        startUTF16: start, endUTF16: start + atom.text.utf16.count)
      let graphemes = atom.text.map(String.init)
      return try PreparedInlineText(
        atom: atom,
        sourceRange: range,
        graphemes: graphemes,
        shaped: shaper.shape(text: atom.text, style: atom.style, sourceRange: range),
        textBreakEnds: LineBreakOpportunityKernel.breakEnds(
          graphemes: graphemes, sourceStartUTF16: range.startUTF16)
      )
    }

    let document = try InlineDocument(atoms: [.text(firstAtom), .text(secondAtom)])
    let first = try preparedText(firstAtom, start: 0)
    let noncontiguousSecond = try preparedText(secondAtom, start: 100)

    XCTAssertThrowsError(
      try PreparedInlineDocument(
        document: document,
        atoms: [.text(first), .text(noncontiguousSecond)],
        revision: "revision",
        totalTextUTF16Units: 2,
        totalGraphemes: 2,
        totalGlyphs: 0,
        totalRuns: 0
      )
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidSourceRange)
    }
  }

  func testLayoutResultRejectsInvalidResultDimensionsAtValidationAndDecode() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let atom = try InlineAtom.text(InlineTextAtom(id: "text", text: "a", style: style))
    let prepared = try InlinePreparation(shaper: ModelFixedShaper()).prepare(
      document: InlineDocument(atoms: [atom]))
    let valid = try InlineLayoutEngine().layout(prepared: prepared, width: 20)

    let negative = InlineLayoutResult(
      lines: valid.lines,
      width: -1,
      height: valid.height,
      preparationRevision: prepared.revision,
      continuation: nil
    )
    XCTAssertThrowsError(try negative.validate(for: prepared)) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidRenderPlan)
    }
    XCTAssertThrowsError(try InlineRenderPlan(prepared: prepared, layout: negative))

    let nonFinite = InlineLayoutResult(
      lines: valid.lines,
      width: valid.width,
      height: .nan,
      preparationRevision: prepared.revision,
      continuation: nil
    )
    XCTAssertThrowsError(try nonFinite.validate(for: prepared)) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidRenderPlan)
    }

    let encoded = try JSONEncoder().encode(valid)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["height"] = -1
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        InlineLayoutResult.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidRenderPlan)
    }
  }

  func testLayoutResultValidatesItsPreparationRevision() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let atom = try InlineAtom.text(InlineTextAtom(id: "text", text: "a", style: style))
    let prepared = try InlinePreparation(shaper: ModelFixedShaper()).prepare(
      document: InlineDocument(atoms: [atom]))
    let result = try InlineLayoutEngine().layout(prepared: prepared, width: 20)

    XCTAssertNoThrow(try result.validate(for: prepared))
    let stale = InlineLayoutResult(
      lines: result.lines,
      width: result.width,
      height: result.height,
      preparationRevision: "stale",
      continuation: nil
    )
    XCTAssertThrowsError(try stale.validate(for: prepared)) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidRenderPlan)
    }
  }

  func testPreparationRevisionIsFixedLengthDeterministicAndProfileBound() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let atom = try InlineAtom.text(InlineTextAtom(id: "text", text: "a b", style: style))
    let document = try InlineDocument(atoms: [atom])
    let preparation = InlinePreparation(shaper: RevisionCancellableShaper(advance: 1))

    let full = try preparation.prepare(document: document)
    let repeated = try InlinePreparation(shaper: RevisionCancellableShaper(advance: 1))
      .prepare(document: document)
    let cancellable = try preparation.prepare(document: document, cancellation: {})
    let changedShaper = try InlinePreparation(shaper: RevisionCancellableShaper(advance: 2))
      .prepare(document: document)

    XCTAssertEqual(full.revision.utf8.count, 64)
    XCTAssertEqual(full.revision, repeated.revision)
    XCTAssertEqual(cancellable.revision.utf8.count, 64)
    XCTAssertNotEqual(full.revision, cancellable.revision)
    XCTAssertNotEqual(full.revision, changedShaper.revision)

    let changedAtom = try InlineAtom.text(InlineTextAtom(id: "text", text: "a c", style: style))
    let changed = try preparation.prepare(
      document: InlineDocument(atoms: [changedAtom]))
    XCTAssertEqual(changed.revision.utf8.count, full.revision.utf8.count)
    XCTAssertNotEqual(full.revision, changed.revision)
  }

  func testPreparationRevisionRejectsContinuationFromDifferentContent() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let original = try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "text", text: "a b c", style: style))
    ])
    let changed = try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "text", text: "a b d", style: style))
    ])
    let preparation = InlinePreparation(shaper: RevisionCancellableShaper(advance: 1))
    let originalPrepared = try preparation.prepare(document: original)
    let changedPrepared = try preparation.prepare(document: changed)
    let first = try InlineLayoutEngine().layout(
      prepared: originalPrepared, width: 1, maximumLines: 1)
    guard let continuation = first.continuation else {
      return XCTFail("expected a continuation for the bounded layout")
    }

    XCTAssertThrowsError(
      try InlineLayoutEngine().layoutTail(
        prepared: changedPrepared,
        from: continuation,
        width: 1,
        maximumLines: 1
      )
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidContinuation)
    }
  }

  func testPreparedDocumentRejectsRevisionSubstitutionAtInitializerAndDecode() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    func make(_ text: String) throws -> PreparedInlineDocument {
      try InlinePreparation(shaper: ModelFixedShaper()).prepare(
        document: InlineDocument(atoms: [
          .text(InlineTextAtom(id: "text", text: text, style: style))
        ])
      )
    }

    let first = try make("a")
    let second = try make("b")
    XCTAssertNotEqual(first.revision, second.revision)

    XCTAssertThrowsError(
      try PreparedInlineDocument(
        document: second.document,
        atoms: second.atoms,
        revision: first.revision,
        identityContext: second.identityContext,
        totalTextUTF16Units: second.totalTextUTF16Units,
        totalGraphemes: second.totalGraphemes,
        totalGlyphs: second.totalGlyphs,
        totalRuns: second.totalRuns,
        totalImageAtoms: second.totalImageAtoms
      )
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidRenderPlan)
    }

    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(second)) as? [String: Any])
    object["revision"] = first.revision
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        PreparedInlineDocument.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidRenderPlan)
    }
  }

  func testPreparedDocumentRejectsInvalidIdentityContextLimits() throws {
    let metrics = try InlineMetrics(advance: 1, ascent: 1, descent: 0)
    let atom = try InlineVectorAtom(
      id: "vector",
      assetID: InlineAssetID(rawValue: "vector-asset"),
      metrics: metrics
    )
    let document = try InlineDocument(atoms: [.vector(atom)])
    let invalidContext = InlinePreparationIdentityContext.full(
      limits: InlinePreparationLimits(maximumAtoms: -1)
    )

    XCTAssertThrowsError(
      try PreparedInlineDocument(
        document: document,
        atoms: [.vector(PreparedInlineVector(atom: atom))],
        identityContext: invalidContext,
        totalTextUTF16Units: 0,
        totalGraphemes: 0,
        totalGlyphs: 0,
        totalRuns: 0
      )
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidRenderPlan)
    }
  }

  func testPreparedDocumentIdentityContextRoundTripsAndLegacyDefaultRemainsVerifiable() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let document = try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "text", text: "a", style: style))
    ])
    let limits = InlinePreparationLimits(maximumAtoms: 8)
    let prepared = try InlinePreparation(
      shaper: RevisionCancellableShaper(advance: 1),
      limits: limits
    ).prepare(document: document, cancellation: {})

    let encoded = try JSONEncoder().encode(prepared)
    let roundTrip = try JSONDecoder().decode(PreparedInlineDocument.self, from: encoded)
    XCTAssertEqual(roundTrip, prepared)
    XCTAssertEqual(roundTrip.identityContext, .cancellationAware(limits: limits))

    let defaultPrepared = try InlinePreparation(shaper: ModelFixedShaper()).prepare(
      document: document)
    var legacyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(defaultPrepared)) as? [String: Any])
    legacyObject.removeValue(forKey: "identityContext")
    let legacyDecoded = try JSONDecoder().decode(
      PreparedInlineDocument.self,
      from: JSONSerialization.data(withJSONObject: legacyObject)
    )
    XCTAssertEqual(legacyDecoded.revision, defaultPrepared.revision)
    XCTAssertEqual(legacyDecoded.identityContext, .full())

    var unverifiableCustomLegacy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    unverifiableCustomLegacy.removeValue(forKey: "identityContext")
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        PreparedInlineDocument.self,
        from: JSONSerialization.data(withJSONObject: unverifiableCustomLegacy)
      )
    ) { error in
      XCTAssertEqual(error as? InlineLayoutError, .invalidRenderPlan)
    }
  }

  func testPreparationRevisionIncludesLimitsProfile() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let document = try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "text", text: "a", style: style))
    ])
    let defaultPreparation = InlinePreparation(shaper: RevisionCancellableShaper(advance: 1))
    let boundedPreparation = InlinePreparation(
      shaper: RevisionCancellableShaper(advance: 1),
      limits: InlinePreparationLimits(maximumAtoms: 8)
    )
    let defaultPrepared = try defaultPreparation.prepare(document: document, cancellation: {})
    let boundedPrepared = try boundedPreparation.prepare(document: document, cancellation: {})

    XCTAssertEqual(defaultPrepared.atoms, boundedPrepared.atoms)
    XCTAssertEqual(defaultPrepared.totalTextUTF16Units, boundedPrepared.totalTextUTF16Units)
    XCTAssertEqual(defaultPrepared.totalGraphemes, boundedPrepared.totalGraphemes)
    XCTAssertEqual(defaultPrepared.totalGlyphs, boundedPrepared.totalGlyphs)
    XCTAssertEqual(defaultPrepared.totalRuns, boundedPrepared.totalRuns)
    XCTAssertNotEqual(defaultPrepared.revision, boundedPrepared.revision)
  }

  func testPreparationRejectsShaperSourceMappingDrift() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let atom = try InlineAtom.text(InlineTextAtom(id: "text", text: "a", style: style))

    XCTAssertThrowsError(
      try InlinePreparation(shaper: InvalidMappingShaper()).prepare(
        document: InlineDocument(atoms: [atom])
      )
    ) { error in
      guard case .unsupportedShaping = error as? InlineLayoutError else {
        return XCTFail("expected a typed shaping error")
      }
    }
  }

  func testShapedLigatureCannotBreakBetweenGraphemes() throws {
    let sourceRange = try InlineSourceRange(startUTF16: 0, endUTF16: 2)
    let glyph = try InlineGlyph(
      glyphID: 1,
      positionX: 0,
      positionY: 0,
      sourceUTF16Index: 0,
      sourceRange: sourceRange
    )
    let run = try InlineShapedRun(
      glyphs: [glyph],
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
      sourceRange: sourceRange,
      advance: 2,
      ascent: 10,
      descent: 2
    )
    let shaped = try InlineShapedText(
      graphemeRanges: [
        try InlineSourceRange(startUTF16: 0, endUTF16: 1),
        try InlineSourceRange(startUTF16: 1, endUTF16: 2),
      ],
      graphemeAdvances: [2, 0],
      runs: [run],
      metrics: try InlineMetrics(advance: 2, ascent: 10, descent: 2)
    )

    XCTAssertEqual(shaped.graphemeCanBreakAfter, [false, true])
  }

  func testShapedValuesRejectInvalidOwnershipTopology() throws {
    let glyphRange = try InlineSourceRange(startUTF16: 0, endUTF16: 2)
    let glyph = try InlineGlyph(
      glyphID: 1,
      positionX: 0,
      positionY: 0,
      sourceUTF16Index: 0,
      sourceRange: glyphRange
    )
    XCTAssertThrowsError(
      try InlineShapedRun(
        glyphs: [glyph],
        font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12),
        sourceRange: try InlineSourceRange(startUTF16: 0, endUTF16: 1),
        advance: 1,
        ascent: 10,
        descent: 2
      )
    )

    XCTAssertThrowsError(
      try InlineShapedText(
        graphemeRanges: [
          try InlineSourceRange(startUTF16: 0, endUTF16: 2),
          try InlineSourceRange(startUTF16: 1, endUTF16: 3),
        ],
        graphemeAdvances: [1, 1],
        runs: [],
        metrics: try InlineMetrics(advance: 2, ascent: 10, descent: 2)
      )
    )
  }

  func testRelayoutKeepsPreparedAndRevealIdentityWidthIndependent() throws {
    let style = try InlineTextStyle(
      font: FontDescriptor(postScriptName: "Helvetica", pointSize: 12))
    let document = try InlineDocument(atoms: [
      .text(InlineTextAtom(id: "text", text: "a b c d e f", style: style))
    ])
    let prepared = try InlinePreparation(shaper: ModelFixedShaper()).prepare(document: document)
    let engine = try InlineLayoutEngine(leading: 2)
    let wideLayout = try engine.layout(prepared: prepared, width: 6)
    let narrowLayout = try engine.layout(prepared: prepared, width: 2)
    let widePlan = try InlineRenderPlan(prepared: prepared, layout: wideLayout)
    let narrowPlan = try InlineRenderPlan(prepared: prepared, layout: narrowLayout)
    let textPlan = try InlineRevealPlanBuilder(secondsPerUnit: 0.1).textPlan(prepared: prepared)
    let wideSchedule = try InlineRenderRevealSchedule(
      plan: widePlan, assets: InlineAssetStore(), textPlan: textPlan)
    let narrowSchedule = try InlineRenderRevealSchedule(
      plan: narrowPlan, assets: InlineAssetStore(), textPlan: textPlan)

    XCTAssertNotEqual(wideLayout.lines.count, narrowLayout.lines.count)
    XCTAssertEqual(widePlan.prepared.revision, narrowPlan.prepared.revision)
    XCTAssertEqual(wideSchedule, narrowSchedule)
    XCTAssertEqual(
      try InlineRenderRevealPhase(rawValue: 0.37),
      try InlineRenderRevealPhase(rawValue: 0.37))
  }

  func testDecodedShapedValuesRejectInvalidRangeTopology() throws {
    let valid = try InlineShapedText(
      graphemeRanges: [
        try InlineSourceRange(startUTF16: 0, endUTF16: 1),
        try InlineSourceRange(startUTF16: 1, endUTF16: 2),
      ],
      graphemeAdvances: [1, 1],
      runs: [],
      metrics: try InlineMetrics(advance: 2, ascent: 10, descent: 2)
    )
    let encoded = try JSONEncoder().encode(valid)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["graphemeRanges"] = [
      ["startUTF16": 0, "endUTF16": 2],
      ["startUTF16": 1, "endUTF16": 3],
    ]
    let malformed = try JSONSerialization.data(withJSONObject: object)

    XCTAssertThrowsError(try JSONDecoder().decode(InlineShapedText.self, from: malformed))
  }

  func testEmptyGeometryProviderFailsExplicitlyForVectorLookup() throws {
    let id = try InlineAssetID(rawValue: "missing-vector")
    XCTAssertThrowsError(
      try InlineEmptyAssetGeometryProvider().resolveGeometry(assetID: id, version: 1)
    ) { error in
      XCTAssertEqual(
        error as? InlineAssetResolutionError,
        .missingGeometry(id, version: 1)
      )
    }
  }
}

private struct ModelFixedShaper: InlineTextShaping {
  func shape(text: String, style: InlineTextStyle, sourceRange: InlineSourceRange) throws
    -> InlineShapedText
  {
    let ranges = try text.enumerated().map { offset, character in
      let start = sourceRange.startUTF16 + text.prefix(offset).utf16.count
      return try InlineSourceRange(
        startUTF16: start,
        endUTF16: start + String(character).utf16.count
      )
    }
    return try InlineShapedText(
      graphemeRanges: ranges,
      graphemeAdvances: Array(repeating: 1, count: ranges.count),
      runs: [],
      metrics: try InlineMetrics(advance: Double(ranges.count), ascent: 10, descent: 2)
    )
  }
}

private struct RevisionCancellableShaper: CancellableInlineTextShaping {
  let advance: Double

  func shape(text: String, style: InlineTextStyle, sourceRange: InlineSourceRange) throws
    -> InlineShapedText
  {
    let ranges = try text.enumerated().map { offset, character in
      let start = sourceRange.startUTF16 + text.prefix(offset).utf16.count
      return try InlineSourceRange(
        startUTF16: start,
        endUTF16: start + String(character).utf16.count
      )
    }
    return try InlineShapedText(
      graphemeRanges: ranges,
      graphemeAdvances: Array(repeating: advance, count: ranges.count),
      runs: [],
      metrics: try InlineMetrics(advance: advance * Double(ranges.count), ascent: 10, descent: 2)
    )
  }

  func shape(
    text: String,
    style: InlineTextStyle,
    sourceRange: InlineSourceRange,
    cancellation: InlineCancellationCheck
  ) throws -> InlineShapedText {
    try cancellation()
    return try shape(text: text, style: style, sourceRange: sourceRange)
  }
}

private struct InvalidMappingShaper: InlineTextShaping {
  func shape(text: String, style: InlineTextStyle, sourceRange: InlineSourceRange) throws
    -> InlineShapedText
  {
    try InlineShapedText(
      graphemeRanges: [try InlineSourceRange(startUTF16: 1, endUTF16: 2)],
      graphemeAdvances: [1],
      runs: [],
      metrics: try InlineMetrics(advance: 1, ascent: 10, descent: 2)
    )
  }
}
