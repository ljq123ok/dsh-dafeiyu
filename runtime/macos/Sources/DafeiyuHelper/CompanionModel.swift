// CompanionModel (Step5/Step6/Step7 of the macOS native refactor).
//
// Owns the animation state machine. Two layers of state drive which clip is shown:
//   - baseState / baseActivity: the steady state from the most recent STATE message.
//   - pulseState: a transient override from a PULSE message (e.g. SUCCESS/ERROR),
//     which expires after its TTL and falls back to the base (or the resume target).
//
// Step6 adds the task/bubble state: the model consumes the TASK/TASKS messages (and
// the task/progress/detail fields that STATE also carries) and exposes them to the
// view for bubble and multi-task-card rendering. The model remains the single source
// of truth; the protocol reader calls `applyState`/`applyPulse`/`applyTask`/
// `applyTasks`; the window then resolves the matching clip via ManifestStore and the
// view draws the bubble from `currentTask`/`taskList`.
//
// Step7 adds the CONFIG consumption: the model stores the configuration fields
// (scale/bubbleScale/reducedMotion/bubbleMode/bubbleStates, plus activityLevel which
// is stored but not consumed yet) and answers the visibility question — whether a
// bubble/card with a given state should be shown — via `shouldShowBubble`. Main.swift
// feeds the initial values from `DSH_DAFEIYU_*` env at startup and applies live CONFIG
// messages through `applyConfig`.
//
// Step8 adds notification snapshots: `applyState`/`applyPulse` also store the
// reducer-computed `message`/`detail` (stateMessage/stateDetail and
// pulseMessage/pulseDetail) so main.swift can read them for the desktop
// notification. These fields never participate in drawing — the bubble/card
// copy still comes from `currentTask`/`taskList`. Whether anything is notified
// is decided in main.swift (deliver only for SUCCESS/ERROR, only in visual
// mode); the model never decides that.

import Foundation

/// A single task shown in the bubble: title, optional todo progress, and the copy
/// (message/detail) that the Node layer already computed (Swift never invents copy).
struct TaskInfo {
  var title: String?
  var completed: Int?
  var total: Int?
  var message: String?
  var detail: String?
  var project: String?

  /// Convenience: `true` when there is anything worth rendering.
  var isEmpty: Bool {
    title == nil && completed == nil && total == nil && message == nil && detail == nil && project == nil
  }
}

/// One entry of the multi-task card (from a TASKS message; ordering already decided
/// by the reducer's priority sort — Swift keeps the order as received).
struct TaskItem {
  var sessionId: String
  var state: String?
  var project: String?
  var title: String?
  var message: String?
  var detail: String?
}

/// The model is only ever touched from the main actor (the protocol reader's
/// `handleLine`, which is `@MainActor`), so it is explicitly main-actor-isolated.
/// This keeps its `Timer` callbacks and state access on the same actor as the view.
@MainActor
final class CompanionModel {
  /// Steady state from the last STATE message (defaults to idle).
  private(set) var baseState: String = "IDLE"
  /// Activity refinement for the steady state (used when baseState == WORKING).
  private(set) var baseActivity: String?

  /// Transient override state from the latest PULSE, or nil when no pulse is active.
  private(set) var pulseState: String?
  /// Activity refinement for the pulse (preserved so a WORKING+activity pulse restores
  /// the same granularity on expiry — t13 F1).
  private(set) var pulseActivity: String?

  /// Step8: message/detail snapshot from the latest PULSE (reducer-computed copy;
  /// notification source only — never used for drawing).
  private(set) var pulseMessage: String?
  private(set) var pulseDetail: String?

  /// Step8: message/detail snapshot from the latest STATE (reducer-computed copy;
  /// notification source only — never used for drawing).
  private(set) var stateMessage: String?
  private(set) var stateDetail: String?

  /// Timer that clears the pulse override when it expires.
  private var pulseTimer: Timer?

  /// Step6: the current task for the single-task bubble (nil when idle / no task).
  /// Updated by `applyTask` (TASK message) and by `applyState` (STATE also carries
  /// task/progress/detail/payload.message — reducer L487-495).
  private(set) var currentTask: TaskInfo?

  /// Step6: the multi-task card list (from TASKS messages). The reducer clears it by
  /// sending `{ tasks: [] }` when fewer than two tasks are active, which maps to nil.
  private(set) var taskList: [TaskItem]?

  // MARK: - Step7 configuration (CONFIG message / DSH_DAFEIYU_* env)

  /// Window/pet scale factor (0.7–1.4, default 1). Internal (not private) so
  /// main.swift can seed it from DSH_DAFEIYU_* env before the window is built.
  var configScale: Double = 1
  /// Bubble/card scale factor (0.8–1.2, default 1).
  var configBubbleScale: Double = 1
  /// Reduced motion: hold looping clips on their first frame (default false).
  var configReducedMotion: Bool = false
  /// Bubble mode: "always" | "hidden" | "custom" (default "always").
  var configBubbleMode: String = "always"
  /// In "custom" mode, which states may show a bubble (default SUCCESS/ERROR/WAITING).
  var configBubbleStates: Set<String> = ["SUCCESS", "ERROR", "WAITING"]
  /// Activity level ("quiet"/"normal"/"lively"). Carried by CONFIG/env but **not
  /// consumed yet** (idle micro-action frequency is a later step, see plan §8).
  var configActivityLevel: String = "normal"

  /// Hook invoked whenever the active clip should be re-resolved and redrawn — after a
  /// STATE change or a pulse expiry. main.swift wires this to `showActiveClip` so the
  /// window follows the model without the model holding view/window references (F4: a
  /// pulse that expires must redraw to the base clip, not leave the pulse frame on screen).
  /// Step7: `applyConfig` also fires it so a CONFIG-only change still repaints.
  var onActiveClipChanged: (() -> Void)?

  /// The state/activity that should currently be rendered: pulse wins over base.
  var activeState: String { pulseState ?? baseState }

  /// Whether a bubble/card associated with `state` should be shown, per the current
  /// bubble mode:
  ///   - "hidden"  → never.
  ///   - "custom"  → only when `state` is in `bubbleStates`.
  ///   - "always"  → always.
  /// The multi-task card applies this per task item (filtered, then ≥2 remain).
  /// MainActor-isolated: main.swift snapshots the decision into the view's pure-value
  /// filter closure (main.swift configurePetView), which the view consults at draw
  /// time without an actor hop.
  func shouldShowBubble(state: String?) -> Bool {
    switch configBubbleMode {
    case "hidden":
      return false
    case "custom":
      guard let state else { return false }
      return configBubbleStates.contains(state)
    default:
      return true
    }
  }

  /// Apply a CONFIG message payload. Invalid/missing values keep the current value
  /// (defaults at startup). Fires `onActiveClipChanged` so the visible overlays are
  /// re-evaluated (window resizing for `scale` is handled by main.swift's UI wiring).
  func applyConfig(_ config: [String: Any]) {
    if let scale = config["scale"] as? Double, (0.7...1.4).contains(scale) {
      configScale = scale
    }
    if let bubbleScale = config["bubbleScale"] as? Double, (0.8...1.2).contains(bubbleScale) {
      configBubbleScale = bubbleScale
    }
    if let reducedMotion = config["reducedMotion"] as? Bool {
      configReducedMotion = reducedMotion
    }
    if let bubbleMode = config["bubbleMode"] as? String, ["always", "hidden", "custom"].contains(bubbleMode) {
      configBubbleMode = bubbleMode
    }
    if let bubbleStates = config["bubbleStates"] as? [Any] {
      // Step10 (F5): a CONFIG message with an empty array must clear bubbleStates
      // so "custom" mode can be turned off; TASKS uses nil as its clear signal,
      // but CONFIG has no separate "absent" case — an explicit [] must clear.
      configBubbleStates = Set(bubbleStates.compactMap { $0 as? String })
    }
    if let activityLevel = config["activityLevel"] as? String, ["quiet", "normal", "lively"].contains(activityLevel) {
      configActivityLevel = activityLevel
    }
    onActiveClipChanged?()
  }
  var activeActivity: String? {
    if pulseState != nil { return pulseActivity }
    return baseActivity
  }

  /// Apply a steady STATE message. If no pulse is active, the change takes effect
  /// immediately (the window re-resolves the clip from `activeState/activeActivity`).
  /// Step6: STATE also carries task/progress/detail/payload.message, so the bubble
  /// data is refreshed here too (otherwise a state change would leave stale bubble copy).
  /// Step8: the reducer-computed `message`/`detail` are snapshotted for the desktop
  /// notification (never used for drawing).
  func applyState(_ state: String, activity: String? = nil,
                  task: TaskInfo? = nil, message: String? = nil, detail: String? = nil) {
    baseState = state
    baseActivity = activity
    stateMessage = message
    stateDetail = detail
    if let task { currentTask = task.isEmpty ? nil : task }
    // A pulse in flight keeps displaying its override; once it expires the window
    // will re-resolve to this new base via `onActiveClipChanged`.
    onActiveClipChanged?()
  }

  /// Step6: apply a TASK message (todo progress update). `task == nil` (or empty)
  /// clears the single-task bubble.
  func applyTask(_ task: TaskInfo?) {
    if let task {
      currentTask = task.isEmpty ? nil : task
    } else {
      currentTask = nil
    }
    onActiveClipChanged?()
  }

  /// Step6: apply a TASKS message. An empty list (the reducer's `{ tasks: [] }` clear)
  /// hides the multi-task card; a list of one is also kept (the reducer only sends
  /// TASKS when ≥2 are active, but tolerating one is harmless).
  func applyTasks(_ tasks: [TaskItem]) {
    taskList = tasks.isEmpty ? nil : tasks
    onActiveClipChanged?()
  }

  /// Apply a transient PULSE message. Shows `state` immediately and schedules a
  /// fallback to `resumeState ?? baseState` after `ttlMs` (default 1800 ms).
  /// Step8: the reducer-computed `message`/`detail` are snapshotted for the desktop
  /// notification (never used for drawing).
  func applyPulse(_ state: String, activity: String? = nil, ttlMs: Int? = nil, resumeState: String? = nil,
                  message: String? = nil, detail: String? = nil) {
    pulseState = state
    pulseActivity = activity
    pulseMessage = message
    pulseDetail = detail
    pulseTimer?.invalidate()
    let ttl = Double(ttlMs ?? 1800) / 1000.0
    pulseTimer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) {
      [weak self] _ in
      // Step10 (F2/F6): the timer is scheduled on the main run loop and fires
      // on the main thread. `assumeIsolated` is a no-op runtime assertion — it
      // runs inline without an actor hop, but under Swift 6 strict concurrency
      // the compiler still requires an explicit bridge from this Sendable
      // closure into the main actor. Release the one-shot timer after it fires
      // so a subsequent pulse can reschedule without holding a dead reference.
      MainActor.assumeIsolated {
        self?.clearPulse(resumeState: resumeState)
        self?.pulseTimer = nil
      }
    }
  }

  /// Clear the pulse override. After this the window re-resolves to
  /// `resumeState ?? baseState` (preserving base activity for WORKING).
  /// Step8: the notification snapshot is cleared alongside the pulse override.
  private func clearPulse(resumeState: String?) {
    pulseState = nil
    pulseActivity = nil
    pulseMessage = nil
    pulseDetail = nil
    // Step10 (F4): resumeState is an intentional override of baseState, not a
    // fallback to the last STATE. The reducer emits the state that the pulse
    // should land on when it expires (e.g. IDLE after a SUCCESS), so writing it
    // to baseState is the correct behaviour — the base is advanced to that
    // target rather than left at the pre-pulse value.
    if let resume = resumeState, !resume.isEmpty {
      baseState = resume
    }
    // F4: redraw immediately so the pulse frame is replaced by the base clip now,
    // without waiting for the next STATE/PULSE message.
    onActiveClipChanged?()
  }
}
