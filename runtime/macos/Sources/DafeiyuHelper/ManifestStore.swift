// ManifestStore (Step4 of the macOS native refactor).
//
// Locates the bundled `assets/` root relative to the running executable and loads
// the idle frame PNG from `assets/pet-manifest.json`. Missing manifest or missing
// idle frame is a hard failure (exit code 2) — never a silent fallback image.
//
// Asset-root resolution covers both shipping and dev layouts:
//   - Shipping:  …/runtime/bin/darwin-arm64/dsh-dafeiyu-helper  (go up 3 levels)
//   - Dev:       …/runtime/macos/.build/release/DafeiyuHelper    (go up 4 levels)
// An explicit `--asset-root <path>` overrides the upward probe entirely.

import AppKit
import Foundation

struct PetManifest: Codable {
  let baseSize: Int
  let clips: [String: Clip]
  struct Clip: Codable {
    let frames: [String]
  }
}

enum ManifestError: Error {
  case missing
  case idleFrameNotFound
}

final class ManifestStore {
  let manifest: PetManifest
  let assetRoot: URL

  /// Resolve the repo-root `assets/` directory. `override` short-circuits the probe.
  static func locateAssetRoot(override: String?) throws -> URL {
    if let override = override {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    let executable = Bundle.main.executableURL
      ?? URL(fileURLWithPath: CommandLine.arguments[0])
    var dir = executable.deletingLastPathComponent()
    for _ in 0..<6 {
      let candidate = dir.appendingPathComponent("assets/pet-manifest.json")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return dir
      }
      dir = dir.deletingLastPathComponent()
    }
    throw ManifestError.missing
  }

  init(assetRootOverride: String?) throws {
    self.assetRoot = try Self.locateAssetRoot(override: assetRootOverride)
    let url = assetRoot.appendingPathComponent("assets/pet-manifest.json")
    guard let data = try? Data(contentsOf: url) else { throw ManifestError.missing }
    self.manifest = try JSONDecoder().decode(PetManifest.self, from: data)
  }

  /// Step4 only needs the first frame of the `idle` clip. `stateMap`/`workingActivityMap`
  /// drive animation selection in Step5.
  func idleImage() throws -> NSImage {
    guard let first = manifest.clips["idle"]?.frames.first else {
      throw ManifestError.idleFrameNotFound
    }
    let url = assetRoot.appendingPathComponent("assets/pet").appendingPathComponent(first)
    // AppKit may return a non-nil NSImage for a missing file, so also require a valid,
    // non-zero-sized bitmap before treating the idle frame as loaded.
    guard let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 else {
      throw ManifestError.idleFrameNotFound
    }
    return image
  }
}
