// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "LiveTextProductConsumer",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [.library(name: "ProductConsumer", targets: ["ProductConsumer"])],
  dependencies: [.package(name: "LiveTextFixture", path: "../../..")],
  targets: [.target(name: "ProductConsumer", dependencies: [
    .product(name: "LiveText", package: "LiveTextFixture"),
    .product(name: "LiveTextCore", package: "LiveTextFixture"),
    .product(name: "LiveTextLayout", package: "LiveTextFixture"),
    .product(name: "LiveTextEffects", package: "LiveTextFixture"),
    .product(name: "LiveTextSVG", package: "LiveTextFixture"),
    .product(name: "LiveTextApple", package: "LiveTextFixture"),
    .product(name: "LiveTextAppleRendering", package: "LiveTextFixture"),
    .product(name: "LiveTextSwiftUI", package: "LiveTextFixture"),
    .product(name: "LiveTextCanvas", package: "LiveTextFixture"),
    .product(name: "LiveTextWritingUI", package: "LiveTextFixture"),
    .product(name: "ChalkLineEffects", package: "LiveTextFixture"),
    .product(name: "LiveTextPresentation", package: "LiveTextFixture"),
    .product(name: "DustKit", package: "LiveTextFixture"),
  ]), .testTarget(name: "ProductConsumerTests", dependencies: [
    "ProductConsumer",
    .product(name: "LiveTextCore", package: "LiveTextFixture"),
    .product(name: "LiveTextLayout", package: "LiveTextFixture"),
    .product(name: "LiveTextWritingUI", package: "LiveTextFixture"),
  ])]
)
