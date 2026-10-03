import Foundation

struct PreparationSession<Measurer: SegmentMeasuring> {
  let measurer: Measurer
  let source: String
  let analysis: TextAnalysis
  let font: FontDescriptor
  let options: PrepareOptions
  let profile: EngineProfile
  let localeIdentifier: String?

  private(set) var measurementCache: [SegmentMeasurementRequest: SegmentMeasurement] = [:]
  private(set) var preparedSegments: [PreparedSegment]
  private(set) var simpleFastPath: Bool
  private(set) var preparedStartByAnalysisIndex: [Int]

  init(
    measurer: Measurer,
    source: String,
    analysis: TextAnalysis,
    font: FontDescriptor,
    options: PrepareOptions,
    profile: EngineProfile
  ) {
    self.measurer = measurer
    self.source = source
    self.analysis = analysis
    self.font = font
    self.options = options
    self.profile = profile
    localeIdentifier = options.localeIdentifier ?? font.localeIdentifier
    preparedSegments = []
    preparedSegments.reserveCapacity(analysis.segments.count)
    simpleFastPath = analysis.chunks.count <= 1
    preparedStartByAnalysisIndex = Array(repeating: 0, count: analysis.segments.count)
  }

  mutating func run() throws -> PreparedText {
    let discretionaryHyphenWidth = try measureWidth(of: "-", breakableMode: .none)
    let spaceWidth = try measureWidth(of: " ", breakableMode: .none)
    let tabStopAdvance = spaceWidth * 8.0

    guard analysis.segments.isEmpty == false else {
      return PreparedText(
        source: source,
        normalized: analysis.normalized,
        font: font,
        options: options,
        profile: profile,
        segments: [],
        chunks: [],
        simpleLineWalkFastPath: true,
        discretionaryHyphenWidth: discretionaryHyphenWidth,
        tabStopAdvance: tabStopAdvance
      )
    }

    try appendPreparedSegments(discretionaryHyphenWidth: discretionaryHyphenWidth)

    let chunks = mapAnalysisChunksToPreparedChunks(
      analysisChunks: analysis.chunks,
      preparedStartByAnalysisIndex: preparedStartByAnalysisIndex,
      preparedEndSegmentIndex: preparedSegments.count
    )

    return PreparedText(
      source: source,
      normalized: analysis.normalized,
      font: font,
      options: options,
      profile: profile,
      segments: preparedSegments,
      chunks: chunks,
      simpleLineWalkFastPath: simpleFastPath,
      discretionaryHyphenWidth: discretionaryHyphenWidth,
      tabStopAdvance: tabStopAdvance
    )
  }

  private mutating func appendPreparedSegments(discretionaryHyphenWidth: Double) throws {
    for index in analysis.segments.indices {
      preparedStartByAnalysisIndex[index] = preparedSegments.count
      let segment = analysis.segments[index]

      switch segment.kind {
      case .softHyphen:
        simpleFastPath = false
        preparedSegments.append(
          PreparedSegment(
            text: segment.text,
            isWordLike: segment.isWordLike,
            kind: .softHyphen,
            startUTF16: segment.startUTF16,
            width: 0,
            lineEndFitAdvance: discretionaryHyphenWidth,
            lineEndPaintAdvance: discretionaryHyphenWidth,
            breakableAdvances: nil
          )
        )
      case .hardBreak, .tab:
        simpleFastPath = false
        preparedSegments.append(
          PreparedSegment(
            text: segment.text,
            isWordLike: segment.isWordLike,
            kind: segment.kind,
            startUTF16: segment.startUTF16,
            width: 0,
            lineEndFitAdvance: 0,
            lineEndPaintAdvance: 0,
            breakableAdvances: nil
          )
        )
      case .text where isCJK(segment.text):
        try appendPreparedCJKTextSegments(from: segment)
      default:
        try appendMeasuredTextSegment(
          text: segment.text,
          kind: segment.kind,
          startUTF16: segment.startUTF16,
          isWordLike: segment.isWordLike,
          allowOverflowBreaks: true
        )
      }
    }
  }

  private mutating func appendPreparedCJKTextSegments(from segment: AnalysisSegment) throws {
    let baseUnits = buildBaseCJKUnits(segment.text, profile: profile)
    let measuredUnits =
      options.wordBreak == .keepAll
      ? mergeKeepAllTextUnits(baseUnits)
      : baseUnits

    for unit in measuredUnits {
      try appendMeasuredTextSegment(
        text: unit.text,
        kind: .text,
        startUTF16: segment.startUTF16 + unit.startUTF16,
        isWordLike: segment.isWordLike,
        allowOverflowBreaks: options.wordBreak == .keepAll || isCJK(unit.text) == false
      )
    }
  }

  private mutating func appendMeasuredTextSegment(
    text: String,
    kind: SegmentBreakKind,
    startUTF16: Int,
    isWordLike: Bool,
    allowOverflowBreaks: Bool
  ) throws {
    let measurement = try measure(
      SegmentMeasurementRequest(
        text: text,
        font: font,
        localeIdentifier: localeIdentifier,
        breakableMode: breakableMeasurementMode(
          for: text,
          isWordLike: isWordLike,
          allowOverflowBreaks: allowOverflowBreaks,
          profile: profile
        )
      )
    )

    pushMeasuredSegment(
      text: text,
      kind: kind,
      startUTF16: startUTF16,
      isWordLike: isWordLike,
      width: measurement.width,
      breakableAdvances: measurement.breakableAdvances
    )
  }

  private mutating func pushMeasuredSegment(
    text: String,
    kind: SegmentBreakKind,
    startUTF16: Int,
    isWordLike: Bool,
    width: Double,
    breakableAdvances: [Double]?
  ) {
    if kind != .text && kind != .space && kind != .zeroWidthBreak {
      simpleFastPath = false
    }

    let lineEndFitAdvance: Double
    switch kind {
    case .space, .preservedSpace, .zeroWidthBreak:
      lineEndFitAdvance = 0
    default:
      lineEndFitAdvance = width
    }

    let lineEndPaintAdvance: Double
    switch kind {
    case .space, .zeroWidthBreak:
      lineEndPaintAdvance = 0
    default:
      lineEndPaintAdvance = width
    }

    preparedSegments.append(
      PreparedSegment(
        text: text,
        isWordLike: isWordLike,
        kind: kind,
        startUTF16: startUTF16,
        width: width,
        lineEndFitAdvance: lineEndFitAdvance,
        lineEndPaintAdvance: lineEndPaintAdvance,
        breakableAdvances: breakableAdvances
      )
    )
  }

  private mutating func measureWidth(of text: String, breakableMode: BreakableMeasurementMode)
    throws -> Double
  {
    try measure(
      SegmentMeasurementRequest(
        text: text,
        font: font,
        localeIdentifier: localeIdentifier,
        breakableMode: breakableMode
      )
    ).width
  }

  private mutating func measure(_ request: SegmentMeasurementRequest) throws -> SegmentMeasurement {
    if let cached = measurementCache[request] {
      return cached
    }

    let measured = try measurer.measure(request)
    measurementCache[request] = measured
    return measured
  }
}
