import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// Image ownership for the Apple-only chalk renderer.
///
/// LiveTextEffects remains the authority for LiveText's existing three public
/// textures. This target separately owns ChalkStroke's advanced surface, tip
/// and support assets; the two resource sets serve different contracts.
package enum ChalkRenderResources {
  package static func surfaceImage(for style: ChalkRenderStyle) -> Image {
    BundleImageCache.image(named: style.surfaceResourceName)
  }

  package static func tipImage(style: ChalkRenderStyle, variant: Int) -> Image {
    guard let prefix = style.tipResourcePrefix else {
      preconditionFailure("Surface-only chalk material requested a contact tip")
    }
    let boundedVariant = variant & 3
    let name = "\(prefix)-\(boundedVariant)"
    return BundleImageCache.image(named: name)
  }

  package static var boardToothImage: Image {
    BundleImageCache.image(named: "chalk-board-tooth")
  }

  private enum BundleImageCache {
    static let images: [String: Image] = {
      let names = [
        "chalk-board-tooth",
        "chalk-surface-fine-line", "chalk-surface-dry-brush",
        "chalk-surface-powder-fill", "chalk-surface-smudged",
        "chalk-tip-fine-line-0", "chalk-tip-fine-line-1",
        "chalk-tip-fine-line-2", "chalk-tip-fine-line-3",
        "chalk-tip-dry-brush-0", "chalk-tip-dry-brush-1",
        "chalk-tip-dry-brush-2", "chalk-tip-dry-brush-3",
      ]
      return Dictionary(uniqueKeysWithValues: names.map { name in
        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else {
          preconditionFailure("Missing LiveText chalk renderer resource: \(name).png")
        }
        do {
          let data = try Data(contentsOf: url, options: [.mappedIfSafe])
          return (name, try decodeImage(data: data, name: name))
        } catch {
          preconditionFailure("Unable to decode LiveText chalk renderer resource \(name): \(error)")
        }
      })
    }()

    static func image(named name: String) -> Image {
      guard let image = images[name] else {
        preconditionFailure("Unknown LiveText chalk renderer resource: \(name)")
      }
      return image
    }
  }

  private static func decodeImage(data: Data, name: String) throws -> Image {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw ChalkRenderResourceError.invalidImage(name)
    }
    return Image(decorative: cgImage, scale: 1, orientation: .up)
  }
}

private enum ChalkRenderResourceError: Error {
  case invalidImage(String)
}

private extension ChalkRenderStyle {
  var surfaceResourceName: String {
    switch self {
    case .fineLine: return "chalk-surface-fine-line"
    case .dryBrush: return "chalk-surface-dry-brush"
    case .powderFill, .diagonalHatch, .crossHatch: return "chalk-surface-powder-fill"
    case .smudged: return "chalk-surface-smudged"
    }
  }

  var tipResourcePrefix: String? {
    switch self {
    case .fineLine: return "chalk-tip-fine-line"
    case .dryBrush: return "chalk-tip-dry-brush"
    case .powderFill, .diagonalHatch, .crossHatch, .smudged: return nil
    }
  }
}
