import Foundation
import LiveTextLayout

/// A renderer-neutral rectangle used while compiling an effect plan.
public struct ColoredPencilRect: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double = 0, y: Double = 0, width: Double, height: Double) throws {
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
      width >= 0, height >= 0
    else {
      throw ColoredPencilError.invalidGeometry
    }
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  package init(validatedX x: Double, y: Double, width: Double, height: Double) {
    precondition(
      x.isFinite && y.isFinite && width.isFinite && height.isFinite && width >= 0 && height >= 0)
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  private enum CodingKeys: String, CodingKey { case x, y, width, height }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      x: values.decode(Double.self, forKey: .x),
      y: values.decode(Double.self, forKey: .y),
      width: values.decode(Double.self, forKey: .width),
      height: values.decode(Double.self, forKey: .height)
    )
  }
}

/// Errors raised while preparing a colored-pencil plan.
public enum ColoredPencilError: Error, Equatable, LocalizedError, Sendable {
  case invalidConfiguration(field: String, value: Double)
  case invalidGeometry
  case resourceLimitExceeded(resource: String, actual: Int, limit: Int)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let field, let value):
      return "Invalid colored-pencil configuration '\(field)': \(value)."
    case .invalidGeometry:
      return "Colored-pencil geometry must contain finite, non-negative dimensions."
    case .resourceLimitExceeded(let resource, let actual, let limit):
      return "Colored-pencil \(resource) limit exceeded: \(actual) > \(limit)."
    }
  }
}

/// Deterministic material parameters for a colored-pencil stroke.
///
/// The defaults are tuned to remain legible at body-text scale while making
/// paper tooth, pigment fibers, and open-stroke taper observable. These values
/// affect only the visual plan; they never change layout metrics.
public struct ColoredPencilConfiguration: Codable, Equatable, Hashable, Sendable {
  public static let maximumFiberDensity = 64.0
  public static let maximumJitterAmount = 1.0
  public static let maximumFiberAmount = 1.0
  public static let maximumPaperTooth = 1.0
  public static let maximumTaperAmount = 1.0

  public let seed: UInt64
  public let jitterAmount: Double
  public let fiberAmount: Double
  public let paperTooth: Double
  public let taperAmount: Double
  public let fiberDensity: Double

  public init(
    seed: UInt64 = 0x43_50_454E_4349_4C,
    jitterAmount: Double = 0.42,
    fiberAmount: Double = 0.34,
    paperTooth: Double = 0.28,
    taperAmount: Double = 0.92,
    fiberDensity: Double = 0.58
  ) throws {
    let values = [
      ("jitterAmount", jitterAmount, Self.maximumJitterAmount),
      ("fiberAmount", fiberAmount, Self.maximumFiberAmount),
      ("paperTooth", paperTooth, Self.maximumPaperTooth),
      ("taperAmount", taperAmount, Self.maximumTaperAmount),
      ("fiberDensity", fiberDensity, Self.maximumFiberDensity),
    ]
    for (field, value, maximum) in values {
      guard value.isFinite, value >= 0, value <= maximum else {
        throw ColoredPencilError.invalidConfiguration(field: field, value: value)
      }
    }
    self.seed = seed
    self.jitterAmount = jitterAmount
    self.fiberAmount = fiberAmount
    self.paperTooth = paperTooth
    self.taperAmount = taperAmount
    self.fiberDensity = fiberDensity
  }

  private enum CodingKeys: String, CodingKey {
    case seed, jitterAmount, fiberAmount, paperTooth, taperAmount, fiberDensity
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      seed: values.decode(UInt64.self, forKey: .seed),
      jitterAmount: values.decode(Double.self, forKey: .jitterAmount),
      fiberAmount: values.decode(Double.self, forKey: .fiberAmount),
      paperTooth: values.decode(Double.self, forKey: .paperTooth),
      taperAmount: values.decode(Double.self, forKey: .taperAmount),
      fiberDensity: values.decode(Double.self, forKey: .fiberDensity)
    )
  }

  /// A visible pencil trace suitable for body text and mixed inline content.
  public static let `default` = ColoredPencilConfiguration(
    uncheckedSeed: 0x43_50_454E_4349_4C,
    jitterAmount: 0.50,
    fiberAmount: 0.48,
    paperTooth: 0.58,
    taperAmount: 0.96,
    fiberDensity: 0.82
  )

  /// A quieter treatment for small sizes where dense fibers would alias.
  public static let soft = ColoredPencilConfiguration(
    uncheckedSeed: 0x43_50_454E_534F_4654,
    jitterAmount: 0.25,
    fiberAmount: 0.18,
    paperTooth: 0.16,
    taperAmount: 0.82,
    fiberDensity: 0.34
  )

  /// A more tactile treatment for display-sized vector writing.
  public static let textured = ColoredPencilConfiguration(
    uncheckedSeed: 0x43_50_454E_5445_5854,
    jitterAmount: 0.66,
    fiberAmount: 0.52,
    paperTooth: 0.46,
    taperAmount: 1,
    fiberDensity: 0.92
  )

  private init(
    uncheckedSeed seed: UInt64,
    jitterAmount: Double,
    fiberAmount: Double,
    paperTooth: Double,
    taperAmount: Double,
    fiberDensity: Double
  ) {
    self.seed = seed
    self.jitterAmount = jitterAmount
    self.fiberAmount = fiberAmount
    self.paperTooth = paperTooth
    self.taperAmount = taperAmount
    self.fiberDensity = fiberDensity
  }
}

/// One sampled centerline point. `width` is the full visible stroke width in
/// points, not a radius. The body is always one point wide.
public struct ColoredPencilPoint: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double

  public init(x: Double, y: Double, width: Double = 1) throws {
    guard x.isFinite, y.isFinite, width.isFinite, width > 0 else {
      throw ColoredPencilError.invalidGeometry
    }
    self.x = x
    self.y = y
    self.width = width
  }

  package init(validatedX x: Double, y: Double, width: Double = 1) {
    precondition(x.isFinite && y.isFinite && width.isFinite && width > 0)
    self.x = x
    self.y = y
    self.width = width
  }

  private enum CodingKeys: String, CodingKey { case x, y, width }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      x: values.decode(Double.self, forKey: .x),
      y: values.decode(Double.self, forKey: .y),
      width: values.decode(Double.self, forKey: .width)
    )
  }
}

/// The distance interval belonging to one source path command.
public struct ColoredPencilCommandSpan: Codable, Equatable, Hashable, Sendable {
  public let commandIndex: Int
  public let startDistance: Double
  public let endDistance: Double

  public var length: Double { max(0, endDistance - startDistance) }

  fileprivate init(commandIndex: Int, startDistance: Double, endDistance: Double) {
    self.commandIndex = commandIndex
    self.startDistance = startDistance
    self.endDistance = endDistance
  }

  private enum CodingKeys: String, CodingKey { case commandIndex, startDistance, endDistance }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let commandIndex = try values.decode(Int.self, forKey: .commandIndex)
    let startDistance = try values.decode(Double.self, forKey: .startDistance)
    let endDistance = try values.decode(Double.self, forKey: .endDistance)
    guard commandIndex >= 0, startDistance.isFinite, endDistance.isFinite,
      startDistance >= 0, endDistance > startDistance
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .endDistance, in: values, debugDescription: "invalid colored-pencil command span")
    }
    self.init(commandIndex: commandIndex, startDistance: startDistance, endDistance: endDistance)
  }
}

/// A deterministic, low-opacity fiber drawn alongside a pencil body.
public struct ColoredPencilFiber: Codable, Equatable, Hashable, Sendable {
  public let offset: Double
  public let opacity: Double
  public let widthScale: Double
  public let phase: Double

  fileprivate init(offset: Double, opacity: Double, widthScale: Double, phase: Double) {
    self.offset = offset
    self.opacity = opacity
    self.widthScale = widthScale
    self.phase = phase
  }

  private enum CodingKeys: String, CodingKey { case offset, opacity, widthScale, phase }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let offset = try values.decode(Double.self, forKey: .offset)
    let opacity = try values.decode(Double.self, forKey: .opacity)
    let widthScale = try values.decode(Double.self, forKey: .widthScale)
    let phase = try values.decode(Double.self, forKey: .phase)
    guard [offset, opacity, widthScale, phase].allSatisfy(\.isFinite),
      (0...1).contains(opacity), widthScale > 0, (0...1).contains(phase)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .opacity, in: values, debugDescription: "invalid colored-pencil fiber")
    }
    self.init(offset: offset, opacity: opacity, widthScale: widthScale, phase: phase)
  }
}

/// One deterministic interior stroke used to give closed display glyphs the
/// layered, filled look of a colored pencil. Hatches are material geometry,
/// not handwriting-order units; vector reveal still follows source commands.
public struct ColoredPencilHatch: Codable, Equatable, Hashable, Sendable {
  public let start: ColoredPencilPoint
  public let end: ColoredPencilPoint
  /// Sampled variable-width ribbon. Width remains stable through the body and
  /// uses smoothstep over the final 28 percent, matching open source strokes.
  public let points: [ColoredPencilPoint]
  public let opacity: Double

  fileprivate init(
    start: ColoredPencilPoint,
    end: ColoredPencilPoint,
    points: [ColoredPencilPoint],
    opacity: Double
  ) {
    self.start = start
    self.end = end
    self.points = points
    self.opacity = opacity
  }

  private enum CodingKeys: String, CodingKey { case start, end, points, opacity }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let start = try values.decode(ColoredPencilPoint.self, forKey: .start)
    let end = try values.decode(ColoredPencilPoint.self, forKey: .end)
    let points = try values.decode([ColoredPencilPoint].self, forKey: .points)
    let opacity = try values.decode(Double.self, forKey: .opacity)
    guard points.count >= 2, opacity.isFinite, (0...1).contains(opacity)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .points, in: values, debugDescription: "invalid colored-pencil hatch geometry")
    }
    self.init(start: start, end: end, points: points, opacity: opacity)
  }
}

/// Renderer-neutral material geometry for filled outlines such as ordinary
/// text glyphs. The caller supplies the outline mask; this plan supplies only
/// deterministic pencil deposition, so Core Text color glyphs and images can
/// continue through their native paint paths unchanged.
public struct ColoredPencilFillPlan: Codable, Equatable, Hashable, Sendable {
  public let destination: ColoredPencilRect
  public let configuration: ColoredPencilConfiguration
  public let hatches: [ColoredPencilHatch]

  public init(
    destination: ColoredPencilRect,
    configuration: ColoredPencilConfiguration = .default,
    maximumHatches: Int = ColoredPencilPathPlan.maximumHatches
  ) {
    self.destination = destination
    self.configuration = configuration
    self.hatches = ColoredPencilPathPlan.makeHatches(
      destination: destination,
      configuration: configuration,
      hasClosedStroke: true,
      maximumHatches: max(0, min(ColoredPencilPathPlan.maximumHatches, maximumHatches))
    )
  }

  private enum CodingKeys: String, CodingKey { case destination, configuration, hatches }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let destination = try values.decode(ColoredPencilRect.self, forKey: .destination)
    let configuration = try values.decode(ColoredPencilConfiguration.self, forKey: .configuration)
    let hatches = try values.decode([ColoredPencilHatch].self, forKey: .hatches)
    guard hatches.count <= ColoredPencilPathPlan.maximumHatches else {
      throw DecodingError.dataCorruptedError(
        forKey: .hatches, in: values, debugDescription: "colored-pencil hatch budget exceeded")
    }
    let expected = Self(
      destination: destination, configuration: configuration, maximumHatches: hatches.count)
    guard expected.hatches == hatches else {
      throw DecodingError.dataCorruptedError(
        forKey: .hatches, in: values,
        debugDescription: "colored-pencil fill hatches do not match canonical geometry")
    }
    self = expected
  }

  /// Returns the deterministic allocation needed for a destination without
  /// constructing any hatch points. Render-content plan books use this to
  /// divide a document-wide budget in source order before viewport visits.
  public static func requestedHatchCount(
    destination: ColoredPencilRect,
    configuration: ColoredPencilConfiguration = .default,
    maximumHatches: Int = ColoredPencilPathPlan.maximumHatches
  ) -> Int {
    ColoredPencilPathPlan.hatchCount(
      destination: destination,
      configuration: configuration,
      maximumHatches: max(0, min(ColoredPencilPathPlan.maximumHatches, maximumHatches))
    )
  }

  /// Distributes a document-wide hatch budget deterministically. When there
  /// are more text fragments than hatches, single-hatch fragments are sampled
  /// across the whole document instead of starving either end of it.
  public static func boundedHatchAllocations(
    requestedCounts: [Int],
    maximumHatches: Int
  ) -> [Int] {
    let requests = requestedCounts.map { max(0, $0) }
    let budget = max(0, maximumHatches)
    guard !requests.isEmpty, budget > 0 else {
      return Array(repeating: 0, count: requests.count)
    }
    if requests.count > budget {
      var allocations = Array(repeating: 0, count: requests.count)
      for slot in 0..<budget {
        let position = (Double(slot) + 0.5) * Double(requests.count) / Double(budget)
        let index = min(requests.count - 1, Int(position))
        if requests[index] > 0 { allocations[index] = 1 }
      }
      return allocations
    }
    var allocations = Array(repeating: 0, count: requests.count)
    var remaining = budget
    for index in requests.indices {
      let remainingItems = requests.count - index
      let fairShare = max(1, remaining / remainingItems)
      let count = min(requests[index], fairShare)
      allocations[index] = count
      remaining -= count
    }
    return allocations
  }
}

/// One source subpath after deterministic sampling and width planning.
public struct ColoredPencilStrokePlan: Codable, Equatable, Hashable, Sendable {
  public let subpathIndex: Int
  public let isClosed: Bool
  public let points: [ColoredPencilPoint]
  public let cumulativeLengths: [Double]
  public let length: Double
  public let bodyWidth: Double
  public let tipWidth: Double
  public let commandSpans: [ColoredPencilCommandSpan]
  public let fibers: [ColoredPencilFiber]

  public var isOpen: Bool { !isClosed }
  public var hasTaper: Bool { isOpen && tipWidth < bodyWidth }

  fileprivate init(
    subpathIndex: Int,
    isClosed: Bool,
    points: [ColoredPencilPoint],
    cumulativeLengths: [Double],
    length: Double,
    bodyWidth: Double,
    tipWidth: Double,
    commandSpans: [ColoredPencilCommandSpan],
    fibers: [ColoredPencilFiber]
  ) {
    self.subpathIndex = subpathIndex
    self.isClosed = isClosed
    self.points = points
    self.cumulativeLengths = cumulativeLengths
    self.length = length
    self.bodyWidth = bodyWidth
    self.tipWidth = tipWidth
    self.commandSpans = commandSpans
    self.fibers = fibers
  }

  private enum CodingKeys: String, CodingKey {
    case subpathIndex, isClosed, points, cumulativeLengths, length, bodyWidth, tipWidth
    case commandSpans, fibers
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let subpathIndex = try values.decode(Int.self, forKey: .subpathIndex)
    let isClosed = try values.decode(Bool.self, forKey: .isClosed)
    let points = try values.decode([ColoredPencilPoint].self, forKey: .points)
    let cumulativeLengths = try values.decode([Double].self, forKey: .cumulativeLengths)
    let length = try values.decode(Double.self, forKey: .length)
    let bodyWidth = try values.decode(Double.self, forKey: .bodyWidth)
    let tipWidth = try values.decode(Double.self, forKey: .tipWidth)
    let commandSpans = try values.decode([ColoredPencilCommandSpan].self, forKey: .commandSpans)
    let fibers = try values.decode([ColoredPencilFiber].self, forKey: .fibers)

    let lengthsAreOrdered = zip(cumulativeLengths, cumulativeLengths.dropFirst())
      .allSatisfy { $0.isFinite && $1.isFinite && $0 <= $1 }
    let spansAreOrdered = zip(commandSpans, commandSpans.dropFirst())
      .allSatisfy { $0.commandIndex < $1.commandIndex && $0.endDistance <= $1.startDistance }
    guard subpathIndex >= 0, points.count >= 2,
      points.count <= ColoredPencilPathPlan.maximumSamples,
      cumulativeLengths.count == points.count, cumulativeLengths.first == 0, lengthsAreOrdered,
      length.isFinite, length > 0, cumulativeLengths.last == length,
      bodyWidth.isFinite, bodyWidth > 0, tipWidth.isFinite, tipWidth > 0,
      fibers.count <= 24, spansAreOrdered,
      commandSpans.allSatisfy({ $0.startDistance >= 0 && $0.endDistance <= length })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .cumulativeLengths, in: values,
        debugDescription: "invalid colored-pencil stroke-plan derived state")
    }
    self.init(
      subpathIndex: subpathIndex, isClosed: isClosed, points: points,
      cumulativeLengths: cumulativeLengths, length: length, bodyWidth: bodyWidth,
      tipWidth: tipWidth,
      commandSpans: commandSpans, fibers: fibers)
  }

  /// Returns a stable centerline prefix for a reveal frame.
  public func points(upToDistance distance: Double) -> [ColoredPencilPoint] {
    guard !points.isEmpty else { return [] }
    guard length > 0, distance.isFinite else { return [points[0]] }
    let target = min(length, max(0, distance))
    if target >= length { return points }
    if target <= 0 { return [points[0]] }

    var result = [points[0]]
    for index in 0..<(points.count - 1) {
      let startDistance = cumulativeLengths[index]
      let endDistance = cumulativeLengths[index + 1]
      guard endDistance >= target else {
        result.append(points[index + 1])
        continue
      }
      let segmentLength = endDistance - startDistance
      if segmentLength > 0 {
        let fraction = min(1, max(0, (target - startDistance) / segmentLength))
        let first = points[index]
        let second = points[index + 1]
        let x = first.x + (second.x - first.x) * fraction
        let y = first.y + (second.y - first.y) * fraction
        let width = first.width + (second.width - first.width) * fraction
        result.append(ColoredPencilPoint(validatedX: x, y: y, width: width))
      }
      break
    }
    return result
  }

  /// Returns the visible prefix through one reveal command.
  public func points(
    throughCommand commandIndex: Int,
    progress: Double = 1
  ) -> [ColoredPencilPoint] {
    guard let span = commandSpans.first(where: { $0.commandIndex == commandIndex }) else {
      return []
    }
    let value = min(1, max(0, progress.isFinite ? progress : 0))
    return points(upToDistance: span.startDistance + span.length * value)
  }

}

/// Shared geometry plan consumed by both SwiftUI and Canvas adapters.
public struct ColoredPencilPathPlan: Codable, Equatable, Hashable, Sendable {
  public static let maximumSamples = 16_384
  public static let maximumFibers = 2_048
  public static let maximumHatches = 1_024

  public let assetID: InlineAssetID
  public let assetVersion: Int
  public let destination: ColoredPencilRect
  public let configuration: ColoredPencilConfiguration
  public let strokes: [ColoredPencilStrokePlan]
  public let totalLength: Double
  public let sampleCount: Int
  public let fiberCount: Int
  public let hatches: [ColoredPencilHatch]

  /// Returns the portion of a stroke that is visible at a reveal frame.
  ///
  /// The reveal schedule is expressed in source command order while this
  /// plan is expressed in sampled distance. Mapping the active command to its
  /// span here keeps both platform adapters temporally stable and avoids
  /// duplicating a subtly different reveal calculation in SwiftUI and Canvas.
  public func visiblePoints(
    for stroke: ColoredPencilStrokePlan,
    activation: InlineRenderRevealVectorActivation?,
    time: Double
  ) -> [ColoredPencilPoint] {
    let distance = visibleDistance(for: stroke, activation: activation, time: time)
    return stroke.points(upToDistance: distance)
  }

  /// Returns the visible distance for one sampled subpath.
  public func visibleDistance(
    for stroke: ColoredPencilStrokePlan,
    activation: InlineRenderRevealVectorActivation?,
    time: Double
  ) -> Double {
    guard let activation else { return stroke.length }
    guard let firstSpan = stroke.commandSpans.first,
      let lastSpan = stroke.commandSpans.last
    else { return 0 }
    let completed = activation.completedCommandCount(at: time)
    guard completed < activation.units.count else { return stroke.length }
    let active = activation.units[completed]
    if active.commandIndex < firstSpan.commandIndex { return 0 }
    if active.commandIndex > lastSpan.commandIndex { return stroke.length }
    guard
      let span = stroke.commandSpans.first(where: {
        $0.commandIndex == active.commandIndex
      })
    else {
      // A validated schedule cannot land between spans in the same subpath,
      // but treating such a frame as fully visible keeps this helper safe for
      // callers constructing a valid schedule themselves.
      return stroke.length
    }
    let progress = activation.progress(at: time, commandIndex: active.commandIndex)
    return span.startDistance + span.length * progress
  }

  /// Number of interior material strokes visible at one reveal frame.
  /// Hatches are not handwriting-order data; they follow the aggregate vector
  /// timeline only so an incomplete glyph never receives its finished fill.
  public func visibleHatchCount(
    activation: InlineRenderRevealVectorActivation?,
    time: Double
  ) -> Int {
    guard !hatches.isEmpty else { return 0 }
    guard let activation else { return hatches.count }
    guard activation.duration > 0, time.isFinite else { return 0 }
    let progress = min(1, max(0, time / activation.duration))
    return min(hatches.count, Int(floor(progress * Double(hatches.count))))
  }

  private enum CodingKeys: String, CodingKey {
    case assetID, assetVersion, destination, configuration, strokes, totalLength
    case sampleCount, fiberCount, hatches
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let assetID = try values.decode(InlineAssetID.self, forKey: .assetID)
    let assetVersion = try values.decode(Int.self, forKey: .assetVersion)
    let destination = try values.decode(ColoredPencilRect.self, forKey: .destination)
    let configuration = try values.decode(ColoredPencilConfiguration.self, forKey: .configuration)
    let strokes = try values.decode([ColoredPencilStrokePlan].self, forKey: .strokes)
    let totalLength = try values.decode(Double.self, forKey: .totalLength)
    let sampleCount = try values.decode(Int.self, forKey: .sampleCount)
    let fiberCount = try values.decode(Int.self, forKey: .fiberCount)
    let hatches = try values.decode([ColoredPencilHatch].self, forKey: .hatches)

    let expectedSampleCount = strokes.reduce(0) { $0 + $1.points.count }
    let expectedFiberCount = strokes.reduce(0) { $0 + $1.fibers.count }
    let expectedTotalLength = strokes.reduce(0.0) { $0 + $1.length }
    let subpathsAreOrdered = zip(strokes, strokes.dropFirst())
      .allSatisfy { $0.subpathIndex < $1.subpathIndex }
    let expectedHatches = Self.makeHatches(
      destination: destination, configuration: configuration,
      hasClosedStroke: strokes.contains(where: { $0.isClosed }), maximumHatches: hatches.count)
    guard assetVersion >= 0, totalLength.isFinite, totalLength >= 0,
      sampleCount == expectedSampleCount, sampleCount <= Self.maximumSamples,
      fiberCount == expectedFiberCount, fiberCount <= Self.maximumFibers,
      totalLength == expectedTotalLength, subpathsAreOrdered,
      hatches.count <= Self.maximumHatches, hatches == expectedHatches
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .sampleCount, in: values,
        debugDescription: "colored-pencil path-plan aggregates or derived hatches are inconsistent")
    }
    self.assetID = assetID
    self.assetVersion = assetVersion
    self.destination = destination
    self.configuration = configuration
    self.strokes = strokes
    self.totalLength = totalLength
    self.sampleCount = sampleCount
    self.fiberCount = fiberCount
    self.hatches = hatches
  }

  public init(
    asset: InlineSVGAsset,
    destination: ColoredPencilRect,
    configuration: ColoredPencilConfiguration = .default
  ) {
    let commands = asset.trajectoryPath.commands
    // Every source command may contribute at most `samplingBudget` points.
    // Basing the budget on all commands (including move/close) guarantees the
    // finished plan cannot exceed `maximumSamples`, while ordinary short
    // paths retain enough interior samples for visible, stable pencil jitter.
    let samplingBudget = max(1, Self.maximumSamples / max(1, commands.count))
    let bounds = asset.trajectoryPath.bounds
    func map(_ point: InlinePathPoint) -> ColoredPencilPoint {
      let unitX = Self.normalizedPosition(point.x, minimum: bounds.minX, maximum: bounds.maxX)
      let unitY = Self.normalizedPosition(point.y, minimum: bounds.minY, maximum: bounds.maxY)
      let x = Self.addingScaled(destination.x, destination.width, factor: unitX)
      let y = Self.addingScaled(destination.y, destination.height, factor: unitY)
      return ColoredPencilPoint(validatedX: x, y: y)
    }

    struct RawSample {
      let point: ColoredPencilPoint
      let commandIndex: Int
    }

    var rawSubpaths: [(samples: [RawSample], isClosed: Bool)] = []
    var rawSamples: [RawSample] = []
    var isClosed = false
    var subpathStartPoint: InlinePathPoint?
    var currentPoint: InlinePathPoint?
    var subpathIndex = 0

    func appendRaw(_ point: InlinePathPoint, commandIndex: Int, into values: inout [RawSample]) {
      let mapped = map(point)
      if let last = values.last,
        abs(last.point.x - mapped.x) < 1.0e-9,
        abs(last.point.y - mapped.y) < 1.0e-9
      {
        return
      }
      values.append(RawSample(point: mapped, commandIndex: commandIndex))
    }

    func finishSubpath() {
      guard rawSamples.count > 1 else {
        rawSamples.removeAll(keepingCapacity: true)
        isClosed = false
        return
      }
      rawSubpaths.append((samples: rawSamples, isClosed: isClosed))
      rawSamples.removeAll(keepingCapacity: true)
      isClosed = false
      subpathIndex += 1
    }

    for (commandIndex, command) in commands.enumerated() {
      switch command {
      case .move(let point):
        finishSubpath()
        subpathStartPoint = point
        currentPoint = point
        appendRaw(point, commandIndex: commandIndex, into: &rawSamples)
      case .line(let end):
        guard let start = currentPoint else { continue }
        let count = max(1, min(8, samplingBudget))
        for step in 1...count {
          let t = Double(step) / Double(count)
          let point = InlinePathPoint(
            validatedX: Self.interpolate(start.x, end.x, fraction: t),
            y: Self.interpolate(start.y, end.y, fraction: t))
          appendRaw(point, commandIndex: commandIndex, into: &rawSamples)
        }
        currentPoint = end
      case .quadratic(let control, let end):
        guard let start = currentPoint else { continue }
        let count = max(1, min(8, samplingBudget))
        for step in 1...count {
          let t = Double(step) / Double(count)
          let first = Self.interpolate(start, control, fraction: t)
          let interpolated = Self.interpolate(first, end, fraction: t)
          let point = InlinePathPoint(validatedX: interpolated.x, y: interpolated.y)
          appendRaw(point, commandIndex: commandIndex, into: &rawSamples)
        }
        currentPoint = end
      case .cubic(let control1, let control2, let end):
        guard let start = currentPoint else { continue }
        let count = max(1, min(12, samplingBudget))
        for step in 1...count {
          let t = Double(step) / Double(count)
          let first = Self.interpolate(start, control1, fraction: t)
          let second = Self.interpolate(control1, control2, fraction: t)
          let third = Self.interpolate(control2, end, fraction: t)
          let fourth = Self.interpolate(first, second, fraction: t)
          let fifth = Self.interpolate(second, third, fraction: t)
          let interpolated = Self.interpolate(fourth, fifth, fraction: t)
          let point = InlinePathPoint(validatedX: interpolated.x, y: interpolated.y)
          appendRaw(point, commandIndex: commandIndex, into: &rawSamples)
        }
        currentPoint = end
      case .close:
        guard currentPoint != nil, let subpathStartPoint else { continue }
        appendRaw(subpathStartPoint, commandIndex: commandIndex, into: &rawSamples)
        currentPoint = subpathStartPoint
        // A close command defines a closed subpath even when the source also
        // contains an explicit line back to its origin (that close segment is
        // then zero length). Closed contours keep a constant one-point body
        // width; only genuinely open subpaths receive tapering.
        isClosed = true
      }
    }
    finishSubpath()

    let rawSampleCount = rawSubpaths.reduce(0) { partialResult, subpath in
      partialResult + subpath.samples.count
    }
    assert(rawSampleCount <= Self.maximumSamples)

    var generator = ColoredPencilRandom(seed: configuration.seed)
    var plans: [ColoredPencilStrokePlan] = []
    plans.reserveCapacity(rawSubpaths.count)
    var totalLength = 0.0
    var sampleCount = 0
    var fiberCount = 0
    for (index, raw) in rawSubpaths.enumerated() {
      let basePoints = raw.samples.map(\.point)
      guard basePoints.count > 1 else { continue }
      var cumulative = [Double](repeating: 0, count: basePoints.count)
      for pointIndex in 1..<basePoints.count {
        cumulative[pointIndex] = Self.addingScaled(
          cumulative[pointIndex - 1],
          hypot(
            basePoints[pointIndex].x - basePoints[pointIndex - 1].x,
            basePoints[pointIndex].y - basePoints[pointIndex - 1].y
          ),
          factor: 1
        )
      }
      let length = cumulative.last ?? 0
      guard length > 0, length.isFinite else { continue }

      var points: [ColoredPencilPoint] = []
      points.reserveCapacity(basePoints.count)
      for pointIndex in basePoints.indices {
        let base = basePoints[pointIndex]
        let preserveEndpoint =
          !raw.isClosed
          && (pointIndex == basePoints.startIndex
            || pointIndex == basePoints.index(before: basePoints.endIndex))
        let jitter =
          preserveEndpoint
          ? (x: 0.0, y: 0.0)
          : Self.jitterOffset(
            at: pointIndex,
            points: basePoints,
            generator: &generator,
            amount: configuration.jitterAmount
          )
        let width: Double
        if raw.isClosed {
          width = 1
        } else {
          let fraction = cumulative[pointIndex] / length
          let ramp = Self.smoothstep(0.72, 1, fraction)
          width = max(0.08, 1 - configuration.taperAmount * 0.92 * ramp)
        }
        points.append(
          ColoredPencilPoint(
            validatedX: Self.addingScaled(base.x, jitter.x, factor: 1),
            y: Self.addingScaled(base.y, jitter.y, factor: 1),
            width: width
          )
        )
      }

      var commandSpans: [ColoredPencilCommandSpan] = []
      var spanStartIndex = 0
      while spanStartIndex < raw.samples.count - 1 {
        let commandIndex = raw.samples[spanStartIndex + 1].commandIndex
        var spanEndIndex = spanStartIndex + 1
        while spanEndIndex + 1 < raw.samples.count,
          raw.samples[spanEndIndex + 1].commandIndex == commandIndex
        {
          spanEndIndex += 1
        }
        let startDistance = cumulative[spanStartIndex]
        let endDistance = cumulative[spanEndIndex]
        if endDistance > startDistance {
          commandSpans.append(
            ColoredPencilCommandSpan(
              commandIndex: commandIndex,
              startDistance: startDistance,
              endDistance: endDistance
            )
          )
        }
        spanStartIndex = spanEndIndex
      }

      let remainingFiberBudget = max(0, Self.maximumFibers - fiberCount)
      let perStrokeFiberLimit = min(24, remainingFiberBudget)
      let scaledFiberRequest = length * configuration.fiberDensity / 10
      let count: Int
      if configuration.fiberAmount <= 0 || perStrokeFiberLimit == 0 {
        count = 0
      } else if !scaledFiberRequest.isFinite
        || scaledFiberRequest >= Double(perStrokeFiberLimit)
      {
        count = perStrokeFiberLimit
      } else {
        count = min(perStrokeFiberLimit, max(1, Int(ceil(scaledFiberRequest))))
      }
      var fibers: [ColoredPencilFiber] = []
      fibers.reserveCapacity(count)
      for _ in 0..<count {
        let offset = (generator.nextUnit() * 2 - 1) * 0.38 * configuration.fiberAmount
        let opacity =
          (0.06 + generator.nextUnit() * 0.12)
          * (0.45 + 0.55 * configuration.fiberAmount)
          * (0.76 + 0.24 * configuration.paperTooth)
        let widthScale = 0.10 + generator.nextUnit() * 0.20
        fibers.append(
          ColoredPencilFiber(
            offset: offset,
            opacity: opacity,
            widthScale: widthScale,
            phase: generator.nextUnit()
          )
        )
      }

      plans.append(
        ColoredPencilStrokePlan(
          subpathIndex: index,
          isClosed: raw.isClosed,
          points: points,
          cumulativeLengths: cumulative,
          length: length,
          bodyWidth: 1,
          tipWidth: raw.isClosed ? 1 : max(0.08, 1 - configuration.taperAmount * 0.92),
          commandSpans: commandSpans,
          fibers: fibers
        )
      )
      totalLength = Self.addingScaled(totalLength, length, factor: 1)
      sampleCount += points.count
      fiberCount += fibers.count
    }

    self.assetID = asset.id
    self.assetVersion = asset.version
    self.destination = destination
    self.configuration = configuration
    self.strokes = plans
    self.totalLength = totalLength
    self.sampleCount = sampleCount
    self.fiberCount = fiberCount
    self.hatches = Self.makeHatches(
      destination: destination,
      configuration: configuration,
      hasClosedStroke: plans.contains(where: { $0.isClosed })
    )
  }

  /// Builds a plan from one arbitrary polyline, useful for adapter tests and
  /// custom drawing clients that do not have an SVG asset wrapper.
  public init(
    points: [ColoredPencilPoint],
    isClosed: Bool = false,
    configuration: ColoredPencilConfiguration = .default
  ) throws {
    guard points.count > 1 else { throw ColoredPencilError.invalidGeometry }
    let commands: [InlinePathCommand] =
      [
        .move(try InlinePathPoint(x: points[0].x, y: points[0].y))
      ]
      + (try points.dropFirst().map {
        .line(try InlinePathPoint(x: $0.x, y: $0.y))
      }) + (isClosed ? [.close] : [])
    let path = try InlinePathData(commands: commands)
    let assetID = try InlineAssetID(rawValue: "colored-pencil-polyline")
    let metrics = try InlineMetrics(advance: 1, ascent: 1, descent: 0, baselineOffset: 0)
    let asset = try InlineSVGAsset(
      id: assetID,
      metrics: metrics,
      coordinateBounds: path.bounds,
      coveragePath: path,
      coveragePaint: .stroke(try InlineSVGStrokeStyle(width: 1)),
      trajectoryPath: path,
      trajectoryStyle: try InlineSVGStrokeStyle(width: 1)
    )
    let minimumX = points.map(\.x).min()!
    let maximumX = points.map(\.x).max()!
    let minimumY = points.map(\.y).min()!
    let maximumY = points.map(\.y).max()!
    let bounds = try ColoredPencilRect(
      x: minimumX,
      y: minimumY,
      width: Self.addingScaled(maximumX, -minimumX, factor: 1),
      height: Self.addingScaled(maximumY, -minimumY, factor: 1)
    )
    self = ColoredPencilPathPlan(
      asset: asset, destination: bounds, configuration: configuration)
  }

  private static func normalizedPosition(
    _ value: Double,
    minimum: Double,
    maximum: Double
  ) -> Double {
    guard minimum != maximum else { return 0.5 }
    let scale = max(1, abs(minimum), abs(maximum))
    let lower = minimum / scale
    let upper = maximum / scale
    let position = (value / scale - lower) / (upper - lower)
    return min(1, max(0, position.isFinite ? position : 0.5))
  }

  fileprivate static func makeHatches(
    destination: ColoredPencilRect,
    configuration: ColoredPencilConfiguration,
    hasClosedStroke: Bool,
    maximumHatches: Int = Self.maximumHatches
  ) -> [ColoredPencilHatch] {
    guard hasClosedStroke else { return [] }
    let count = hatchCount(
      destination: destination,
      configuration: configuration,
      maximumHatches: maximumHatches
    )
    guard count > 0 else { return [] }
    var generator = ColoredPencilRandom(seed: configuration.seed ^ 0x4841_5443_485F_5631)
    var result: [ColoredPencilHatch] = []
    result.reserveCapacity(count)
    let diagonal = addingScaled(destination.width, destination.height, factor: 1)
    // A pencil mark is a soft ribbon, not a one-pixel hairline. At the
    // sample's 21pt body size a sub-point hatch disappears after antialiasing
    // and the filled glyph looks indistinguishable from ordinary text. Keep
    // the hatch narrow enough for legibility, but wide/opaque enough that the
    // paper tooth is visible without a label.
    let width = max(0.92, 1.05 + 1.10 * configuration.paperTooth)
    let baseOpacity =
      (0.28 + 0.30 * configuration.fiberAmount)
      * (0.84 + 0.16 * configuration.paperTooth)
    for index in 0..<count {
      let fraction = count == 1 ? 0.5 : Double(index) / Double(count - 1)
      let offset = addingScaled(-destination.height, diagonal, factor: fraction)
      let jitterX = (generator.nextUnit() * 2 - 1) * 0.45 * configuration.jitterAmount
      let jitterY = (generator.nextUnit() * 2 - 1) * 0.45 * configuration.jitterAmount
      // Alternate the direction of adjacent ribbons. A single diagonal is
      // useful for a star/path proof, but cross-direction deposition is what
      // makes a filled ordinary glyph read as wax/pigment rather than a solid
      // vector fill.
      let descending = index.isMultiple(of: 2)
      let rightEdge = addingScaled(destination.x, destination.width, factor: 1)
      let startX =
        descending
        ? addingScaled(destination.x, offset, factor: 1)
        : addingScaled(rightEdge, -offset, factor: 1)
      let jitteredStartX = addingScaled(startX, jitterX, factor: 1)
      let endX = addingScaled(
        jitteredStartX,
        destination.height,
        factor: descending ? 1 : -1
      )
      let startY = addingScaled(destination.y, jitterY, factor: 1)
      let start = ColoredPencilPoint(validatedX: jitteredStartX, y: startY, width: width)
      let end = ColoredPencilPoint(
        validatedX: endX,
        y: addingScaled(startY, destination.height, factor: 1),
        width: max(0.08, width * (1 - configuration.taperAmount * 0.92)))
      let sampleFractions = [0.0, 1.0 / 6.0, 2.0 / 6.0, 0.5, 0.72, 5.0 / 6.0, 1.0]
      let points = sampleFractions.map { fraction in
        let ramp = smoothstep(0.72, 1, fraction)
        return ColoredPencilPoint(
          validatedX: interpolate(start.x, end.x, fraction: fraction),
          y: interpolate(start.y, end.y, fraction: fraction),
          width: max(0.08, width * (1 - configuration.taperAmount * 0.92 * ramp))
        )
      }
      result.append(
        ColoredPencilHatch(
          start: start,
          end: end,
          points: points,
          opacity: baseOpacity * (0.82 + 0.18 * generator.nextUnit())
        )
      )
    }
    return result
  }

  fileprivate static func hatchCount(
    destination: ColoredPencilRect,
    configuration: ColoredPencilConfiguration,
    maximumHatches: Int
  ) -> Int {
    guard maximumHatches > 0, destination.width > 0, destination.height > 0 else { return 0 }
    let spacing = max(1.35, 2.6 - 1.1 * configuration.paperTooth)
    let diagonal = addingScaled(destination.width, destination.height, factor: 1)
    let estimate = diagonal / spacing
    if !estimate.isFinite || estimate >= Double(maximumHatches) {
      return maximumHatches
    }
    return min(maximumHatches, max(1, Int(ceil(estimate)) + 1))
  }

  private static func addingScaled(
    _ base: Double,
    _ value: Double,
    factor: Double
  ) -> Double {
    let scale = max(1, abs(base), abs(value))
    let normalized = base / scale + value / scale * factor
    let limit = Double.greatestFiniteMagnitude / scale
    if normalized >= limit { return Double.greatestFiniteMagnitude }
    if normalized <= -limit { return -Double.greatestFiniteMagnitude }
    return normalized * scale
  }

  private static func interpolate(
    _ first: Double,
    _ second: Double,
    fraction: Double
  ) -> Double {
    let scale = max(1, abs(first), abs(second))
    let normalized = first / scale * (1 - fraction) + second / scale * fraction
    return min(1, max(-1, normalized)) * scale
  }

  private static func interpolate(
    _ first: InlinePathPoint,
    _ second: InlinePathPoint,
    fraction: Double
  ) -> (x: Double, y: Double) {
    (
      x: interpolate(first.x, second.x, fraction: fraction),
      y: interpolate(first.y, second.y, fraction: fraction)
    )
  }

  private static func interpolate(
    _ first: (x: Double, y: Double),
    _ second: InlinePathPoint,
    fraction: Double
  ) -> (x: Double, y: Double) {
    (
      x: interpolate(first.x, second.x, fraction: fraction),
      y: interpolate(first.y, second.y, fraction: fraction)
    )
  }

  private static func interpolate(
    _ first: (x: Double, y: Double),
    _ second: (x: Double, y: Double),
    fraction: Double
  ) -> (x: Double, y: Double) {
    (
      x: interpolate(first.x, second.x, fraction: fraction),
      y: interpolate(first.y, second.y, fraction: fraction)
    )
  }

  private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
    let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
  }

  private static func jitterOffset(
    at index: Int,
    points: [ColoredPencilPoint],
    generator: inout ColoredPencilRandom,
    amount: Double
  ) -> (x: Double, y: Double) {
    guard amount > 0, index > 0, index + 1 < points.count else { return (0, 0) }
    let previous = points[index - 1]
    let next = points[index + 1]
    let dx = next.x - previous.x
    let dy = next.y - previous.y
    let tangentLength = hypot(dx, dy)
    guard tangentLength > 0 else { return (0, 0) }
    let normalX = -dy / tangentLength
    let normalY = dx / tangentLength
    let previousNoise = generator.nextUnit() * 2 - 1
    let currentNoise = generator.nextUnit() * 2 - 1
    let nextNoise = generator.nextUnit() * 2 - 1
    let filtered = (previousNoise + currentNoise * 2 + nextNoise) / 4
    let amplitude = 0.22 * amount
    return (normalX * filtered * amplitude, normalY * filtered * amplitude)
  }
}

private struct ColoredPencilRandom {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func nextUnit() -> Double {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    value ^= value >> 31
    return Double(value >> 11) / Double(UInt64.max >> 11)
  }
}
