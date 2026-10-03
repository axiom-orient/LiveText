import Foundation
import LiveTextLayout

/// Failures specific to conversion from the canonical SVG document into an
/// inline asset.
public enum LiveTextSVGInlineAdapterError: Error, Equatable, LocalizedError, Sendable {
  case invalidAssetVersion(Int)
  case invalidBundle(String)
  case unsupportedPaint(String)

  public var errorDescription: String? {
    switch self {
    case .invalidAssetVersion(let version): return "Invalid SVG asset version \(version)."
    case .invalidBundle(let message): return "Invalid SVG inline bundle: \(message)."
    case .unsupportedPaint(let reason): return "SVG paint is unsupported: \(reason)."
    }
  }
}

/// The geometry-only result of importing one SVG document. Coverage and
/// trajectory are stored once in one asset addressed by the one vector atom.
public struct LiveTextSVGInlineDocument: Sendable {
  public let document: InlineDocument
  public let asset: InlineSVGAsset
  public let size: LiveTextSVGSize

  public init(document: InlineDocument, asset: InlineSVGAsset, size: LiveTextSVGSize) throws {
    guard document.atoms.count == 1 else {
      throw LiveTextSVGInlineAdapterError.invalidBundle("an SVG document must contain one atom")
    }
    guard case .vector(let vector) = document.atoms[0],
      vector.assetID == asset.id,
      vector.assetVersion == asset.version,
      vector.metrics == asset.metrics
    else {
      throw LiveTextSVGInlineAdapterError.invalidBundle("asset and vector atom differ")
    }
    guard asset.coordinateBounds.minX == 0,
      asset.coordinateBounds.minY == 0,
      asset.coordinateBounds.maxX == size.width,
      asset.coordinateBounds.maxY == size.height
    else {
      throw LiveTextSVGInlineAdapterError.invalidBundle("asset coordinate bounds and size differ")
    }
    self.document = document
    self.asset = asset
    self.size = size
  }
}

/// Converts one validated, renderer-neutral SVG document into one inline
/// vector asset and one vector atom.
public enum LiveTextSVGInlineAdapter {
  public static func convert(
    source: String,
    id: InlineAssetID,
    metrics: InlineMetrics,
    version: Int,
    accessibilityLabel: String? = nil,
    options: LiveTextSVGImportOptions = .default
  ) throws -> LiveTextSVGInlineDocument {
    try convert(
      imported: LiveTextSVGImporter.document(from: source, options: options),
      id: id,
      metrics: metrics,
      version: version,
      accessibilityLabel: accessibilityLabel
    )
  }

  public static func convert(
    data: Data,
    id: InlineAssetID,
    metrics: InlineMetrics,
    version: Int,
    accessibilityLabel: String? = nil,
    options: LiveTextSVGImportOptions = .default
  ) throws -> LiveTextSVGInlineDocument {
    try convert(
      imported: LiveTextSVGImporter.document(from: data, options: options),
      id: id,
      metrics: metrics,
      version: version,
      accessibilityLabel: accessibilityLabel
    )
  }

  private static func convert(
    imported: LiveTextSVGImportedDocument,
    id: InlineAssetID,
    metrics: InlineMetrics,
    version: Int,
    accessibilityLabel: String?
  ) throws -> LiveTextSVGInlineDocument {
    guard version >= 0 else {
      throw LiveTextSVGInlineAdapterError.invalidAssetVersion(version)
    }
    let coordinateBounds = try InlinePathBounds(
      minX: imported.coordinateBounds.minX,
      minY: imported.coordinateBounds.minY,
      maxX: imported.coordinateBounds.maxX,
      maxY: imported.coordinateBounds.maxY
    )
    let coveragePath = try InlinePathData(commands: try imported.coverageCommands.map(convert(_:)))
    let trajectoryPath = try InlinePathData(
      commands: try imported.trajectoryCommands.map(convert(_:)))
    let coveragePaint: InlineSVGCoveragePaint
    switch imported.coveragePaint {
    case .fill(let rule):
      coveragePaint = .fill(rule == .nonZero ? .nonZero : .evenOdd)
    case .stroke(let style):
      coveragePaint = .stroke(try convert(style))
    }
    let trajectoryStyle = try convert(imported.trajectoryStyle)
    let asset = try InlineSVGAsset(
      id: id,
      version: version,
      metrics: metrics,
      coordinateBounds: coordinateBounds,
      coveragePath: coveragePath,
      coveragePaint: coveragePaint,
      trajectoryPath: trajectoryPath,
      trajectoryStyle: trajectoryStyle,
      accessibilityLabel: accessibilityLabel
    )
    let atom = try InlineVectorAtom(id: id.rawValue, asset: asset)
    return try LiveTextSVGInlineDocument(
      document: try InlineDocument(atoms: [.vector(atom)]),
      asset: asset,
      size: imported.size
    )
  }

  private static func convert(_ command: LiveTextSVGCommand) throws -> InlinePathCommand {
    switch command {
    case .move(let point): return .move(try InlinePathPoint(x: point.x, y: point.y))
    case .line(let point): return .line(try InlinePathPoint(x: point.x, y: point.y))
    case .quadratic(let control, let point):
      return .quadratic(
        control: try InlinePathPoint(x: control.x, y: control.y),
        to: try InlinePathPoint(x: point.x, y: point.y)
      )
    case .cubic(let control1, let control2, let point):
      return .cubic(
        control1: try InlinePathPoint(x: control1.x, y: control1.y),
        control2: try InlinePathPoint(x: control2.x, y: control2.y),
        to: try InlinePathPoint(x: point.x, y: point.y)
      )
    case .close: return .close
    }
  }

  private static func convert(_ style: LiveTextSVGStrokeStyle) throws -> InlineSVGStrokeStyle {
    if let color = style.color, color != .black {
      throw LiveTextSVGInlineAdapterError.unsupportedPaint(
        "only opaque black source pigment is representable")
    }
    return try InlineSVGStrokeStyle(
      width: style.width,
      cap: convert(style.lineCap),
      join: convert(style.lineJoin),
      miterLimit: style.miterLimit
    )
  }

  private static func convert(_ cap: LiveTextSVGLineCap) -> InlineSVGLineCap {
    switch cap {
    case .butt: return .butt
    case .round: return .round
    case .square: return .square
    }
  }

  private static func convert(_ join: LiveTextSVGLineJoin) -> InlineSVGLineJoin {
    switch join {
    case .miter: return .miter
    case .round: return .round
    case .bevel: return .bevel
    }
  }
}
