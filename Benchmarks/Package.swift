// swift-tools-version: 6.1
import PackageDescription

// swift-curl's benchmarks, on ordo-one/package-benchmark (https://www.swift.org/blog/benchmarks/). A separate
// package so the library keeps no dependencies. Run from the repository root:
// `swift package --package-path Benchmarks benchmark`. Needs macOS 15 and jemalloc (`brew install jemalloc`).
let package = Package(
  name: "Benchmarks",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(name: "swift-curl", path: ".."),
    .package(url: "https://github.com/ordo-one/package-benchmark.git", from: "1.38.0"),
  ],
  targets: [
    .executableTarget(
      name: "SwiftCURLBenchmarks",
      dependencies: [
        .product(name: "Benchmark", package: "package-benchmark"),
        .product(name: "SwiftCURL", package: "swift-curl"),
      ],
      path: "Benchmarks/SwiftCURLBenchmarks",
      plugins: [
        .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
      ]
    ),
    // Reads two `benchmark --format markdown` outputs and prints each benchmark's p50 before and after.
    .executableTarget(name: "p50", path: "Tools/P50"),
    // Reads an exported Time Profiler table and prints the hottest functions (scripts/profile.sh).
    .executableTarget(name: "hotspots", path: "Tools/Hotspots"),
  ]
)
