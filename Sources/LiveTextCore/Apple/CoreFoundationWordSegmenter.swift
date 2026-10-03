#if canImport(CoreText)
  import CoreFoundation
  import Foundation

  /// Word segmenter backed by `CFStringTokenizer`.
  public struct CoreFoundationWordSegmenter: WordSegmenting, Sendable {
    /// Creates a CoreFoundation-backed word segmenter.
    public init() {}

    /// Tokenizes text with CoreFoundation word-boundary rules.
    public func tokenize(_ text: String, localeIdentifier: String?) -> [WordToken] {
      guard text.isEmpty == false else { return [] }

      let utf16Length = text.utf16Length
      let locale: CFLocale?
      if let localeIdentifier, localeIdentifier.isEmpty == false {
        locale = CFLocaleCreate(
          kCFAllocatorDefault,
          CFLocaleIdentifier(NSString(string: localeIdentifier))
        )
      } else {
        locale = nil
      }

      guard
        let tokenizer = CFStringTokenizerCreate(
          kCFAllocatorDefault,
          text as CFString,
          CFRange(location: 0, length: utf16Length),
          kCFStringTokenizerUnitWordBoundary,
          locale
        )
      else {
        return [WordToken(text: text, startUTF16: 0, isWordLike: false)]
      }

      var tokens: [WordToken] = []
      tokens.reserveCapacity(max(8, utf16Length / 4))
      var cursor = 0

      while true {
        _ = CFStringTokenizerAdvanceToNextToken(tokenizer)
        let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
        if range.location == kCFNotFound || range.length <= 0 {
          break
        }

        if cursor < range.location {
          tokens.append(
            WordToken(
              text: text.substringUTF16(cursor..<range.location),
              startUTF16: cursor,
              isWordLike: false
            )
          )
        }

        tokens.append(
          WordToken(
            text: text.substringUTF16(range.location..<(range.location + range.length)),
            startUTF16: range.location,
            isWordLike: true
          )
        )
        cursor = range.location + range.length
      }

      if cursor < utf16Length {
        tokens.append(
          WordToken(
            text: text.substringUTF16(cursor..<utf16Length),
            startUTF16: cursor,
            isWordLike: false
          )
        )
      }

      return tokens
    }
  }
#endif
