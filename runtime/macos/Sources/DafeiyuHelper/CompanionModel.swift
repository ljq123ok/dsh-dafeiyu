// CompanionModel (Step5 of the macOS native refactor).
//
// Owns the animation state machine. Two layers of state drive which clip is shown:
//   - baseState / baseActivity: the steady state from the most recent STATE message.
//   - pulseState: a transient override from a PULSE message (e.g. SUCCESS/ERROR),
//     which expires after its TTL and falls back to the base (or the resume target).
//
// The model is the single source of truth; `activeState`/`activeActivity` is what the
// window should be displaying right now. The protocol reader calls `applyState` /
// `applyPulse`; the window then resolves the matching clip via ManifestStore.

import Foundation

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

  /// Timer that clears the pulse override when it expires.
  private var pulseTimer: Timer?

  /// The state/activity that should currently be rendered: pulse wins over base.
  var activeState: String { pulseState ?? baseState }
  var activeActivity: String? {
    if pulseState != nil { return pulseActivity }
    return baseActivity
  }

  /// Apply a steady STATE message. If no pulse is active, the change takes effect
  /// immediately (the window re-resolves the clip from `activeState/activeActivity`).
  func applyState(_ state: String, activity: String? = nil) {
    baseState = state
    baseActivity = activity
    // A pulse in flight keeps displaying its override; once it expires the window
    // will re-resolve to this new base.
  }

  /// Apply a transient PULSE message. Shows `state` immediately and schedules a
  /// fallback to `resumeState ?? baseState` after `ttlMs` (default 1800 ms).
  func applyPulse(_ state: String, activity: String? = nil, ttlMs: Int? = nil, resumeState: String? = nil) {
    pulseState = state
    pulseActivity = activity
    pulseTimer?.invalidate()
    let ttl = Double(ttlMs ?? 1800) / 1000.0
    pulseTimer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) {
      [weak self] _ in
      // The timer fires on the main run loop's thread, i.e. the main actor.
      MainActor.assumeIsolated { self?.clearPulse(resumeState: resumeState) }
    }
  }

  /// Clear the pulse override. After this the window re-resolves to
  /// `resumeState ?? baseState` (preserving base activity for WORKING).
  private func clearPulse(resumeState: String?) {
    pulseState = nil
    pulseActivity = nil
    if let resume = resumeState, !resume.isEmpty {
      baseState = resume
    }
  }
}
