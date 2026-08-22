// Headless companion helper skeleton (Step2 of the macOS native refactor).
// Window / AppKit rendering is implemented later (Step4); this stage only speaks
// the newline-delimited JSON protocol on stdout/stdin so the Node plugin can be
// wired against a real Swift binary.
//
// Protocol invariants (must hold in every build of this helper):
//   1. The first line written to stdout is a `ready` message (protocolVersion: 1).
//   2. A `ping` message is answered with a `pong` message.
//   3. A `shutdown` message or stdin EOF terminates the process with exit code 0.
//   4. Invalid JSON is reported to stderr only; the process never crashes on it.
//   5. Nothing except protocol lines is ever written to stdout (logs go to stderr).

import Foundation

// MARK: - Protocol messages

struct ReadyMessage: Encodable {
  let protocolVersion: Int
  let kind: String
  let timestamp: Int
}

struct PongMessage: Encodable {
  let protocolVersion: Int
  let kind: String
  let timestamp: Int
}

enum MessageKind: String {
  case ready, ping, pong, shutdown, closed
  case state, hello, config, task, tasks, pulse
  // unknown kinds fall through to the default branch below
}

// MARK: - Output

private let stdoutHandle = FileHandle.standardOutput
private let stderrHandle = FileHandle.standardError

func writeJSON<T: Encodable>(_ value: T) {
  guard let data = try? JSONEncoder().encode(value) else { return }
  stdoutHandle.write(data)
  stdoutHandle.write(Data("\n".utf8))
}

func logToStderr(_ message: String) {
  stderrHandle.write(Data("dsh-dafeiyu-helper: \(message)\n".utf8))
}

// MARK: - Argument parsing

// Node may pass extra arguments such as `--event-log` / `--snapshot`. This helper
// consumes `--headless` (no window, for testing) and `--asset-root` (override the
// upward asset probe); it tolerates any other unknown argument so that protocol
// evolution on the Node side does not break launch.
var isHeadless = false
var assetRootOverride: String? = nil
// `--asset-root VALUE` (space-separated) or `--asset-root=VALUE` (equals form).
var pendingAssetRoot = false
for argument in CommandLine.arguments.dropFirst() {
  if pendingAssetRoot {
    assetRootOverride = argument
    pendingAssetRoot = false
    continue
  }
  switch argument {
  case "--headless":
    isHeadless = true
  case "--asset-root":
    // Next token is the path.
    pendingAssetRoot = true
  case let arg where arg.hasPrefix("--asset-root="):
    assetRootOverride = String(arg.dropFirst("--asset-root=".count))
  default:
    // Unknown argument: ignore silently (Node controls launch flags).
    break
  }
}

// MARK: - Companion model (Step4)

// Single source of truth for the current state. Step4 stores it but does not swap the
// visible clip; Step5 will branch on `stateMap` here.
let companionModel = CompanionModel()

// MARK: - Visual mode (Step5)

// In visual mode (no `--headless`) show the idle clip in a transparent panel. On any
// asset failure (manifest, idle clip, or first frame missing) fail fast with exit code 2
// — never a silent fallback image. The companion model and window are retained for the
// lifetime of the run loop.
var manifestStore: ManifestStore?
var petWindow: PetWindow?

if !isHeadless {
  do {
    let store = try ManifestStore(assetRootOverride: assetRootOverride)
    manifestStore = store
    let idle = try store.idleClip()
    let window = PetWindow(clip: idle)
    petWindow = window // retain the window for the lifetime of the run loop
    // Wire the model→window redraw hook (F4: a pulse expiry must re-resolve the base
    // clip). In headless mode this closure stays nil, so the hook is a no-op there.
    companionModel.onActiveClipChanged = { [weak store, weak window] in
      guard let s = store, let w = window else { return }
      showActiveClip(store: s, window: w, fatalIfMissing: false)
    }
    logToStderr("visual mode: idle clip shown")
  } catch {
    logToStderr("failed to load idle asset (manifest or PNG missing): \(error); exiting with code 2")
    exit(2)
  }
}

/// Resolve and display the clip for the model's current active state. On a missing
/// base clip at startup this fails fast (exit 2); when switching at runtime, a missing
/// non-base clip is logged and we fall back to the idle clip rather than crashing.
@MainActor
func showActiveClip(store: ManifestStore, window: PetWindow, fatalIfMissing: Bool) {
  do {
    guard let clip = try store.clip(forState: companionModel.activeState, activity: companionModel.activeActivity) else {
      throw ManifestError.clipNotFound
    }
    window.showClip(clip)
  } catch {
    if fatalIfMissing {
      logToStderr("failed to load active clip: \(error); exiting with code 2")
      exit(2)
    }
    // Runtime switch to a clip whose assets are missing: keep the current frame and
    // revert to idle so the pet never disappears.
    logToStderr("cannot load clip for \(companionModel.activeState); falling back to idle")
    if let idle = try? store.idleClip() { window.showClip(idle) }
  }
}

// MARK: - Main loop

// Announce readiness immediately so the Node plugin can detect startup.
writeJSON(ReadyMessage(protocolVersion: 1, kind: MessageKind.ready.rawValue, timestamp: Int(Date().timeIntervalSince1970 * 1000)))

// Read stdin byte-by-byte via the `bytes` async sequence until EOF, accumulating
// complete newline-terminated lines. The byte read runs off the main actor (so the
// AppKit run loop stays responsive); each complete line is processed on the main
// actor, where the companion model and window live.
Task {
  var pending = Data()
  let newline = UInt8(ascii: "\n")
  for try await byte in FileHandle.standardInput.bytes {
    if byte == newline {
      if !pending.isEmpty {
        let line = pending
        pending.removeAll()
        await MainActor.run { handleLine(line) }
      }
      continue
    }
    pending.append(byte)
  }
  // EOF: process any trailing line without a final newline.
  if !pending.isEmpty {
    let line = pending
    await MainActor.run { handleLine(line) }
  }
  logToStderr("stdin EOF, exiting")
  exit(0)
}

// Keep the process alive while the async reader runs.
RunLoop.main.run()

// MARK: - Line handling

@MainActor
func handleLine(_ lineData: Data) {
  guard let string = String(data: lineData, encoding: .utf8),
        !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

  guard let data = string.data(using: .utf8) else { return }

  // First, try to read the `kind` field without fully decoding the payload.
  guard
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let kindString = object["kind"] as? String
  else {
    // Not a recognizable protocol object: report and ignore.
    logToStderr("skipping non-protocol line: \(String(string.prefix(200)))")
    return
  }

  // Unknown `kind` values are logged and ignored (never fatal).
  guard let kind = MessageKind(rawValue: kindString) else {
    logToStderr("unknown kind '\(kindString)' ignored")
    return
  }

  switch kind {
  case .ping:
    writeJSON(PongMessage(protocolVersion: 1, kind: MessageKind.pong.rawValue, timestamp: Int(Date().timeIntervalSince1970 * 1000)))
  case .shutdown:
    logToStderr("shutdown received, exiting")
    exit(0)
  case .state:
    // Step5: switch the visible clip to match the state. `activity` refines WORKING.
    if let state = object["state"] as? String {
      companionModel.applyState(state, activity: object["activity"] as? String)
      if let store = manifestStore, let window = petWindow {
        showActiveClip(store: store, window: window, fatalIfMissing: false)
      }
    }
  case .pulse:
    // Step5: a transient override (e.g. SUCCESS/ERROR) shown for `ttlMs`, then the
    // model falls back to `resumeState ?? baseState`.
    if let state = object["state"] as? String {
      companionModel.applyPulse(
        state,
        activity: object["activity"] as? String,
        ttlMs: object["ttlMs"] as? Int,
        resumeState: object["resumeState"] as? String
      )
      if let store = manifestStore, let window = petWindow {
        showActiveClip(store: store, window: window, fatalIfMissing: false)
      }
    }
  case .ready, .pong, .closed, .hello, .config, .task, .tasks:
    // Legal protocol messages not rendered here; acknowledged by keeping the pipe open.
    break
  }
}
