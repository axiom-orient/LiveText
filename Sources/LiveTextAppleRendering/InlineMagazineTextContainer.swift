#if canImport(UIKit)
import CoreText
import LiveTextLayout
import UIKit

/// Bridges LiveText's contour geometry to one native editable text surface.
/// The native text system owns Unicode shaping, bidi, wrapping and input;
/// LiveText supplies the available intervals for each full-height line band.
public final class InlineMagazineTextContainer: NSTextContainer {
  public var magazineFlow: InlineMagazineFlow? {
    didSet {
      guard magazineFlow != oldValue else { return }
      if let manager = textLayoutManager {
        if let range = manager.textContentManager?.documentRange {
          manager.invalidateLayout(for: range)
        }
      } else {
        layoutManager?.textContainerChangedGeometry(self)
      }
    }
  }

  public override var isSimpleRectangularTextContainer: Bool {
    Self.preservesNativeRectangle(flow: magazineFlow, size: size)
      && exclusionPaths.isEmpty && maximumNumberOfLines == 0
  }

  public override func lineFragmentRect(
    forProposedRect proposedRect: CGRect,
    at characterIndex: Int,
    writingDirection baseWritingDirection: NSWritingDirection,
    remaining remainingRect: UnsafeMutablePointer<CGRect>?
  ) -> CGRect {
    guard let flow = magazineFlow,
      !Self.preservesNativeRectangle(flow: flow, size: size)
    else {
      return super.lineFragmentRect(
        forProposedRect: proposedRect, at: characterIndex,
        writingDirection: baseWritingDirection, remaining: remainingRect)
    }
    remainingRect?.pointee = .zero
    let content = CGRect(
      x: flow.contentRect.x, y: flow.contentRect.y,
      width: flow.contentRect.width, height: flow.contentRect.height)
    var proposal = proposedRect
    let rightToLeft = baseWritingDirection == .rightToLeft

    while proposal.minY < content.maxY {
      var nativeRemainder = CGRect.zero
      let native = super.lineFragmentRect(
        forProposedRect: proposal, at: characterIndex,
        writingDirection: baseWritingDirection, remaining: &nativeRemainder)
      let clippedRemainder = nativeRemainder.intersection(content)
      nativeRemainder = clippedRemainder.isNull || clippedRemainder.isEmpty ? .zero : clippedRemainder
      let band = native.intersection(content)
      guard !band.isNull, !band.isInfinite, band.width > 0, band.height > 0 else {
        if !nativeRemainder.isEmpty, nativeRemainder != proposal {
          proposal = nativeRemainder
          continue
        }
        return .zero
      }
      let fragments: [InlineFlowFragment]
      let contourNarrowsLine: Bool
      let maximumFlankWidth: CGFloat
      do {
        // If only the trailing edge occupies at most half a line, a small
        // downward move is preferable to splitting that line around the photo.
        // Only move a fresh full-width proposal: a remainder already has text
        // on its baseline. Other contours must also leave the new line clear.
        if band.minX == content.minX, band.width == content.width,
          let bottom = flow.contours.map(\.bounds).filter({
            $0.minX < band.maxX && $0.maxX > band.minX
              && $0.minY < band.minY && $0.maxY > band.minY
              && $0.maxY - band.minY <= band.height * 0.5
          }).map(\.maxY).max(), bottom + band.height <= content.maxY
        {
          let below = try flow.fragments(forLine: InlineFlowRect(
            x: content.minX, y: bottom, width: content.width, height: band.height))
          if below.count == 1, below[0].originX == content.minX,
            below[0].maxWidth == content.width
          {
            proposal = CGRect(x: content.minX, y: bottom,
                              width: content.width, height: proposedRect.height)
            continue
          }
        }
        fragments = try flow.fragments(forLine: InlineFlowRect(
          x: band.minX, y: band.minY, width: band.width, height: band.height))
        let wholeRow = try flow.fragments(forLine: InlineFlowRect(
          x: content.minX, y: band.minY, width: content.width, height: band.height))
        contourNarrowsLine = wholeRow.count != 1 || wholeRow.first?.maxWidth != content.width
        maximumFlankWidth = wholeRow.map(\.maxWidth).max() ?? 0
      } catch {
        // The public flow and native intersection were already validated. An
        // invariant failure must not silently switch to a second layout engine.
        preconditionFailure("Invalid LiveText native line geometry: \(error)")
      }
      let ordered = rightToLeft ? Array(fragments.reversed()) : fragments
      var candidate: (Int, InlineFlowFragment, CGFloat)?
      for (index, fragment) in ordered.enumerated() {
        let width: CGFloat? = contourNarrowsLine
          ? preferredWordFragmentWidth(at: characterIndex, availableWidth: fragment.maxWidth,
                                       contentWidth: content.width)
          : fragment.maxWidth
        if let width {
          candidate = (index, fragment, width)
          break
        }
      }
      if candidate == nil, contourNarrowsLine {
        for (index, fragment) in ordered.enumerated() {
          if let width = balancedHangulFragmentWidth(
            at: characterIndex, availableWidth: fragment.maxWidth,
            maximumFlankWidth: maximumFlankWidth, contentWidth: content.width
          ) {
            candidate = (index, fragment, width)
            break
          }
        }
      }
      if let (index, fragment, width) = candidate {
        let result = CGRect(
          x: rightToLeft ? fragment.originX + fragment.maxWidth - width : fragment.originX,
          y: band.minY, width: width, height: band.height)
        if index < ordered.count - 1 {
          // The next native query passes this remainder back through the same
          // solver, so several gaps still produce multiple fragments on one row.
          let minX = rightToLeft
            ? min(band.minX, nativeRemainder.isEmpty ? band.minX : nativeRemainder.minX)
            : fragment.originX + fragment.maxWidth
          let maxX = rightToLeft
            ? fragment.originX
            : max(band.maxX, nativeRemainder.isEmpty ? band.maxX : nativeRemainder.maxX)
          remainingRect?.pointee = CGRect(
            x: minX, y: band.minY, width: maxX - minX, height: band.height)
        } else {
          remainingRect?.pointee = nativeRemainder
        }
        return result
      }

      // Native exclusions may have split this row before LiveText's contours
      // are applied. Exhaust that same-row remainder before advancing vertically.
      if !nativeRemainder.isEmpty, nativeRemainder != proposal {
        proposal = nativeRemainder
        continue
      }

      // A completely occupied band is not end-of-document. Keep looking at
      // subsequent native line bands until geometry frees space. The first
      // usable row is returned with its actual y, retaining the full text tail.
      let nextY = band.maxY
      guard nextY > proposal.minY, nextY < content.maxY else { return .zero }
      proposal = CGRect(
        x: content.minX, y: nextY, width: content.width,
        height: proposedRect.height)
    }
    return .zero
  }

  nonisolated private static func preservesNativeRectangle(
    flow: InlineMagazineFlow?, size: CGSize
  ) -> Bool {
    guard let flow else { return true }
    return flow.contours.isEmpty && flow.minimumFragmentFraction == 0
      && flow.contentRect.x == 0 && flow.contentRect.y == 0
      && flow.contentRect.width == size.width && flow.contentRect.height == size.height
  }

  /// Native Hangul word priority can still split an eojeol between contour
  /// fragments. Measure complete whitespace-delimited units with their actual
  /// attributed font runs, including attached punctuation, before admitting a
  /// fragment. No font-size multiple or fixed minimum width is involved.
  nonisolated private func preferredWordFragmentWidth(
    at characterIndex: Int, availableWidth: CGFloat, contentWidth: CGFloat
  ) -> CGFloat? {
    let attributed: NSAttributedString?
    if let manager = textLayoutManager {
      attributed = (manager.textContentManager as? NSTextContentStorage)?.textStorage
    } else {
      attributed = layoutManager?.textStorage
    }
    guard let attributed, characterIndex >= 0, characterIndex < attributed.length,
      let paragraph = attributed.attribute(.paragraphStyle, at: characterIndex,
                                           effectiveRange: nil) as? NSParagraphStyle,
      paragraph.lineBreakMode == .byWordWrapping,
      paragraph.lineBreakStrategy.contains(.hangulWordPriority)
    else { return availableWidth }

    let source = attributed.string as NSString
    let paragraphEnd = NSMaxRange(source.paragraphRange(for: NSRange(location: characterIndex, length: 0)))
    var separators = CharacterSet.whitespacesAndNewlines
    separators.remove(charactersIn: "\u{00A0}\u{202F}\u{2060}")
    var cursor = characterIndex
    var lastFit: CGFloat?
    let padding = lineFragmentPadding * 2
    let usableWidth = max(0, availableWidth - padding)
    let fullUsableWidth = max(0, contentWidth - padding)

    while cursor < paragraphEnd {
      let unitStart = source.rangeOfCharacter(
        from: separators.inverted, options: [],
        range: NSRange(location: cursor, length: paragraphEnd - cursor))
      guard unitStart.location != NSNotFound else { return lastFit ?? availableWidth }
      let separator = source.rangeOfCharacter(
        from: separators, options: [],
        range: NSRange(location: unitStart.location, length: paragraphEnd - unitStart.location))
      let unitEnd = separator.location == NSNotFound ? paragraphEnd : separator.location
      let unit = source.substring(with: NSRange(location: unitStart.location,
                                               length: unitEnd - unitStart.location))
      if Self.permitsNativeBreaksWithinUnit(unit) {
        // Japanese, Chinese and emoji runs have valid non-space line-break
        // opportunities. A Hangul paragraph preference must not turn these
        // entire passages into one indivisible word.
        return lastFit ?? availableWidth
      }
      let prefix = attributed.attributedSubstring(
        from: NSRange(location: characterIndex, length: unitEnd - characterIndex))
      let width = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(prefix), nil, nil, nil))

      if lastFit == nil, width > fullUsableWidth {
        // A URL or an unspaced word wider than the page must eventually use
        // native emergency wrapping. Wait for full-page space, never loop while
        // insisting that an impossible word fit a smaller photo flank.
        return availableWidth >= contentWidth ? availableWidth : nil
      }
      guard width <= usableWidth else { break }
      lastFit = min(availableWidth, (width + padding).nextUp)
      guard unitEnd > cursor else { break }
      cursor = unitEnd
    }
    return lastFit
  }

  nonisolated private static func permitsNativeBreaksWithinUnit(_ unit: String) -> Bool {
    guard unit.range(of: "\\p{Hangul}", options: .regularExpression) == nil else { return false }
    let scalars = unit.unicodeScalars
    let emojiPresentation = scalars.contains { $0.properties.isEmojiPresentation }
    let emojiSequence = scalars.contains { $0.properties.isEmoji }
      && scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
    return unit.range(of: "[\\p{Han}\\p{Hiragana}\\p{Katakana}]", options: .regularExpression) != nil
      || emojiPresentation || emojiSequence
  }

  /// When an eojeol fits the page but no photo flank, divide it into measured,
  /// balanced groups of at least two Hangul graphemes. A final punctuation mark
  /// belongs to its preceding group; an impossible two-plus-one split waits for
  /// wider space. Whole-word placement above always takes precedence.
  nonisolated private func balancedHangulFragmentWidth(
    at characterIndex: Int, availableWidth: CGFloat,
    maximumFlankWidth: CGFloat, contentWidth: CGFloat
  ) -> CGFloat? {
    let attributed: NSAttributedString?
    if let manager = textLayoutManager {
      attributed = (manager.textContentManager as? NSTextContentStorage)?.textStorage
    } else {
      attributed = layoutManager?.textStorage
    }
    guard let attributed, characterIndex >= 0, characterIndex < attributed.length,
      let paragraph = attributed.attribute(.paragraphStyle, at: characterIndex,
                                           effectiveRange: nil) as? NSParagraphStyle,
      paragraph.lineBreakMode == .byWordWrapping,
      paragraph.lineBreakStrategy.contains(.hangulWordPriority)
    else { return nil }
    let source = attributed.string as NSString
    let paragraphEnd = NSMaxRange(source.paragraphRange(for: NSRange(location: characterIndex, length: 0)))
    let separators = CharacterSet.whitespacesAndNewlines
    let start = source.rangeOfCharacter(from: separators.inverted, options: [],
      range: NSRange(location: characterIndex, length: paragraphEnd - characterIndex))
    guard start.location != NSNotFound else { return nil }
    let separator = source.rangeOfCharacter(from: separators, options: [],
      range: NSRange(location: start.location, length: paragraphEnd - start.location))
    let end = separator.location == NSNotFound ? paragraphEnd : separator.location
    let unit = source.substring(with: NSRange(location: start.location, length: end - start.location))
    var letterEnds: [Int] = []
    var offset = start.location
    var reachedPunctuation = false
    for grapheme in unit {
      let text = String(grapheme)
      offset += text.utf16.count
      if text.range(of: "\\p{Hangul}", options: .regularExpression) != nil {
        guard !reachedPunctuation else { return nil }
        letterEnds.append(offset)
      } else if text.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) {
        guard !letterEnds.isEmpty else { return nil }
        reachedPunctuation = true
      } else {
        return nil
      }
    }
    guard letterEnds.count >= 4 else { return nil }
    let padding = lineFragmentPadding * 2
    func measured(_ start: Int, _ end: Int) -> CGFloat {
      let run = attributed.attributedSubstring(from: NSRange(location: start, length: end - start))
      return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(run), nil, nil, nil)) + padding
    }
    let wholeWidth = measured(characterIndex, end)
    guard wholeWidth > maximumFlankWidth, wholeWidth <= contentWidth else { return nil }

    for groupCount in 2...(letterEnds.count / 2) {
      let baseCount = letterEnds.count / groupCount
      let largerGroups = letterEnds.count % groupCount
      // Both balanced orders are meaningful when the two flanks differ in width.
      for largerFirst in [true, false] {
        var consumed = 0
        var groupStart = characterIndex
        var firstWidth: CGFloat?
        var fits = true
        for group in 0..<groupCount {
          let takesExtra = largerFirst ? group < largerGroups : group >= groupCount - largerGroups
          consumed += baseCount + (takesExtra ? 1 : 0)
          let groupEnd = group == groupCount - 1 ? end : letterEnds[consumed - 1]
          let width = measured(groupStart, groupEnd)
          let capacity = group == 0 ? availableWidth : maximumFlankWidth
          if width > capacity { fits = false; break }
          if firstWidth == nil { firstWidth = min(availableWidth, width.nextUp) }
          groupStart = groupEnd
        }
        if fits { return firstWidth }
      }
    }
    return nil
  }
}
#endif
