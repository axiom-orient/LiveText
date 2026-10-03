import Foundation

private enum SVGPaint: Equatable, Sendable {
  case none
  case solid(LiveTextSVGColor)
}

enum SVGParseMode {
  case liveText
  case artwork
}

private struct SVGStyle: Sendable {
  var fill: SVGPaint = .solid(.black)
  var stroke: SVGPaint = .none
  var fillRule: LiveTextSVGFillRule = .nonZero
  var strokeWidth = 1.0
  var lineCap: LiveTextSVGLineCap = .butt
  var lineJoin: LiveTextSVGLineJoin = .miter
  var miterLimit = 4.0
  var fillOpacity = 1.0
  var strokeOpacity = 1.0
  var opacity = 1.0
}

private enum SVGAspectAlignment: String {
  case min
  case mid
  case max
}

private enum SVGAspectMode {
  case meet
  case slice
}

private struct SVGPreserveAspectRatio {
  let x: SVGAspectAlignment?
  let y: SVGAspectAlignment?
  let mode: SVGAspectMode?

  static let `default` = SVGPreserveAspectRatio(
    x: .mid, y: .mid, mode: .meet
  )

  static func parse(_ raw: String?) throws -> SVGPreserveAspectRatio {
    guard let raw else { return .default }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return .default }
    let tokens = value.split { character in
      character == " " || character == "\t" || character == "\n" || character == "\r"
    }
    guard !tokens.isEmpty, tokens.count <= 2 else {
      throw LiveTextSVGImportError.unsupportedSemantic("preserveAspectRatio \(raw)")
    }
    let normalized = tokens.map { $0.lowercased() }
    if normalized[0] == "none" {
      guard normalized.count == 1 else {
        throw LiveTextSVGImportError.unsupportedSemantic("preserveAspectRatio \(raw)")
      }
      return SVGPreserveAspectRatio(x: nil, y: nil, mode: nil)
    }
    guard normalized[0].count == 8,
      normalized[0].hasPrefix("x"),
      normalized[0].contains("y")
    else {
      throw LiveTextSVGImportError.unsupportedSemantic("preserveAspectRatio \(raw)")
    }
    let alignment = normalized[0]
    let x: SVGAspectAlignment
    let y: SVGAspectAlignment
    if alignment.hasPrefix("xmin") {
      x = .min
    } else if alignment.hasPrefix("xmid") {
      x = .mid
    } else if alignment.hasPrefix("xmax") {
      x = .max
    } else {
      throw LiveTextSVGImportError.unsupportedSemantic("preserveAspectRatio \(raw)")
    }
    if alignment.hasSuffix("ymin") {
      y = .min
    } else if alignment.hasSuffix("ymid") {
      y = .mid
    } else if alignment.hasSuffix("ymax") {
      y = .max
    } else {
      throw LiveTextSVGImportError.unsupportedSemantic("preserveAspectRatio \(raw)")
    }
    let mode: SVGAspectMode
    if normalized.count == 1 || normalized[1] == "meet" {
      mode = .meet
    } else if normalized[1] == "slice" {
      mode = .slice
    } else {
      throw LiveTextSVGImportError.unsupportedSemantic("preserveAspectRatio \(raw)")
    }
    return SVGPreserveAspectRatio(x: x, y: y, mode: mode)
  }
}

private enum SVGPathRole: Hashable {
  case coverageStroke
  case coverageFill
  case trajectory
}

private struct PendingSVGPath {
  let commands: [LiveTextSVGCommand]
  let style: LiveTextSVGStrokeStyle
  let role: SVGPathRole
  let fillRule: LiveTextSVGFillRule
  let artworkPaint: LiveTextSVGArtworkPaint?
}

private struct SVGFrame {
  let name: String
  let style: SVGStyle
  let transform: SVGTransform
}

final class SVGDocumentParser {
  private let bytes: [UInt8]
  private let options: LiveTextSVGImportOptions
  private let mode: SVGParseMode
  private var index = 0
  private var frames: [SVGFrame] = []
  private var rootSeen = false
  private var rootClosed = false
  private var elementCount = 0
  private var sourcePathCommandCount = 0
  private var normalizedSegmentCount = 0
  private var pendingPaths: [PendingSVGPath] = []
  private var sceneSize: LiveTextSVGSize?
  private var viewBoxTransform = SVGTransform.identity

  private static let geometryStyleAttributes: Set<String> = [
    "id", "transform", "fill", "stroke", "stroke-width", "stroke-linecap",
    "stroke-linejoin", "stroke-miterlimit", "fill-rule", "fill-opacity",
    "stroke-opacity", "opacity",
  ]

  init(data: Data, options: LiveTextSVGImportOptions, mode: SVGParseMode = .liveText) throws {
    self.options = options
    self.mode = mode
    guard data.count <= options.limits.maximumInputBytes else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "input bytes", actual: data.count, limit: options.limits.maximumInputBytes
      )
    }
    guard data.count > 0 else { throw LiveTextSVGImportError.invalidDocument("input is empty") }
    self.bytes = Array(data)
  }

  func parse() throws -> LiveTextSVGImportedDocument {
    try parseElements()
    guard let sceneSize else { throw LiveTextSVGImportError.missingSize }
    guard !pendingPaths.isEmpty else {
      throw LiveTextSVGImportError.invalidPathData("SVG contains no visible path")
    }

    let visible = pendingPaths.filter {
      $0.role == .coverageStroke || $0.role == .coverageFill
    }
    let trajectories = pendingPaths.filter { $0.role == .trajectory }
    guard !visible.isEmpty else {
      throw LiveTextSVGImportError.unsupportedSemantic("trajectory paths require visible coverage")
    }

    let coverageCommands = visible.flatMap(\.commands)
    guard coverageCommands.count <= LiveTextSVGImportedDocument.maximumOutputCommands else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "coverage output commands",
        actual: coverageCommands.count,
        limit: LiveTextSVGImportedDocument.maximumOutputCommands
      )
    }
    let coveragePaint: LiveTextSVGCoveragePaint
    let kinds = Set(visible.map(\.role))
    if kinds == [.coverageStroke], let first = visible.first,
      visible.allSatisfy({ $0.style == first.style })
    {
      coveragePaint = .stroke(first.style)
    } else if kinds == [.coverageFill], let first = visible.first,
      visible.allSatisfy({ $0.fillRule == first.fillRule })
    {
      coveragePaint = .fill(first.fillRule)
    } else {
      throw LiveTextSVGImportError.unsupportedSemantic("mixed coverage paint or style")
    }

    let trajectoryCommands: [LiveTextSVGCommand]
    let trajectoryStyle: LiveTextSVGStrokeStyle
    if trajectories.isEmpty {
      guard case .stroke(let style) = coveragePaint else {
        throw LiveTextSVGImportError.missingTrajectory
      }
      trajectoryCommands = coverageCommands
      trajectoryStyle = style
    } else {
      guard let first = trajectories.first,
        trajectories.allSatisfy({ $0.style == first.style })
      else {
        throw LiveTextSVGImportError.unsupportedSemantic("mixed trajectory styles")
      }
      trajectoryCommands = trajectories.flatMap(\.commands)
      trajectoryStyle = first.style
    }
    guard trajectoryCommands.count <= LiveTextSVGImportedDocument.maximumOutputCommands else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "trajectory output commands",
        actual: trajectoryCommands.count,
        limit: LiveTextSVGImportedDocument.maximumOutputCommands
      )
    }

    return try LiveTextSVGImportedDocument(
      size: sceneSize,
      coordinateBounds: LiveTextSVGRect(
        minX: 0, minY: 0, maxX: sceneSize.width, maxY: sceneSize.height),
      coverageCommands: coverageCommands,
      coveragePaint: coveragePaint,
      trajectoryCommands: trajectoryCommands,
      trajectoryStyle: trajectoryStyle
    )
  }

  func parseArtwork() throws -> LiveTextSVGArtworkDocument {
    try parseElements()
    guard let sceneSize else { throw LiveTextSVGImportError.missingSize }
    let visible = pendingPaths.filter { $0.role == .coverageStroke || $0.role == .coverageFill }
    guard !visible.isEmpty, visible.count == pendingPaths.count else {
      throw LiveTextSVGImportError.unsupportedSemantic("artwork cannot contain trajectory paths")
    }
    let paths = try visible.map { path in
      guard let paint = path.artworkPaint else {
        throw LiveTextSVGImportError.unsupportedSemantic("artwork path has no paint")
      }
      return try LiveTextSVGArtworkPath(commands: path.commands, paint: paint)
    }
    return try LiveTextSVGArtworkDocument(
      size: sceneSize,
      coordinateBounds: LiveTextSVGRect(
        minX: 0, minY: 0, maxX: sceneSize.width, maxY: sceneSize.height),
      paths: paths
    )
  }

  private func parseElements() throws {
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    while true {
      skipWhitespace()
      guard index < bytes.count else { break }
      guard bytes[index] == 0x3C else {
        try consumeText()
        continue
      }
      if bytes[index...].starts(with: Array("<!--".utf8)) {
        try consumeComment()
      } else if bytes[index...].starts(with: Array("<?".utf8)) {
        try consumeProcessingInstruction()
      } else if bytes[index...].starts(with: Array("<!".utf8)) {
        throw LiveTextSVGImportError.invalidDocument(
          "DTD, entity, and CDATA declarations are unsupported")
      } else if index + 1 < bytes.count, bytes[index + 1] == 0x2F {
        try consumeEndElement()
      } else {
        try consumeStartElement()
      }
    }

    guard rootSeen else { throw LiveTextSVGImportError.missingRoot }
    guard rootClosed, frames.isEmpty else {
      throw LiveTextSVGImportError.invalidDocument("unterminated SVG element")
    }
  }

  private func consumeText() throws {
    let start = index
    while index < bytes.count, bytes[index] != 0x3C { index += 1 }
    guard let text = String(bytes: bytes[start..<index], encoding: .utf8) else {
      throw LiveTextSVGImportError.invalidDocument("document is not valid UTF-8")
    }
    guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LiveTextSVGImportError.invalidDocument("visible text content is unsupported")
    }
  }

  private func consumeComment() throws {
    index += 4
    while index + 2 < bytes.count {
      if bytes[index] == 0x2D, bytes[index + 1] == 0x2D, bytes[index + 2] == 0x3E {
        index += 3
        return
      }
      index += 1
    }
    throw LiveTextSVGImportError.invalidDocument("unterminated comment")
  }

  private func consumeProcessingInstruction() throws {
    let start = index
    index += 2
    let end = findSequence([0x3F, 0x3E])
    guard end > start else {
      throw LiveTextSVGImportError.invalidDocument("unterminated processing instruction")
    }
    guard end < bytes.count else {
      throw LiveTextSVGImportError.invalidDocument("unterminated processing instruction")
    }
    let content = String(decoding: bytes[(start + 2)..<end], as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    index = end + 2
    let lowercasedContent = content.lowercased()
    if !rootSeen {
      if lowercasedContent == "xml" || lowercasedContent.hasPrefix("xml ") {
        return
      }
    }
    throw LiveTextSVGImportError.unsupportedSemantic("processing instruction")
  }

  private func consumeStartElement() throws {
    index += 1
    let name = try readName()
    var attributes: [String: String] = [:]
    while true {
      skipWhitespace()
      guard index < bytes.count else {
        throw LiveTextSVGImportError.invalidDocument("unterminated start element")
      }
      if bytes[index] == 0x3E {
        index += 1
        try startElement(name, attributes: attributes, selfClosing: false)
        return
      }
      if bytes[index] == 0x2F {
        index += 1
        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x3E else {
          throw LiveTextSVGImportError.invalidDocument("invalid self-closing element")
        }
        index += 1
        try startElement(name, attributes: attributes, selfClosing: true)
        return
      }
      let attributeName = try readName()
      guard attributes[attributeName] == nil else {
        throw LiveTextSVGImportError.invalidDocument("duplicate attribute \(attributeName)")
      }
      skipWhitespace()
      guard index < bytes.count, bytes[index] == 0x3D else {
        throw LiveTextSVGImportError.invalidDocument("attribute \(attributeName) has no value")
      }
      index += 1
      skipWhitespace()
      guard index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 else {
        throw LiveTextSVGImportError.invalidDocument("attribute \(attributeName) must be quoted")
      }
      let quote = bytes[index]
      index += 1
      let valueStart = index
      while index < bytes.count, bytes[index] != quote { index += 1 }
      guard index < bytes.count else {
        throw LiveTextSVGImportError.invalidDocument("unterminated attribute \(attributeName)")
      }
      let rawValue = bytes[valueStart..<index]
      guard rawValue.count <= options.limits.maximumAttributeBytes else {
        throw LiveTextSVGImportError.resourceLimitExceeded(
          resource: "attribute bytes", actual: rawValue.count,
          limit: options.limits.maximumAttributeBytes
        )
      }
      index += 1
      attributes[attributeName] = try decodeXMLAttribute(rawValue)
    }
  }

  private func consumeEndElement() throws {
    index += 2
    let name = try readName()
    skipWhitespace()
    guard index < bytes.count, bytes[index] == 0x3E else {
      throw LiveTextSVGImportError.invalidDocument("invalid end element")
    }
    index += 1
    guard let frame = frames.last, frame.name == name else {
      throw LiveTextSVGImportError.invalidDocument("mismatched closing element \(name)")
    }
    frames.removeLast()
    if name == "svg" {
      rootClosed = true
    }
  }

  private func startElement(
    _ name: String,
    attributes: [String: String],
    selfClosing: Bool
  ) throws {
    elementCount += 1
    guard elementCount <= options.limits.maximumElements else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "elements", actual: elementCount, limit: options.limits.maximumElements
      )
    }
    guard frames.count + 1 <= options.limits.maximumDepth else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "nesting depth", actual: frames.count + 1, limit: options.limits.maximumDepth
      )
    }
    guard !rootClosed else {
      throw LiveTextSVGImportError.invalidDocument("content after svg root")
    }

    if frames.isEmpty {
      guard name == "svg", !rootSeen else { throw LiveTextSVGImportError.missingRoot }
      rootSeen = true
      try validateAttributes(
        attributes,
        allowed: [
          "id", "version", "viewBox", "width", "height", "transform",
          "preserveAspectRatio",
          "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin",
          "stroke-miterlimit", "fill-rule", "fill-opacity", "stroke-opacity", "opacity",
        ],
        allowNamespaceDeclarations: true
      )
      let viewport = try parseViewport(attributes)
      sceneSize = viewport.size
      viewBoxTransform = viewport.transform
      let style = try mergedStyle(SVGStyle(), attributes: attributes)
      let localTransform = try parseTransform(attributes["transform"])
      frames.append(
        SVGFrame(
          name: name,
          style: style,
          transform: localTransform.concatenating(viewBoxTransform)
        )
      )
      if selfClosing {
        frames.removeLast()
        rootClosed = true
      }
      return
    }

    guard let parent = frames.last else {
      throw LiveTextSVGImportError.invalidDocument("missing parent element")
    }
    guard parent.name != "path" else {
      throw LiveTextSVGImportError.invalidDocument("elements cannot be nested inside path")
    }
    switch name {
    case "g":
      try validateAttributes(
        attributes,
        allowed: [
          "id", "transform", "fill", "stroke", "stroke-width", "stroke-linecap",
          "stroke-linejoin", "stroke-miterlimit", "fill-rule", "fill-opacity", "stroke-opacity",
          "opacity",
        ]
      )
      let style = try mergedStyle(parent.style, attributes: attributes)
      let localTransform = try parseTransform(attributes["transform"])
      frames.append(
        SVGFrame(
          name: name,
          style: style,
          transform: parent.transform.concatenating(localTransform)
        )
      )
      if selfClosing { frames.removeLast() }
    case "path":
      try validateAttributes(
        attributes,
        allowed: [
          "id", "d", "transform", "data-live-text-role", "fill", "stroke", "stroke-width",
          "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "fill-rule", "fill-opacity",
          "stroke-opacity", "opacity",
        ]
      )
      try appendPath(attributes, inheritedStyle: parent.style, inheritedTransform: parent.transform)
      frames.append(
        SVGFrame(name: name, style: parent.style, transform: parent.transform)
      )
      if selfClosing { frames.removeLast() }
    case "circle":
      try validateGeometryAttributes(attributes, geometry: ["cx", "cy", "r"])
      try appendCircle(attributes, inheritedStyle: parent.style, inheritedTransform: parent.transform)
      frames.append(SVGFrame(name: name, style: parent.style, transform: parent.transform))
      if selfClosing { frames.removeLast() }
    case "ellipse":
      try validateGeometryAttributes(attributes, geometry: ["cx", "cy", "rx", "ry"])
      try appendEllipse(attributes, inheritedStyle: parent.style, inheritedTransform: parent.transform)
      frames.append(SVGFrame(name: name, style: parent.style, transform: parent.transform))
      if selfClosing { frames.removeLast() }
    case "rect":
      try validateGeometryAttributes(attributes, geometry: ["x", "y", "width", "height", "rx", "ry"])
      try appendRect(attributes, inheritedStyle: parent.style, inheritedTransform: parent.transform)
      frames.append(SVGFrame(name: name, style: parent.style, transform: parent.transform))
      if selfClosing { frames.removeLast() }
    case "line":
      try validateGeometryAttributes(attributes, geometry: ["x1", "x2", "y1", "y2"])
      try appendLine(attributes, inheritedStyle: parent.style, inheritedTransform: parent.transform)
      frames.append(SVGFrame(name: name, style: parent.style, transform: parent.transform))
      if selfClosing { frames.removeLast() }
    case "polyline":
      try validateGeometryAttributes(attributes, geometry: ["points"])
      try appendPolyline(attributes, inheritedStyle: parent.style, inheritedTransform: parent.transform)
      frames.append(SVGFrame(name: name, style: parent.style, transform: parent.transform))
      if selfClosing { frames.removeLast() }
    case "polygon":
      try validateGeometryAttributes(attributes, geometry: ["points"])
      try appendPolygon(attributes, inheritedStyle: parent.style, inheritedTransform: parent.transform)
      frames.append(SVGFrame(name: name, style: parent.style, transform: parent.transform))
      if selfClosing { frames.removeLast() }
    default:
      throw LiveTextSVGImportError.unsupportedElement(name)
    }
  }

  private func validateGeometryAttributes(
    _ attributes: [String: String],
    geometry: Set<String>
  ) throws {
    try validateAttributes(
      attributes,
      allowed: Self.geometryStyleAttributes.union(geometry)
    )
  }

  private func appendPath(
    _ attributes: [String: String],
    inheritedStyle: SVGStyle,
    inheritedTransform: SVGTransform
  ) throws {
    guard let pathData = attributes["d"],
      !pathData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw LiveTextSVGImportError.invalidPathData("path requires d")
    }
    let style = try mergedStyle(inheritedStyle, attributes: attributes)
    let localTransform = try parseTransform(attributes["transform"])
    let transform = inheritedTransform.concatenating(localTransform)
    guard let scale = transform.similarityScale else {
      throw LiveTextSVGImportError.nonUniformStrokeTransform
    }
    guard scale.isFinite, scale > 0,
      scale <= options.limits.maximumCoordinateMagnitude
    else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "transform scale",
        actual: liveTextSVGBoundedMagnitude(scale),
        limit: liveTextSVGBoundedMagnitude(options.limits.maximumCoordinateMagnitude)
      )
    }

    let parsedResult = try SVGPathDataParser.parse(pathData, limits: options.limits)
    try reserveGeometry(
      sourceCommandCount: parsedResult.sourceCommandCount,
      normalizedSegmentCount: parsedResult.normalizedSegmentCount
    )
    let parsed = parsedResult.subpaths
    guard !parsed.isEmpty else {
      throw LiveTextSVGImportError.invalidPathData("path has no subpaths")
    }

    let transformedCommands = try parsed.flatMap { subpath in
      try subpath.map { try applying(transform, to: $0) }
    }
    try appendPaintedGeometry(
      transformedCommands,
      attributes: attributes,
      style: style,
      scale: scale
    )
  }

  private func appendCircle(
    _ attributes: [String: String],
    inheritedStyle: SVGStyle,
    inheritedTransform: SVGTransform
  ) throws {
    let cx = try requiredLength(attributes, name: "cx")
    let cy = try requiredLength(attributes, name: "cy")
    let radius = try requiredLength(attributes, name: "r")
    let commands = try ellipseCommands(cx: cx, cy: cy, rx: radius, ry: radius)
    try appendPrimitive(commands, attributes: attributes, inheritedStyle: inheritedStyle,
                        inheritedTransform: inheritedTransform)
  }

  private func appendEllipse(
    _ attributes: [String: String],
    inheritedStyle: SVGStyle,
    inheritedTransform: SVGTransform
  ) throws {
    let cx = try requiredLength(attributes, name: "cx")
    let cy = try requiredLength(attributes, name: "cy")
    let rx = try requiredLength(attributes, name: "rx")
    let ry = try requiredLength(attributes, name: "ry")
    let commands = try ellipseCommands(cx: cx, cy: cy, rx: rx, ry: ry)
    try appendPrimitive(commands, attributes: attributes, inheritedStyle: inheritedStyle,
                        inheritedTransform: inheritedTransform)
  }

  private func appendRect(
    _ attributes: [String: String],
    inheritedStyle: SVGStyle,
    inheritedTransform: SVGTransform
  ) throws {
    let x = try requiredLength(attributes, name: "x")
    let y = try requiredLength(attributes, name: "y")
    let width = try requiredLength(attributes, name: "width")
    let height = try requiredLength(attributes, name: "height")
    let rawRX = try optionalLength(attributes, name: "rx")
    let rawRY = try optionalLength(attributes, name: "ry")
    let radiusX = rawRX ?? rawRY ?? 0
    let radiusY = rawRY ?? rawRX ?? 0
    guard radiusX >= 0, radiusY >= 0 else {
      throw LiveTextSVGImportError.invalidDocument("rect corner radius cannot be negative")
    }
    let commands = try rectangleCommands(
      x: x, y: y, width: width, height: height,
      rx: min(radiusX, width / 2), ry: min(radiusY, height / 2)
    )
    try appendPrimitive(commands, attributes: attributes, inheritedStyle: inheritedStyle,
                        inheritedTransform: inheritedTransform)
  }

  private func appendLine(
    _ attributes: [String: String],
    inheritedStyle: SVGStyle,
    inheritedTransform: SVGTransform
  ) throws {
    let x1 = try requiredLength(attributes, name: "x1")
    let y1 = try requiredLength(attributes, name: "y1")
    let x2 = try requiredLength(attributes, name: "x2")
    let y2 = try requiredLength(attributes, name: "y2")
    let start = try LiveTextSVGPoint(x: x1, y: y1)
    let end = try LiveTextSVGPoint(x: x2, y: y2)
    let commands: [LiveTextSVGCommand] = [.move(to: start), .line(to: end)]
    try appendPrimitive(commands, attributes: attributes, inheritedStyle: inheritedStyle,
                        inheritedTransform: inheritedTransform, forceFillNone: true)
  }

  private func appendPolyline(
    _ attributes: [String: String],
    inheritedStyle: SVGStyle,
    inheritedTransform: SVGTransform
  ) throws {
    let commands = try pointsCommands(attributes, closed: false)
    try appendPrimitive(commands, attributes: attributes, inheritedStyle: inheritedStyle,
                        inheritedTransform: inheritedTransform)
  }

  private func appendPolygon(
    _ attributes: [String: String],
    inheritedStyle: SVGStyle,
    inheritedTransform: SVGTransform
  ) throws {
    let commands = try pointsCommands(attributes, closed: true)
    try appendPrimitive(commands, attributes: attributes, inheritedStyle: inheritedStyle,
                        inheritedTransform: inheritedTransform)
  }

  private func appendPrimitive(
    _ sourceCommands: [LiveTextSVGCommand],
    attributes: [String: String],
    inheritedStyle: SVGStyle,
    inheritedTransform: SVGTransform,
    forceFillNone: Bool = false
  ) throws {
    guard !sourceCommands.isEmpty else {
      throw LiveTextSVGImportError.invalidDocument("shape has no geometry")
    }
    var style = try mergedStyle(inheritedStyle, attributes: attributes)
    if forceFillNone { style.fill = .none }
    if forceFillNone, style.stroke == .none { return }
    let localTransform = try parseTransform(attributes["transform"])
    let transform = inheritedTransform.concatenating(localTransform)
    guard let scale = transform.similarityScale else {
      throw LiveTextSVGImportError.nonUniformStrokeTransform
    }
    guard scale.isFinite, scale > 0,
      scale <= options.limits.maximumCoordinateMagnitude
    else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "transform scale",
        actual: liveTextSVGBoundedMagnitude(scale),
        limit: liveTextSVGBoundedMagnitude(options.limits.maximumCoordinateMagnitude)
      )
    }
    try reserveGeometry(
      sourceCommandCount: max(1, sourceCommands.count),
      normalizedSegmentCount: max(1, sourceCommands.count)
    )
    let transformedCommands = try sourceCommands.map { try applying(transform, to: $0) }
    try appendPaintedGeometry(
      transformedCommands,
      attributes: attributes,
      style: style,
      scale: scale
    )
  }

  private func appendPaintedGeometry(
    _ transformedCommands: [LiveTextSVGCommand],
    attributes: [String: String],
    style: SVGStyle,
    scale: Double
  ) throws {
    let role: SVGPathRole
    let strokeStyle: LiveTextSVGStrokeStyle
    let artworkPaint: LiveTextSVGArtworkPaint?
    switch attributes["data-live-text-role"] {
    case nil:
      switch (style.fill, style.stroke) {
      case (.none, .solid(let color)):
        role = .coverageStroke
        strokeStyle = try makeStrokeStyle(
          color: color, style: style, scale: scale, preserveColor: mode == .artwork)
        artworkPaint = mode == .artwork ? .stroke(style: strokeStyle) : nil
      case (.solid(let color), .none):
        let effectiveColor = try applyingOpacity(color, opacity: style.fillOpacity * style.opacity)
        if mode == .liveText {
          try validateOpaqueBlack(color, opacity: style.fillOpacity * style.opacity)
        }
        role = .coverageFill
        strokeStyle = .default
        artworkPaint = mode == .artwork
          ? .fill(color: effectiveColor, rule: style.fillRule)
          : nil
      case (.solid(let fillColor), .solid(let strokeColor)) where mode == .artwork:
        role = .coverageFill
        let effectiveFill = try applyingOpacity(fillColor, opacity: style.fillOpacity * style.opacity)
        strokeStyle = try makeStrokeStyle(
          color: strokeColor, style: style, scale: scale, preserveColor: true)
        artworkPaint = .fillAndStroke(
          color: effectiveFill, rule: style.fillRule, stroke: strokeStyle)
      default:
        throw LiveTextSVGImportError.unsupportedSemantic(
          "visible geometry must be fill-only or stroke-only")
      }
    case .some("trajectory"):
      guard style.fill == .none, case .solid(let color) = style.stroke else {
        throw LiveTextSVGImportError.unsupportedSemantic(
          "trajectory geometry must be stroke-only")
      }
      role = .trajectory
      strokeStyle = try makeStrokeStyle(color: color, style: style, scale: scale)
      artworkPaint = nil
    case .some(let value):
      throw LiveTextSVGImportError.unsupportedSemantic(
        "unsupported data-live-text-role \(value)")
    }

    try validateTransformedCoordinates(transformedCommands)
    let commands = transformedCommands.map(clampingToViewport)
    guard pendingPaths.count < options.limits.maximumStrokes else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "paths", actual: pendingPaths.count + 1,
        limit: options.limits.maximumStrokes
      )
    }
    pendingPaths.append(
      PendingSVGPath(
        commands: commands,
        style: strokeStyle,
        role: role,
        fillRule: style.fillRule,
        artworkPaint: artworkPaint
      )
    )
  }

  private func reserveGeometry(sourceCommandCount: Int, normalizedSegmentCount: Int) throws {
    guard sourceCommandCount <= options.limits.maximumPathCommands - sourcePathCommandCount else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "path commands",
        actual: sourcePathCommandCount + sourceCommandCount,
        limit: options.limits.maximumPathCommands
      )
    }
    guard normalizedSegmentCount <= options.limits.maximumNormalizedSegments - self.normalizedSegmentCount else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "normalized segments",
        actual: self.normalizedSegmentCount + normalizedSegmentCount,
        limit: options.limits.maximumNormalizedSegments
      )
    }
    sourcePathCommandCount += sourceCommandCount
    self.normalizedSegmentCount += normalizedSegmentCount
  }

  private func requiredLength(_ attributes: [String: String], name: String) throws -> Double {
    guard let raw = attributes[name] else {
      throw LiveTextSVGImportError.invalidDocument("\(name) is required")
    }
    return try SVGNumberScanner.parseLength(raw)
  }

  private func optionalLength(_ attributes: [String: String], name: String) throws -> Double? {
    guard let raw = attributes[name] else { return nil }
    return try SVGNumberScanner.parseLength(raw)
  }

  private func ellipseCommands(
    cx: Double,
    cy: Double,
    rx: Double,
    ry: Double
  ) throws -> [LiveTextSVGCommand] {
    guard cx.isFinite, cy.isFinite, rx.isFinite, ry.isFinite, rx > 0, ry > 0 else {
      throw LiveTextSVGImportError.invalidDocument("ellipse radii must be positive")
    }
    let kappa = 0.5522847498307936
    func point(_ x: Double, _ y: Double) throws -> LiveTextSVGPoint {
      try LiveTextSVGPoint(x: x, y: y)
    }
    return [
      .move(to: try point(cx + rx, cy)),
      .cubic(control1: try point(cx + rx, cy + kappa * ry),
             control2: try point(cx + kappa * rx, cy + ry),
             to: try point(cx, cy + ry)),
      .cubic(control1: try point(cx - kappa * rx, cy + ry),
             control2: try point(cx - rx, cy + kappa * ry),
             to: try point(cx - rx, cy)),
      .cubic(control1: try point(cx - rx, cy - kappa * ry),
             control2: try point(cx - kappa * rx, cy - ry),
             to: try point(cx, cy - ry)),
      .cubic(control1: try point(cx + kappa * rx, cy - ry),
             control2: try point(cx + rx, cy - kappa * ry),
             to: try point(cx + rx, cy)),
      .close,
    ]
  }

  private func rectangleCommands(
    x: Double,
    y: Double,
    width: Double,
    height: Double,
    rx: Double,
    ry: Double
  ) throws -> [LiveTextSVGCommand] {
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
      width > 0, height > 0, rx.isFinite, ry.isFinite, rx >= 0, ry >= 0 else {
      throw LiveTextSVGImportError.invalidDocument("rect dimensions must be positive")
    }
    func point(_ pointX: Double, _ pointY: Double) throws -> LiveTextSVGPoint {
      try LiveTextSVGPoint(x: pointX, y: pointY)
    }
    if rx == 0 || ry == 0 {
      return [
        .move(to: try point(x, y)),
        .line(to: try point(x + width, y)),
        .line(to: try point(x + width, y + height)),
        .line(to: try point(x, y + height)),
        .close,
      ]
    }
    let kappa = 0.5522847498307936
    return [
      .move(to: try point(x + rx, y)),
      .line(to: try point(x + width - rx, y)),
      .cubic(control1: try point(x + width - rx + kappa * rx, y),
             control2: try point(x + width, y + ry - kappa * ry),
             to: try point(x + width, y + ry)),
      .line(to: try point(x + width, y + height - ry)),
      .cubic(control1: try point(x + width, y + height - ry + kappa * ry),
             control2: try point(x + width - rx + kappa * rx, y + height),
             to: try point(x + width - rx, y + height)),
      .line(to: try point(x + rx, y + height)),
      .cubic(control1: try point(x + rx - kappa * rx, y + height),
             control2: try point(x, y + height - ry + kappa * ry),
             to: try point(x, y + height - ry)),
      .line(to: try point(x, y + ry)),
      .cubic(control1: try point(x, y + ry - kappa * ry),
             control2: try point(x + rx - kappa * rx, y),
             to: try point(x + rx, y)),
      .close,
    ]
  }

  private func pointsCommands(
    _ attributes: [String: String],
    closed: Bool
  ) throws -> [LiveTextSVGCommand] {
    guard let raw = attributes["points"] else {
      throw LiveTextSVGImportError.invalidDocument("points is required")
    }
    var scanner = SVGNumberScanner(raw)
    let values = try scanner.allNumbers()
    guard values.count >= 4, values.count.isMultiple(of: 2) else {
      throw LiveTextSVGImportError.invalidDocument("points requires coordinate pairs")
    }
    func point(_ offset: Int) throws -> LiveTextSVGPoint {
      try LiveTextSVGPoint(x: values[offset], y: values[offset + 1])
    }
    var commands: [LiveTextSVGCommand] = [.move(to: try point(0))]
    for offset in stride(from: 2, to: values.count, by: 2) {
      commands.append(.line(to: try point(offset)))
    }
    if closed { commands.append(.close) }
    return commands
  }

  private func makeStrokeStyle(
    color: LiveTextSVGColor,
    style: SVGStyle,
    scale: Double,
    preserveColor: Bool = false
  ) throws -> LiveTextSVGStrokeStyle {
    let effectiveColor = try applyingOpacity(color, opacity: style.strokeOpacity * style.opacity)
    if !preserveColor {
      try validateOpaqueBlack(color, opacity: style.strokeOpacity * style.opacity)
    }
    let width = style.strokeWidth * scale
    guard width.isFinite, width > 0 else {
      throw LiveTextSVGImportError.invalidDocument("stroke width must be positive")
    }
    guard width <= options.limits.maximumCoordinateMagnitude else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "stroke width",
        actual: liveTextSVGBoundedMagnitude(width),
        limit: liveTextSVGBoundedMagnitude(options.limits.maximumCoordinateMagnitude)
      )
    }
    return try LiveTextSVGStrokeStyle(
      color: preserveColor ? effectiveColor : .black,
      width: width,
      lineCap: style.lineCap,
      lineJoin: style.lineJoin,
      miterLimit: style.miterLimit
    )
  }

  private func validateOpaqueBlack(_ color: LiveTextSVGColor, opacity: Double) throws {
    let effective = try applyingOpacity(color, opacity: opacity)
    guard effective == .black else {
      throw LiveTextSVGImportError.unsupportedPaint(
        "only opaque black SVG pigment is representable")
    }
  }

  private func clampingToViewport(_ command: LiveTextSVGCommand) -> LiveTextSVGCommand {
    guard let size = sceneSize else { return command }
    func point(_ value: LiveTextSVGPoint) -> LiveTextSVGPoint {
      let epsilon = 1e-9
      let x =
        abs(value.x) <= epsilon ? 0 : abs(value.x - size.width) <= epsilon ? size.width : value.x
      let y =
        abs(value.y) <= epsilon ? 0 : abs(value.y - size.height) <= epsilon ? size.height : value.y
      return try! LiveTextSVGPoint(x: x, y: y)
    }
    switch command {
    case .move(let value): return .move(to: point(value))
    case .line(let value): return .line(to: point(value))
    case .quadratic(let control, let value):
      return .quadratic(control: point(control), to: point(value))
    case .cubic(let control1, let control2, let value):
      return .cubic(control1: point(control1), control2: point(control2), to: point(value))
    case .close: return .close
    }
  }

  private func parseViewport(_ attributes: [String: String]) throws -> (
    size: LiveTextSVGSize, transform: SVGTransform
  ) {
    let preserveAspectRatio = try SVGPreserveAspectRatio.parse(attributes["preserveAspectRatio"])
    let viewBox: [Double]?
    if let raw = attributes["viewBox"] {
      var scanner = SVGNumberScanner(raw)
      let values = try scanner.allNumbers()
      guard values.count == 4 else {
        throw LiveTextSVGImportError.invalidDocument("viewBox requires four numbers")
      }
      guard values.allSatisfy({ $0.isFinite }) else {
        throw LiveTextSVGImportError.invalidDocument("viewBox contains a non-finite number")
      }
      guard values[2] > 0, values[3] > 0 else {
        throw LiveTextSVGImportError.invalidDocument("viewBox width and height must be positive")
      }
      try validateCoordinateLimit(values)
      viewBox = values
    } else {
      viewBox = nil
    }

    let hasWidth = attributes["width"] != nil
    let hasHeight = attributes["height"] != nil
    guard hasWidth == hasHeight else {
      throw LiveTextSVGImportError.missingSize
    }
    let width: Double
    let height: Double
    if let rawWidth = attributes["width"], let rawHeight = attributes["height"] {
      width = try SVGNumberScanner.parseLength(rawWidth)
      height = try SVGNumberScanner.parseLength(rawHeight)
    } else if let viewBox {
      width = viewBox[2]
      height = viewBox[3]
    } else {
      throw LiveTextSVGImportError.missingSize
    }
    guard width > 0, height > 0 else { throw LiveTextSVGImportError.missingSize }
    try validateCoordinateLimit([width, height])
    let size = try LiveTextSVGSize(width: width, height: height)
    guard let viewBox else { return (size, .identity) }
    let scaleX = width / viewBox[2]
    let scaleY = height / viewBox[3]
    let translate = SVGTransform.translation(-viewBox[0], -viewBox[1])
    guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
      throw LiveTextSVGImportError.invalidDocument("viewBox transform is not finite")
    }
    switch preserveAspectRatio.mode {
    case nil:
      let tolerance = 0.000_001 * max(1, scaleX, scaleY)
      guard abs(scaleX - scaleY) <= tolerance else {
        throw LiveTextSVGImportError.nonUniformStrokeTransform
      }
      return (
        size,
        SVGTransform.scale(scaleX, scaleY).concatenating(translate)
      )
    case .some(let mode):
      let scale = mode == .meet ? min(scaleX, scaleY) : max(scaleX, scaleY)
      guard scale.isFinite, scale > 0,
        scale <= options.limits.maximumCoordinateMagnitude
      else {
        throw LiveTextSVGImportError.resourceLimitExceeded(
          resource: "viewBox scale",
          actual: liveTextSVGBoundedMagnitude(scale),
          limit: liveTextSVGBoundedMagnitude(options.limits.maximumCoordinateMagnitude)
        )
      }
      let remainingX = width - viewBox[2] * scale
      let remainingY = height - viewBox[3] * scale
      guard remainingX.isFinite, remainingY.isFinite else {
        throw LiveTextSVGImportError.invalidDocument("viewBox alignment is not finite")
      }
      let offsetX: Double
      let offsetY: Double
      switch preserveAspectRatio.x {
      case .min: offsetX = 0
      case .mid: offsetX = remainingX * 0.5
      case .max: offsetX = remainingX
      case nil: offsetX = 0
      }
      switch preserveAspectRatio.y {
      case .min: offsetY = 0
      case .mid: offsetY = remainingY * 0.5
      case .max: offsetY = remainingY
      case nil: offsetY = 0
      }
      let uniformTransform = SVGTransform.scale(scale, scale).concatenating(translate)
      return (
        size,
        SVGTransform.translation(offsetX, offsetY).concatenating(uniformTransform)
      )
    }
  }

  private func validateCoordinateLimit(_ values: [Double]) throws {
    let maximum = values.map { abs($0) }.max() ?? 0
    guard maximum <= options.limits.maximumCoordinateMagnitude else {
      throw LiveTextSVGImportError.resourceLimitExceeded(
        resource: "coordinate magnitude",
        actual: liveTextSVGBoundedMagnitude(maximum),
        limit: liveTextSVGBoundedMagnitude(options.limits.maximumCoordinateMagnitude)
      )
    }
  }

  private func mergedStyle(_ base: SVGStyle, attributes: [String: String]) throws -> SVGStyle {
    var style = base
    if let fill = attributes["fill"] { style.fill = try parsePaint(fill) }
    if let stroke = attributes["stroke"] { style.stroke = try parsePaint(stroke) }
    if let width = attributes["stroke-width"] {
      style.strokeWidth = try SVGNumberScanner.parseLength(width)
      guard style.strokeWidth >= 0 else {
        throw LiveTextSVGImportError.invalidDocument("stroke-width cannot be negative")
      }
    }
    if let cap = attributes["stroke-linecap"] {
      guard
        let value = LiveTextSVGLineCap(
          rawValue: cap.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
      else {
        throw LiveTextSVGImportError.unsupportedSemantic("stroke-linecap \(cap)")
      }
      style.lineCap = value
    }
    if let join = attributes["stroke-linejoin"] {
      guard
        let value = LiveTextSVGLineJoin(
          rawValue: join.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
      else {
        throw LiveTextSVGImportError.unsupportedSemantic("stroke-linejoin \(join)")
      }
      style.lineJoin = value
    }
    if let rule = attributes["fill-rule"] {
      switch rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "nonzero": style.fillRule = .nonZero
      case "evenodd": style.fillRule = .evenOdd
      default: throw LiveTextSVGImportError.unsupportedSemantic("fill-rule \(rule)")
      }
    }
    if let miter = attributes["stroke-miterlimit"] {
      style.miterLimit = try SVGNumberScanner.parseLength(miter)
      guard style.miterLimit >= 1 else {
        throw LiveTextSVGImportError.invalidDocument("stroke-miterlimit must be at least one")
      }
    }
    if let value = attributes["fill-opacity"] { style.fillOpacity = try parseOpacity(value) }
    if let value = attributes["stroke-opacity"] { style.strokeOpacity = try parseOpacity(value) }
    if let value = attributes["opacity"] {
      style.opacity *= try parseOpacity(value)
    }
    return style
  }

  private func parsePaint(_ raw: String) throws -> SVGPaint {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.lowercased() == "none" { return .none }
    if value.lowercased() == "inherit" {
      throw LiveTextSVGImportError.unsupportedSemantic("paint inheritance")
    }
    if value.lowercased().hasPrefix("url(") {
      throw LiveTextSVGImportError.unsupportedPaint(value)
    }
    guard let color = try SVGColorParser.parse(value) else {
      throw LiveTextSVGImportError.invalidColor(value)
    }
    return .solid(color)
  }

  private func parseOpacity(_ raw: String) throws -> Double {
    let value = try SVGNumberScanner.parseLength(raw)
    guard value.isFinite, (0...1).contains(value) else {
      throw LiveTextSVGImportError.invalidDocument("opacity must be between zero and one")
    }
    return value
  }

  private func applyingOpacity(_ color: LiveTextSVGColor, opacity: Double) throws
    -> LiveTextSVGColor
  {
    try LiveTextSVGColor(
      red: color.red, green: color.green, blue: color.blue, alpha: color.alpha * opacity)
  }

  private func applying(
    _ transform: SVGTransform,
    to command: LiveTextSVGCommand
  ) throws -> LiveTextSVGCommand {
    switch command {
    case .move(let point): return .move(to: try transform.applying(to: point))
    case .line(let point): return .line(to: try transform.applying(to: point))
    case .quadratic(let control, let point):
      return .quadratic(
        control: try transform.applying(to: control),
        to: try transform.applying(to: point)
      )
    case .cubic(let control1, let control2, let point):
      return .cubic(
        control1: try transform.applying(to: control1),
        control2: try transform.applying(to: control2),
        to: try transform.applying(to: point)
      )
    case .close: return .close
    }
  }

  private func parseTransform(_ raw: String?) throws -> SVGTransform {
    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .identity
    }
    return try SVGTransformParser.parse(raw)
  }

  private func validateTransformedCoordinates(_ commands: [LiveTextSVGCommand]) throws {
    func validate(_ point: LiveTextSVGPoint) throws {
      guard abs(point.x) <= options.limits.maximumCoordinateMagnitude,
        abs(point.y) <= options.limits.maximumCoordinateMagnitude
      else {
        throw LiveTextSVGImportError.resourceLimitExceeded(
          resource: "coordinate magnitude",
          actual: max(liveTextSVGBoundedMagnitude(point.x), liveTextSVGBoundedMagnitude(point.y)),
          limit: liveTextSVGBoundedMagnitude(options.limits.maximumCoordinateMagnitude)
        )
      }
    }
    for command in commands {
      switch command {
      case .move(let point), .line(let point):
        try validate(point)
      case .quadratic(let control, let point):
        try validate(control)
        try validate(point)
      case .cubic(let control1, let control2, let point):
        try validate(control1)
        try validate(control2)
        try validate(point)
      case .close:
        break
      }
    }
  }

  private func validateAttributes(
    _ attributes: [String: String],
    allowed: Set<String>,
    allowNamespaceDeclarations: Bool = false
  ) throws {
    for name in attributes.keys {
      if allowed.contains(name) { continue }
      if allowNamespaceDeclarations, name == "xmlns" || name.hasPrefix("xmlns:") { continue }
      if name == "style" || name == "class" || name == "href" || name.hasPrefix("xlink:") {
        throw LiveTextSVGImportError.unsupportedAttribute(name)
      }
      throw LiveTextSVGImportError.unsupportedAttribute(name)
    }
  }

  private func readName() throws -> String {
    let start = index
    guard index < bytes.count, isNameStart(bytes[index]) else {
      throw LiveTextSVGImportError.invalidDocument("invalid XML name")
    }
    index += 1
    while index < bytes.count, isNameCharacter(bytes[index]) { index += 1 }
    return String(decoding: bytes[start..<index], as: UTF8.self)
  }

  private func skipWhitespace() {
    while index < bytes.count {
      switch bytes[index] {
      case 0x09, 0x0A, 0x0D, 0x20: index += 1
      default: return
      }
    }
  }

  private func findSequence(_ sequence: [UInt8]) -> Int {
    var cursor = index
    while cursor + sequence.count <= bytes.count {
      if bytes[cursor..<(cursor + sequence.count)].elementsEqual(sequence) { return cursor }
      cursor += 1
    }
    return bytes.count
  }

  private func isNameStart(_ byte: UInt8) -> Bool {
    byte == 0x5F || byte == 0x3A || (byte >= 0x41 && byte <= 0x5A)
      || (byte >= 0x61 && byte <= 0x7A)
  }

  private func isNameCharacter(_ byte: UInt8) -> Bool {
    isNameStart(byte) || byte == 0x2D || byte == 0x2E || (byte >= 0x30 && byte <= 0x39)
  }
}

private func decodeXMLAttribute(_ bytes: ArraySlice<UInt8>) throws -> String {
  guard let raw = String(bytes: bytes, encoding: .utf8) else {
    throw LiveTextSVGImportError.invalidDocument("attribute is not valid UTF-8")
  }
  guard raw.contains("&") else { return raw }
  var result = ""
  result.reserveCapacity(raw.count)
  var cursor = raw.startIndex
  while cursor < raw.endIndex {
    guard let ampersand = raw[cursor...].firstIndex(of: "&") else {
      result.append(contentsOf: raw[cursor...])
      break
    }
    result.append(contentsOf: raw[cursor..<ampersand])
    guard let semicolon = raw[ampersand...].firstIndex(of: ";") else {
      throw LiveTextSVGImportError.invalidDocument("unterminated XML entity")
    }
    let entity = String(raw[raw.index(after: ampersand)..<semicolon])
    switch entity {
    case "amp": result.append("&")
    case "lt": result.append("<")
    case "gt": result.append(">")
    case "quot": result.append("\"")
    case "apos": result.append("'")
    default:
      if entity.hasPrefix("#x"), let scalar = UInt32(entity.dropFirst(2), radix: 16),
        let value = UnicodeScalar(scalar)
      {
        result.unicodeScalars.append(value)
      } else if entity.hasPrefix("#"), let scalar = UInt32(entity.dropFirst(), radix: 10),
        let value = UnicodeScalar(scalar)
      {
        result.unicodeScalars.append(value)
      } else {
        throw LiveTextSVGImportError.invalidDocument("unsupported XML entity &\(entity);")
      }
    }
    cursor = raw.index(after: semicolon)
  }
  return result
}
