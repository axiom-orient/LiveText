import Foundation

/// Coordinates text analysis, measurement, and line layout for prepared text.
public struct LiveTextEngine<Segmenter: WordSegmenting, Measurer: SegmentMeasuring>: Sendable {
  /// The word-boundary adapter used during analysis.
  public let segmenter: Segmenter

  /// The width measurement adapter used during preparation.
  public let measurer: Measurer

  /// Tunable layout policy values used by analysis, measurement, and line breaking.
  public let profile: EngineProfile

  /// Creates an engine from explicit segmentation and measurement backends.
  public init(
    segmenter: Segmenter,
    measurer: Measurer,
    profile: EngineProfile = .appleRecommended
  ) {
    self.segmenter = segmenter
    self.measurer = measurer
    self.profile = profile
  }

  private func makeAnalyzer() -> TextAnalyzer<Segmenter> {
    TextAnalyzer(segmenter: segmenter, profile: profile)
  }

  private func makePreparer() -> TextPreparer<Segmenter, Measurer> {
    TextPreparer(segmenter: segmenter, measurer: measurer, profile: profile)
  }

  func validate(maxWidth: Double) throws {
    guard maxWidth.isFinite, maxWidth >= 0 else {
      throw LiveTextCoreError.invalidWidth(maxWidth)
    }
  }

  func validate(lineHeight: Double) throws {
    guard lineHeight.isFinite, lineHeight >= 0 else {
      throw LiveTextCoreError.invalidFragmentConfiguration(
        "lineHeight must be finite and non-negative"
      )
    }
  }

  func validatedVerticalOrigin(
    index: Int,
    lineHeight: Double,
    context: String
  ) throws -> Double {
    guard index >= 0 else {
      throw LiveTextCoreError.invalidFragmentConfiguration(
        "\(context) index must be non-negative"
      )
    }
    let origin = Double(index) * lineHeight
    guard origin.isFinite, (origin + lineHeight).isFinite else {
      throw LiveTextCoreError.invalidFragmentConfiguration(
        "\(context) vertical range overflowed"
      )
    }
    return origin
  }

  func validateHorizontalExtent(
    originX: Double,
    width: Double,
    context: String
  ) throws {
    guard originX.isFinite, width.isFinite, (originX + width).isFinite else {
      throw LiveTextCoreError.invalidFragmentConfiguration(
        "\(context) horizontal range must remain finite"
      )
    }
  }

  func incrementedLayoutIndex(_ index: Int, context: String) throws -> Int {
    let (next, overflow) = index.addingReportingOverflow(1)
    guard !overflow else {
      throw LiveTextCoreError.invalidFragmentConfiguration(
        "\(context) index overflowed"
      )
    }
    return next
  }

  func validatedLayoutHeight(
    count: Int,
    lineHeight: Double,
    context: String
  ) throws -> Double {
    guard count >= 0 else {
      throw LiveTextCoreError.invalidFragmentConfiguration(
        "\(context) count must be non-negative"
      )
    }
    let height = Double(count) * lineHeight
    guard height.isFinite else {
      throw LiveTextCoreError.invalidFragmentConfiguration(
        "\(context) height overflowed"
      )
    }
    return height
  }

  /// Runs width-independent text analysis without measuring glyph advances.
  public func analyze(
    _ text: String,
    options: PrepareOptions = PrepareOptions()
  ) -> TextAnalysis {
    makeAnalyzer().analyze(text, options: options)
  }

  /// Builds reusable prepared text for the supplied font and options.
  public func prepare(
    _ text: String,
    font: FontDescriptor,
    options: PrepareOptions = PrepareOptions()
  ) throws -> PreparedText {
    try makePreparer().prepare(text, font: font, options: options)
  }

  /// Counts fixed-width lines and returns the resulting total height.
  public func layout(
    prepared: PreparedText,
    maxWidth: Double,
    lineHeight: Double
  ) throws -> LayoutResult {
    try validate(maxWidth: maxWidth)
    try validate(lineHeight: lineHeight)
    let lineCount = countPreparedLines(prepared: prepared, maxWidth: maxWidth)
    let height = try validatedLayoutHeight(
      count: lineCount, lineHeight: lineHeight, context: "fixed layout"
    )
    return LayoutResult(lineCount: lineCount, height: height)
  }

  /// Measures fixed-width line count and maximum line width without materializing line text.
  public func measureLineStats(
    prepared: PreparedText,
    maxWidth: Double
  ) throws -> LineStats {
    try validate(maxWidth: maxWidth)
    return measurePreparedLineGeometry(prepared: prepared, maxWidth: maxWidth)
  }

  /// Returns the next fixed-width line range starting at a layout cursor.
  public func layoutNextLineRange(
    prepared: PreparedText,
    start: LayoutCursor,
    maxWidth: Double
  ) throws -> LayoutLineRange? {
    try validate(maxWidth: maxWidth)
    return try LiveTextCore.layoutNextLineRange(
      prepared: prepared, start: start, maxWidth: maxWidth)
  }

  /// Walks every fixed-width line range and invokes `onLine` for each range.
  public func walkLineRanges(
    prepared: PreparedText,
    maxWidth: Double,
    onLine: @escaping (LayoutLineRange) -> Void
  ) throws {
    try validate(maxWidth: maxWidth)
    _ = walkPreparedLinesRaw(prepared: prepared, maxWidth: maxWidth) {
      width,
      startSegmentIndex,
      startGraphemeIndex,
      endSegmentIndex,
      endGraphemeIndex in
      onLine(
        makeLayoutLineRange(
          width: width,
          startSegmentIndex: startSegmentIndex,
          startGraphemeIndex: startGraphemeIndex,
          endSegmentIndex: endSegmentIndex,
          endGraphemeIndex: endGraphemeIndex
        )
      )
    }
  }

  /// Lays out fixed-width lines and materializes each line's display text.
  public func layoutWithLines(
    prepared: PreparedText,
    maxWidth: Double,
    lineHeight: Double
  ) throws -> LayoutLinesResult {
    try validate(maxWidth: maxWidth)
    try validate(lineHeight: lineHeight)
    var lines: [LayoutLine] = []
    var materializer = LineTextMaterializer(prepared: prepared)
    _ = walkPreparedLinesRaw(prepared: prepared, maxWidth: maxWidth) {
      width,
      startSegmentIndex,
      startGraphemeIndex,
      endSegmentIndex,
      endGraphemeIndex in
      let range = makeLayoutLineRange(
        width: width,
        startSegmentIndex: startSegmentIndex,
        startGraphemeIndex: startGraphemeIndex,
        endSegmentIndex: endSegmentIndex,
        endGraphemeIndex: endGraphemeIndex
      )
      lines.append(
        LayoutLine(
          text: materializer.build(start: range.start, end: range.end),
          width: range.width,
          start: range.start,
          end: range.end
        )
      )
    }
    return LayoutLinesResult(
      lineCount: lines.count,
      height: try validatedLayoutHeight(
        count: lines.count, lineHeight: lineHeight, context: "fixed line layout"
      ),
      lines: lines
    )
  }
}

private func makeLayoutLineRange(
  width: Double,
  startSegmentIndex: Int,
  startGraphemeIndex: Int,
  endSegmentIndex: Int,
  endGraphemeIndex: Int
) -> LayoutLineRange {
  LayoutLineRange(
    width: width,
    start: LayoutCursor(segmentIndex: startSegmentIndex, graphemeIndex: startGraphemeIndex),
    end: LayoutCursor(segmentIndex: endSegmentIndex, graphemeIndex: endGraphemeIndex)
  )
}

#if canImport(CoreText)
  extension LiveTextEngine
  where Segmenter == CoreFoundationWordSegmenter, Measurer == CoreTextSegmentMeasurer {
    /// Creates the default Apple-platform engine backed by CoreFoundation tokenization and CoreText measurement.
    public static func appleDefault(
      profile: EngineProfile = .appleRecommended
    ) -> LiveTextEngine<CoreFoundationWordSegmenter, CoreTextSegmentMeasurer> {
      LiveTextEngine(
        segmenter: CoreFoundationWordSegmenter(),
        measurer: CoreTextSegmentMeasurer(),
        profile: profile
      )
    }
  }
#endif
