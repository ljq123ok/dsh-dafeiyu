// ManifestStore (Step5 of the macOS native refactor).
//
// Locates the bundled `assets/` root relative to the running executable and loads
// animation clips from `assets/pet-manifest.json`. A "clip" is a sequence of PNG
// frames plus a per-frame duration (frameMs) and a loop flag. The manifest also
// maps companion states to clip names (`stateMap`), refines WORKING into named
// activities (`workingActivityMap`), and lists idle micro-actions (`idleMicroClips`).
//
// Missing manifest, missing clip, or any un-decodable frame is a hard failure
// (exit code 2) — never a silent fallback image.
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
  let stateMap: [String: String]
  let workingActivityMap: [String: String]
  let idleMicroClips: [String]
  struct Clip: Codable {
    let frames: [String]
    let frameMs: Int
    let loop: Bool
    // `motion` is reserved metadata (e.g. "breathe") describing the clip's intent.
    // Step5 does not require it to render, so it is parsed but unused — see t13 F2.
    let motion: String?
  }
}

enum ManifestError: Error {
  case missing
  case clipNotFound
  case frameNotFound
}

/// A decoded, render-ready clip: ordered frames plus playback timing.
struct ResolvedClip {
  let name: String
  let frames: [NSImage]
  let frameMs: Int
  let loops: Bool
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

  // MARK: - Clip resolution

  /// Resolve a clip by name into render-ready frames. Any missing/un-decodable frame
  /// fails fast with `.frameNotFound` (the caller maps this to exit code 2).
  func clip(named name: String) throws -> ResolvedClip {
    guard let c = manifest.clips[name] else { throw ManifestError.clipNotFound }
    var images: [NSImage] = []
    for rel in c.frames {
      let url = assetRoot.appendingPathComponent("assets/pet").appendingPathComponent(rel)
      // AppKit may return a non-nil NSImage for a missing file, so also require a valid,
      // non-zero-sized bitmap before treating the frame as loaded.
      guard let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 else {
        throw ManifestError.frameNotFound
      }
      images.append(image)
    }
    guard !images.isEmpty else { throw ManifestError.frameNotFound }
    return ResolvedClip(name: name, frames: images, frameMs: max(1, c.frameMs), loops: c.loop)
  }

  /// The IDLE base clip (also the animation's resting state).
  func idleClip() throws -> ResolvedClip {
    try clip(named: "idle")
  }

  // MARK: - State → clip mapping

  /// Map a companion state (and optional WORKING activity) to a clip name.
  /// WORKING consults `workingActivityMap`; every state falls back to `stateMap`.
  func clipName(forState state: String, activity: String? = nil) -> String? {
    if state == "WORKING", let act = activity, !act.isEmpty,
       let w = manifest.workingActivityMap[act] {
      return w
    }
    return manifest.stateMap[state]
  }

  /// Resolve the clip to display for a base state. Returns nil if unmapped.
  func clip(forState state: String, activity: String? = nil) throws -> ResolvedClip? {
    guard let name = clipName(forState: state, activity: activity) else { return nil }
    return try clip(named: name)
  }

  /// The idle micro-clip names (e.g. "blink", "glance"), useful for random idle breaks.
  var microClipNames: [String] { manifest.idleMicroClips }
}

// MARK: - Backwards-compatible single-frame accessor (Step4 kept for reference)

extension ManifestStore {
  /// Step4 compatibility: first frame of the idle clip as a single image.
  func idleImage() throws -> NSImage {
    try idleClip().frames.first!
  }
}
