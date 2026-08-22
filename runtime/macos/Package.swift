// swift-tools-version:6.0
// arm64-only by design: this helper targets Apple Silicon (darwin-arm64) exclusively.
// Intel macOS, Rosetta, and Universal Binary are explicitly out of scope.
//
// NOTE: M1 intentionally keeps `cpu: ["x64", "arm64"]` in package.json so the package
// stays installable/testable on this Apple-Silicon dev machine. The macOS-only,
// arm64-only *publish* shape (cpu: ["arm64"], os: ["darwin"]) is converged later at
// Step9 of the v2 plan. M1 = dev-installable state; Step9 = publish state. They are
// not in conflict.
import PackageDescription

let package = Package(
  name: "DafeiyuHelper",
  platforms: [
    // Minimum macOS version for the modern Swift concurrency / SwiftUI stack.
    // Architecture is constrained to arm64 via `swift build --arch arm64` and the
    // fixed install path `runtime/bin/darwin-arm64/dsh-dafeiyu-helper`.
    .macOS(.v14)
  ],
  targets: [
    .executableTarget(
      name: "DafeiyuHelper",
      path: "Sources/DafeiyuHelper"
    )
  ]
)
