import Foundation

struct SVGPathDataParser {
  struct Result {
    let subpaths: [[LiveTextSVGCommand]]
    let sourceCommandCount: Int
    let normalizedSegmentCount: Int
  }

  private var scanner: SVGPathScanner
  private var currentCommand: UInt8?
  private var current: LiveTextSVGPoint
  private var subpathStart: LiveTextSVGPoint
  private var hasCurrent = false
  private var previousCommand: UInt8?
  private var previousCubicControl: LiveTextSVGPoint?
  private var previousQuadraticControl: LiveTextSVGPoint?
  private var subpaths: [[LiveTextSVGCommand]] = []
  private var activeSubpath: [LiveTextSVGCommand] = []
  private var activeSegmentCount = 0
  private var activeHasNonZeroDrawable = false
  private var subpathClosed = false
  private var sourceCommandCount = 0
  private var normalizedSegmentCount = 0
  private let limits: LiveTextSVGImportLimits

  private init(
    _ source: String,
    limits: LiveTextSVGImportLimits
  ) {
    scanner = SVGPathScanner(source)
    current = try! LiveTextSVGPoint(x: 0, y: 0)
    subpathStart = try! LiveTextSVGPoint(x: 0, y: 0)
    self.limits = limits
  }

  static func parse(
    _ source: String,
    limits: LiveTextSVGImportLimits
  ) throws -> Result {
    var parser = SVGPathDataParser(source, limits: limits)
    return try parser.parse()
  }

  private mutating func parse() throws -> Result {
    while true {
      scanner.skipSeparators()
      guard !scanner.isAtEnd else { break }
      if let command = scanner.readCommandIfPresent() {
        guard isSupportedCommand(command) else {
          throw LiveTextSVGImportError.invalidPathData(
            "unsupported command \(UnicodeScalar(command))")
        }
        currentCommand = command
        if command == 0x5A || command == 0x7A {
          try incrementSourceCommandCount()
          guard hasCurrent else {
            throw LiveTextSVGImportError.invalidPathData("close before move")
          }
          guard previousCommand != 0x5A, previousCommand != 0x7A else {
            throw LiveTextSVGImportError.invalidPathData("duplicate close command")
          }
          activeSubpath.append(.close)
          try incrementNormalizedSegmentCount()
          current = subpathStart
          subpathClosed = true
          previousCommand = command
          currentCommand = nil
          continue
        }
      } else {
        guard currentCommand != nil else {
          throw LiveTextSVGImportError.invalidPathData("expected path command")
        }
      }

      guard let command = currentCommand else {
        throw LiveTextSVGImportError.invalidPathData("missing path command")
      }
      let absolute = command >= 0x41 && command <= 0x5A
      let upper = command >= 0x61 ? command - 0x20 : command
      if subpathClosed, upper != 0x4D {
        throw LiveTextSVGImportError.invalidPathData(
          "commands after close require a new move"
        )
      }
      switch upper {
      case 0x4D:
        try parseMove(absolute: absolute)
        currentCommand = absolute ? 0x4C : 0x6C
      case 0x4C:
        try parseLine(absolute: absolute)
      case 0x48:
        try parseHorizontalLine(absolute: absolute)
      case 0x56:
        try parseVerticalLine(absolute: absolute)
      case 0x43:
        try parseCubic(absolute: absolute)
      case 0x53:
        try parseSmoothCubic(absolute: absolute)
      case 0x51:
        try parseQuadratic(absolute: absolute)
      case 0x54:
        try parseSmoothQuadratic(absolute: absolute)
      case 0x41:
        try parseArc(absolute: absolute)
      default:
        throw LiveTextSVGImportError.invalidPathData("unsupported path command")
      }
    }
    try finishActiveSubpath()
    guard !subpaths.isEmpty else {
      throw LiveTextSVGImportError.invalidPathData("path has no drawable subpath")
    }
    return Result(
      subpaths: subpaths,
      sourceCommandCount: sourceCommandCount,
      normalizedSegmentCount: normalizedSegmentCount
    )
  }

  private mutating func parseMove(absolute: Bool) throws {
    try incrementSourceCommandCount()
    let point = try readPoint(absolute: absolute)
    try finishActiveSubpath()
    activeSubpath = [.move(to: point)]
    activeSegmentCount = 0
    activeHasNonZeroDrawable = false
    subpathClosed = false
    current = point
    subpathStart = point
    hasCurrent = true
    previousCommand = absolute ? 0x4D : 0x6D
    previousCubicControl = nil
    previousQuadraticControl = nil
  }

  private mutating func parseLine(absolute: Bool) throws {
    try incrementSourceCommandCount()
    let point = try readPoint(absolute: absolute)
    guard hasCurrent else { throw LiveTextSVGImportError.invalidPathData("line before move") }
    activeSubpath.append(.line(to: point))
    activeHasNonZeroDrawable = activeHasNonZeroDrawable || point != current
    try incrementNormalizedSegmentCount()
    current = point
    previousCommand = absolute ? 0x4C : 0x6C
    previousCubicControl = nil
    previousQuadraticControl = nil
  }

  private mutating func parseHorizontalLine(absolute: Bool) throws {
    try incrementSourceCommandCount()
    let x = try scanner.readNumber()
    guard hasCurrent else { throw LiveTextSVGImportError.invalidPathData("line before move") }
    let point = try checkedPoint(
      x: absolute ? x : current.x + x,
      y: current.y
    )
    activeSubpath.append(.line(to: point))
    activeHasNonZeroDrawable = activeHasNonZeroDrawable || point != current
    try incrementNormalizedSegmentCount()
    current = point
    previousCommand = absolute ? 0x48 : 0x68
    previousCubicControl = nil
    previousQuadraticControl = nil
  }

  private mutating func parseVerticalLine(absolute: Bool) throws {
    try incrementSourceCommandCount()
    let y = try scanner.readNumber()
    guard hasCurrent else { throw LiveTextSVGImportError.invalidPathData("line before move") }
    let point = try checkedPoint(
      x: current.x,
      y: absolute ? y : current.y + y
    )
    activeSubpath.append(.line(to: point))
    activeHasNonZeroDrawable = activeHasNonZeroDrawable || point != current
    try incrementNormalizedSegmentCount()
    current = point
    previousCommand = absolute ? 0x56 : 0x76
    previousCubicControl = nil
    previousQuadraticControl = nil
  }

  private mutating func parseCubic(absolute: Bool) throws {
    try incrementSourceCommandCount()
    let control1 = try readPoint(absolute: absolute)
    let control2 = try readPoint(absolute: absolute)
    let point = try readPoint(absolute: absolute)
    guard hasCurrent else { throw LiveTextSVGImportError.invalidPathData("cubic before move") }
    activeSubpath.append(.cubic(control1: control1, control2: control2, to: point))
    activeHasNonZeroDrawable =
      activeHasNonZeroDrawable
      || control1 != current || control2 != current || point != current
    try incrementNormalizedSegmentCount()
    current = point
    previousCommand = absolute ? 0x43 : 0x63
    previousCubicControl = control2
    previousQuadraticControl = nil
  }

  private mutating func parseSmoothCubic(absolute: Bool) throws {
    try incrementSourceCommandCount()
    guard hasCurrent else { throw LiveTextSVGImportError.invalidPathData("cubic before move") }
    let control1: LiveTextSVGPoint
    if previousCommand == 0x43 || previousCommand == 0x63
      || previousCommand == 0x53 || previousCommand == 0x73,
      let previousCubicControl
    {
      control1 = try checkedPoint(
        x: 2 * current.x - previousCubicControl.x,
        y: 2 * current.y - previousCubicControl.y
      )
    } else {
      control1 = current
    }
    let control2 = try readPoint(absolute: absolute)
    let point = try readPoint(absolute: absolute)
    activeSubpath.append(.cubic(control1: control1, control2: control2, to: point))
    activeHasNonZeroDrawable =
      activeHasNonZeroDrawable
      || control1 != current || control2 != current || point != current
    try incrementNormalizedSegmentCount()
    current = point
    previousCommand = absolute ? 0x53 : 0x73
    previousCubicControl = control2
    previousQuadraticControl = nil
  }

  private mutating func parseQuadratic(absolute: Bool) throws {
    try incrementSourceCommandCount()
    let control = try readPoint(absolute: absolute)
    let point = try readPoint(absolute: absolute)
    guard hasCurrent else { throw LiveTextSVGImportError.invalidPathData("quadratic before move") }
    activeSubpath.append(.quadratic(control: control, to: point))
    activeHasNonZeroDrawable =
      activeHasNonZeroDrawable
      || control != current || point != current
    try incrementNormalizedSegmentCount()
    current = point
    previousCommand = absolute ? 0x51 : 0x71
    previousQuadraticControl = control
    previousCubicControl = nil
  }

  private mutating func parseSmoothQuadratic(absolute: Bool) throws {
    try incrementSourceCommandCount()
    guard hasCurrent else { throw LiveTextSVGImportError.invalidPathData("quadratic before move") }
    let control: LiveTextSVGPoint
    if previousCommand == 0x51 || previousCommand == 0x71
      || previousCommand == 0x54 || previousCommand == 0x74,
      let previousQuadraticControl
    {
      control = try checkedPoint(
        x: 2 * current.x - previousQuadraticControl.x,
        y: 2 * current.y - previousQuadraticControl.y
      )
    } else {
      control = current
    }
    let point = try readPoint(absolute: absolute)
    activeSubpath.append(.quadratic(control: control, to: point))
    activeHasNonZeroDrawable =
      activeHasNonZeroDrawable
      || control != current || point != current
    try incrementNormalizedSegmentCount()
    current = point
    previousCommand = absolute ? 0x54 : 0x74
    previousQuadraticControl = control
    previousCubicControl = nil
  }

  private mutating func parseArc(absolute: Bool) throws {
    try incrementSourceCommandCount()
    guard hasCurrent else { throw LiveTextSVGImportError.invalidPathData("arc before move") }
    let radiusX = try scanner.readNumber()
    let radiusY = try scanner.readNumber()
    let rotation = try scanner.readNumber()
    let largeArcFlag = try scanner.readFlag()
    let sweepFlag = try scanner.readFlag()
    let point = try readPoint(absolute: absolute)
    let commands = try arcCommands(
      from: current,
      to: point,
      radiusX: radiusX,
      radiusY: radiusY,
      rotation: rotation,
      largeArc: largeArcFlag == 1,
      sweep: sweepFlag == 1
    )
    activeSubpath.append(contentsOf: commands)
    activeHasNonZeroDrawable = activeHasNonZeroDrawable || point != current
    for _ in commands { try incrementNormalizedSegmentCount() }
    current = point
    previousCommand = absolute ? 0x41 : 0x61
    previousCubicControl = nil
    previousQuadraticControl = nil
  }

  private mutating func readPoint(absolute: Bool) throws -> LiveTextSVGPoint {
    let x = try scanner.readNumber()
    let y = try scanner.readNumber()
    return try checkedPoint(
      x: absolute || !hasCurrent ? x : current.x + x,
      y: absolute || !hasCurrent ? y : current.y + y
    )
  }

  private func checkedPoint(x: Double, y: Double) throws -> LiveTextSVGPoint {
    guard x.isFinite, y.isFinite else {
      throw LiveTextSVGImportError.invalidPathData("point is not finite")
    }
    guard abs(x) <= limits.maximumCoordinateMagnitude,
      abs(y) <= limits.maximumCoordinateMagnitude
    else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "coordinate magnitude",
        actual: max(liveTextSVGBoundedMagnitude(x), liveTextSVGBoundedMagnitude(y)),
        limit: liveTextSVGBoundedMagnitude(limits.maximumCoordinateMagnitude)
      )
    }
    return try LiveTextSVGPoint(x: x, y: y)
  }

  private mutating func finishActiveSubpath() throws {
    guard !activeSubpath.isEmpty else { return }
    guard activeSubpath.count > 1 else {
      throw LiveTextSVGImportError.invalidPathData("subpath has no drawable command")
    }
    guard activeHasNonZeroDrawable else {
      throw LiveTextSVGImportError.invalidPathData("subpath has no nonzero drawable segment")
    }
    subpaths.append(activeSubpath)
    activeSubpath.removeAll(keepingCapacity: true)
    activeSegmentCount = 0
    activeHasNonZeroDrawable = false
    subpathClosed = false
  }

  private mutating func incrementSourceCommandCount() throws {
    guard sourceCommandCount < limits.maximumPathCommands else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "path commands", actual: sourceCommandCount + 1,
        limit: limits.maximumPathCommands
      )
    }
    sourceCommandCount += 1
  }

  private mutating func incrementNormalizedSegmentCount() throws {
    guard activeSegmentCount < limits.maximumSegmentsPerStroke else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "segments per stroke", actual: activeSegmentCount + 1,
        limit: limits.maximumSegmentsPerStroke
      )
    }
    guard normalizedSegmentCount < limits.maximumNormalizedSegments else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "normalized segments", actual: normalizedSegmentCount + 1,
        limit: limits.maximumNormalizedSegments
      )
    }
    activeSegmentCount += 1
    normalizedSegmentCount += 1
  }

  private func isSupportedCommand(_ command: UInt8) -> Bool {
    switch command >= 0x61 ? command - 0x20 : command {
    case 0x4D, 0x4C, 0x48, 0x56, 0x43, 0x53, 0x51, 0x54, 0x41, 0x5A:
      return true
    default:
      return false
    }
  }
}

private struct SVGPathScanner {
  private let bytes: [UInt8]
  private var index = 0

  init(_ source: String) {
    bytes = Array(source.utf8)
  }

  var isAtEnd: Bool { index >= bytes.count }

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

  mutating func readCommandIfPresent() -> UInt8? {
    guard index < bytes.count else { return nil }
    let byte = bytes[index]
    guard (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) else {
      return nil
    }
    index += 1
    return byte
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
      throw LiveTextSVGImportError.invalidPathData("invalid number")
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
        throw LiveTextSVGImportError.invalidPathData("invalid exponent")
      }
    }
    let value = Double(String(decoding: bytes[start..<index], as: UTF8.self))
    guard let value, value.isFinite else {
      throw LiveTextSVGImportError.invalidPathData("number is not finite")
    }
    return value
  }

  mutating func readFlag() throws -> Int {
    skipSeparators()
    guard index < bytes.count, bytes[index] == 0x30 || bytes[index] == 0x31 else {
      throw LiveTextSVGImportError.invalidPathData("arc flag must be zero or one")
    }
    let value = bytes[index] - 0x30
    index += 1
    return Int(value)
  }
}

extension SVGPathDataParser {
  fileprivate func arcCommands(
    from start: LiveTextSVGPoint,
    to end: LiveTextSVGPoint,
    radiusX: Double,
    radiusY: Double,
    rotation: Double,
    largeArc: Bool,
    sweep: Bool
  ) throws -> [LiveTextSVGCommand] {
    guard radiusX.isFinite, radiusY.isFinite, rotation.isFinite else {
      throw LiveTextSVGImportError.invalidPathData("arc contains a non-finite value")
    }
    if start == end { return [] }
    let rx = abs(radiusX)
    let ry = abs(radiusY)
    if rx == 0 || ry == 0 { return [.line(to: end)] }

    let phi = rotation.truncatingRemainder(dividingBy: 360) * .pi / 180
    let cosPhi = cos(phi)
    let sinPhi = sin(phi)
    let dx = (start.x - end.x) * 0.5
    let dy = (start.y - end.y) * 0.5
    let xPrime = cosPhi * dx + sinPhi * dy
    let yPrime = -sinPhi * dx + cosPhi * dy
    var adjustedRx = rx
    var adjustedRy = ry
    let lambda = xPrime * xPrime / (rx * rx) + yPrime * yPrime / (ry * ry)
    if lambda > 1 {
      let factor = sqrt(lambda)
      adjustedRx *= factor
      adjustedRy *= factor
    }

    let rxSquared = adjustedRx * adjustedRx
    let rySquared = adjustedRy * adjustedRy
    let numerator = max(
      0, rxSquared * rySquared - rxSquared * yPrime * yPrime - rySquared * xPrime * xPrime)
    let denominator = rxSquared * yPrime * yPrime + rySquared * xPrime * xPrime
    guard denominator > 0 else { return [.line(to: end)] }
    let sign = largeArc == sweep ? -1.0 : 1.0
    let coefficient = sign * sqrt(numerator / denominator)
    let centerPrimeX = coefficient * adjustedRx * yPrime / adjustedRy
    let centerPrimeY = coefficient * -adjustedRy * xPrime / adjustedRx
    let centerX = cosPhi * centerPrimeX - sinPhi * centerPrimeY + (start.x + end.x) * 0.5
    let centerY = sinPhi * centerPrimeX + cosPhi * centerPrimeY + (start.y + end.y) * 0.5

    func vectorAngle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
      let dot = ux * vx + uy * vy
      let cross = ux * vy - uy * vx
      return atan2(cross, dot)
    }
    let thetaStart = vectorAngle(
      1, 0,
      (xPrime - centerPrimeX) / adjustedRx,
      (yPrime - centerPrimeY) / adjustedRy
    )
    var delta = vectorAngle(
      (xPrime - centerPrimeX) / adjustedRx,
      (yPrime - centerPrimeY) / adjustedRy,
      (-xPrime - centerPrimeX) / adjustedRx,
      (-yPrime - centerPrimeY) / adjustedRy
    )
    if !sweep, delta > 0 { delta -= 2 * .pi }
    if sweep, delta < 0 { delta += 2 * .pi }
    let segmentCount = max(1, Int(ceil(abs(delta) / (.pi * 0.5))))
    var commands: [LiveTextSVGCommand] = []
    commands.reserveCapacity(segmentCount)
    for index in 0..<segmentCount {
      let startAngle = thetaStart + delta * Double(index) / Double(segmentCount)
      let endAngle = thetaStart + delta * Double(index + 1) / Double(segmentCount)
      let span = endAngle - startAngle
      let alpha = 4 / 3 * tan(span / 4)

      func point(_ angle: Double) -> (x: Double, y: Double) {
        (
          centerX + cosPhi * adjustedRx * cos(angle) - sinPhi * adjustedRy * sin(angle),
          centerY + sinPhi * adjustedRx * cos(angle) + cosPhi * adjustedRy * sin(angle)
        )
      }
      func derivative(_ angle: Double) -> (x: Double, y: Double) {
        (
          -cosPhi * adjustedRx * sin(angle) - sinPhi * adjustedRy * cos(angle),
          -sinPhi * adjustedRx * sin(angle) + cosPhi * adjustedRy * cos(angle)
        )
      }
      let segmentStart =
        index == 0 ? start : try checkedPoint(x: point(startAngle).x, y: point(startAngle).y)
      let segmentEnd =
        index == segmentCount - 1
        ? end : try checkedPoint(x: point(endAngle).x, y: point(endAngle).y)
      let startDerivative = derivative(startAngle)
      let endDerivative = derivative(endAngle)
      let control1 = try checkedPoint(
        x: segmentStart.x + alpha * startDerivative.x,
        y: segmentStart.y + alpha * startDerivative.y
      )
      let control2 = try checkedPoint(
        x: segmentEnd.x - alpha * endDerivative.x,
        y: segmentEnd.y - alpha * endDerivative.y
      )
      commands.append(.cubic(control1: control1, control2: control2, to: segmentEnd))
    }
    return commands
  }
}
