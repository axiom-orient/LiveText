import Foundation

struct SVGTransform: Equatable, Sendable {
  var a: Double = 1
  var b: Double = 0
  var c: Double = 0
  var d: Double = 1
  var tx: Double = 0
  var ty: Double = 0

  static let identity = SVGTransform()

  static func translation(_ x: Double, _ y: Double) -> SVGTransform {
    SVGTransform(tx: x, ty: y)
  }

  static func scale(_ x: Double, _ y: Double) -> SVGTransform {
    SVGTransform(a: x, d: y)
  }

  /// Returns `self ∘ other`: `other` is applied first, then `self`.
  func concatenating(_ other: SVGTransform) -> SVGTransform {
    SVGTransform(
      a: a * other.a + c * other.b,
      b: b * other.a + d * other.b,
      c: a * other.c + c * other.d,
      d: b * other.c + d * other.d,
      tx: a * other.tx + c * other.ty + tx,
      ty: b * other.tx + d * other.ty + ty
    )
  }

  func applying(to point: LiveTextSVGPoint) throws -> LiveTextSVGPoint {
    let x = a * point.x + c * point.y + tx
    let y = b * point.x + d * point.y + ty
    guard x.isFinite, y.isFinite else {
      throw LiveTextSVGImportError.invalidTransform("transformed coordinate is not finite")
    }
    return try LiveTextSVGPoint(x: x, y: y)
  }

  var similarityScale: Double? {
    let first = hypot(a, b)
    let second = hypot(c, d)
    let dot = a * c + b * d
    let tolerance = 0.000_001 * max(1, first, second)
    guard first.isFinite, second.isFinite, first > 0,
      abs(first - second) <= tolerance,
      abs(dot) <= tolerance * tolerance
    else { return nil }
    return (first + second) * 0.5
  }
}

enum SVGTransformParser {
  static func parse(_ raw: String) throws -> SVGTransform {
    var scanner = SVGNumberScanner(raw)
    var result = SVGTransform.identity
    while let function = try scanner.nextTransformFunction() {
      let transform: SVGTransform
      switch function.name {
      case "translate":
        guard function.numbers.count == 1 || function.numbers.count == 2 else {
          throw LiveTextSVGImportError.invalidTransform("translate expects one or two numbers")
        }
        transform = .translation(
          function.numbers[0], function.numbers.count == 2 ? function.numbers[1] : 0)
      case "scale":
        guard function.numbers.count == 1 || function.numbers.count == 2 else {
          throw LiveTextSVGImportError.invalidTransform("scale expects one or two numbers")
        }
        transform = .scale(
          function.numbers[0],
          function.numbers.count == 2 ? function.numbers[1] : function.numbers[0])
      case "rotate":
        guard function.numbers.count == 1 || function.numbers.count == 3 else {
          throw LiveTextSVGImportError.invalidTransform("rotate expects one or three numbers")
        }
        let radians = function.numbers[0] * .pi / 180
        let rotation = SVGTransform(
          a: cos(radians), b: sin(radians), c: -sin(radians), d: cos(radians)
        )
        if function.numbers.count == 3 {
          let center = SVGTransform.translation(function.numbers[1], function.numbers[2])
          let inverse = SVGTransform.translation(-function.numbers[1], -function.numbers[2])
          transform = center.concatenating(rotation).concatenating(inverse)
        } else {
          transform = rotation
        }
      case "skewx", "skewy":
        guard function.numbers.count == 1 else {
          throw LiveTextSVGImportError.invalidTransform("skew expects one number")
        }
        let tangent = tan(function.numbers[0] * .pi / 180)
        guard tangent.isFinite else {
          throw LiveTextSVGImportError.invalidTransform("skew angle is singular")
        }
        transform =
          function.name == "skewx"
          ? SVGTransform(a: 1, c: tangent, d: 1)
          : SVGTransform(a: 1, b: tangent, d: 1)
      case "matrix":
        guard function.numbers.count == 6 else {
          throw LiveTextSVGImportError.invalidTransform("matrix expects six numbers")
        }
        transform = SVGTransform(
          a: function.numbers[0], b: function.numbers[1], c: function.numbers[2],
          d: function.numbers[3], tx: function.numbers[4], ty: function.numbers[5]
        )
      default:
        throw LiveTextSVGImportError.invalidTransform("unsupported transform \(function.name)")
      }
      guard
        [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
          .allSatisfy({ $0.isFinite })
      else {
        throw LiveTextSVGImportError.invalidTransform("transform contains a non-finite value")
      }
      result = result.concatenating(transform)
    }
    return result
  }
}
