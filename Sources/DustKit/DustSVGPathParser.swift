#if os(iOS)
import CoreGraphics
import Foundation

// Path command handling and elliptical-arc conversion are derived from
// PocketSVG's MIT-licensed SVGEngine.mm, rewritten in Swift and tightened for
// DustKit's read-only SVG -> CGPath boundary. See THIRD_PARTY_NOTICES.md.
enum DustSVGPathParser {
  enum ParseError: Error, LocalizedError {
    case invalidNumber(Int)
    case missingCommand(Int)
    case invalidOperandCount(Character)
    case invalidArc
    case unsupportedCommand(Character)

    var errorDescription: String? {
      switch self {
      case .invalidNumber(let offset): return "invalid number near offset \(offset)"
      case .missingCommand(let offset): return "missing path command near offset \(offset)"
      case .invalidOperandCount(let command): return "invalid operand count for \(command)"
      case .invalidArc: return "invalid elliptical arc"
      case .unsupportedCommand(let command): return "unsupported path command \(command)"
      }
    }
  }

  private enum Token {
    case command(Character)
    case number(CGFloat)
  }

  static func parse(_ definition: String) throws -> CGPath {
    let tokens = try tokenize(definition)
    let path = CGMutablePath()
    var index = 0
    var command: Character?
    var previousCommand: Character?
    var current = CGPoint.zero
    var subpathStart = CGPoint.zero
    var lastCubicControl: CGPoint?
    var lastQuadraticControl: CGPoint?

    func isCommand(at i: Int) -> Bool {
      guard i < tokens.count else { return false }
      if case .command = tokens[i] { return true }
      return false
    }

    func number(_ i: inout Int) throws -> CGFloat {
      guard i < tokens.count else {
        throw ParseError.invalidOperandCount(command ?? "?")
      }
      guard case .number(let value) = tokens[i] else {
        throw ParseError.invalidOperandCount(command ?? "?")
      }
      i += 1
      return value
    }

    func absolutePoint(x: CGFloat, y: CGFloat, relative: Bool, from origin: CGPoint) -> CGPoint {
      relative ? CGPoint(x: origin.x + x, y: origin.y + y) : CGPoint(x: x, y: y)
    }

    while index < tokens.count {
      if case .command(let explicit) = tokens[index] {
        command = explicit
        index += 1
      } else if command == nil {
        throw ParseError.missingCommand(index)
      }

      guard let cmd = command else { break }
      let relative = cmd.isLowercase
      let upper = Character(String(cmd).uppercased())

      if upper == "Z" {
        path.closeSubpath()
        current = subpathStart
        lastCubicControl = nil
        lastQuadraticControl = nil
        previousCommand = cmd
        command = nil
        continue
      }

      let operandStart = index
      switch upper {
      case "M":
        var first = true
        while index < tokens.count, !isCommand(at: index) {
          let x = try number(&index)
          let y = try number(&index)
          let point = absolutePoint(x: x, y: y, relative: relative, from: current)
          if first {
            path.move(to: point)
            subpathStart = point
            first = false
          } else {
            path.addLine(to: point)
          }
          current = point
          lastCubicControl = nil
          lastQuadraticControl = nil
        }
        if first { throw ParseError.invalidOperandCount(cmd) }
        // SVG: additional moveto coordinate pairs are implicit lineto.
        command = relative ? "l" : "L"

      case "L":
        var consumed = false
        while index < tokens.count, !isCommand(at: index) {
          let x = try number(&index)
          let y = try number(&index)
          current = absolutePoint(x: x, y: y, relative: relative, from: current)
          path.addLine(to: current)
          consumed = true
        }
        if !consumed { throw ParseError.invalidOperandCount(cmd) }
        lastCubicControl = nil
        lastQuadraticControl = nil

      case "H":
        var consumed = false
        while index < tokens.count, !isCommand(at: index) {
          let x = try number(&index)
          current = CGPoint(x: relative ? current.x + x : x, y: current.y)
          path.addLine(to: current)
          consumed = true
        }
        if !consumed { throw ParseError.invalidOperandCount(cmd) }
        lastCubicControl = nil
        lastQuadraticControl = nil

      case "V":
        var consumed = false
        while index < tokens.count, !isCommand(at: index) {
          let y = try number(&index)
          current = CGPoint(x: current.x, y: relative ? current.y + y : y)
          path.addLine(to: current)
          consumed = true
        }
        if !consumed { throw ParseError.invalidOperandCount(cmd) }
        lastCubicControl = nil
        lastQuadraticControl = nil

      case "C":
        var consumed = false
        while index < tokens.count, !isCommand(at: index) {
          let origin = current
          let c1 = absolutePoint(
            x: try number(&index), y: try number(&index),
            relative: relative, from: origin
          )
          let c2 = absolutePoint(
            x: try number(&index), y: try number(&index),
            relative: relative, from: origin
          )
          let end = absolutePoint(
            x: try number(&index), y: try number(&index),
            relative: relative, from: origin
          )
          path.addCurve(to: end, control1: c1, control2: c2)
          current = end
          lastCubicControl = c2
          lastQuadraticControl = nil
          consumed = true
        }
        if !consumed { throw ParseError.invalidOperandCount(cmd) }

      case "S":
        var consumed = false
        while index < tokens.count, !isCommand(at: index) {
          let origin = current
          let previousUpper = previousCommand.map { Character(String($0).uppercased()) }
          let c1: CGPoint
          if previousUpper == "C" || previousUpper == "S", let prior = lastCubicControl {
            c1 = CGPoint(x: origin.x * 2 - prior.x, y: origin.y * 2 - prior.y)
          } else {
            c1 = origin
          }
          let c2 = absolutePoint(
            x: try number(&index), y: try number(&index),
            relative: relative, from: origin
          )
          let end = absolutePoint(
            x: try number(&index), y: try number(&index),
            relative: relative, from: origin
          )
          path.addCurve(to: end, control1: c1, control2: c2)
          current = end
          lastCubicControl = c2
          lastQuadraticControl = nil
          previousCommand = cmd
          consumed = true
        }
        if !consumed { throw ParseError.invalidOperandCount(cmd) }

      case "Q":
        var consumed = false
        while index < tokens.count, !isCommand(at: index) {
          let origin = current
          let control = absolutePoint(
            x: try number(&index), y: try number(&index),
            relative: relative, from: origin
          )
          let end = absolutePoint(
            x: try number(&index), y: try number(&index),
            relative: relative, from: origin
          )
          path.addQuadCurve(to: end, control: control)
          current = end
          lastQuadraticControl = control
          lastCubicControl = nil
          consumed = true
        }
        if !consumed { throw ParseError.invalidOperandCount(cmd) }

      case "T":
        var consumed = false
        while index < tokens.count, !isCommand(at: index) {
          let origin = current
          let previousUpper = previousCommand.map { Character(String($0).uppercased()) }
          let control: CGPoint
          if previousUpper == "Q" || previousUpper == "T", let prior = lastQuadraticControl {
            control = CGPoint(x: origin.x * 2 - prior.x, y: origin.y * 2 - prior.y)
          } else {
            control = origin
          }
          let end = absolutePoint(
            x: try number(&index), y: try number(&index),
            relative: relative, from: origin
          )
          path.addQuadCurve(to: end, control: control)
          current = end
          lastQuadraticControl = control
          lastCubicControl = nil
          previousCommand = cmd
          consumed = true
        }
        if !consumed { throw ParseError.invalidOperandCount(cmd) }

      case "A":
        var consumed = false
        while index < tokens.count, !isCommand(at: index) {
          let origin = current
          let rx = try number(&index)
          let ry = try number(&index)
          let rotation = try number(&index)
          let largeArc = try number(&index)
          let sweep = try number(&index)
          guard largeArc == 0 || largeArc == 1, sweep == 0 || sweep == 1 else {
            throw ParseError.invalidArc
          }
          let end = absolutePoint(
            x: try number(&index), y: try number(&index),
            relative: relative, from: origin
          )
          try appendArc(
            to: path,
            from: origin,
            to: end,
            rx: rx,
            ry: ry,
            xAxisRotationDegrees: rotation,
            largeArc: largeArc != 0,
            sweep: sweep != 0
          )
          current = end
          lastCubicControl = nil
          lastQuadraticControl = nil
          consumed = true
        }
        if !consumed { throw ParseError.invalidOperandCount(cmd) }

      default:
        throw ParseError.unsupportedCommand(cmd)
      }

      if index == operandStart {
        throw ParseError.invalidOperandCount(cmd)
      }
      previousCommand = cmd
    }

    return path
  }

  private static func tokenize(_ source: String) throws -> [Token] {
    let scalars = Array(source.unicodeScalars)
    let commands = Set("MmLlHhVvCcSsQqTtAaZz".unicodeScalars)
    var result: [Token] = []
    var i = 0

    while i < scalars.count {
      let scalar = scalars[i]
      if commands.contains(scalar) {
        result.append(.command(Character(String(scalar))))
        i += 1
        continue
      }
      if scalar == "," || CharacterSet.whitespacesAndNewlines.contains(scalar) {
        i += 1
        continue
      }

      let start = i
      if scalars[i] == "+" || scalars[i] == "-" { i += 1 }
      var digits = 0
      while i < scalars.count, scalars[i].value >= 48, scalars[i].value <= 57 {
        digits += 1
        i += 1
      }
      if i < scalars.count, scalars[i] == "." {
        i += 1
        while i < scalars.count, scalars[i].value >= 48, scalars[i].value <= 57 {
          digits += 1
          i += 1
        }
      }
      if digits == 0 { throw ParseError.invalidNumber(start) }
      if i < scalars.count, scalars[i] == "e" || scalars[i] == "E" {
        let exponentStart = i
        i += 1
        if i < scalars.count, scalars[i] == "+" || scalars[i] == "-" { i += 1 }
        var exponentDigits = 0
        while i < scalars.count, scalars[i].value >= 48, scalars[i].value <= 57 {
          exponentDigits += 1
          i += 1
        }
        if exponentDigits == 0 { throw ParseError.invalidNumber(exponentStart) }
      }
      let numberString = String(scalars[start..<i].map { Character(String($0)) })
      guard let value = Double(numberString), value.isFinite else {
        throw ParseError.invalidNumber(start)
      }
      result.append(.number(CGFloat(value)))
    }
    return result
  }

  // SVG 1.1 endpoint-to-center arc conversion, adapted from PocketSVG.
  private static func appendArc(
    to path: CGMutablePath,
    from start: CGPoint,
    to end: CGPoint,
    rx rawRX: CGFloat,
    ry rawRY: CGFloat,
    xAxisRotationDegrees: CGFloat,
    largeArc: Bool,
    sweep: Bool
  ) throws {
    if start == end { return }
    var rx = abs(Double(rawRX))
    var ry = abs(Double(rawRY))
    guard rx > 0, ry > 0 else {
      path.addLine(to: end)
      return
    }

    let phi = Double(xAxisRotationDegrees) * .pi / 180
    let sinPhi = sin(phi)
    let cosPhi = cos(phi)
    let px = Double(start.x)
    let py = Double(start.y)
    let ex = Double(end.x)
    let ey = Double(end.y)
    let pxp = cosPhi * (px - ex) / 2 + sinPhi * (py - ey) / 2
    let pyp = -sinPhi * (px - ex) / 2 + cosPhi * (py - ey) / 2

    let lambda = pxp * pxp / (rx * rx) + pyp * pyp / (ry * ry)
    if lambda > 1 {
      let scale = sqrt(lambda)
      rx *= scale
      ry *= scale
    }

    let rx2 = rx * rx
    let ry2 = ry * ry
    let pxp2 = pxp * pxp
    let pyp2 = pyp * pyp
    let denominator = rx2 * pyp2 + ry2 * pxp2
    guard denominator > 0 else {
      path.addLine(to: end)
      return
    }
    var radicand = max((rx2 * ry2 - rx2 * pyp2 - ry2 * pxp2) / denominator, 0)
    radicand = sqrt(radicand) * (largeArc == sweep ? -1 : 1)
    let centerXP = radicand * rx / ry * pyp
    let centerYP = radicand * -ry / rx * pxp
    let centerX = cosPhi * centerXP - sinPhi * centerYP + (px + ex) / 2
    let centerY = sinPhi * centerXP + cosPhi * centerYP + (py + ey) / 2

    let v1 = ((pxp - centerXP) / rx, (pyp - centerYP) / ry)
    let v2 = ((-pxp - centerXP) / rx, (-pyp - centerYP) / ry)
    var angle1 = vectorAngle(1, 0, v1.0, v1.1)
    var delta = vectorAngle(v1.0, v1.1, v2.0, v2.1)
    let tau = Double.pi * 2
    if !sweep, delta > 0 { delta -= tau }
    if sweep, delta < 0 { delta += tau }
    let segments = max(Int(ceil(abs(delta) / (tau / 4))), 1)
    let segmentAngle = delta / Double(segments)

    for _ in 0..<segments {
      let alpha = 4.0 / 3.0 * tan(segmentAngle / 4.0)
      let x1 = cos(angle1)
      let y1 = sin(angle1)
      let x2 = cos(angle1 + segmentAngle)
      let y2 = sin(angle1 + segmentAngle)
      let c1 = mapToEllipse(
        x1 - y1 * alpha, y1 + x1 * alpha,
        rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi,
        centerX: centerX, centerY: centerY
      )
      let c2 = mapToEllipse(
        x2 + y2 * alpha, y2 - x2 * alpha,
        rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi,
        centerX: centerX, centerY: centerY
      )
      let point = mapToEllipse(
        x2, y2,
        rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi,
        centerX: centerX, centerY: centerY
      )
      path.addCurve(to: point, control1: c1, control2: c2)
      angle1 += segmentAngle
    }
  }

  private static func vectorAngle(
    _ ux: Double, _ uy: Double,
    _ vx: Double, _ vy: Double
  ) -> Double {
    let sign = ux * vy - uy * vx < 0 ? -1.0 : 1.0
    let uMagnitude = hypot(ux, uy)
    let vMagnitude = hypot(vx, vy)
    guard uMagnitude > 0, vMagnitude > 0 else { return 0 }
    let cosine = min(max((ux * vx + uy * vy) / (uMagnitude * vMagnitude), -1), 1)
    return sign * acos(cosine)
  }

  private static func mapToEllipse(
    _ x: Double,
    _ y: Double,
    rx: Double,
    ry: Double,
    cosPhi: Double,
    sinPhi: Double,
    centerX: Double,
    centerY: Double
  ) -> CGPoint {
    let sx = x * rx
    let sy = y * ry
    return CGPoint(
      x: cosPhi * sx - sinPhi * sy + centerX,
      y: sinPhi * sx + cosPhi * sy + centerY
    )
  }
}

extension Character {
  fileprivate var isLowercase: Bool {
    String(self) == String(self).lowercased()
  }
}
#endif
