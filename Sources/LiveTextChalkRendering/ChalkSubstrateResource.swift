import CoreGraphics
import Foundation
import ImageIO
import LiveTextEffects
import SwiftUI

/// Decoder for the public chalk substrate microtexture families.
/// Runtime chalk rendering is owned by `ChalkMaskRenderer`; these images are bounded material
/// inputs and never form a second rendering path.
package enum ChalkSubstrateResource {
  package static func image(for style: WritingChalkTextureStyle) -> Image {
    Image(decorative: cgImage(for: style), scale: 1)
  }

  package static func cgImage(for style: WritingChalkTextureStyle) -> CGImage {
    guard let image = cache[style] else {
      preconditionFailure("No canonical LiveText chalk texture registered for \(style)")
    }
    return image
  }

  package static func coverageMask(for style: WritingChalkTextureStyle) throws -> CGImage {
    let data = try WritingChalkTextureResource.data(for: style)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == WritingChalkTextureResource.pixelDimension,
      image.height == WritingChalkTextureResource.pixelDimension,
      let mask = makeCoverageMask(from: image, style: style)
    else {
      throw WritingMaterialError.unreadableResource(WritingChalkTextureResource.name(for: style))
    }
    return mask
  }

  private static let cache: [WritingChalkTextureStyle: CGImage] = {
    Dictionary(
      uniqueKeysWithValues: WritingChalkTextureStyle.allCases.map { style in
        do {
          return (style, try coverageMask(for: style))
        } catch {
          preconditionFailure("Unable to prepare LiveText chalk texture \(style): \(error)")
        }
      })
  }()

  private static func makeCoverageMask(
    from image: CGImage,
    style: WritingChalkTextureStyle
  ) -> CGImage? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0, width <= Int.max / height,
      width * height <= Int.max / 4,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }

    var sourcePixels = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let sourceContext = CGContext(
        data: &sourcePixels, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else { return nil }
    sourceContext.interpolationQuality = .high
    sourceContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var sourceCoverage = [Double](repeating: 0, count: width * height)
    for index in stride(from: 0, to: sourcePixels.count, by: 4) {
      let alpha = Double(sourcePixels[index + 3]) / 255
      let red = alpha > 0 ? min(1, Double(sourcePixels[index]) / 255 / alpha) : 0
      let green = alpha > 0 ? min(1, Double(sourcePixels[index + 1]) / 255 / alpha) : 0
      let blue = alpha > 0 ? min(1, Double(sourcePixels[index + 2]) / 255 / alpha) : 0
      sourceCoverage[index / 4] = (0.2126 * red + 0.7152 * green + 0.0722 * blue) * alpha
    }

    var maskPixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let sourceIndex = y * width + x
        let rawCoverage = sourceCoverage[sourceIndex]
        let coverage: Double
        switch style {
        case .fineGrain:
          var localMaximum = 0.0
          for offsetY in -2...2 {
            for offsetX in -2...2 {
              let neighborX = min(width - 1, max(0, x + offsetX))
              let neighborY = min(height - 1, max(0, y + offsetY))
              localMaximum = max(localMaximum, sourceCoverage[neighborY * width + neighborX])
            }
          }
          coverage = min(1, 0.06 + max(rawCoverage, localMaximum) * 1.20)
        case .photographic:
          coverage = min(1, rawCoverage * 1.15)
        case .referenceSampled:
          coverage = min(1, rawCoverage * 1.20)
        }
        let destinationIndex = sourceIndex * 4
        maskPixels[destinationIndex] = 255
        maskPixels[destinationIndex + 1] = 255
        maskPixels[destinationIndex + 2] = 255
        maskPixels[destinationIndex + 3] = UInt8(max(0, min(255, (coverage * 255).rounded())))
      }
    }

    guard let provider = CGDataProvider(data: Data(maskPixels) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}
