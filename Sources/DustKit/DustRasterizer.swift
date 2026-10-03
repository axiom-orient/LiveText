#if os(iOS)
import CoreGraphics
import CoreText
import Foundation
import UIKit

enum DustRasterizer {
  private struct DecodedRGBA {
    let image: CGImage
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int
  }

  static func image(_ image: UIImage) throws -> DustRaster {
    guard image.size.width.isFinite, image.size.height.isFinite,
      image.size.width > 0, image.size.height > 0,
      image.scale.isFinite, image.scale > 0
    else {
      throw DustError.invalidImage
    }

    let normalized: UIImage
    if image.imageOrientation == .up, image.cgImage != nil {
      normalized = image
    } else {
      let scale = max(image.scale, 1)
      try DustResourceLimits.validateRaster(size: image.size, scale: scale, operation: "image")
      let format = UIGraphicsImageRendererFormat()
      format.scale = scale
      format.opaque = false
      format.preferredRange = .standard
      normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: image.size))
      }
    }
    return try canonicalCrop(normalized, operation: "image")
  }

  static func snapshot(_ image: CGImage, scale: CGFloat) throws -> DustRaster {
    try validateScale(scale, operation: "snapshot")
    let decoded = try decodeRGBA(image, operation: "snapshot")
    let alphaMask = DustAlphaMask(
      width: decoded.width,
      height: decoded.height,
      rgba: decoded.pixels,
      bytesPerRow: decoded.bytesPerRow
    )
    guard alphaMask.visiblePixelCount > 0 else {
      throw DustError.emptyContent(operation: "snapshot")
    }

    return DustRaster(
      image: decoded.image,
      alphaMask: alphaMask,
      canvasSize: CGSize(
        width: CGFloat(decoded.width) / scale,
        height: CGFloat(decoded.height) / scale
      ),
      scale: scale
    )
  }

  static func text(
    _ text: NSAttributedString,
    maxWidth: CGFloat?,
    scale: CGFloat
  ) throws -> DustRaster {
    guard text.length > 0 else {
      throw DustError.emptyContent(operation: "text")
    }
    try validateScale(scale, operation: "text")
    if let maxWidth {
      guard maxWidth.isFinite, maxWidth > 0 else {
        throw DustError.invalidConfiguration(reason: "text maxWidth must be finite and positive")
      }
    }

    let framesetter = CTFramesetterCreateWithAttributedString(text)
    let widthConstraint = maxWidth ?? CGFloat(DustResourceLimits.maximumRasterDimension) / scale
    var fitRange = CFRange()
    let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
      framesetter,
      CFRange(location: 0, length: text.length),
      nil,
      CGSize(width: widthConstraint, height: .greatestFiniteMagnitude),
      &fitRange
    )
    guard suggested.width.isFinite, suggested.height.isFinite,
      suggested.width > 0, suggested.height > 0
    else {
      throw DustError.emptyContent(operation: "text")
    }

    let padding = max(1, 2 / scale)
    let size = CGSize(
      width: ceil(min(suggested.width, widthConstraint)) + padding * 2,
      height: ceil(suggested.height) + padding * 2
    )
    try DustResourceLimits.validateRaster(size: size, scale: scale, operation: "text")

    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    format.preferredRange = .standard
    let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
      let context = renderer.cgContext
      context.saveGState()
      context.translateBy(x: 0, y: size.height)
      context.scaleBy(x: 1, y: -1)
      let framePath = CGPath(
        rect: CGRect(
          x: padding,
          y: padding,
          width: size.width - padding * 2,
          height: size.height - padding * 2
        ),
        transform: nil
      )
      let frame = CTFramesetterCreateFrame(
        framesetter,
        CFRange(location: 0, length: text.length),
        framePath,
        nil
      )
      CTFrameDraw(frame, context)
      context.restoreGState()
    }
    return try canonicalCrop(image, operation: "text")
  }

  static func path(
    _ path: CGPath,
    style: DustPathStyle,
    scale: CGFloat
  ) throws -> DustRaster {
    guard !path.isEmpty else {
      throw DustError.emptyContent(operation: "path")
    }
    guard style.fill != nil || (style.stroke != nil && style.strokeWidth > 0) else {
      throw DustError.emptyContent(operation: "path paint")
    }
    try validateScale(scale, operation: "path")

    var paintedBounds = CGRect.null
    if style.fill != nil {
      paintedBounds = paintedBounds.union(path.boundingBoxOfPath)
    }
    if style.stroke != nil, style.strokeWidth > 0 {
      let stroked = path.copy(
        strokingWithWidth: style.strokeWidth,
        lineCap: .butt,
        lineJoin: .miter,
        miterLimit: 10
      )
      paintedBounds = paintedBounds.union(stroked.boundingBoxOfPath)
    }

    let antialiasPadding = max(1, 2 / scale)
    let bounds = paintedBounds.insetBy(dx: -antialiasPadding, dy: -antialiasPadding)
    guard bounds.minX.isFinite, bounds.minY.isFinite,
      bounds.width.isFinite, bounds.height.isFinite,
      bounds.width > 0, bounds.height > 0
    else {
      throw DustError.invalidConfiguration(reason: "path bounds must be finite and nonempty")
    }

    let size = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    try DustResourceLimits.validateRaster(size: size, scale: scale, operation: "path")

    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    format.preferredRange = .standard
    let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
      let context = renderer.cgContext
      context.translateBy(x: -bounds.minX, y: -bounds.minY)
      context.setAllowsAntialiasing(true)
      context.setShouldAntialias(true)
      if let fill = style.fill {
        context.addPath(path)
        context.setFillColor(fill.cgColor)
        context.fillPath()
      }
      if let stroke = style.stroke, style.strokeWidth > 0 {
        context.addPath(path)
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(style.strokeWidth)
        context.setLineCap(.butt)
        context.setLineJoin(.miter)
        context.setMiterLimit(10)
        context.strokePath()
      }
    }
    return try canonicalCrop(image, operation: "path")
  }

  static func svg(_ data: Data, scale: CGFloat) throws -> DustRaster {
    try validateScale(scale, operation: "SVG")
    guard data.count <= DustResourceLimits.maximumSVGBytes else {
      throw DustError.resourceLimitExceeded(
        operation: "SVG",
        reason: "input exceeds \(DustResourceLimits.maximumSVGBytes) bytes"
      )
    }
    let document = try DustSVGParser.parse(data: data)
    return try document.raster(scale: scale)
  }

  static func canonicalCrop(_ image: UIImage, operation: String) throws -> DustRaster {
    guard image.scale.isFinite, image.scale > 0, let source = image.cgImage else {
      throw DustError.rasterizationFailed(operation: operation)
    }

    let decoded = try decodeRGBA(source, operation: operation)
    let width = decoded.width
    let height = decoded.height
    let bytesPerPixel = 4
    let bytesPerRow = decoded.bytesPerRow
    let pixels = decoded.pixels

    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    let alphaThreshold: UInt8 = 1
    for y in 0..<height {
      let row = y * bytesPerRow
      for x in 0..<width where pixels[row + x * bytesPerPixel + 3] > alphaThreshold {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else {
      throw DustError.emptyContent(operation: operation)
    }

    minX = max(minX - 1, 0)
    minY = max(minY - 1, 0)
    maxX = min(maxX + 1, width - 1)
    maxY = min(maxY + 1, height - 1)

    let scale = image.scale
    if minX == 0, minY == 0, maxX == width - 1, maxY == height - 1 {
      return DustRaster(
        image: decoded.image,
        alphaMask: DustAlphaMask(
          width: width,
          height: height,
          rgba: pixels,
          bytesPerRow: bytesPerRow
        ),
        canvasSize: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale),
        scale: scale
      )
    }

    let croppedWidth = maxX - minX + 1
    let croppedHeight = maxY - minY + 1
    let croppedBytesPerRow = croppedWidth * bytesPerPixel
    var croppedPixels = [UInt8](repeating: 0, count: croppedBytesPerRow * croppedHeight)
    croppedPixels.withUnsafeMutableBytes { destination in
      pixels.withUnsafeBytes { sourceBytes in
        guard let destinationBase = destination.baseAddress,
          let sourceBase = sourceBytes.baseAddress
        else { return }
        for row in 0..<croppedHeight {
          memcpy(
            destinationBase.advanced(by: row * croppedBytesPerRow),
            sourceBase.advanced(by: (minY + row) * bytesPerRow + minX * bytesPerPixel),
            croppedBytesPerRow
          )
        }
      }
    }

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw DustError.rasterizationFailed(operation: operation)
    }
    guard
      let croppedContext = CGContext(
        data: &croppedPixels,
        width: croppedWidth,
        height: croppedHeight,
        bitsPerComponent: 8,
        bytesPerRow: croppedBytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue
      ), let cropped = croppedContext.makeImage()
    else {
      throw DustError.rasterizationFailed(operation: "\(operation) alpha crop")
    }

    return DustRaster(
      image: cropped,
      alphaMask: DustAlphaMask(
        width: croppedWidth,
        height: croppedHeight,
        rgba: croppedPixels,
        bytesPerRow: croppedBytesPerRow
      ),
      canvasSize: CGSize(
        width: CGFloat(croppedWidth) / scale,
        height: CGFloat(croppedHeight) / scale
      ),
      scale: scale
    )
  }

  private static func decodeRGBA(_ image: CGImage, operation: String) throws -> DecodedRGBA {
    let width = image.width
    let height = image.height
    try DustResourceLimits.validateRaster(
      widthPixels: width,
      heightPixels: height,
      operation: operation
    )

    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw DustError.rasterizationFailed(operation: operation)
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let normalized = context.makeImage() else {
      throw DustError.rasterizationFailed(operation: operation)
    }

    return DecodedRGBA(
      image: normalized,
      pixels: pixels,
      width: width,
      height: height,
      bytesPerRow: bytesPerRow
    )
  }

  private static func validateScale(_ scale: CGFloat, operation: String) throws {
    guard scale.isFinite, scale >= 1 else {
      throw DustError.invalidConfiguration(reason: "\(operation) scale must be finite and >= 1")
    }
  }
}
#endif
