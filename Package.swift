// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "swift-curl",
  platforms: [
    .macOS(.v13),
    .iOS(.v16),
    .tvOS(.v16),
    .watchOS(.v9),
    .visionOS(.v1),
  ],
  products: [
    .library(name: "SwiftCURL", targets: ["SwiftCURL"])
  ],
  targets: [
    .target(name: "SwiftCURL"),
    .testTarget(
      name: "SwiftCURLTests",
      dependencies: ["SwiftCURL"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
