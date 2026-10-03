import Foundation

struct SVGNumberScanner {
  private let bytes: [UInt8]
  private var index = 0

  init(_ source: String) {
    bytes = Array(source.utf8)
  }

  mutating func allNumbers() throws -> [Double] {
    var values: [Double] = []
    while true {
      skipSeparators()
      guard index < bytes.count else { return values }
      values.append(try readNumber())
    }
  }

  static func parseLength(_ source: String) throws -> Double {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized: String
    if trimmed.lowercased().hasSuffix("px") {
      normalized = String(trimmed.dropLast(2))
    } else {
      normalized = trimmed
    }
    var scanner = SVGNumberScanner(normalized)
    let values = try scanner.allNumbers()
    guard values.count == 1, let value = values.first, value.isFinite else {
      throw LiveTextSVGImportError.invalidDocument("length must be one finite number")
    }
    return value
  }

  mutating func nextTransformFunction() throws -> (name: String, numbers: [Double])? {
    skipSeparators()
    guard index < bytes.count else { return nil }
    let start = index
    guard isIdentifierStart(bytes[index]) else {
      throw LiveTextSVGImportError.invalidTransform("expected transform function")
    }
    index += 1
    while index < bytes.count, isIdentifierCharacter(bytes[index]) { index += 1 }
    let name = String(decoding: bytes[start..<index], as: UTF8.self).lowercased()
    skipSeparators()
    guard index < bytes.count, bytes[index] == 0x28 else {
      throw LiveTextSVGImportError.invalidTransform("missing opening parenthesis")
    }
    index += 1
    var numbers: [Double] = []
    while true {
      skipSeparators()
      guard index < bytes.count else {
        throw LiveTextSVGImportError.invalidTransform("missing closing parenthesis")
      }
      if bytes[index] == 0x29 {
        index += 1
        break
      }
      numbers.append(try readNumber())
    }
    return (name, numbers)
  }

  mutating func hasNumber() -> Bool {
    skipSeparators()
    guard index < bytes.count else { return false }
    return isNumberStart(at: index)
  }

  mutating func readNumberIfPresent() throws -> Double? {
    guard hasNumber() else { return nil }
    return try readNumber()
  }

  mutating func readNumber() throws -> Double {
    skipSeparators()
    let start = index
    if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }

    var digits = 0
    while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
      index += 1
      digits += 1
    }
    if index < bytes.count, bytes[index] == 0x2E {
      index += 1
      while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
        index += 1
        digits += 1
      }
    }
    guard digits > 0 else {
      throw LiveTextSVGImportError.invalidDocument("invalid numeric token")
    }
    if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
      index += 1
      if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
      var exponentDigits = 0
      while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
        index += 1
        exponentDigits += 1
      }
      guard exponentDigits > 0 else {
        throw LiveTextSVGImportError.invalidDocument("invalid exponent")
      }
    }
    let value = Double(String(decoding: bytes[start..<index], as: UTF8.self))
    guard let value, value.isFinite else {
      throw LiveTextSVGImportError.invalidDocument("number is not finite")
    }
    return value
  }

  mutating func skipSeparators() {
    while index < bytes.count {
      switch bytes[index] {
      case 0x09, 0x0A, 0x0D, 0x20, 0x2C:
        index += 1
      default:
        return
      }
    }
  }

  private func isNumberStart(at offset: Int) -> Bool {
    guard offset < bytes.count else { return false }
    switch bytes[offset] {
    case 0x2B, 0x2D, 0x30...0x39:
      return true
    case 0x2E:
      return offset + 1 < bytes.count && bytes[offset + 1] >= 0x30
        && bytes[offset + 1] <= 0x39
    default:
      return false
    }
  }

  private func isIdentifierStart(_ byte: UInt8) -> Bool {
    (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
  }

  private func isIdentifierCharacter(_ byte: UInt8) -> Bool {
    isIdentifierStart(byte)
  }
}
