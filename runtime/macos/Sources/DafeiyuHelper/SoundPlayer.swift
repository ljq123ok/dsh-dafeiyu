// SoundPlayer (M2 completion sounds).
//
// Plays a completion chime for SUCCESS/ERROR via NSSound. The sound comes from
// the bundled assets: `assets/sounds/success.wav` / `error.wav` (the original
// v0.1.5 chimes), located beneath `soundRoot` (the app's asset root, set by
// main.swift). When the wav is missing (e.g. a dev checkout) it falls back to
// the Apple system sounds "Glass"/"Basso". The pet is the helper's single
// completion-audio source; DSHNotifier banners are visual-only so a completion
// never double-dings.
//
// Discipline (mirrors DSHNotifier, plan §4.1/§6):
//   - Gated by the `soundEnabled` config (CONFIG message / DSH_DAFEIYU_SOUND_ENABLED
//     env); off means completely silent.
//   - Only SUCCESS/ERROR are completion events; every other state is silent.
//   - Failure (sound name not found / play not started) is stderr-only: never a
//     crash, never an exit, never a UI pop-up.
//   - Caller-side dedup lives in main.swift (notifyCompletionIfNeeded), so a
//     PULSE→STATE echo of the same completion never double-chimes.
//   - Main-actor only: NSSound is an AppKit type and the call site
//     (notifyCompletionIfNeeded) is @MainActor anyway.

import AppKit

/// Main-actor isolated: the only mutable state is `activeSound` (an NSSound),
/// and the only call site (notifyCompletionIfNeeded) is @MainActor anyway.
/// Marking the whole enum @MainActor makes `activeSound` concurrency-safe and
/// keeps the API honest — no off-main actor could reach it.
@MainActor
enum SoundPlayer {
  /// The most recent sound kept alive until it finishes playing: NSSound does
  /// not guarantee self-retention after play() returns, and a released sound
  /// could cut off mid-chime. One system sound (~100 KB) retained is
  /// negligible; a newer completion simply replaces it.
  private static var activeSound: NSSound?

  /// Asset root that contains `assets/sounds/success.wav` / `error.wav`
  /// (the original v0.1.5 chimes). Set by main.swift after the manifest loads.
  static var soundRoot: URL?

  /// Play the completion chime for a completion state, unless sounds are
  /// disabled. Safe to call at any time — never blocks, never exits, never
  /// crashes.
  @MainActor
  static func playCompletion(state: String, enabled: Bool) {
    guard enabled else { return }
    let filename: String
    switch state {
    case "SUCCESS": filename = "success"
    case "ERROR": filename = "error"
    default: return
    }
    // Prefer the original bundled chime; fall back to the built-in system sound
    // (Glass/Basso) when the wav is absent (e.g. dev checkout without assets).
    var sound: NSSound?
    if let root = soundRoot {
      let url = root.appendingPathComponent("assets/sounds/\(filename).wav")
      sound = NSSound(contentsOf: url, byReference: true)
      if sound == nil {
        log("assets/sounds/\(filename).wav not found; falling back to system sound")
      }
    }
    let fallbackName = state == "SUCCESS" ? "Glass" : "Basso"
    sound = sound ?? NSSound(named: fallbackName)
    guard let sound else {
      log("no completion sound available for '\(filename)'")
      return
    }
    // Step12: max volume explicitly — NSSound defaults to the system alert
    // volume, which can be much lower than 1.0 when the user's alert slider is
    // turned down. Setting volume to 1.0 makes the chime as loud as the sound
    // file allows (the OS alert volume is the only remaining limiter).
    sound.volume = 1.0
    activeSound = sound
    if !sound.play() {
      activeSound = nil
      log("failed to start completion sound '\(filename)'")
    }
  }

  /// Write one stderr line using the same `dsh-dafeiyu-helper: ` prefix as the
  /// rest of the helper, so sound diagnostics stay greppable and uniform.
  private static func log(_ message: String) {
    FileHandle.standardError.write(Data("dsh-dafeiyu-helper: \(message)\n".utf8))
  }
}
