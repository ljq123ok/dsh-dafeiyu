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
// only consumes `--headless` for now and tolerates any unknown argument so that
// protocol evolution on the Node side does not break launch.
var isHeadless = false
for argument in CommandLine.arguments.dropFirst() {
  switch argument {
  case "--headless":
    isHeadless = true
  default:
    // Unknown argument: ignore silently (Node controls launch flags).
    break
  }
}
// Step2 always runs headless; keep the flag available for Step4 window branching.
_ = isHeadless

// MARK: - Main loop

// Announce readiness immediately so the Node plugin can detect startup.
writeJSON(ReadyMessage(protocolVersion: 1, kind: MessageKind.ready.rawValue, timestamp: Int(Date().timeIntervalSince1970 * 1000)))

// Read stdin byte-by-byte via the `bytes` async sequence until EOF, accumulating
// complete newline-terminated lines and handing them to `handleLine`.
// `FileHandle.standardInput.bytes` yields `UInt8`, so we append to a Data buffer.
Task {
  var pending = Data()
  let newline = UInt8(ascii: "\n")
  for try await byte in FileHandle.standardInput.bytes {
    if byte == newline {
      if !pending.isEmpty {
        handleLine(pending)
        pending.removeAll()
      }
      continue
    }
    pending.append(byte)
  }
  // EOF: process any trailing line without a final newline.
  if !pending.isEmpty {
    handleLine(pending)
  }
  logToStderr("stdin EOF, exiting")
  exit(0)
}

// Keep the process alive while the async reader runs.
RunLoop.main.run()

// MARK: - Line handling

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
  case .ready, .pong, .closed, .state, .hello, .config, .task, .tasks, .pulse:
    // Step2 does not render; legal messages are acknowledged by keeping the pipe open.
    break
  }
}
