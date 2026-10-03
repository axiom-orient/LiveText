import Foundation

enum HangulStrokeCatalog {
  private static let initialJamo = [
    "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
  ]
  private static let medialJamo = [
    "ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅘ", "ㅙ", "ㅚ", "ㅛ", "ㅜ", "ㅝ", "ㅞ", "ㅟ", "ㅠ", "ㅡ",
    "ㅢ", "ㅣ",
  ]
  private static let finalJamo = [
    "", "ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ", "ㄺ", "ㄻ", "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ", "ㅄ",
    "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
  ]

  static func template(for character: Character) throws -> GlyphStrokeTemplate? {
    let text = String(character)
    if let strokes = jamoStrokes(text) {
      return try makeTemplate(advance: 1, strokes: strokes)
    }
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
      return nil
    }
    let value = scalar.value
    guard (0xAC00...0xD7A3).contains(value) else { return nil }
    let syllableIndex = Int(value - 0xAC00)
    let initial = initialJamo[syllableIndex / 588]
    let medial = medialJamo[(syllableIndex % 588) / 28]
    let final = finalJamo[syllableIndex % 28]
    let strokes = compose(initial: initial, medial: medial, final: final)
    return try makeTemplate(advance: 1.02, strokes: strokes)
  }

  private static func compose(initial: String, medial: String, final: String) -> [[NormalizedPoint]]
  {
    let hasFinal = !final.isEmpty
    let bodyBottom = hasFinal ? 0.67 : 0.94
    let vertical = verticalVowels.contains(medial)
    let mixed = mixedVowels.contains(medial)
    var result: [[NormalizedPoint]] = []

    if vertical {
      result += transformed(
        jamoStrokes(initial) ?? [], x: 0.04, y: 0.05, width: 0.44, height: bodyBottom - 0.08)
      result += transformed(
        jamoStrokes(medial) ?? [], x: 0.50, y: 0.04, width: 0.46, height: bodyBottom - 0.06)
    } else if mixed {
      result += transformed(
        jamoStrokes(initial) ?? [], x: 0.05, y: 0.04, width: 0.40, height: bodyBottom - 0.08)
      result += transformed(
        jamoStrokes(medial) ?? [], x: 0.43, y: 0.04, width: 0.54, height: bodyBottom - 0.05)
    } else {
      result += transformed(
        jamoStrokes(initial) ?? [], x: 0.12, y: 0.03, width: 0.76,
        height: (bodyBottom - 0.05) * 0.52)
      result += transformed(
        jamoStrokes(medial) ?? [], x: 0.06, y: (bodyBottom - 0.02) * 0.50, width: 0.88,
        height: (bodyBottom - 0.05) * 0.48)
    }

    if hasFinal {
      result += transformed(
        jamoStrokes(final) ?? [], x: 0.10, y: 0.71, width: 0.80, height: 0.25)
    }
    return result
  }

  private static let verticalVowels: Set<String> = [
    "ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅣ",
  ]
  private static let mixedVowels: Set<String> = ["ㅘ", "ㅙ", "ㅚ", "ㅝ", "ㅞ", "ㅟ", "ㅢ"]

  private static func jamoStrokes(_ jamo: String) -> [[NormalizedPoint]]? {
    let pi = Double.pi
    switch jamo {
    case "ㄱ":
      return [
        [NormalizedPoint(0.10, 0.12), NormalizedPoint(0.90, 0.12)],
        [NormalizedPoint(0.90, 0.12), NormalizedPoint(0.90, 0.90)],
      ]
    case "ㄴ":
      return [
        [NormalizedPoint(0.12, 0.10), NormalizedPoint(0.12, 0.88)],
        [NormalizedPoint(0.12, 0.88), NormalizedPoint(0.90, 0.88)],
      ]
    case "ㄷ":
      return [
        [NormalizedPoint(0.10, 0.12), NormalizedPoint(0.90, 0.12)],
        [NormalizedPoint(0.10, 0.12), NormalizedPoint(0.10, 0.88)],
        [NormalizedPoint(0.10, 0.88), NormalizedPoint(0.90, 0.88)],
      ]
    case "ㄹ":
      return [
        [NormalizedPoint(0.10, 0.10), NormalizedPoint(0.90, 0.10)],
        [NormalizedPoint(0.90, 0.10), NormalizedPoint(0.90, 0.43)],
        [NormalizedPoint(0.90, 0.43), NormalizedPoint(0.18, 0.43)],
        [NormalizedPoint(0.18, 0.43), NormalizedPoint(0.18, 0.88)],
        [NormalizedPoint(0.18, 0.88), NormalizedPoint(0.92, 0.88)],
      ]
    case "ㅁ":
      return [
        [NormalizedPoint(0.12, 0.12), NormalizedPoint(0.88, 0.12)],
        [NormalizedPoint(0.12, 0.12), NormalizedPoint(0.12, 0.88)],
        [NormalizedPoint(0.88, 0.12), NormalizedPoint(0.88, 0.88)],
        [NormalizedPoint(0.12, 0.88), NormalizedPoint(0.88, 0.88)],
      ]
    case "ㅂ":
      return [
        [NormalizedPoint(0.16, 0.10), NormalizedPoint(0.16, 0.90)],
        [NormalizedPoint(0.84, 0.10), NormalizedPoint(0.84, 0.90)],
        [NormalizedPoint(0.16, 0.12), NormalizedPoint(0.84, 0.12)],
        [NormalizedPoint(0.16, 0.50), NormalizedPoint(0.84, 0.50)],
        [NormalizedPoint(0.16, 0.88), NormalizedPoint(0.84, 0.88)],
      ]
    case "ㅅ":
      return [
        [NormalizedPoint(0.50, 0.12), NormalizedPoint(0.12, 0.88)],
        [NormalizedPoint(0.50, 0.12), NormalizedPoint(0.90, 0.88)],
      ]
    case "ㅇ":
      return [
        sampledArc(
          centerX: 0.50, centerY: 0.50, radiusX: 0.38, radiusY: 0.38, start: -0.5 * pi,
          end: 1.5 * pi, count: 28)
      ]
    case "ㅈ":
      return [
        [NormalizedPoint(0.12, 0.12), NormalizedPoint(0.88, 0.12)],
        [NormalizedPoint(0.50, 0.14), NormalizedPoint(0.12, 0.88)],
        [NormalizedPoint(0.50, 0.14), NormalizedPoint(0.90, 0.88)],
      ]
    case "ㅊ":
      return [
        [NormalizedPoint(0.32, 0.06), NormalizedPoint(0.68, 0.06)],
        [NormalizedPoint(0.12, 0.27), NormalizedPoint(0.88, 0.27)],
        [NormalizedPoint(0.50, 0.29), NormalizedPoint(0.12, 0.90)],
        [NormalizedPoint(0.50, 0.29), NormalizedPoint(0.90, 0.90)],
      ]
    case "ㅋ":
      return [
        [NormalizedPoint(0.10, 0.12), NormalizedPoint(0.90, 0.12)],
        [NormalizedPoint(0.90, 0.12), NormalizedPoint(0.90, 0.90)],
        [NormalizedPoint(0.34, 0.52), NormalizedPoint(0.90, 0.52)],
      ]
    case "ㅌ":
      return [
        [NormalizedPoint(0.10, 0.10), NormalizedPoint(0.90, 0.10)],
        [NormalizedPoint(0.10, 0.48), NormalizedPoint(0.90, 0.48)],
        [NormalizedPoint(0.10, 0.10), NormalizedPoint(0.10, 0.90)],
        [NormalizedPoint(0.10, 0.90), NormalizedPoint(0.90, 0.90)],
      ]
    case "ㅍ":
      return [
        [NormalizedPoint(0.10, 0.20), NormalizedPoint(0.90, 0.20)],
        [NormalizedPoint(0.10, 0.80), NormalizedPoint(0.90, 0.80)],
        [NormalizedPoint(0.28, 0.08), NormalizedPoint(0.28, 0.92)],
        [NormalizedPoint(0.72, 0.08), NormalizedPoint(0.72, 0.92)],
      ]
    case "ㅎ":
      return [
        [NormalizedPoint(0.34, 0.08), NormalizedPoint(0.66, 0.08)],
        [NormalizedPoint(0.12, 0.28), NormalizedPoint(0.88, 0.28)],
        sampledArc(
          centerX: 0.50, centerY: 0.66, radiusX: 0.29, radiusY: 0.25, start: -0.5 * pi,
          end: 1.5 * pi, count: 24),
      ]

    case "ㄲ": return duplicate(jamoStrokes("ㄱ") ?? [])
    case "ㄸ": return duplicate(jamoStrokes("ㄷ") ?? [])
    case "ㅃ": return duplicate(jamoStrokes("ㅂ") ?? [])
    case "ㅆ": return duplicate(jamoStrokes("ㅅ") ?? [])
    case "ㅉ": return duplicate(jamoStrokes("ㅈ") ?? [])

    case "ㄳ": return pair("ㄱ", "ㅅ")
    case "ㄵ": return pair("ㄴ", "ㅈ")
    case "ㄶ": return pair("ㄴ", "ㅎ")
    case "ㄺ": return pair("ㄹ", "ㄱ")
    case "ㄻ": return pair("ㄹ", "ㅁ")
    case "ㄼ": return pair("ㄹ", "ㅂ")
    case "ㄽ": return pair("ㄹ", "ㅅ")
    case "ㄾ": return pair("ㄹ", "ㅌ")
    case "ㄿ": return pair("ㄹ", "ㅍ")
    case "ㅀ": return pair("ㄹ", "ㅎ")
    case "ㅄ": return pair("ㅂ", "ㅅ")

    case "ㅏ":
      return [
        [NormalizedPoint(0.46, 0.08), NormalizedPoint(0.46, 0.92)],
        [NormalizedPoint(0.46, 0.50), NormalizedPoint(0.90, 0.50)],
      ]
    case "ㅑ":
      return [
        [NormalizedPoint(0.42, 0.08), NormalizedPoint(0.42, 0.92)],
        [NormalizedPoint(0.42, 0.36), NormalizedPoint(0.90, 0.36)],
        [NormalizedPoint(0.42, 0.64), NormalizedPoint(0.90, 0.64)],
      ]
    case "ㅓ":
      return [
        [NormalizedPoint(0.10, 0.50), NormalizedPoint(0.54, 0.50)],
        [NormalizedPoint(0.54, 0.08), NormalizedPoint(0.54, 0.92)],
      ]
    case "ㅕ":
      return [
        [NormalizedPoint(0.10, 0.36), NormalizedPoint(0.58, 0.36)],
        [NormalizedPoint(0.10, 0.64), NormalizedPoint(0.58, 0.64)],
        [NormalizedPoint(0.58, 0.08), NormalizedPoint(0.58, 0.92)],
      ]
    case "ㅗ":
      return [
        [NormalizedPoint(0.50, 0.52), NormalizedPoint(0.50, 0.10)],
        [NormalizedPoint(0.08, 0.54), NormalizedPoint(0.92, 0.54)],
      ]
    case "ㅛ":
      return [
        [NormalizedPoint(0.34, 0.52), NormalizedPoint(0.34, 0.12)],
        [NormalizedPoint(0.66, 0.52), NormalizedPoint(0.66, 0.12)],
        [NormalizedPoint(0.08, 0.54), NormalizedPoint(0.92, 0.54)],
      ]
    case "ㅜ":
      return [
        [NormalizedPoint(0.08, 0.46), NormalizedPoint(0.92, 0.46)],
        [NormalizedPoint(0.50, 0.46), NormalizedPoint(0.50, 0.90)],
      ]
    case "ㅠ":
      return [
        [NormalizedPoint(0.08, 0.44), NormalizedPoint(0.92, 0.44)],
        [NormalizedPoint(0.34, 0.44), NormalizedPoint(0.34, 0.90)],
        [NormalizedPoint(0.66, 0.44), NormalizedPoint(0.66, 0.90)],
      ]
    case "ㅡ": return [[NormalizedPoint(0.08, 0.50), NormalizedPoint(0.92, 0.50)]]
    case "ㅣ": return [[NormalizedPoint(0.50, 0.08), NormalizedPoint(0.50, 0.92)]]

    case "ㅐ":
      return (jamoStrokes("ㅏ") ?? []) + [
        [NormalizedPoint(0.82, 0.08), NormalizedPoint(0.82, 0.92)]
      ]
    case "ㅒ":
      return (jamoStrokes("ㅑ") ?? []) + [
        [NormalizedPoint(0.82, 0.08), NormalizedPoint(0.82, 0.92)]
      ]
    case "ㅔ":
      return (jamoStrokes("ㅓ") ?? []) + [
        [NormalizedPoint(0.84, 0.08), NormalizedPoint(0.84, 0.92)]
      ]
    case "ㅖ":
      return (jamoStrokes("ㅕ") ?? []) + [
        [NormalizedPoint(0.86, 0.08), NormalizedPoint(0.86, 0.92)]
      ]
    case "ㅘ": return compoundVowel(base: "ㅗ", side: "ㅏ")
    case "ㅙ": return compoundVowel(base: "ㅗ", side: "ㅐ")
    case "ㅚ": return compoundVowel(base: "ㅗ", side: "ㅣ")
    case "ㅝ": return compoundVowel(base: "ㅜ", side: "ㅓ")
    case "ㅞ": return compoundVowel(base: "ㅜ", side: "ㅔ")
    case "ㅟ": return compoundVowel(base: "ㅜ", side: "ㅣ")
    case "ㅢ":
      return transformed(jamoStrokes("ㅡ") ?? [], x: 0.02, y: 0.10, width: 0.62, height: 0.80)
        + transformed(jamoStrokes("ㅣ") ?? [], x: 0.62, y: 0.04, width: 0.34, height: 0.92)
    default:
      return nil
    }
  }

  private static func duplicate(_ strokes: [[NormalizedPoint]]) -> [[NormalizedPoint]] {
    transformed(strokes, x: 0.02, y: 0.02, width: 0.46, height: 0.96)
      + transformed(strokes, x: 0.52, y: 0.02, width: 0.46, height: 0.96)
  }

  private static func pair(_ left: String, _ right: String) -> [[NormalizedPoint]] {
    transformed(jamoStrokes(left) ?? [], x: 0.02, y: 0.04, width: 0.46, height: 0.92)
      + transformed(jamoStrokes(right) ?? [], x: 0.52, y: 0.04, width: 0.46, height: 0.92)
  }

  private static func compoundVowel(base: String, side: String) -> [[NormalizedPoint]] {
    transformed(jamoStrokes(base) ?? [], x: 0.02, y: 0.08, width: 0.64, height: 0.84)
      + transformed(jamoStrokes(side) ?? [], x: 0.60, y: 0.02, width: 0.38, height: 0.96)
  }
}
