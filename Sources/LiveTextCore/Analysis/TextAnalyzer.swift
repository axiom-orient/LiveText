import Foundation

/// Performs width-independent text normalization, segmentation, and chunking.
public struct TextAnalyzer<Segmenter: WordSegmenting>: Sendable {
  /// The tokenizer backend used for word-boundary discovery.
  public let segmenter: Segmenter

  /// The engine profile that controls analysis policy.
  public let profile: EngineProfile

  /// Creates a text analyzer.
  public init(
    segmenter: Segmenter,
    profile: EngineProfile = .appleRecommended
  ) {
    self.segmenter = segmenter
    self.profile = profile
  }

  /// Analyzes source text into normalized text, segments, and chunks.
  public func analyze(
    _ text: String,
    options: PrepareOptions = PrepareOptions()
  ) -> TextAnalysis {
    let whiteSpaceProfile = whiteSpaceProfile(for: options.whiteSpace)
    let normalized: String

    switch whiteSpaceProfile.mode {
    case .preWrap:
      normalized = normalizeWhitespacePreWrap(text)
    case .normal:
      normalized = normalizeWhitespaceNormal(text)
    }

    guard normalized.isEmpty == false else {
      return TextAnalysis(normalized: normalized, segments: [], chunks: [])
    }

    let tokens = segmenter.tokenize(normalized, localeIdentifier: options.localeIdentifier)
    var segments = buildMergedSegmentation(
      normalized: normalized,
      profile: profile,
      whiteSpaceProfile: whiteSpaceProfile,
      tokens: tokens
    )

    if options.wordBreak == .keepAll {
      segments = mergeKeepAllTextSegments(segments)
    }

    return TextAnalysis(
      normalized: normalized,
      segments: segments,
      chunks: compileAnalysisChunks(segments, whiteSpaceProfile: whiteSpaceProfile)
    )
  }
}
