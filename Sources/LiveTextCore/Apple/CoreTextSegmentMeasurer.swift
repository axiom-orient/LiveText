#if canImport(CoreText)
  import CoreText
  import Foundation

  /// Segment measurer backed by CoreText.
  public struct CoreTextSegmentMeasurer: SegmentMeasuring, Sendable {
    /// Creates a CoreText-backed segment measurer.
    public init() {}

    /// Measures a segment request with CoreText.
    public func measure(_ request: SegmentMeasurementRequest) throws -> SegmentMeasurement {
      if let scalarWidth = Self.singleScalarWidth(for: request.text, font: request.font) {
        return SegmentMeasurement(
          width: scalarWidth,
          containsCJK: isCJK(request.text),
          breakableAdvances: nil
        )
      }

      var context = MeasurementContext(request: request)
      let totalWidth = context.totalWidth

      let breakableAdvances: [Double]?
      switch request.breakableMode {
      case .none:
        breakableAdvances = nil
      case .sumGraphemes:
        breakableAdvances = measureSumGraphemeAdvances(request, context: &context)
      case .exactPrefix:
        breakableAdvances = measureExactPrefixAdvances(request, context: context)
      case .pairContext:
        breakableAdvances = measurePairContextAdvances(request, context: &context)
      }

      return SegmentMeasurement(
        width: totalWidth,
        containsCJK: isCJK(request.text),
        breakableAdvances: breakableAdvances?.isEmpty == true ? nil : breakableAdvances
      )
    }

    private static func singleScalarWidth(for text: String, font descriptor: FontDescriptor)
      -> Double?
    {
      // Keep this shortcut ASCII-only; non-ASCII text may require font
      // fallback, which CTLine/CTTypesetter resolves for us.
      guard text.utf16.count == 1, let value = text.utf16.first, value < 0x80 else {
        return nil
      }

      let font = CTFontCreateWithName(
        descriptor.postScriptName as CFString, descriptor.pointSize, nil)
      var character = UniChar(value)
      var glyph = CGGlyph()
      guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else {
        return nil
      }

      var advance = CGSize.zero
      guard CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1) == 1 else {
        return nil
      }
      return Double(advance.width)
    }

    private func measureExactPrefixAdvances(
      _ request: SegmentMeasurementRequest,
      context: MeasurementContext
    ) -> [Double]? {
      let graphemes = graphemeClustersWithUTF16Offsets(request.text)
      guard graphemes.count > 1 else { return nil }

      var advances: [Double] = []
      advances.reserveCapacity(graphemes.count)
      var previousWidth = 0.0

      for grapheme in graphemes.dropLast() {
        let prefixWidth = context.lineWidth(endUTF16: grapheme.endUTF16)
        advances.append(prefixWidth - previousWidth)
        previousWidth = prefixWidth
      }
      advances.append(context.totalWidth - previousWidth)

      return advances
    }

    private func measureSumGraphemeAdvances(
      _ request: SegmentMeasurementRequest,
      context: inout MeasurementContext
    ) -> [Double]? {
      let graphemes = graphemeClustersWithUTF16Offsets(request.text)
      guard graphemes.count > 1 else { return nil }

      if let independentAdvances = context.independentGraphemeAdvances(for: graphemes) {
        return independentAdvances
      }

      var advances: [Double] = []
      advances.reserveCapacity(graphemes.count)

      for grapheme in graphemes {
        advances.append(context.lineWidth(for: grapheme.text))
      }

      return advances
    }

    private func measurePairContextAdvances(
      _ request: SegmentMeasurementRequest,
      context: inout MeasurementContext
    ) -> [Double]? {
      let graphemes = graphemeClustersWithUTF16Offsets(request.text)
      guard graphemes.count > 1 else { return nil }

      var advances: [Double] = []
      advances.reserveCapacity(graphemes.count)

      var previousGrapheme: (text: String, startUTF16: Int, endUTF16: Int)?
      var previousWidth: Double?

      for grapheme in graphemes {
        let currentWidth = context.lineWidth(
          startUTF16: grapheme.startUTF16,
          endUTF16: grapheme.endUTF16
        )

        if let previousGrapheme, let previousWidth {
          let pairWidth = context.lineWidth(
            startUTF16: previousGrapheme.startUTF16,
            endUTF16: grapheme.endUTF16
          )
          advances.append(pairWidth - previousWidth)
        } else {
          advances.append(currentWidth)
        }

        previousGrapheme = grapheme
        previousWidth = currentWidth
      }

      return advances
    }
  }

  private struct MeasurementContext {
    let font: CTFont
    let attributes: [NSAttributedString.Key: Any]
    let attributedString: CFAttributedString
    let typesetter: CTTypesetter?
    let totalWidth: Double

    private var lineWidthCache: [String: Double] = [:]

    init(request: SegmentMeasurementRequest) {
      font = CTFontCreateWithName(
        request.font.postScriptName as CFString, request.font.pointSize, nil)
      attributes = MeasurementContext.makeAttributes(for: request, font: font)
      attributedString = NSAttributedString(string: request.text, attributes: attributes)
      if request.breakableMode == .exactPrefix || request.breakableMode == .pairContext {
        let typesetter = CTTypesetterCreateWithAttributedString(attributedString)
        self.typesetter = typesetter
        totalWidth = MeasurementContext.measureLineWidth(
          typesetter: typesetter,
          endUTF16: request.text.utf16Length
        )
      } else {
        // These modes need only the unwrapped width. CTLine avoids creating
        // a typesetter that is otherwise never queried.
        typesetter = nil
        totalWidth = MeasurementContext.measureLineWidth(
          line: CTLineCreateWithAttributedString(attributedString)
        )
      }
    }

    func lineWidth(endUTF16: Int) -> Double {
      MeasurementContext.measureLineWidth(
        typesetter: requireTypesetter(),
        endUTF16: endUTF16
      )
    }

    func lineWidth(startUTF16: Int, endUTF16: Int) -> Double {
      MeasurementContext.measureLineWidth(
        typesetter: requireTypesetter(),
        startUTF16: startUTF16,
        endUTF16: endUTF16
      )
    }

    mutating func lineWidth(for text: String) -> Double {
      if let cached = lineWidthCache[text] {
        return cached
      }

      let width =
        singleGraphemeAdvance(for: text)
        ?? {
          let attributedString = NSAttributedString(string: text, attributes: attributes)
          return MeasurementContext.measureLineWidth(
            typesetter: CTTypesetterCreateWithAttributedString(attributedString),
            endUTF16: text.utf16Length
          )
        }()
      lineWidthCache[text] = width
      return width
    }

    private func singleGraphemeAdvance(for text: String) -> Double? {
      guard text.utf16.count == 1, let value = text.utf16.first, value < 0x80 else {
        return nil
      }

      var character = UniChar(value)
      var glyph = CGGlyph()
      guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else {
        return nil
      }

      var advance = CGSize.zero
      guard CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1) == 1 else {
        return nil
      }
      return Double(advance.width)
    }

    fileprivate func independentGraphemeAdvances(
      for graphemes: [(text: String, startUTF16: Int, endUTF16: Int)]
    ) -> [Double]? {
      // Raw glyph metrics do not perform fallback or complex-script shaping.
      // Restrict this path to ASCII, where each grapheme is one scalar and
      // the independent advance is the shaped advance contract we need.
      guard
        graphemes.allSatisfy({
          $0.text.utf16.count == 1 && $0.text.utf16.first! < 0x80
        })
      else {
        return nil
      }

      var characters = graphemes.map { UniChar($0.text.utf16.first!) }
      var glyphs = [CGGlyph](repeating: 0, count: graphemes.count)
      let converted = characters.withUnsafeMutableBufferPointer { charactersBuffer in
        glyphs.withUnsafeMutableBufferPointer { glyphsBuffer in
          CTFontGetGlyphsForCharacters(
            font,
            charactersBuffer.baseAddress!,
            glyphsBuffer.baseAddress!,
            graphemes.count
          )
        }
      }
      guard converted, glyphs.allSatisfy({ $0 != 0 }) else {
        return nil
      }

      var advances = [CGSize](repeating: .zero, count: graphemes.count)
      glyphs.withUnsafeBufferPointer { glyphsBuffer in
        advances.withUnsafeMutableBufferPointer { advancesBuffer in
          _ = CTFontGetAdvancesForGlyphs(
            font,
            .horizontal,
            glyphsBuffer.baseAddress!,
            advancesBuffer.baseAddress!,
            graphemes.count
          )
        }
      }
      return advances.map { Double($0.width) }
    }

    private func requireTypesetter() -> CTTypesetter {
      precondition(typesetter != nil, "Typesetter required for contextual measurement")
      return typesetter!
    }

    private static func makeAttributes(
      for request: SegmentMeasurementRequest,
      font: CTFont
    ) -> [NSAttributedString.Key: Any] {
      var attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font
      ]

      if let localeIdentifier = request.localeIdentifier ?? request.font.localeIdentifier,
        localeIdentifier.isEmpty == false
      {
        attributes[NSAttributedString.Key(rawValue: kCTLanguageAttributeName as String)] =
          localeIdentifier
      }

      return attributes
    }

    private static func measureLineWidth(typesetter: CTTypesetter, endUTF16: Int) -> Double {
      measureLineWidth(typesetter: typesetter, startUTF16: 0, endUTF16: endUTF16)
    }

    private static func measureLineWidth(line: CTLine) -> Double {
      CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    private static func measureLineWidth(typesetter: CTTypesetter, startUTF16: Int, endUTF16: Int)
      -> Double
    {
      let length = max(0, endUTF16 - startUTF16)
      let line = CTTypesetterCreateLine(typesetter, CFRange(location: startUTF16, length: length))
      return CTLineGetTypographicBounds(line, nil, nil, nil)
    }
  }
#endif
