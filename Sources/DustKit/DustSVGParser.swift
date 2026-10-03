#if os(iOS)
import CoreGraphics
import Foundation
import UIKit

// Vector-only SVG subset adapted from PocketSVG's MIT-licensed parsing ideas.
// DustKit deliberately fails closed for semantics it cannot rasterize exactly.
enum DustSVGParser {
  static func parse(data: Data) throws -> DustSVGDocument {
    guard data.count <= DustResourceLimits.maximumSVGBytes else {
      throw DustError.resourceLimitExceeded(
        operation: "SVG",
        reason: "input exceeds \(DustResourceLimits.maximumSVGBytes) bytes"
      )
    }
    guard let xml = String(data: data, encoding: .utf8) else {
      throw DustError.invalidSVG(reason: "only UTF-8 SVG input is supported")
    }
    let upper = xml.uppercased()
    guard !upper.contains("<!DOCTYPE"), !upper.contains("<!ENTITY") else {
      throw DustError.invalidSVG(reason: "DOCTYPE and entity declarations are unsupported")
    }

    let delegate = SVGDelegate()
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = delegate
    parser.shouldProcessNamespaces = false
    parser.shouldReportNamespacePrefixes = false
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never

    let parsed = parser.parse()
    if let dustError = delegate.failure as? DustError {
      throw dustError
    }
    if let failure = delegate.failure {
      throw DustError.invalidSVG(reason: failure.localizedDescription)
    }
    guard parsed else {
      throw DustError.invalidSVG(
        reason: parser.parserError?.localizedDescription ?? "malformed XML")
    }
    guard delegate.sawRootSVG else {
      throw DustError.invalidSVG(reason: "missing <svg> root")
    }
    guard !delegate.shapes.isEmpty else {
      throw DustError.emptyContent(operation: "SVG")
    }

    return DustSVGDocument(
      shapes: delegate.shapes,
      viewBox: delegate.viewBox,
      viewportSize: delegate.viewportSize,
      preserveAspectRatio: delegate.preserveAspectRatio
    )
  }
}

struct DustSVGPreserveAspectRatio: Equatable {
  enum Alignment: Equatable {
    case xMinYMin, xMidYMin, xMaxYMin
    case xMinYMid, xMidYMid, xMaxYMid
    case xMinYMax, xMidYMax, xMaxYMax

    var factors: (x: CGFloat, y: CGFloat) {
      switch self {
      case .xMinYMin: return (0, 0)
      case .xMidYMin: return (0.5, 0)
      case .xMaxYMin: return (1, 0)
      case .xMinYMid: return (0, 0.5)
      case .xMidYMid: return (0.5, 0.5)
      case .xMaxYMid: return (1, 0.5)
      case .xMinYMax: return (0, 1)
      case .xMidYMax: return (0.5, 1)
      case .xMaxYMax: return (1, 1)
      }
    }
  }

  enum Scaling: Equatable {
    case meet
    case slice
  }

  static let `default` = DustSVGPreserveAspectRatio(
    alignment: .xMidYMid,
    scaling: .meet
  )
  static let none = DustSVGPreserveAspectRatio(alignment: nil, scaling: .meet)

  let alignment: Alignment?
  let scaling: Scaling

  func transform(viewBox: CGRect, viewport: CGSize) -> CGAffineTransform {
    let sx = viewport.width / viewBox.width
    let sy = viewport.height / viewBox.height

    guard let alignment else {
      return CGAffineTransform(
        a: sx,
        b: 0,
        c: 0,
        d: sy,
        tx: -viewBox.minX * sx,
        ty: -viewBox.minY * sy
      )
    }

    let scale = scaling == .meet ? min(sx, sy) : max(sx, sy)
    let renderedWidth = viewBox.width * scale
    let renderedHeight = viewBox.height * scale
    let factors = alignment.factors
    let offsetX = (viewport.width - renderedWidth) * factors.x
    let offsetY = (viewport.height - renderedHeight) * factors.y

    return CGAffineTransform(
      a: scale,
      b: 0,
      c: 0,
      d: scale,
      tx: offsetX - viewBox.minX * scale,
      ty: offsetY - viewBox.minY * scale
    )
  }
}

struct DustSVGDocument {
  let shapes: [DustSVGShape]
  let viewBox: CGRect?
  let viewportSize: CGSize?
  let preserveAspectRatio: DustSVGPreserveAspectRatio

  func raster(scale: CGFloat) throws -> DustRaster {
    let contentBounds = try paintedBounds()
    guard !contentBounds.isNull, contentBounds.width > 0, contentBounds.height > 0 else {
      throw DustError.emptyContent(operation: "SVG")
    }

    let canvasSize: CGSize
    let rootTransform: CGAffineTransform
    if let viewBox {
      let viewport = viewportSize ?? viewBox.size
      canvasSize = viewport
      rootTransform = preserveAspectRatio.transform(viewBox: viewBox, viewport: viewport)
    } else if let viewportSize {
      canvasSize = viewportSize
      rootTransform = .identity
    } else {
      canvasSize = CGSize(width: ceil(contentBounds.width), height: ceil(contentBounds.height))
      rootTransform = CGAffineTransform(
        translationX: -contentBounds.minX,
        y: -contentBounds.minY
      )
    }

    try DustResourceLimits.validateRaster(size: canvasSize, scale: scale, operation: "SVG")

    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    format.preferredRange = .standard
    let image = UIGraphicsImageRenderer(size: canvasSize, format: format).image { renderer in
      let context = renderer.cgContext
      context.setAllowsAntialiasing(true)
      context.setShouldAntialias(true)
      context.concatenate(rootTransform)

      for shape in shapes where !shape.hidden {
        context.saveGState()
        context.concatenate(shape.transform)
        if shape.opacity < 1 {
          context.setAlpha(shape.opacity)
          context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if let fill = shape.fill {
          context.addPath(shape.path)
          context.setFillColor(fill.cgColor)
          context.drawPath(using: shape.fillRule == .evenOdd ? .eoFill : .fill)
        }
        if let stroke = shape.stroke, shape.strokeWidth > 0 {
          context.addPath(shape.path)
          context.setStrokeColor(stroke.cgColor)
          context.setLineWidth(shape.strokeWidth)
          context.setLineCap(shape.lineCap)
          context.setLineJoin(shape.lineJoin)
          context.setMiterLimit(DustSVGShape.defaultMiterLimit)
          context.strokePath()
        }
        if shape.opacity < 1 {
          context.endTransparencyLayer()
        }
        context.restoreGState()
      }
    }
    return try DustRasterizer.canonicalCrop(image, operation: "SVG")
  }

  private func paintedBounds() throws -> CGRect {
    var result = CGRect.null
    for shape in shapes where !shape.hidden {
      if shape.fill != nil {
        let transformed = CGMutablePath()
        transformed.addPath(shape.path, transform: shape.transform)
        let bounds = transformed.boundingBoxOfPath
        guard bounds.isFinite else {
          throw DustError.invalidSVG(reason: "transformed fill bounds are non-finite")
        }
        result = result.union(bounds)
      }
      if shape.stroke != nil, shape.strokeWidth > 0 {
        let stroked = shape.path.copy(
          strokingWithWidth: shape.strokeWidth,
          lineCap: shape.lineCap,
          lineJoin: shape.lineJoin,
          miterLimit: DustSVGShape.defaultMiterLimit
        )
        let transformedStroke = CGMutablePath()
        transformedStroke.addPath(stroked, transform: shape.transform)
        let bounds = transformedStroke.boundingBoxOfPath
        guard bounds.isFinite else {
          throw DustError.invalidSVG(reason: "transformed stroke bounds are non-finite")
        }
        result = result.union(bounds)
      }
    }
    return result
  }
}

struct DustSVGShape {
  static let defaultMiterLimit: CGFloat = 4

  let path: CGPath
  let transform: CGAffineTransform
  let fill: UIColor?
  let stroke: UIColor?
  let strokeWidth: CGFloat
  let opacity: CGFloat
  let fillRule: CGPathFillRule
  let lineCap: CGLineCap
  let lineJoin: CGLineJoin
  let hidden: Bool
}

private final class SVGDelegate: NSObject, XMLParserDelegate {
  struct StyleContext {
    var transform = CGAffineTransform.identity
    var fill: UIColor? = .black
    var stroke: UIColor?
    var strokeWidth: CGFloat = 1
    var fillOpacity: CGFloat = 1
    var strokeOpacity: CGFloat = 1
    var fillRule: CGPathFillRule = .winding
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    var displaySuppressed = false
    var visibilityHidden = false

    var hidden: Bool { displaySuppressed || visibilityHidden }
  }

  enum SVGFailure: Error, LocalizedError {
    case unsupportedElement(String)
    case unsupportedAttribute(String)
    case invalidAttribute(String)
    case invalidPath(String)

    var errorDescription: String? {
      switch self {
      case .unsupportedElement(let name): return "unsupported <\(name)> element"
      case .unsupportedAttribute(let value): return "unsupported SVG attribute: \(value)"
      case .invalidAttribute(let name): return "invalid SVG attribute: \(name)"
      case .invalidPath(let reason): return "invalid SVG path: \(reason)"
      }
    }
  }

  var shapes: [DustSVGShape] = []
  var viewBox: CGRect?
  var viewportSize: CGSize?
  var preserveAspectRatio: DustSVGPreserveAspectRatio = .default
  var failure: Error?
  var sawRootSVG = false

  private var stack: [StyleContext] = [.init()]
  private var ignoredDepth = 0

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    guard failure == nil else {
      parser.abortParsing()
      return
    }

    let name = elementName.lowercased()
    if !sawRootSVG {
      guard name == "svg" else {
        failure = DustError.invalidSVG(reason: "document root must be <svg>")
        parser.abortParsing()
        return
      }
      sawRootSVG = true
    } else if name == "svg" {
      failure = SVGFailure.unsupportedElement("nested svg")
      parser.abortParsing()
      return
    }

    if ignoredDepth > 0 {
      ignoredDepth += 1
      return
    }
    if ["defs", "metadata", "title", "desc"].contains(name) {
      ignoredDepth = 1
      return
    }

    do {
      let attributes = try normalizedAttributes(attributeDict)
      try validateAttributes(attributes, for: name)

      switch name {
      case "svg":
        guard attributes["transform"] == nil else {
          throw SVGFailure.unsupportedAttribute("root transform")
        }
        guard attributes["opacity"] == nil else {
          throw SVGFailure.unsupportedAttribute("root opacity")
        }

        if let raw = attributes["viewbox"] {
          viewBox = try parseViewBox(raw)
        }
        let width = try attributes["width"].map(parsePositiveLength)
        let height = try attributes["height"].map(parsePositiveLength)
        guard (width == nil) == (height == nil) else {
          throw SVGFailure.invalidAttribute("root width and height must be supplied together")
        }
        if let width, let height {
          viewportSize = CGSize(width: width, height: height)
        }
        if let raw = attributes["preserveaspectratio"] {
          guard viewBox != nil else {
            throw SVGFailure.invalidAttribute("preserveAspectRatio requires viewBox")
          }
          preserveAspectRatio = try parsePreserveAspectRatio(raw)
        }
        stack.append(try applying(attributes: attributes, to: stack.last!, allowsOpacity: false))

      case "g", "a":
        guard attributes["opacity"] == nil else {
          throw SVGFailure.unsupportedAttribute("group opacity")
        }
        stack.append(try applying(attributes: attributes, to: stack.last!, allowsOpacity: false))

      case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
        let style = try applying(attributes: attributes, to: stack.last!, allowsOpacity: true)
        guard !style.hidden else { return }
        guard shapes.count < DustResourceLimits.maximumSVGShapes else {
          throw DustError.resourceLimitExceeded(
            operation: "SVG",
            reason: "rendered shape count exceeds \(DustResourceLimits.maximumSVGShapes)"
          )
        }
        let path = try makePath(element: name, attributes: attributes)
        let opacity = try attributes["opacity"].map(parseUnitInterval) ?? 1
        shapes.append(
          DustSVGShape(
            path: path,
            transform: style.transform,
            fill: style.fill.map {
              $0.withAlphaComponent($0.cgColor.alpha * style.fillOpacity)
            },
            stroke: style.stroke.map {
              $0.withAlphaComponent($0.cgColor.alpha * style.strokeOpacity)
            },
            strokeWidth: style.strokeWidth,
            opacity: opacity,
            fillRule: style.fillRule,
            lineCap: style.lineCap,
            lineJoin: style.lineJoin,
            hidden: style.hidden
          )
        )

      case "lineargradient", "radialgradient", "filter", "mask", "clippath",
        "pattern", "text", "image", "use", "symbol", "style", "foreignobject":
        throw SVGFailure.unsupportedElement(elementName)

      default:
        throw SVGFailure.unsupportedElement(elementName)
      }
    } catch {
      failure = error
      parser.abortParsing()
    }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if ignoredDepth > 0 {
      ignoredDepth -= 1
      return
    }
    let name = elementName.lowercased()
    if name == "svg" || name == "g" || name == "a" {
      if stack.count > 1 { stack.removeLast() }
    }
  }

  private func normalizedAttributes(_ raw: [String: String]) throws -> [String: String] {
    var attributes: [String: String] = [:]
    for (key, value) in raw {
      attributes[key.lowercased()] = value
    }

    if let inline = attributes.removeValue(forKey: "style") {
      for rawDeclaration in inline.split(separator: ";", omittingEmptySubsequences: true) {
        let pair = rawDeclaration.split(
          separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { throw SVGFailure.invalidAttribute("style") }
        let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { throw SVGFailure.invalidAttribute("style") }
        guard key != "transform" else {
          throw SVGFailure.unsupportedAttribute("CSS transform")
        }
        attributes[key] = value
      }
    }
    return attributes
  }

  private func validateAttributes(_ attributes: [String: String], for element: String) throws {
    let presentation: Set<String> = [
      "id", "fill", "stroke", "stroke-width", "fill-opacity", "stroke-opacity",
      "fill-rule", "stroke-linecap", "stroke-linejoin", "display", "visibility",
      "transform", "opacity",
    ]
    let geometry: Set<String>
    switch element {
    case "svg":
      geometry = [
        "xmlns", "xmlns:xlink", "version", "width", "height", "viewbox", "preserveaspectratio",
      ]
    case "g", "a":
      geometry = []
    case "path":
      geometry = ["d"]
    case "rect":
      geometry = ["x", "y", "width", "height", "rx", "ry"]
    case "circle":
      geometry = ["cx", "cy", "r"]
    case "ellipse":
      geometry = ["cx", "cy", "rx", "ry"]
    case "line":
      geometry = ["x1", "y1", "x2", "y2"]
    case "polyline", "polygon":
      geometry = ["points"]
    default:
      geometry = []
    }

    let allowed = presentation.union(geometry)
    if let unknown = attributes.keys.first(where: { !allowed.contains($0) }) {
      throw SVGFailure.unsupportedAttribute(unknown)
    }

    let alwaysUnsupported: Set<String> = [
      "clip-path", "filter", "mask", "vector-effect", "paint-order",
      "stroke-dasharray", "stroke-dashoffset", "stroke-miterlimit",
      "marker-start", "marker-mid", "marker-end", "transform-origin", "class",
    ]
    if let unsupported = attributes.keys.first(where: { alwaysUnsupported.contains($0) }) {
      throw SVGFailure.unsupportedAttribute(unsupported)
    }
  }

  private func applying(
    attributes: [String: String],
    to parent: StyleContext,
    allowsOpacity: Bool
  ) throws -> StyleContext {
    var result = parent

    if let transform = attributes["transform"] {
      let local = try parseTransform(transform)
      result.transform = CGAffineTransformConcat(local, parent.transform)
      guard result.transform.isFinite else {
        throw SVGFailure.invalidAttribute("transform")
      }
    }

    if let display = attributes["display"] {
      switch display.lowercased() {
      case "none": result.displaySuppressed = true
      case "inline": break
      default: throw SVGFailure.invalidAttribute("display")
      }
    }
    if let visibility = attributes["visibility"] {
      switch visibility.lowercased() {
      case "hidden": result.visibilityHidden = true
      case "visible": result.visibilityHidden = false
      default: throw SVGFailure.invalidAttribute("visibility")
      }
    }
    if let fill = attributes["fill"] { result.fill = try parseColor(fill) }
    if let stroke = attributes["stroke"] { result.stroke = try parseColor(stroke) }
    if let width = attributes["stroke-width"] {
      let parsed = try parseLength(width)
      guard parsed >= 0, parsed <= DustPathStyle.maximumStrokeWidth else {
        throw SVGFailure.invalidAttribute("stroke-width")
      }
      result.strokeWidth = parsed
    }
    if attributes["opacity"] != nil, !allowsOpacity {
      throw SVGFailure.unsupportedAttribute("opacity")
    }
    if let opacity = attributes["fill-opacity"] {
      result.fillOpacity = try parseUnitInterval(opacity)
    }
    if let opacity = attributes["stroke-opacity"] {
      result.strokeOpacity = try parseUnitInterval(opacity)
    }
    if let rule = attributes["fill-rule"] {
      switch rule.lowercased() {
      case "nonzero": result.fillRule = .winding
      case "evenodd": result.fillRule = .evenOdd
      default: throw SVGFailure.invalidAttribute("fill-rule")
      }
    }
    if let cap = attributes["stroke-linecap"] {
      switch cap.lowercased() {
      case "butt": result.lineCap = .butt
      case "round": result.lineCap = .round
      case "square": result.lineCap = .square
      default: throw SVGFailure.invalidAttribute("stroke-linecap")
      }
    }
    if let join = attributes["stroke-linejoin"] {
      switch join.lowercased() {
      case "miter": result.lineJoin = .miter
      case "round": result.lineJoin = .round
      case "bevel": result.lineJoin = .bevel
      default: throw SVGFailure.invalidAttribute("stroke-linejoin")
      }
    }
    return result
  }

  private func makePath(element: String, attributes: [String: String]) throws -> CGPath {
    switch element {
    case "path":
      guard let definition = attributes["d"], !definition.isEmpty else {
        throw SVGFailure.invalidAttribute("path d")
      }
      do {
        return try DustSVGPathParser.parse(definition)
      } catch {
        throw SVGFailure.invalidPath(error.localizedDescription)
      }

    case "rect":
      let x = try optionalLength(attributes["x"])
      let y = try optionalLength(attributes["y"])
      let width = try requiredLength(attributes["width"], name: "rect width")
      let height = try requiredLength(attributes["height"], name: "rect height")
      var rx = try optionalLength(attributes["rx"])
      var ry = try optionalLength(attributes["ry"])
      if attributes["rx"] == nil { rx = ry }
      if attributes["ry"] == nil { ry = rx }
      guard rx >= 0, ry >= 0 else { throw SVGFailure.invalidAttribute("rect corner radius") }
      let path = CGMutablePath()
      path.addRoundedRect(
        in: CGRect(x: x, y: y, width: width, height: height),
        cornerWidth: min(rx, width / 2),
        cornerHeight: min(ry, height / 2)
      )
      return path

    case "circle":
      let cx = try optionalLength(attributes["cx"])
      let cy = try optionalLength(attributes["cy"])
      let r = try requiredLength(attributes["r"], name: "circle r")
      let path = CGMutablePath()
      path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
      return path

    case "ellipse":
      let cx = try optionalLength(attributes["cx"])
      let cy = try optionalLength(attributes["cy"])
      let rx = try requiredLength(attributes["rx"], name: "ellipse rx")
      let ry = try requiredLength(attributes["ry"], name: "ellipse ry")
      let path = CGMutablePath()
      path.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
      return path

    case "line":
      let x1 = try optionalLength(attributes["x1"])
      let y1 = try optionalLength(attributes["y1"])
      let x2 = try optionalLength(attributes["x2"])
      let y2 = try optionalLength(attributes["y2"])
      let path = CGMutablePath()
      path.move(to: CGPoint(x: x1, y: y1))
      path.addLine(to: CGPoint(x: x2, y: y2))
      return path

    case "polyline", "polygon":
      guard let rawPoints = attributes["points"] else {
        throw SVGFailure.invalidAttribute("points")
      }
      let values = try parseNumberList(rawPoints)
      guard values.count >= 2, values.count.isMultiple(of: 2) else {
        throw SVGFailure.invalidAttribute("points")
      }
      let path = CGMutablePath()
      path.move(to: CGPoint(x: values[0], y: values[1]))
      var index = 2
      while index < values.count {
        path.addLine(to: CGPoint(x: values[index], y: values[index + 1]))
        index += 2
      }
      if element == "polygon" { path.closeSubpath() }
      return path

    default:
      throw SVGFailure.unsupportedElement(element)
    }
  }

  private func parseViewBox(_ value: String) throws -> CGRect {
    let values = try parseNumberList(value)
    guard values.count == 4, values[2] > 0, values[3] > 0 else {
      throw SVGFailure.invalidAttribute("viewBox")
    }
    return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
  }

  private func parsePreserveAspectRatio(_ value: String) throws -> DustSVGPreserveAspectRatio {
    let parts = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !parts.isEmpty, parts.first?.lowercased() != "defer" else {
      throw SVGFailure.unsupportedAttribute("preserveAspectRatio defer")
    }
    if parts.count == 1, parts[0].lowercased() == "none" {
      return .none
    }
    guard parts.count == 1 || parts.count == 2 else {
      throw SVGFailure.invalidAttribute("preserveAspectRatio")
    }

    let alignment: DustSVGPreserveAspectRatio.Alignment
    switch parts[0].lowercased() {
    case "xminymin": alignment = .xMinYMin
    case "xmidymin": alignment = .xMidYMin
    case "xmaxymin": alignment = .xMaxYMin
    case "xminymid": alignment = .xMinYMid
    case "xmidymid": alignment = .xMidYMid
    case "xmaxymid": alignment = .xMaxYMid
    case "xminymax": alignment = .xMinYMax
    case "xmidymax": alignment = .xMidYMax
    case "xmaxymax": alignment = .xMaxYMax
    default: throw SVGFailure.invalidAttribute("preserveAspectRatio alignment")
    }

    let scaling: DustSVGPreserveAspectRatio.Scaling
    if parts.count == 1 || parts[1].lowercased() == "meet" {
      scaling = .meet
    } else if parts[1].lowercased() == "slice" {
      scaling = .slice
    } else {
      throw SVGFailure.invalidAttribute("preserveAspectRatio meetOrSlice")
    }
    return .init(alignment: alignment, scaling: scaling)
  }

  private func parseNumberList(_ value: String) throws -> [CGFloat] {
    let scanner = Scanner(string: value)
    scanner.locale = Locale(identifier: "en_US_POSIX")
    scanner.charactersToBeSkipped = CharacterSet.whitespacesAndNewlines.union(
      CharacterSet(charactersIn: ",")
    )
    var values: [CGFloat] = []
    while !scanner.isAtEnd {
      guard let number = scanner.scanDouble(), number.isFinite else {
        throw SVGFailure.invalidAttribute(value)
      }
      values.append(CGFloat(number))
    }
    return values
  }

  private func parsePositiveLength(_ value: String) throws -> CGFloat {
    let parsed = try parseLength(value)
    guard parsed > 0 else { throw SVGFailure.invalidAttribute(value) }
    return parsed
  }

  private func parseLength(_ value: String) throws -> CGFloat {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.hasSuffix("%") {
      throw SVGFailure.unsupportedAttribute(value)
    }
    let scanner = Scanner(string: trimmed)
    scanner.locale = Locale(identifier: "en_US_POSIX")
    guard let number = scanner.scanDouble(), number.isFinite else {
      throw SVGFailure.invalidAttribute(value)
    }
    let unit = String(trimmed[scanner.currentIndex...]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard unit.isEmpty || unit == "px" else {
      throw SVGFailure.unsupportedAttribute("unit \(unit)")
    }
    return CGFloat(number)
  }

  private func optionalLength(_ value: String?) throws -> CGFloat {
    guard let value else { return 0 }
    return try parseLength(value)
  }

  private func requiredLength(_ value: String?, name: String) throws -> CGFloat {
    guard let value else { throw SVGFailure.invalidAttribute(name) }
    let result = try parseLength(value)
    guard result >= 0 else { throw SVGFailure.invalidAttribute(name) }
    return result
  }

  private func parseUnitInterval(_ value: String) throws -> CGFloat {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let result: CGFloat
    if trimmed.hasSuffix("%") {
      guard let percent = Double(trimmed.dropLast()), percent.isFinite else {
        throw SVGFailure.invalidAttribute(value)
      }
      result = CGFloat(percent / 100)
    } else {
      guard let number = Double(trimmed), number.isFinite else {
        throw SVGFailure.invalidAttribute(value)
      }
      result = CGFloat(number)
    }
    guard result >= 0, result <= 1 else { throw SVGFailure.invalidAttribute(value) }
    return result
  }

  private func parseColor(_ raw: String) throws -> UIColor? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value == "none" { return nil }
    if value == "transparent" { return UIColor.clear }
    if value.hasPrefix("url(") || value == "currentcolor" {
      throw SVGFailure.unsupportedAttribute(raw)
    }
    if let mapped = DustSVGColors.named[value] {
      return try parseHexColor(mapped)
    }
    if value.hasPrefix("#") {
      return try parseHexColor(value)
    }
    if value.hasPrefix("rgb(") || value.hasPrefix("rgba(") {
      guard let open = value.firstIndex(of: "("), value.last == ")" else {
        throw SVGFailure.invalidAttribute(raw)
      }
      let body = String(value[value.index(after: open)..<value.index(before: value.endIndex)])
      let parts = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      let expected = value.hasPrefix("rgba(") ? 4 : 3
      guard parts.count == expected else { throw SVGFailure.invalidAttribute(raw) }

      func component(_ text: String) throws -> CGFloat {
        if text.hasSuffix("%") {
          guard let value = Double(text.dropLast()), value.isFinite, value >= 0, value <= 100 else {
            throw SVGFailure.invalidAttribute(raw)
          }
          return CGFloat(value / 100)
        }
        guard let value = Double(text), value.isFinite, value >= 0, value <= 255 else {
          throw SVGFailure.invalidAttribute(raw)
        }
        return CGFloat(value / 255)
      }

      let r = try component(parts[0])
      let g = try component(parts[1])
      let b = try component(parts[2])
      let a = expected == 4 ? try parseUnitInterval(parts[3]) : 1
      return UIColor(red: r, green: g, blue: b, alpha: a)
    }
    throw SVGFailure.unsupportedAttribute(raw)
  }

  private func parseHexColor(_ value: String) throws -> UIColor {
    let hex = String(value.dropFirst())
    let expanded: String
    switch hex.count {
    case 3, 4:
      expanded = hex.map { "\($0)\($0)" }.joined()
    case 6, 8:
      expanded = hex
    default:
      throw SVGFailure.invalidAttribute(value)
    }
    guard let number = UInt64(expanded, radix: 16) else {
      throw SVGFailure.invalidAttribute(value)
    }
    let hasAlpha = expanded.count == 8
    let r = CGFloat((number >> (hasAlpha ? 24 : 16)) & 0xff) / 255
    let g = CGFloat((number >> (hasAlpha ? 16 : 8)) & 0xff) / 255
    let b = CGFloat((number >> (hasAlpha ? 8 : 0)) & 0xff) / 255
    let a = hasAlpha ? CGFloat(number & 0xff) / 255 : 1
    return UIColor(red: r, green: g, blue: b, alpha: a)
  }

  private func parseTransform(_ value: String) throws -> CGAffineTransform {
    var remaining = value[...]
    var transform = CGAffineTransform.identity

    while true {
      remaining = remaining.drop(while: { $0.isWhitespace || $0 == "," })
      guard !remaining.isEmpty else { break }
      guard let open = remaining.firstIndex(of: "(") else {
        throw SVGFailure.invalidAttribute("transform")
      }
      let command = remaining[..<open]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      guard let close = remaining[remaining.index(after: open)...].firstIndex(of: ")") else {
        throw SVGFailure.invalidAttribute("transform")
      }
      let body = String(remaining[remaining.index(after: open)..<close])
      let operands = try parseNumberList(body)
      let additional: CGAffineTransform

      switch command {
      case "matrix" where operands.count == 6:
        additional = .init(
          a: operands[0], b: operands[1], c: operands[2],
          d: operands[3], tx: operands[4], ty: operands[5]
        )
      case "translate" where operands.count == 1 || operands.count == 2:
        additional = .init(
          translationX: operands[0],
          y: operands.count == 2 ? operands[1] : 0
        )
      case "scale" where operands.count == 1 || operands.count == 2:
        additional = .init(
          scaleX: operands[0],
          y: operands.count == 2 ? operands[1] : operands[0]
        )
      case "rotate" where operands.count == 1:
        additional = .init(rotationAngle: operands[0] * .pi / 180)
      case "rotate" where operands.count == 3:
        let radians = operands[0] * .pi / 180
        additional = CGAffineTransform(translationX: operands[1], y: operands[2])
          .rotated(by: radians)
          .translatedBy(x: -operands[1], y: -operands[2])
      case "skewx" where operands.count == 1:
        additional = .init(
          a: 1, b: 0, c: tan(operands[0] * .pi / 180), d: 1, tx: 0, ty: 0
        )
      case "skewy" where operands.count == 1:
        additional = .init(
          a: 1, b: tan(operands[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0
        )
      default:
        throw SVGFailure.invalidAttribute("transform \(command)")
      }
      guard additional.isFinite else { throw SVGFailure.invalidAttribute("transform") }
      transform = CGAffineTransformConcat(additional, transform)
      guard transform.isFinite else { throw SVGFailure.invalidAttribute("transform") }
      remaining = remaining[remaining.index(after: close)...]
    }
    return transform
  }
}

extension CGRect {
  fileprivate var isFinite: Bool {
    minX.isFinite && minY.isFinite && width.isFinite && height.isFinite
  }
}

extension CGAffineTransform {
  fileprivate var isFinite: Bool {
    a.isFinite && b.isFinite && c.isFinite && d.isFinite && tx.isFinite && ty.isFinite
  }
}
#endif
