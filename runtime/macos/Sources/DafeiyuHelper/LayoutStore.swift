// LayoutStore (Step7/Step11 of the macOS native refactor).
//
// Persists the pet window's position (screen coordinates, bottom-left origin) to
// `~/Library/Application Support/dsh-dafeiyu/layout.json` so the window can be
// restored at the last dragged location on the next launch.
//
// Step11 adds scale/bubbleScale (from the right-click menu) to the same file.
// They are optional Codable fields, so a file written by an older build (x/y
// only) still loads — missing keys default to nil and the caller keeps the
// current values.
//
// The values are deliberately *non-critical* data: a missing or corrupt file
// silently yields nil (the caller falls back to the default bottom-right anchor),
// and a failed save only logs to stderr — it never crashes the helper. This is the
// opposite of the asset fail-fast semantics in ManifestStore (Step5).

import Foundation

/// The stored window position and menu-driven sizing:
/// its screen origin (AppKit coordinates, bottom-left) plus optional scale
/// overrides persisted from the right-click menu (nil = not persisted yet).
struct LayoutState: Codable {
  let x: Double
  let y: Double
  var scale: Double?
  var bubbleScale: Double?
}

enum LayoutStore {
  /// The persisted layout file: `~/Library/Application Support/dsh-dafeiyu/layout.json`.
  static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      // Defensive fallback if the directory query ever returns nothing.
      ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("dsh-dafeiyu/layout.json")
  }

  /// Read the persisted position and optional sizing. Missing/corrupt data, or a
  /// file without the scale keys (older build), yields nil for those keys (never
  /// throws).
  static func load() -> LayoutState? {
    guard let data = try? Data(contentsOf: fileURL),
          let state = try? JSONDecoder().decode(LayoutState.self, from: data) else {
      return nil
    }
    return state
  }

  /// Write the position and optional sizing. Creates the directory if needed; any
  /// failure is logged to stderr and swallowed (this is non-critical data).
  static func save(_ state: LayoutState) {
    do {
      let directory = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(state)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      FileHandle.standardError.write(
        Data("dsh-dafeiyu-helper: LayoutStore.save failed: \(error)\n".utf8)
      )
    }
  }
}