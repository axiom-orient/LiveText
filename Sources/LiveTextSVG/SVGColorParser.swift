import Foundation

enum SVGColorParser {
  static func parse(_ raw: String) throws -> LiveTextSVGColor? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value == "inherit" { return nil }
    if value.hasPrefix("#") { return try parseHex(value) }
    if value.hasPrefix("rgb(") && value.hasSuffix(")") {
      return try parseRGB(String(value.dropFirst(4).dropLast()), hasAlpha: false)
    }
    if value.hasPrefix("rgba(") && value.hasSuffix(")") {
      return try parseRGB(String(value.dropFirst(5).dropLast()), hasAlpha: true)
    }
    guard let components = named[value] else { throw LiveTextSVGImportError.invalidColor(raw) }
    return try LiveTextSVGColor(
      red: components.0, green: components.1, blue: components.2, alpha: components.3
    )
  }

  private static func parseHex(_ value: String) throws -> LiveTextSVGColor {
    let digits = String(value.dropFirst())
    guard [3, 4, 6, 8].contains(digits.count), let integer = UInt64(digits, radix: 16) else {
      throw LiveTextSVGImportError.invalidColor(value)
    }
    let divisor: Double
    let red: UInt64
    let green: UInt64
    let blue: UInt64
    let alpha: UInt64
    switch digits.count {
    case 3:
      red = ((integer >> 8) & 0xF) * 17
      green = ((integer >> 4) & 0xF) * 17
      blue = (integer & 0xF) * 17
      alpha = 255
      divisor = 255
    case 4:
      red = ((integer >> 12) & 0xF) * 17
      green = ((integer >> 8) & 0xF) * 17
      blue = ((integer >> 4) & 0xF) * 17
      alpha = (integer & 0xF) * 17
      divisor = 255
    case 6:
      red = (integer >> 16) & 0xFF
      green = (integer >> 8) & 0xFF
      blue = integer & 0xFF
      alpha = 255
      divisor = 255
    default:
      red = (integer >> 24) & 0xFF
      green = (integer >> 16) & 0xFF
      blue = (integer >> 8) & 0xFF
      alpha = integer & 0xFF
      divisor = 255
    }
    return try LiveTextSVGColor(
      red: Double(red) / divisor,
      green: Double(green) / divisor,
      blue: Double(blue) / divisor,
      alpha: Double(alpha) / divisor
    )
  }

  private static func parseRGB(_ raw: String, hasAlpha: Bool) throws -> LiveTextSVGColor {
    let pieces = raw.split(separator: ",", omittingEmptySubsequences: false)
    guard pieces.count == (hasAlpha ? 4 : 3) else {
      throw LiveTextSVGImportError.invalidColor(raw)
    }
    func channel(_ piece: Substring) throws -> Double {
      let value = piece.trimmingCharacters(in: .whitespacesAndNewlines)
      if value.hasSuffix("%") {
        let number = try SVGNumberScanner.parseLength(String(value.dropLast()))
        guard (0...100).contains(number) else { throw LiveTextSVGImportError.invalidColor(raw) }
        return number / 100
      }
      let number = try SVGNumberScanner.parseLength(String(value))
      guard (0...255).contains(number) else { throw LiveTextSVGImportError.invalidColor(raw) }
      return number / 255
    }
    let red = try channel(pieces[0])
    let green = try channel(pieces[1])
    let blue = try channel(pieces[2])
    let alpha: Double
    if hasAlpha {
      let value = pieces[3].trimmingCharacters(in: .whitespacesAndNewlines)
      if value.hasSuffix("%") {
        let number = try SVGNumberScanner.parseLength(String(value.dropLast()))
        guard (0...100).contains(number) else { throw LiveTextSVGImportError.invalidColor(raw) }
        alpha = number / 100
      } else {
        alpha = try SVGNumberScanner.parseLength(String(value))
        guard (0...1).contains(alpha) else { throw LiveTextSVGImportError.invalidColor(raw) }
      }
    } else {
      alpha = 1
    }
    return try LiveTextSVGColor(red: red, green: green, blue: blue, alpha: alpha)
  }

  private static let named: [String: (Double, Double, Double, Double)] = [
    "black": (0, 0, 0, 1), "white": (1, 1, 1, 1), "red": (1, 0, 0, 1),
    "green": (0, 0.5019607843, 0, 1), "blue": (0, 0, 1, 1), "yellow": (1, 1, 0, 1),
    "cyan": (0, 1, 1, 1), "aqua": (0, 1, 1, 1), "magenta": (1, 0, 1, 1),
    "fuchsia": (1, 0, 1, 1), "gray": (0.5019607843, 0.5019607843, 0.5019607843, 1),
    "grey": (0.5019607843, 0.5019607843, 0.5019607843, 1), "orange": (1, 0.6470588235, 0, 1),
    "purple": (0.5019607843, 0, 0.5019607843, 1), "pink": (1, 0.7529411765, 0.7960784314, 1),
    "brown": (0.6470588235, 0.1647058824, 0.1647058824, 1), "transparent": (0, 0, 0, 0),
  ]
}
