import Foundation

enum LatinStrokeCatalog {
  static func template(for character: Character) throws -> GlyphStrokeTemplate? {
    let s = String(character)
    if s == " " || s == "\t" {
      return try makeTemplate(advance: s == "\t" ? 1.6 : 0.45, strokes: [])
    }
    let pi = Double.pi
    switch s {
    // Uppercase Latin — deterministic print-writing profile.
    case "A":
      return try makeTemplate(
        advance: 0.78,
        strokes: [
          [NormalizedPoint(0.08, 0.94), NormalizedPoint(0.50, 0.06), NormalizedPoint(0.92, 0.94)],
          [NormalizedPoint(0.27, 0.60), NormalizedPoint(0.73, 0.60)],
        ])
    case "B":
      return try makeTemplate(
        advance: 0.76,
        strokes: [
          [NormalizedPoint(0.12, 0.08), NormalizedPoint(0.12, 0.94)],
          sampledCubic(
            NormalizedPoint(0.12, 0.08), NormalizedPoint(0.86, 0.04), NormalizedPoint(0.88, 0.49),
            NormalizedPoint(0.12, 0.50))
            + sampledCubic(
              NormalizedPoint(0.12, 0.50), NormalizedPoint(0.90, 0.48), NormalizedPoint(0.90, 0.96),
              NormalizedPoint(0.12, 0.94)
            ).dropFirst(),
        ])
    case "C":
      return try makeTemplate(
        advance: 0.78,
        strokes: [
          sampledArc(
            centerX: 0.52, centerY: 0.51, radiusX: 0.39, radiusY: 0.44, start: 0.22 * pi,
            end: 1.78 * pi, count: 28)
        ])
    case "D":
      return try makeTemplate(
        advance: 0.82,
        strokes: [
          [NormalizedPoint(0.12, 0.08), NormalizedPoint(0.12, 0.94)],
          sampledCubic(
            NormalizedPoint(0.12, 0.08), NormalizedPoint(0.94, 0.08), NormalizedPoint(0.94, 0.94),
            NormalizedPoint(0.12, 0.94), count: 28),
        ])
    case "E":
      return try makeTemplate(
        advance: 0.68,
        strokes: [
          [NormalizedPoint(0.12, 0.08), NormalizedPoint(0.12, 0.94)],
          [NormalizedPoint(0.12, 0.08), NormalizedPoint(0.86, 0.08)],
          [NormalizedPoint(0.12, 0.51), NormalizedPoint(0.72, 0.51)],
          [NormalizedPoint(0.12, 0.94), NormalizedPoint(0.88, 0.94)],
        ])
    case "F":
      return try makeTemplate(
        advance: 0.66,
        strokes: [
          [NormalizedPoint(0.12, 0.08), NormalizedPoint(0.12, 0.94)],
          [NormalizedPoint(0.12, 0.08), NormalizedPoint(0.86, 0.08)],
          [NormalizedPoint(0.12, 0.51), NormalizedPoint(0.70, 0.51)],
        ])
    case "G":
      return try makeTemplate(
        advance: 0.84,
        strokes: [
          sampledArc(
            centerX: 0.52, centerY: 0.51, radiusX: 0.39, radiusY: 0.44, start: 0.22 * pi,
            end: 1.78 * pi, count: 28)
            + [NormalizedPoint(0.88, 0.58), NormalizedPoint(0.60, 0.58)]
        ])
    case "H":
      return try makeTemplate(
        advance: 0.78,
        strokes: [
          [NormalizedPoint(0.12, 0.08), NormalizedPoint(0.12, 0.94)],
          [NormalizedPoint(0.88, 0.08), NormalizedPoint(0.88, 0.94)],
          [NormalizedPoint(0.12, 0.51), NormalizedPoint(0.88, 0.51)],
        ])
    case "I":
      return try makeTemplate(
        advance: 0.45,
        strokes: [
          [NormalizedPoint(0.10, 0.08), NormalizedPoint(0.90, 0.08)],
          [NormalizedPoint(0.50, 0.08), NormalizedPoint(0.50, 0.94)],
          [NormalizedPoint(0.10, 0.94), NormalizedPoint(0.90, 0.94)],
        ])
    case "J":
      return try makeTemplate(
        advance: 0.64,
        strokes: [
          [NormalizedPoint(0.10, 0.08), NormalizedPoint(0.90, 0.08)],
          sampledCubic(
            NormalizedPoint(0.72, 0.08), NormalizedPoint(0.72, 0.74), NormalizedPoint(0.58, 0.96),
            NormalizedPoint(0.30, 0.94), count: 22),
        ])
    case "K":
      return try makeTemplate(
        advance: 0.76,
        strokes: [
          [NormalizedPoint(0.12, 0.08), NormalizedPoint(0.12, 0.94)],
          [NormalizedPoint(0.88, 0.08), NormalizedPoint(0.12, 0.55)],
          [NormalizedPoint(0.38, 0.39), NormalizedPoint(0.90, 0.94)],
        ])
    case "L":
      return try makeTemplate(
        advance: 0.64,
        strokes: [
          [NormalizedPoint(0.12, 0.08), NormalizedPoint(0.12, 0.94), NormalizedPoint(0.88, 0.94)]
        ])
    case "M":
      return try makeTemplate(
        advance: 0.94,
        strokes: [
          [
            NormalizedPoint(0.08, 0.94), NormalizedPoint(0.08, 0.08), NormalizedPoint(0.50, 0.60),
            NormalizedPoint(0.92, 0.08), NormalizedPoint(0.92, 0.94),
          ]
        ])
    case "N":
      return try makeTemplate(
        advance: 0.82,
        strokes: [
          [
            NormalizedPoint(0.10, 0.94), NormalizedPoint(0.10, 0.08), NormalizedPoint(0.90, 0.94),
            NormalizedPoint(0.90, 0.08),
          ]
        ])
    case "O":
      return try makeTemplate(
        advance: 0.84,
        strokes: [
          sampledArc(
            centerX: 0.50, centerY: 0.51, radiusX: 0.40, radiusY: 0.44, start: -0.5 * pi,
            end: 1.5 * pi, count: 34)
        ])
    case "P":
      return try makeTemplate(
        advance: 0.72,
        strokes: [
          [NormalizedPoint(0.12, 0.94), NormalizedPoint(0.12, 0.08)],
          sampledCubic(
            NormalizedPoint(0.12, 0.08), NormalizedPoint(0.88, 0.05), NormalizedPoint(0.88, 0.55),
            NormalizedPoint(0.12, 0.52), count: 24),
        ])
    case "Q":
      return try makeTemplate(
        advance: 0.86,
        strokes: [
          sampledArc(
            centerX: 0.50, centerY: 0.49, radiusX: 0.40, radiusY: 0.42, start: -0.5 * pi,
            end: 1.5 * pi, count: 34),
          [NormalizedPoint(0.58, 0.67), NormalizedPoint(0.94, 0.98)],
        ])
    case "R":
      return try makeTemplate(
        advance: 0.76,
        strokes: [
          [NormalizedPoint(0.12, 0.94), NormalizedPoint(0.12, 0.08)],
          sampledCubic(
            NormalizedPoint(0.12, 0.08), NormalizedPoint(0.88, 0.05), NormalizedPoint(0.88, 0.55),
            NormalizedPoint(0.12, 0.52), count: 24),
          [NormalizedPoint(0.48, 0.52), NormalizedPoint(0.92, 0.94)],
        ])
    case "S":
      return try makeTemplate(
        advance: 0.72,
        strokes: [
          sampledCubic(
            NormalizedPoint(0.88, 0.14), NormalizedPoint(0.52, -0.04), NormalizedPoint(0.10, 0.13),
            NormalizedPoint(0.20, 0.42), count: 18)
            + sampledCubic(
              NormalizedPoint(0.20, 0.42), NormalizedPoint(0.30, 0.67), NormalizedPoint(0.90, 0.48),
              NormalizedPoint(0.84, 0.80), count: 18
            ).dropFirst()
            + sampledCubic(
              NormalizedPoint(0.84, 0.80), NormalizedPoint(0.77, 1.02), NormalizedPoint(0.30, 1.02),
              NormalizedPoint(0.10, 0.86), count: 16
            ).dropFirst()
        ])
    case "T":
      return try makeTemplate(
        advance: 0.72,
        strokes: [
          [NormalizedPoint(0.06, 0.08), NormalizedPoint(0.94, 0.08)],
          [NormalizedPoint(0.50, 0.08), NormalizedPoint(0.50, 0.94)],
        ])
    case "U":
      return try makeTemplate(
        advance: 0.80,
        strokes: [
          sampledCubic(
            NormalizedPoint(0.10, 0.08), NormalizedPoint(0.10, 0.78), NormalizedPoint(0.25, 0.95),
            NormalizedPoint(0.50, 0.95), count: 18)
            + sampledCubic(
              NormalizedPoint(0.50, 0.95), NormalizedPoint(0.75, 0.95), NormalizedPoint(0.90, 0.78),
              NormalizedPoint(0.90, 0.08), count: 18
            ).dropFirst()
        ])
    case "V":
      return try makeTemplate(
        advance: 0.78,
        strokes: [
          [NormalizedPoint(0.06, 0.08), NormalizedPoint(0.50, 0.94), NormalizedPoint(0.94, 0.08)]
        ])
    case "W":
      return try makeTemplate(
        advance: 1.02,
        strokes: [
          [
            NormalizedPoint(0.04, 0.08), NormalizedPoint(0.26, 0.94), NormalizedPoint(0.50, 0.48),
            NormalizedPoint(0.74, 0.94), NormalizedPoint(0.96, 0.08),
          ]
        ])
    case "X":
      return try makeTemplate(
        advance: 0.76,
        strokes: [
          [NormalizedPoint(0.08, 0.08), NormalizedPoint(0.92, 0.94)],
          [NormalizedPoint(0.92, 0.08), NormalizedPoint(0.08, 0.94)],
        ])
    case "Y":
      return try makeTemplate(
        advance: 0.76,
        strokes: [
          [NormalizedPoint(0.06, 0.08), NormalizedPoint(0.50, 0.52), NormalizedPoint(0.50, 0.94)],
          [NormalizedPoint(0.94, 0.08), NormalizedPoint(0.50, 0.52)],
        ])
    case "Z":
      return try makeTemplate(
        advance: 0.74,
        strokes: [
          [
            NormalizedPoint(0.08, 0.08), NormalizedPoint(0.92, 0.08), NormalizedPoint(0.08, 0.94),
            NormalizedPoint(0.92, 0.94),
          ]
        ])

    // Lowercase Latin — single-line handwriting profile.
    case "a":
      return try makeTemplate(
        advance: 0.66,
        strokes: [
          sampledArc(
            centerX: 0.38, centerY: 0.58, radiusX: 0.29, radiusY: 0.29, start: -0.35 * pi,
            end: 1.65 * pi, count: 24),
          [NormalizedPoint(0.67, 0.30), NormalizedPoint(0.67, 0.88)],
        ])
    case "b":
      return try makeTemplate(
        advance: 0.68,
        strokes: [
          [NormalizedPoint(0.14, 0.06), NormalizedPoint(0.14, 0.88)],
          sampledArc(
            centerX: 0.39, centerY: 0.61, radiusX: 0.28, radiusY: 0.28, start: -0.5 * pi,
            end: 1.5 * pi, count: 24),
        ])
    case "c":
      return try makeTemplate(
        advance: 0.60,
        strokes: [
          sampledArc(
            centerX: 0.38, centerY: 0.60, radiusX: 0.30, radiusY: 0.29, start: 0.22 * pi,
            end: 1.78 * pi, count: 24)
        ])
    case "d":
      return try makeTemplate(
        advance: 0.68,
        strokes: [
          sampledArc(
            centerX: 0.36, centerY: 0.61, radiusX: 0.28, radiusY: 0.28, start: -0.5 * pi,
            end: 1.5 * pi, count: 24),
          [NormalizedPoint(0.64, 0.06), NormalizedPoint(0.64, 0.88)],
        ])
    case "e":
      return try makeTemplate(
        advance: 0.62,
        strokes: [
          [NormalizedPoint(0.10, 0.60), NormalizedPoint(0.64, 0.60)]
            + sampledArc(
              centerX: 0.38, centerY: 0.60, radiusX: 0.29, radiusY: 0.29, start: 0, end: 1.78 * pi,
              count: 22
            ).dropFirst()
        ])
    case "f":
      return try makeTemplate(
        advance: 0.46,
        strokes: [
          sampledCubic(
            NormalizedPoint(0.60, 0.08), NormalizedPoint(0.25, 0.00), NormalizedPoint(0.30, 0.35),
            NormalizedPoint(0.31, 0.94), count: 24),
          [NormalizedPoint(0.08, 0.39), NormalizedPoint(0.62, 0.39)],
        ])
    case "g":
      return try makeTemplate(
        advance: 0.68,
        strokes: [
          sampledArc(
            centerX: 0.36, centerY: 0.55, radiusX: 0.28, radiusY: 0.27, start: -0.5 * pi,
            end: 1.5 * pi, count: 24),
          sampledCubic(
            NormalizedPoint(0.64, 0.29), NormalizedPoint(0.64, 0.82), NormalizedPoint(0.61, 1.05),
            NormalizedPoint(0.33, 1.08), count: 22),
        ])
    case "h":
      return try makeTemplate(
        advance: 0.68,
        strokes: [
          [NormalizedPoint(0.14, 0.06), NormalizedPoint(0.14, 0.90)],
          sampledCubic(
            NormalizedPoint(0.14, 0.58), NormalizedPoint(0.28, 0.30), NormalizedPoint(0.64, 0.31),
            NormalizedPoint(0.64, 0.88), count: 20),
        ])
    case "i":
      return try makeTemplate(
        advance: 0.30,
        strokes: [
          [NormalizedPoint(0.16, 0.36), NormalizedPoint(0.16, 0.88)],
          [NormalizedPoint(0.16, 0.16, 1.2), NormalizedPoint(0.165, 0.165, 1.2)],
        ])
    case "j":
      return try makeTemplate(
        advance: 0.34,
        strokes: [
          sampledCubic(
            NormalizedPoint(0.22, 0.36), NormalizedPoint(0.22, 0.87), NormalizedPoint(0.18, 1.08),
            NormalizedPoint(-0.04, 1.02), count: 20),
          [NormalizedPoint(0.22, 0.16, 1.2), NormalizedPoint(0.225, 0.165, 1.2)],
        ])
    case "k":
      return try makeTemplate(
        advance: 0.62,
        strokes: [
          [NormalizedPoint(0.12, 0.06), NormalizedPoint(0.12, 0.90)],
          [NormalizedPoint(0.60, 0.34), NormalizedPoint(0.12, 0.64)],
          [NormalizedPoint(0.31, 0.53), NormalizedPoint(0.64, 0.90)],
        ])
    case "l":
      return try makeTemplate(
        advance: 0.30,
        strokes: [
          [NormalizedPoint(0.16, 0.06), NormalizedPoint(0.16, 0.90)]
        ])
    case "m":
      return try makeTemplate(
        advance: 0.94,
        strokes: [
          [NormalizedPoint(0.10, 0.88), NormalizedPoint(0.10, 0.36)]
            + sampledCubic(
              NormalizedPoint(0.10, 0.58), NormalizedPoint(0.24, 0.30), NormalizedPoint(0.45, 0.31),
              NormalizedPoint(0.45, 0.88), count: 16
            ).dropFirst()
            + sampledCubic(
              NormalizedPoint(0.45, 0.58), NormalizedPoint(0.58, 0.30), NormalizedPoint(0.82, 0.31),
              NormalizedPoint(0.82, 0.88), count: 16
            ).dropFirst()
        ])
    case "n":
      return try makeTemplate(
        advance: 0.66,
        strokes: [
          [NormalizedPoint(0.10, 0.88), NormalizedPoint(0.10, 0.36)]
            + sampledCubic(
              NormalizedPoint(0.10, 0.58), NormalizedPoint(0.24, 0.30), NormalizedPoint(0.62, 0.31),
              NormalizedPoint(0.62, 0.88), count: 20
            ).dropFirst()
        ])
    case "o":
      return try makeTemplate(
        advance: 0.64,
        strokes: [
          sampledArc(
            centerX: 0.34, centerY: 0.60, radiusX: 0.29, radiusY: 0.29, start: -0.5 * pi,
            end: 1.5 * pi, count: 26)
        ])
    case "p":
      return try makeTemplate(
        advance: 0.68,
        strokes: [
          [NormalizedPoint(0.12, 0.34), NormalizedPoint(0.12, 1.08)],
          sampledArc(
            centerX: 0.38, centerY: 0.59, radiusX: 0.28, radiusY: 0.28, start: -0.5 * pi,
            end: 1.5 * pi, count: 24),
        ])
    case "q":
      return try makeTemplate(
        advance: 0.68,
        strokes: [
          sampledArc(
            centerX: 0.36, centerY: 0.59, radiusX: 0.28, radiusY: 0.28, start: -0.5 * pi,
            end: 1.5 * pi, count: 24),
          [NormalizedPoint(0.64, 0.34), NormalizedPoint(0.64, 1.08)],
        ])
    case "r":
      return try makeTemplate(
        advance: 0.52,
        strokes: [
          [NormalizedPoint(0.10, 0.88), NormalizedPoint(0.10, 0.36)]
            + sampledCubic(
              NormalizedPoint(0.10, 0.55), NormalizedPoint(0.21, 0.31), NormalizedPoint(0.47, 0.31),
              NormalizedPoint(0.50, 0.48), count: 16
            ).dropFirst()
        ])
    case "s":
      return try makeTemplate(
        advance: 0.56,
        strokes: [
          sampledCubic(
            NormalizedPoint(0.58, 0.40), NormalizedPoint(0.33, 0.27), NormalizedPoint(0.06, 0.39),
            NormalizedPoint(0.18, 0.58), count: 14)
            + sampledCubic(
              NormalizedPoint(0.18, 0.58), NormalizedPoint(0.30, 0.72), NormalizedPoint(0.63, 0.64),
              NormalizedPoint(0.55, 0.83), count: 14
            ).dropFirst()
            + sampledCubic(
              NormalizedPoint(0.55, 0.83), NormalizedPoint(0.46, 0.97), NormalizedPoint(0.15, 0.92),
              NormalizedPoint(0.08, 0.84), count: 10
            ).dropFirst()
        ])
    case "t":
      return try makeTemplate(
        advance: 0.46,
        strokes: [
          [NormalizedPoint(0.25, 0.16), NormalizedPoint(0.25, 0.84)]
            + sampledCubic(
              NormalizedPoint(0.25, 0.84), NormalizedPoint(0.27, 0.95), NormalizedPoint(0.46, 0.92),
              NormalizedPoint(0.50, 0.84), count: 8
            ).dropFirst(),
          [NormalizedPoint(0.05, 0.40), NormalizedPoint(0.54, 0.40)],
        ])
    case "u":
      return try makeTemplate(
        advance: 0.66,
        strokes: [
          sampledCubic(
            NormalizedPoint(0.10, 0.36), NormalizedPoint(0.10, 0.83), NormalizedPoint(0.24, 0.90),
            NormalizedPoint(0.38, 0.90), count: 16)
            + sampledCubic(
              NormalizedPoint(0.38, 0.90), NormalizedPoint(0.53, 0.90), NormalizedPoint(0.62, 0.79),
              NormalizedPoint(0.62, 0.36), count: 16
            ).dropFirst()
        ])
    case "v":
      return try makeTemplate(
        advance: 0.60,
        strokes: [
          [NormalizedPoint(0.06, 0.36), NormalizedPoint(0.30, 0.90), NormalizedPoint(0.56, 0.36)]
        ])
    case "w":
      return try makeTemplate(
        advance: 0.86,
        strokes: [
          [
            NormalizedPoint(0.04, 0.36), NormalizedPoint(0.22, 0.90), NormalizedPoint(0.42, 0.55),
            NormalizedPoint(0.62, 0.90), NormalizedPoint(0.82, 0.36),
          ]
        ])
    case "x":
      return try makeTemplate(
        advance: 0.58,
        strokes: [
          [NormalizedPoint(0.06, 0.36), NormalizedPoint(0.54, 0.90)],
          [NormalizedPoint(0.54, 0.36), NormalizedPoint(0.06, 0.90)],
        ])
    case "y":
      return try makeTemplate(
        advance: 0.62,
        strokes: [
          [NormalizedPoint(0.06, 0.36), NormalizedPoint(0.30, 0.87), NormalizedPoint(0.56, 0.36)],
          sampledCubic(
            NormalizedPoint(0.56, 0.36), NormalizedPoint(0.48, 0.82), NormalizedPoint(0.42, 1.05),
            NormalizedPoint(0.18, 1.08), count: 16),
        ])
    case "z":
      return try makeTemplate(
        advance: 0.56,
        strokes: [
          [
            NormalizedPoint(0.06, 0.38), NormalizedPoint(0.54, 0.38), NormalizedPoint(0.06, 0.88),
            NormalizedPoint(0.56, 0.88),
          ]
        ])

    // Digits.
    case "0":
      return try makeTemplate(
        advance: 0.68,
        strokes: [
          sampledArc(
            centerX: 0.35, centerY: 0.51, radiusX: 0.29, radiusY: 0.43, start: -0.5 * pi,
            end: 1.5 * pi, count: 30)
        ])
    case "1":
      return try makeTemplate(
        advance: 0.44,
        strokes: [
          [NormalizedPoint(0.12, 0.25), NormalizedPoint(0.34, 0.08), NormalizedPoint(0.34, 0.94)]
        ])
    case "2":
      return try makeTemplate(
        advance: 0.66,
        strokes: [
          sampledCubic(
            NormalizedPoint(0.08, 0.25), NormalizedPoint(0.15, -0.02), NormalizedPoint(0.62, 0.00),
            NormalizedPoint(0.60, 0.30), count: 15) + [
              NormalizedPoint(0.08, 0.94), NormalizedPoint(0.64, 0.94),
            ]
        ])
    case "3":
      return try makeTemplate(
        advance: 0.64,
        strokes: [
          sampledCubic(
            NormalizedPoint(0.08, 0.15), NormalizedPoint(0.55, -0.02), NormalizedPoint(0.72, 0.33),
            NormalizedPoint(0.34, 0.49), count: 16)
            + sampledCubic(
              NormalizedPoint(0.34, 0.49), NormalizedPoint(0.76, 0.53), NormalizedPoint(0.68, 1.02),
              NormalizedPoint(0.06, 0.88), count: 18
            ).dropFirst()
        ])
    case "4":
      return try makeTemplate(
        advance: 0.68,
        strokes: [
          [
            NormalizedPoint(0.58, 0.94), NormalizedPoint(0.58, 0.08), NormalizedPoint(0.08, 0.66),
            NormalizedPoint(0.70, 0.66),
          ]
        ])
    case "5":
      return try makeTemplate(
        advance: 0.64,
        strokes: [
          [NormalizedPoint(0.60, 0.08), NormalizedPoint(0.10, 0.08), NormalizedPoint(0.10, 0.48)]
            + sampledCubic(
              NormalizedPoint(0.10, 0.48), NormalizedPoint(0.65, 0.36), NormalizedPoint(0.72, 0.94),
              NormalizedPoint(0.06, 0.90), count: 20
            ).dropFirst()
        ])
    case "6":
      return try makeTemplate(
        advance: 0.66,
        strokes: [
          sampledCubic(
            NormalizedPoint(0.58, 0.12), NormalizedPoint(0.14, 0.18), NormalizedPoint(0.06, 0.72),
            NormalizedPoint(0.31, 0.88), count: 18)
            + sampledArc(
              centerX: 0.35, centerY: 0.68, radiusX: 0.27, radiusY: 0.25, start: 0.65 * pi,
              end: 2.65 * pi, count: 20
            ).dropFirst()
        ])
    case "7":
      return try makeTemplate(
        advance: 0.62,
        strokes: [
          [NormalizedPoint(0.06, 0.08), NormalizedPoint(0.62, 0.08), NormalizedPoint(0.22, 0.94)]
        ])
    case "8":
      return try makeTemplate(
        advance: 0.66,
        strokes: [
          sampledArc(
            centerX: 0.34, centerY: 0.29, radiusX: 0.24, radiusY: 0.22, start: -0.5 * pi,
            end: 1.5 * pi, count: 18)
            + sampledArc(
              centerX: 0.34, centerY: 0.72, radiusX: 0.29, radiusY: 0.25, start: -0.5 * pi,
              end: 1.5 * pi, count: 20)
        ])
    case "9":
      return try makeTemplate(
        advance: 0.66,
        strokes: [
          sampledArc(
            centerX: 0.32, centerY: 0.31, radiusX: 0.27, radiusY: 0.25, start: -0.5 * pi,
            end: 1.5 * pi, count: 20)
            + sampledCubic(
              NormalizedPoint(0.59, 0.31), NormalizedPoint(0.62, 0.74), NormalizedPoint(0.47, 0.92),
              NormalizedPoint(0.12, 0.92), count: 18
            ).dropFirst()
        ])

    // Common punctuation.
    case ".":
      return try makeTemplate(
        advance: 0.28,
        strokes: [[NormalizedPoint(0.14, 0.88, 1.4), NormalizedPoint(0.145, 0.885, 1.4)]])
    case ",":
      return try makeTemplate(
        advance: 0.30,
        strokes: [[NormalizedPoint(0.16, 0.86, 1.3), NormalizedPoint(0.10, 1.02, 1.0)]])
    case "!":
      return try makeTemplate(
        advance: 0.32,
        strokes: [
          [NormalizedPoint(0.16, 0.08), NormalizedPoint(0.16, 0.70)],
          [NormalizedPoint(0.16, 0.90, 1.4), NormalizedPoint(0.165, 0.895, 1.4)],
        ])
    case "?":
      return try makeTemplate(
        advance: 0.58,
        strokes: [
          sampledCubic(
            NormalizedPoint(0.06, 0.23), NormalizedPoint(0.10, -0.02), NormalizedPoint(0.56, 0.02),
            NormalizedPoint(0.52, 0.30), count: 15)
            + sampledCubic(
              NormalizedPoint(0.52, 0.30), NormalizedPoint(0.48, 0.48), NormalizedPoint(0.28, 0.45),
              NormalizedPoint(0.28, 0.68), count: 12
            ).dropFirst(), [NormalizedPoint(0.28, 0.90, 1.4), NormalizedPoint(0.285, 0.895, 1.4)],
        ])
    case "-":
      return try makeTemplate(
        advance: 0.54, strokes: [[NormalizedPoint(0.06, 0.55), NormalizedPoint(0.48, 0.55)]])
    case "_":
      return try makeTemplate(
        advance: 0.62, strokes: [[NormalizedPoint(0.04, 0.98), NormalizedPoint(0.58, 0.98)]])
    case ":":
      return try makeTemplate(
        advance: 0.28,
        strokes: [
          [NormalizedPoint(0.14, 0.38, 1.3), NormalizedPoint(0.145, 0.385, 1.3)],
          [NormalizedPoint(0.14, 0.82, 1.3), NormalizedPoint(0.145, 0.825, 1.3)],
        ])
    case ";":
      return try makeTemplate(
        advance: 0.30,
        strokes: [
          [NormalizedPoint(0.15, 0.38, 1.3), NormalizedPoint(0.155, 0.385, 1.3)],
          [NormalizedPoint(0.16, 0.80, 1.3), NormalizedPoint(0.10, 0.99, 1.0)],
        ])
    case "'":
      return try makeTemplate(
        advance: 0.24, strokes: [[NormalizedPoint(0.13, 0.08), NormalizedPoint(0.10, 0.28)]])
    case "\"":
      return try makeTemplate(
        advance: 0.40,
        strokes: [
          [NormalizedPoint(0.12, 0.08), NormalizedPoint(0.09, 0.28)],
          [NormalizedPoint(0.28, 0.08), NormalizedPoint(0.25, 0.28)],
        ])
    case "(":
      return try makeTemplate(
        advance: 0.36,
        strokes: [
          sampledArc(
            centerX: 0.34, centerY: 0.52, radiusX: 0.28, radiusY: 0.48, start: 0.62 * pi,
            end: 1.38 * pi, count: 22)
        ])
    case ")":
      return try makeTemplate(
        advance: 0.36,
        strokes: [
          sampledArc(
            centerX: 0.02, centerY: 0.52, radiusX: 0.28, radiusY: 0.48, start: -0.38 * pi,
            end: 0.38 * pi, count: 22)
        ])
    case "/":
      return try makeTemplate(
        advance: 0.52, strokes: [[NormalizedPoint(0.46, 0.04), NormalizedPoint(0.06, 0.98)]])
    case "\\":
      return try makeTemplate(
        advance: 0.52, strokes: [[NormalizedPoint(0.06, 0.04), NormalizedPoint(0.46, 0.98)]])
    case "+":
      return try makeTemplate(
        advance: 0.62,
        strokes: [
          [NormalizedPoint(0.06, 0.55), NormalizedPoint(0.56, 0.55)],
          [NormalizedPoint(0.31, 0.30), NormalizedPoint(0.31, 0.80)],
        ])
    case "=":
      return try makeTemplate(
        advance: 0.62,
        strokes: [
          [NormalizedPoint(0.06, 0.43), NormalizedPoint(0.56, 0.43)],
          [NormalizedPoint(0.06, 0.68), NormalizedPoint(0.56, 0.68)],
        ])
    default:
      return nil
    }
  }
}
