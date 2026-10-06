import ChalkLineEffects
import Foundation
import LiveTextEffects
import SwiftUI

/// Measures real preparation and raster work separately from PNG/disk I/O.
@MainActor
enum DemoBenchmark {
  static func run(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var reports: [[String: Any]] = []
    let phrase = "한글 ABC 곡선 OQ89"
    for (workload, text) in [("normal", phrase), ("paragraph", String(repeating: phrase + "\n", count: 6))] {
      for chalk in [WritingChalkStyle.dryBrush, .fineLine] {
        let start = ContinuousClock.now
        let content = try DemoContent(text: text, height: 72, chalk: chalk)
        let preparationMS = milliseconds(since: start)
        var construction: [Double] = []
        var render: [Double] = []
        var checksum: UInt64 = 0
        for index in 0..<70 {
          let viewStart = ContinuousClock.now
          let view = ChalkWritingText(preparation: content.preparation, style: content.style,
                                      motion: .uniform, progress: Double(index % 10 + 1) / 10)
            .frame(width: 680, height: 240)
          let constructionMS = milliseconds(since: viewStart)
          let rasterStart = ContinuousClock.now
          let renderer = ImageRenderer(content: view)
          renderer.scale = 2
          guard let image = renderer.cgImage else { throw DemoExportError.missingBitmap }
          // Consume the real image; missing/empty output must fail the workload.
          guard let bytes = image.dataProvider?.data, CFDataGetLength(bytes) > 0 else {
            throw DemoExportError.missingBitmap
          }
          let rasterMS = milliseconds(since: rasterStart)
          checksum &+= UInt64(CFDataGetLength(bytes))
          if index >= 10 { construction.append(constructionMS); render.append(rasterMS) }
        }
        let strokeCount = content.preparation.scene.glyphs.reduce(0) { $0 + $1.strokes.count }
        reports.append([
          "workload": workload, "style": chalk.rawValue, "samples": render.count, "warmup": 10,
          "text": content.preparation.scene.text, "strokeCount": strokeCount,
          "width": 680, "height": 240, "scale": 2, "checksum": checksum,
          "semanticPreparationMS": preparationMS,
          "viewConstructionMS": statistics(construction), "rasterMS": statistics(render),
        ])
      }
    }
    let result: [String: Any] = [
      "workloads": reports,
      "measurement": "Synchronous SwiftUI ImageRenderer plus bitmap data materialization; no PNG encoding or disk I/O in timed regions.",
      "limitation": "CPU/offscreen raster timing, not device display FPS or dropped frames."
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: directory.appendingPathComponent("benchmark.json"), options: .atomic)
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let value = start.duration(to: .now).components
    return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
  }

  private static func statistics(_ samples: [Double]) -> [String: Double] {
    let sorted = samples.sorted()
    return ["median": sorted[sorted.count / 2],
            "p95": sorted[Int(Double(sorted.count - 1) * 0.95)], "max": sorted.last ?? 0]
  }
}
