// swift-tools-version: 6.0

import PackageDescription

var products: [Product] = [
  .library(name: "LiveTextSVG", targets: ["LiveTextSVG"]),
]

var targets: [Target] = [
  .target(
    name: "LiveText",
    dependencies: ["LiveTextCore", "LiveTextLayout", "LiveTextEffects"],
    path: "Sources/LiveText"
  ),
  .target(
    name: "LiveTextCore",
    path: "Sources/LiveTextCore"
  ),
  .target(
    name: "LiveTextLayout",
    dependencies: ["LiveTextCore"],
    path: "Sources/LiveTextLayout"
  ),
  .target(
    name: "LiveTextEffects",
    dependencies: ["LiveTextLayout"],
    path: "Sources/LiveTextEffects",
    resources: [.process("Resources")]
  ),
  .target(
    name: "LiveTextSVG",
    dependencies: ["LiveTextLayout"],
    path: "Sources/LiveTextSVG"
  ),
]

#if !os(Linux)
  products += [
    .library(name: "LiveTextApple", targets: ["LiveTextApple"]),
    .library(name: "LiveTextWritingUI", targets: ["LiveTextWritingUI"]),
    .library(name: "DustKit", targets: ["DustKit"]),
    .library(name: "LiveTextPresentation", targets: ["LiveTextPresentation"]),
  ]

  targets += [
    .target(
      name: "LiveTextApple",
      dependencies: ["LiveText", "LiveTextAppleRendering", "LiveTextSwiftUI", "LiveTextCanvas"],
      path: "Sources/LiveTextApple"
    ),
    .target(
      name: "LiveTextChalkRendering",
      dependencies: ["LiveTextEffects"],
      path: "Sources/LiveTextChalkRendering",
      resources: [.process("Resources")]
    ),
    .target(
      name: "LiveTextAppleRendering",
      dependencies: [
        "LiveTextLayout", "LiveTextCore", "LiveTextEffects", "LiveTextChalkRendering",
      ],
      path: "Sources/LiveTextAppleRendering"
    ),
    .target(
      name: "LiveTextSwiftUI",
      dependencies: ["LiveTextLayout", "LiveTextAppleRendering", "LiveTextEffects"],
      path: "Sources/LiveTextSwiftUI"
    ),
    .target(
      name: "LiveTextCanvas",
      dependencies: ["LiveTextLayout", "LiveTextAppleRendering", "LiveTextEffects"],
      path: "Sources/LiveTextCanvas"
    ),
    .target(
      name: "ChalkLineEffects",
      dependencies: ["LiveTextChalkRendering", "LiveTextEffects", "LiveTextLayout"],
      path: "Sources/ChalkLineEffects"
    ),
    .target(
      name: "LiveTextWritingUI",
      dependencies: [
        "LiveTextSwiftUI", "LiveTextCanvas", "ChalkLineEffects", "LiveTextEffects",
        "LiveTextLayout",
      ],
      path: "Sources/LiveTextWritingUI"
    ),
    .target(name: "DustKit", path: "Sources/DustKit", resources: [.process("Shaders")]),
    .target(name: "LiveTextPresentation", dependencies: [
      "LiveTextWritingUI", "LiveTextSwiftUI", "LiveTextAppleRendering", "DustKit",
    ], path: "Sources/LiveTextPresentation"),
  ]
#endif

let package = Package(
  name: "LiveText",
  platforms: [
    .iOS(.v16),
    .macOS(.v13),
  ],
  products: products,
  dependencies: [],
  targets: targets,
  swiftLanguageModes: [.v6]
)
