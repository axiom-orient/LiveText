#if os(macOS)
import Foundation
import Testing

struct PackageManifestTests {
  @Test
  func explicitDemoExclusionDoesNotChangeLibrariesOrTests() throws {
    let normal = try dumpManifest(excludeDemo: false)
    let librariesOnly = try dumpManifest(excludeDemo: true)
    let normalAgain = try dumpManifest(excludeDemo: false)

    #expect(normal.products.contains { $0.name == "LiveTextDemo" })
    #expect(normal.targets.contains { $0.name == "LiveTextDemo" })
    #expect(!librariesOnly.products.contains { $0.name == "LiveTextDemo" })
    #expect(!librariesOnly.targets.contains { $0.name == "LiveTextDemo" })
    #expect(normal.libraryNames == librariesOnly.libraryNames)
    #expect(normal.testTargetNames == librariesOnly.testTargetNames)
    #expect(normal.productNames == normalAgain.productNames)
    #expect(normal.targetNames == normalAgain.targetNames)
  }

  private func dumpManifest(excludeDemo: Bool) throws -> Manifest {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("livetext-manifest-\(UUID().uuidString)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "swift", "package", "--package-path", root.path,
      "--scratch-path", scratch.path, "dump-package",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "LIVETEXT_EXCLUDE_MACOS_DEMO")
    if excludeDemo { environment["LIVETEXT_EXCLUDE_MACOS_DEMO"] = "1" }
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ManifestError.commandFailed(process.terminationStatus)
    }
    return try JSONDecoder().decode(Manifest.self, from: data)
  }

  private enum ManifestError: Error { case commandFailed(Int32) }

  private struct Manifest: Decodable {
    struct Product: Decodable {
      let name: String
      let type: [String: [String]?]
    }
    struct Target: Decodable {
      let name: String
      let type: String
    }
    let products: [Product]
    let targets: [Target]
    var productNames: Set<String> { Set(products.map(\.name)) }
    var targetNames: Set<String> { Set(targets.map(\.name)) }
    var libraryNames: Set<String> {
      Set(products.filter { $0.type["library"] != nil }.map(\.name))
    }
    var testTargetNames: Set<String> {
      Set(targets.filter { $0.type == "test" }.map(\.name))
    }
  }
}
#endif
