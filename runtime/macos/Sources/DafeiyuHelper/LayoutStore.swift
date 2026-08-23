// LayoutStore (Step7 of the macOS native refactor).
//
// Persists the pet window's position (screen coordinates, bottom-left origin) to
// `~/Library/Application Support/dsh-dafeiyu/layout.json` so the window can be
// restored at the last dragged location on the next launch.
//
// The position is deliberately *non-critical* data: a missing or corrupt file
// silently yields nil (the caller falls back to the default bottom-right anchor),
// and a failed save only logs to stderr — it never crashes the helper. This is the
// opposite of the asset fail-fast semantics in ManifestStore (Step5).

import Foundation

/// The stored window position: its screen origin (AppKit coordinates, bottom-left).
struct LayoutState: Codable {
  let x: Double
  let y: Double
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

  /// Read the persisted position. Missing/corrupt data yields nil (never throws).
  static func load() -> LayoutState? {
    guard let data = try? Data(contentsOf: fileURL),
          let state = try? JSONDecoder().decode(LayoutState.self, from: data) else {
      return nil
    }
    return state
  }

  /// Write the position. Creates the directory if needed; any failure is logged to
  /// stderr and swallowed (position is non-critical data).
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