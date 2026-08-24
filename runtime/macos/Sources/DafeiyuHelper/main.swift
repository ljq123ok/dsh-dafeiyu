// Headless companion helper skeleton (Step2 of the macOS native refactor).
// Window / AppKit rendering is implemented later (Step4); this stage only speaks
// the newline-delimited JSON protocol on stdout/stdin so the Node plugin can be
// wired against a real Swift binary.
//
// Step7 adds the CONFIG consumption and settings/layout wiring: the visual mode
// reads initial settings from `DSH_DAFEIYU_*` env, applies CONFIG messages live
// (scale/bubbleScale/reducedMotion/bubbleMode/bubbleStates), and persists the
// dragged window position via LayoutStore. All of it lives in the `!isHeadless`
// branch — the headless protocol path stays byte-for-byte identical to M1.
//
// Step8 adds system notifications: SUCCESS/ERROR from PULSE (and STATE) go to the
// macOS user notification center via DSHNotifier. The reducer-computed
// `message`/`detail` are threaded through to the model (notification snapshots)
// and used as the notification body — Swift never generates copy. Delivery is
// gated on `!isHeadless`, deduplicated by (state, message, detail), and failure
// (no permission / send error) is stderr-only: never a UI pop-up, never an exit.
//
// Protocol invariants (must hold in every build of this helper):
//   1. The first line written to stdout is a `ready` message (protocolVersion: 1).
//   2. A `ping` message is answered with a `pong` message.
//   3. A `shutdown` message or stdin EOF terminates the process with exit code 0.
//   4. Invalid JSON is reported to stderr only; the process never crashes on it.
//   5. Nothing except protocol lines is ever written to stdout (logs go to stderr).

import AppKit
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

struct ClosedMessage: Encodable {
  let protocolVersion: Int
  let kind: String
  let reason: String
}

/// Emit a CLOSED reply (Step11: the right-click "本次关闭" menu item). The Node
/// side treats a CLOSED reply as "the user closed the pet — do not restart the
/// helper", which matches the original Python version's `closed` emit. Only
/// valid after READY; the call site is the menu action on the main thread.
@MainActor
func emitClosed(reason: String) {
  writeJSON(ClosedMessage(protocolVersion: 1, kind: MessageKind.closed.rawValue, reason: reason))
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

// MARK: - Step11 debug tracing (diagnose interaction; writes to a file so the
// DSH UI log does not need to be inspected. Remove after the drag issue is fixed.)

private let petDebugURL = URL(fileURLWithPath: "/tmp/dsh-pet-debug.log")

func petDebugLog(_ message: String) {
  let line = "\(Date()) \(message)\n"
  if let data = line.data(using: .utf8) {
    if let handle = try? FileHandle(forWritingTo: petDebugURL) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: petDebugURL)
    }
  }
}

// MARK: - Step8 notifications

/// Last delivered completion notification, keyed by (state, message, detail).
/// Guards against double-notifying the same completion — the reducer emits
/// SUCCESS/ERROR as PULSE (and can also emit ERROR as STATE on an abnormal turn
/// end); a PULSE immediately followed by a STATE with identical copy must not
/// produce two banners. Distinct events (different copy/state) still notify.
private var lastNotificationKey: String?

/// Deliver a desktop notification for SUCCESS/ERROR completion states.
///   - Only in visual mode (never in headless — the headless path does not touch
///     notification code at all and stays byte-identical on stdout).
///   - Only for SUCCESS/ERROR states (other states are not completion events).
///   - Deduplicated by (state, message, detail) so a PULSE→STATE echo of the same
///     completion does not double-notify.
///   - All actual sending (permission check, request) lives in DSHNotifier and is
///     stderr-only on failure; this function never blocks and never exits.
@MainActor
func notifyCompletionIfNeeded(state: String, message: String?, detail: String?) {
  guard !isHeadless else { return }
  guard state == "SUCCESS" || state == "ERROR" else { return }
  let key = [state, message ?? "", detail ?? ""].joined(separator: "\u{1F}")
  if key == lastNotificationKey { return }
  lastNotificationKey = key
  DSHNotifier.deliver(state: state, message: message, detail: detail)
  // Step12: completion sound (NSSound via SoundPlayer) — the pet is the single
  // audio source for completions, gated by the `soundEnabled` config (env at
  // startup, live CONFIG afterwards). Same dedup as the banner, so a PULSE→STATE
  // echo of one completion never double-chimes.
  SoundPlayer.playCompletion(state: state, enabled: companionModel.configSoundEnabled)
  // Step12: completion shake — the pet window wobbles on SUCCESS/ERROR (visual
  // feedback alongside the chime), never in headless (guarded by the caller).
  petWindow?.shakeWindow()
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
  // Step11: helper is an accessory application — it does not appear in the dock
  // or Force Touch menu, and its windows do not steal focus from the active app
  // when they are clicked. This makes the pet feel like an OS-level overlay while
  // still allowing its NSWindow to become key during a drag (which NSPanel could
  // not do).
  NSApplication.shared.setActivationPolicy(.accessory)
  do {
    // Step7: read the initial settings from DSH_DAFEIYU_* env (startup values; live
    // CONFIG messages override them afterwards).
    applyEnvConfig()
    let store = try ManifestStore(assetRootOverride: assetRootOverride)
    manifestStore = store
    // Step12: the completion sounds come from the bundled assets (success/error
    // wav, v0.1.5 originals), resolved against the same asset root as the clips.
    SoundPlayer.soundRoot = store.assetRoot
    let idle = try store.idleClip()
    let window = PetWindow(clip: idle, scale: CGFloat(companionModel.configScale))
    petWindow = window // retain the window for the lifetime of the run loop
    // Step12: click interactions resolve their clip (head_pat/tail/poke) from the
    // manifest and, once the overlay ends, return to the real active clip.
    window.interactionClipProvider = { [weak store] name in
      try? store?.clip(named: name)
    }
    window.onOverlayReturn = { [weak window] in
      guard let window, let store = manifestStore else { return }
      showActiveClip(store: store, window: window, fatalIfMissing: false)
    }
    configurePetView(window)
    // Wire the model→window redraw hook (F4: a pulse expiry must re-resolve the base
    // clip). In headless mode this closure stays nil, so the hook is a no-op there.
    companionModel.onActiveClipChanged = { [weak store, weak window] in
      guard let s = store, let w = window else { return }
      showActiveClip(store: s, window: w, fatalIfMissing: false)
      // Step11: in IDLE with no pulse override, start scheduling idle micro clips
      // (blink/glance from the manifest) so the pet shows subtle motion instead of
      // appearing frozen. Non-idle states never trigger micro animation.
      if companionModel.activeState == "IDLE", companionModel.pulseState == nil {
        scheduleIdleMicro()
      }
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

// MARK: - Step11 idle micro-clip scheduling

/// Step12: idle micro-clip frequency follows the `activityLevel` setting
/// (quiet/normal/lively), ported from v0.1.5 `microIntervals`: quiet waits
/// 12–24 s, normal 6.5–12.5 s, lively 3.5–8 s. In the IDLE state with no pulse
/// override, schedule a random idle micro clip (blink/glance from the manifest's
/// `idleMicroClips` list) so the pet shows subtle motion instead of appearing
/// frozen. The micro clip is non-looping — after it plays to completion we
/// return to the idle clip and re-schedule. Non-idle states never trigger it.
@MainActor
func scheduleIdleMicro() {
  guard companionModel.activeState == "IDLE", companionModel.pulseState == nil else { return }
  guard let store = manifestStore, let window = petWindow else { return }
  let microNames = store.microClipNames
  guard !microNames.isEmpty else { return }
  let interval: (Double, Double) = switch companionModel.configActivityLevel {
    case "quiet": (12.0, 24.0)
    case "lively": (3.5, 8.0)
    default: (6.5, 12.5)
  }
  let delay = Double.random(in: interval.0...interval.1)
  Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak store, weak window] _ in
    // Re-check idle/pulse at fire time — the state may have changed while the
    // timer was pending (a new STATE or PULSE arrived). If so, reschedule so we
    // don't interrupt a WORKING/THINKING clip with a blink.
    guard companionModel.activeState == "IDLE", companionModel.pulseState == nil else {
      scheduleIdleMicro()
      return
    }
    guard let store, let window else { return }
    guard let name = store.microClipNames.randomElement() else { return }
    do {
      let clip = try store.clip(named: name)
      window.showClip(clip)
      // Non-looping micro clips hold on their last frame; return to idle after
      // the clip's playback duration plus a short tail so the last frame is
      // visible for at least one full tick.
      let duration = Double(clip.frames.count) * Double(clip.frameMs) / 1000.0 + 0.5
      Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak store, weak window] _ in
        guard let store, let window else { return }
        do {
          let idle = try store.clip(named: "idle")
          window.showClip(idle)
          scheduleIdleMicro()
        } catch {
          logToStderr("cannot load idle clip for micro return: \(error)")
        }
      }
    } catch {
      logToStderr("cannot load idle micro clip '\(name)': \(error)")
      scheduleIdleMicro()
    }
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
//
// Step11: visual mode must run the AppKit event loop (`NSApplication.run`), not
// a bare `RunLoop.main.run()`. Mouse events (mouseDown/mouseDragged on the pet
// view) are dispatched by NSApplication's event loop; `RunLoop.main.run()` only
// services timers and input sources, so a window could be visible and animated
// but never receive a click — the root cause of "cannot drag". `NSApplication.run`
// internally runs the main run loop, so the frame timer and the stdin async
// reader keep working. Headless mode never creates windows and keeps the bare
// run loop (byte-identical protocol behavior).
if isHeadless {
  RunLoop.main.run()
} else {
  NSApplication.shared.run()
}

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
    // Step6: STATE also carries task/progress/detail/payload.message (reducer L487-495),
    // so the bubble data is refreshed together with the state.
    // Step8: message/detail are snapshotted by the model and, for SUCCESS/ERROR,
    // trigger the desktop notification (visual mode only, deduplicated).
    if let state = object["state"] as? String {
      let message = object["message"] as? String
      let detail = object["detail"] as? String
      companionModel.applyState(
        state,
        activity: object["activity"] as? String,
        task: taskInfo(from: object),
        message: message,
        detail: detail
      )
      notifyCompletionIfNeeded(state: state, message: message, detail: detail)
      syncOverlays()
      if let store = manifestStore, let window = petWindow {
        showActiveClip(store: store, window: window, fatalIfMissing: false)
      }
    }
  case .pulse:
    // Step5: a transient override (e.g. SUCCESS/ERROR) shown for `ttlMs`, then the
    // model falls back to `resumeState ?? baseState`.
    // Step8: message/detail are snapshotted by the model and SUCCESS/ERROR trigger
    // the desktop notification (visual mode only, deduplicated). This is the main
    // notification channel — the reducer sends SUCCESS/ERROR as PULSE (L317/406).
    if let state = object["state"] as? String {
      // Step10 (t2-minor-2): `phase` (e.g. "turn-end") is informational on the
      // reducer side; Swift never consumes it — pulse timing is driven by ttlMs.
      let message = object["message"] as? String
      let detail = object["detail"] as? String
      // Step10 (t2-minor-1): the reducer emits `resumeActivity` (not `activity`)
      // on PULSE messages when it carries the activity that should resume after the
      // pulse; tolerate both fields so the helper survives either shape.
      let pulseActivity = (object["activity"] ?? object["resumeActivity"]) as? String
      companionModel.applyPulse(
        state,
        activity: pulseActivity,
        ttlMs: object["ttlMs"] as? Int,
        resumeState: object["resumeState"] as? String,
        message: message,
        detail: detail
      )
      notifyCompletionIfNeeded(state: state, message: message, detail: detail)
      if let store = manifestStore, let window = petWindow {
        showActiveClip(store: store, window: window, fatalIfMissing: false)
      }
    }
  case .task:
    // Step6: a todo progress update. Empty `task` clears the single-task bubble.
    companionModel.applyTask(taskInfo(from: object))
    syncOverlays()
  case .tasks:
    // Step6: multi-task card list. `{ tasks: [] }` (fewer than two active tasks)
    // clears the card.
    let rawTasks = object["tasks"] as? [[String: Any]] ?? []
    companionModel.applyTasks(rawTasks.map(TaskItem.init(dictionary:)))
    syncOverlays()
  case .config:
    // Step7: live settings change. Apply to the model and the UI (window scale,
    // bubble scale, reduced motion, bubble visibility). Only in visual mode — the
    // headless path ignores CONFIG entirely so the M1 protocol behavior is unchanged.
    if !isHeadless {
      companionModel.applyConfig(object)
      applyConfigToUI()
    }
  case .ready, .pong, .closed, .hello:
    // Legal protocol messages not rendered here; acknowledged by keeping the pipe open.
    break
  }
}

/// Build the Step6 bubble info from a message payload. The reducer sends
/// task/progress{completed,total}/project/message/detail on both TASK and STATE.
@MainActor
func taskInfo(from object: [String: Any]) -> TaskInfo? {
  let progress = object["progress"] as? [String: Any]
  let task = object["task"] as? String
  let message = object["message"] as? String
  let detail = object["detail"] as? String
  let project = object["project"] as? String
  // When the payload carries none of the bubble fields, treat it as no bubble
  // (the reducer sends `task`/`message`/`detail` on TASK; STATE may omit task).
  let info = TaskInfo(
    title: task,
    completed: progress?["completed"] as? Int,
    total: progress?["total"] as? Int,
    message: message,
    detail: detail,
    project: project
  )
  return info.isEmpty ? nil : info
}

/// Push the current bubble/card state from the model into the window's view.
/// Step7: also refresh the state the single bubble is attributed to, so a state
/// change re-filters the bubble under `bubbleMode`/`bubbleStates`.
@MainActor
func syncOverlays() {
  guard let window = petWindow else { return }
  window.petView.stateForBubble = companionModel.activeState
  window.petView.setBubble(companionModel.currentTask)
  window.petView.setCard(companionModel.taskList)
}

/// Step7: read the startup settings from the `DSH_DAFEIYU_*` env variables (the same
/// values the Node side passes in startRuntime, src/index.js L186-191). Invalid or
/// missing values keep the model defaults. Visual mode only.
@MainActor
func applyEnvConfig() {
  let env = ProcessInfo.processInfo.environment
  if let raw = env["DSH_DAFEIYU_SCALE"], let value = Double(raw), (0.7...1.4).contains(value) {
    companionModel.configScale = value
  }
  if let raw = env["DSH_DAFEIYU_BUBBLE_SCALE"], let value = Double(raw), (0.8...1.2).contains(value) {
    companionModel.configBubbleScale = value
  }
  if env["DSH_DAFEIYU_REDUCED_MOTION"] == "1" {
    companionModel.configReducedMotion = true
  }
  if let mode = env["DSH_DAFEIYU_BUBBLE_MODE"], ["always", "hidden", "custom"].contains(mode) {
    companionModel.configBubbleMode = mode
  }
  if let raw = env["DSH_DAFEIYU_BUBBLE_STATES"], !raw.isEmpty {
    companionModel.configBubbleStates = Set(raw.split(separator: ",").map(String.init))
  }
  if let level = env["DSH_DAFEIYU_ACTIVITY_LEVEL"], ["quiet", "normal", "lively"].contains(level) {
    companionModel.configActivityLevel = level
  }
  if let raw = env["DSH_DAFEIYU_SOUND_ENABLED"] {
    // "0" disables completion sounds explicitly; every other value (including
    // "1"/"true"/"on") is read as enabled, matching the original v0.1.5 gate.
    companionModel.configSoundEnabled = raw != "0"
  }
}

/// Step7: push the model's current configuration into the window's view (bubble/card
/// scale, reduced motion, bubble visibility filter). Called at startup and after every
/// live CONFIG application. The visibility decision is snapshotted from the model's
/// (MainActor-isolated) `shouldShowBubble` into a pure-value closure the view consults
/// at draw time without a MainActor hop; every reconfiguration re-snapshots it, so it
/// always reflects the latest CONFIG.
@MainActor
func configurePetView(_ window: PetWindow) {
  window.petView.bubbleScale = CGFloat(companionModel.configBubbleScale)
  window.petView.reducedMotion = companionModel.configReducedMotion
  let mode = companionModel.configBubbleMode
  let states = companionModel.configBubbleStates
  window.petView.bubbleFilter = { state in
    switch mode {
    case "hidden": return false
    case "custom": guard let state else { return false }; return states.contains(state)
    default: return true
    }
  }
  window.petView.stateForBubble = companionModel.activeState
}

/// Step7: apply the model's current configuration to the UI — window scale (resize),
/// view config, overlay data, and a clip re-show (so reduced-motion/scale take effect
/// on the visible frame).
@MainActor
func applyConfigToUI() {
  guard let window = petWindow else { return }
  window.applyScale(CGFloat(companionModel.configScale))
  configurePetView(window)
  syncOverlays()
  if let store = manifestStore {
    showActiveClip(store: store, window: window, fatalIfMissing: false)
  }
}

/// Parse one TASKS entry into a TaskItem (all fields optional except sessionId).
extension TaskItem {
  init(dictionary: [String: Any]) {
    sessionId = dictionary["sessionId"] as? String ?? ""
    state = dictionary["state"] as? String
    project = dictionary["project"] as? String
    title = dictionary["task"] as? String
    message = dictionary["message"] as? String
    detail = dictionary["detail"] as? String
  }
}
