import Foundation

extension String {
  var utf16Length: Int {
    utf16.count
  }

  func utf16Index(at offset: Int) -> String.Index {
    let utf16 = self.utf16
    let index = utf16.index(utf16.startIndex, offsetBy: offset)
    return String.Index(index, within: self) ?? endIndex
  }

  func substringUTF16(_ range: Range<Int>) -> String {
    let lower = utf16Index(at: range.lowerBound)
    let upper = utf16Index(at: range.upperBound)
    return String(self[lower..<upper])
  }
}

package func composedCharacterClusters(_ text: String) -> [String] {
  let nsText = text as NSString
  var result: [String] = []
  nsText.enumerateSubstrings(
    in: NSRange(location: 0, length: nsText.length),
    options: .byComposedCharacterSequences
  ) { substring, _, _, _ in
    if let substring {
      result.append(substring)
    }
  }
  return result
}

func previousCodePointStart(_ text: String, endUTF16: Int) -> Int {
  let nsText = text as NSString
  let last = endUTF16 - 1
  if last <= 0 { return max(last, 0) }

  let lastCodeUnit = nsText.character(at: last)
  if lastCodeUnit < 0xDC00 || lastCodeUnit > 0xDFFF {
    return last
  }

  let maybeHigh = last - 1
  if maybeHigh < 0 { return last }

  let highCodeUnit = nsText.character(at: maybeHigh)
  return (0xD800...0xDBFF).contains(highCodeUnit) ? maybeHigh : last
}

func lastCodePoint(_ text: String) -> String? {
  guard text.isEmpty == false else { return nil }
  let end = text.utf16Length
  let start = previousCodePointStart(text, endUTF16: end)
  return text.substringUTF16(start..<end)
}

func graphemeClustersWithUTF16Offsets(_ text: String) -> [(
  text: String, startUTF16: Int, endUTF16: Int
)] {
  let nsText = text as NSString
  var result: [(text: String, startUTF16: Int, endUTF16: Int)] = []
  nsText.enumerateSubstrings(
    in: NSRange(location: 0, length: nsText.length),
    options: .byComposedCharacterSequences
  ) { substring, range, _, _ in
    if let substring {
      result.append((substring, range.location, range.location + range.length))
    }
  }
  return result
}
