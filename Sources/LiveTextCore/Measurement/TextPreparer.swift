import Foundation

/// Converts analysis output into reusable measured prepared text.
public struct TextPreparer<Segmenter: WordSegmenting, Measurer: SegmentMeasuring>: Sendable {
  /// The tokenizer backend used when preparing raw source text.
  public let segmenter: Segmenter

  /// The measurement backend used for segment widths.
  public let measurer: Measurer

  /// The engine profile that controls preparation policy.
  public let profile: EngineProfile

  /// Creates a text preparer.
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

  /// Analyzes and prepares raw source text.
  public func prepare(
    _ text: String,
    font: FontDescriptor,
    options: PrepareOptions = PrepareOptions()
  ) throws -> PreparedText {
    var resolvedOptions = options
    if resolvedOptions.localeIdentifier == nil {
      resolvedOptions.localeIdentifier = font.localeIdentifier
    }

    let analysis = makeAnalyzer().analyze(text, options: resolvedOptions)
    return try prepare(
      source: text,
      analysis: analysis,
      font: font,
      options: resolvedOptions
    )
  }

  /// Prepares an existing analysis result without re-running analysis.
  public func prepare(
    source: String,
    analysis: TextAnalysis,
    font: FontDescriptor,
    options: PrepareOptions
  ) throws -> PreparedText {
    var session = PreparationSession(
      measurer: measurer,
      source: source,
      analysis: analysis,
      font: font,
      options: options,
      profile: profile
    )
    return try session.run()
  }
}
