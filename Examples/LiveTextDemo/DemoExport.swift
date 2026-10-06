import ChalkLineEffects
import Foundation
import ImageIO
import LiveTextEffects
import LiveTextWritingUI
import SwiftUI
import UniformTypeIdentifiers

enum DemoExportError: Error {
  case missingBitmap
  case cannotCreateDestination(URL)
  case cannotWriteBitmap(URL)
  case missingExportDirectory
}

@MainActor
enum DemoExport {
  static func write<V: View>(_ view: V, to url: URL) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage else { throw DemoExportError.missingBitmap }
    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { throw DemoExportError.cannotCreateDestination(url) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw DemoExportError.cannotWriteBitmap(url) }
  }

  static func exportAll(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let frames = directory.appendingPathComponent("frames", isDirectory: true)
    try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
    let samples = try [WritingChalkStyle.fineLine, .dryBrush].flatMap { style in
      try WritingChalkTextureStyle.allCases.map { texture in
        (style.label + " · " + texture.label, try DemoContent(chalk: style, texture: texture))
      }
    }
    try write(DemoGallery(samples: samples), to: directory.appendingPathComponent("gallery.png"))
    try write(DemoGallery(samples: [samples[0], samples[3]]),
              to: directory.appendingPathComponent("preview.png"))
    let content = try DemoContent(text: "안녕하세요\nLiveText", height: 72)
    var frameTimes: [Double] = []
    for frame in 0...24 {
      let start = ContinuousClock.now
      try write(DemoSample(content: content, progress: Double(frame) / 24),
                to: frames.appendingPathComponent(String(format: "frame-%03d.png", frame)))
      let elapsed = start.duration(to: .now).components
      frameTimes.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
    }
    try write(DemoBoard {
      LiveTextWritingRenderer(content: content.scene.swiftUIContent,
                              viewport: content.scene.viewport, configuration: content.configuration)
        .frame(width: 680, height: 120)
    }, to: directory.appendingPathComponent("inline.png"))
    let report: [String: Any] = [
      "renderer": "SwiftUI.ImageRenderer", "scale": 2, "frameCount": frameTimes.count,
      "frameExportMilliseconds": frameTimes,
      "note": "Includes PNG encoding and disk I/O; this is not display FPS."
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: directory.appendingPathComponent("export-metrics.json"), options: .atomic)
  }
}

private struct DemoGallery: View {
  let samples: [(String, DemoContent)]

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text("LiveText · 실제 분필 출력").font(.system(size: 30, weight: .semibold))
      Text("한글과 영문 · 두 분필 재질 · 세 텍스처").foregroundStyle(.secondary)
      ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
        VStack(alignment: .leading, spacing: 8) {
          Text(sample.0).font(.system(size: 15, weight: .medium))
          DemoSample(content: sample.1, progress: 1)
        }
      }
    }
    .padding(32)
    .background(Color(red: 0.95, green: 0.95, blue: 0.93))
    .environment(\.colorScheme, .light)
  }
}

extension WritingChalkStyle {
  var label: String {
    switch self {
    case .fineLine: "가는 분필"
    case .dryBrush: "마른 분필"
    case .powderFill: "분말 채움"
    case .diagonalHatch: "사선"
    case .crossHatch: "교차선"
    case .smudged: "번짐"
    }
  }
}

extension WritingChalkTextureStyle {
  var label: String {
    switch self {
    case .fineGrain: "미세 입자"
    case .photographic: "사진 질감"
    case .referenceSampled: "참조 질감"
    }
  }
}
