// CompanionModel (Step4 of the macOS native refactor).
//
// First version only tracks the current companion state. It does NOT drive animation
// or swapping the visible clip — that is Step5, which will consume `stateMap` /
// `workingActivityMap` from the manifest. Step4 keeps the model as a single source of
// truth so Step5 can subscribe to state changes without reshaping the protocol reader.

import Foundation

final class CompanionModel {
  /// Current companion state (defaults to idle). Only stored, never rendered differently
  /// in Step4 — the idle image stays on screen regardless of state.
  var currentState: String = "IDLE"

  /// Called when a `state` protocol message arrives. Step4 stores it and stops; Step5
  /// will branch on `stateMap` here to switch the visible clip.
  func applyState(_ state: String) {
    currentState = state
  }
}
