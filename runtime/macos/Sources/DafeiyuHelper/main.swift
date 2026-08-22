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

// MARK: - Visual mode (Step4)

// In visual mode (no `--headless`) show the idle PNG in a transparent panel. On any
// asset failure, fail fast with exit code 2 — never a silent fallback image.
if !isHeadless {
  do {
    let store = try ManifestStore(assetRootOverride: assetRootOverride)
    let image = try store.idleImage()
    let window = PetWindow(image: image)
    _ = window // retain the window for the lifetime of the run loop
    logToStderr("visual mode: idle panel shown")
  } catch {
    logToStderr("failed to load idle asset (manifest or PNG missing): \(error); exiting with code 2")
    exit(2)
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
    // Step4: store the state only; no clip swap yet (Step5 will branch on stateMap).
    if let state = object["state"] as? String {
      companionModel.applyState(state)
    }
  case .ready, .pong, .closed, .hello, .config, .task, .tasks, .pulse:
    // Step2 does not render; legal messages are acknowledged by keeping the pipe open.
    break
  }
}
