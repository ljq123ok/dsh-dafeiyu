// PetWindow (Step5/Step6 of the macOS native refactor).
//
// A transparent, borderless, always-on-top NSPanel that hosts an animated PetView.
// Window attributes are taken verbatim from the v2 plan §4.2. Frame advancement is
// driven by a `Timer` scheduled on the main run loop (common mode), so it coexists
// with `RunLoop.main.run()` and AppKit event handling without blocking the stdin
// reader (which runs off the main actor).
//
// Step6 reserves extra width on the right of the pet for the speech bubble and
// extra height below the pet for the multi-task card, so the overlays are never
// clipped by the panel bounds. The shared reservation constants live on PetView
// (single source of truth for overlay layout).

import AppKit

final class PetWindow: NSPanel {
  let petView = PetView()
  private var frameTimer: Timer?

  /// Build the panel and show the given clip's first frame. The window anchor is set
  /// near the bottom-right of the main screen; position persistence (drag + LayoutStore)
  /// is Step7.
  init(clip: ResolvedClip) {
    let petSize = PetView.fittingSize(for: clip.frames)
    let size = NSSize(
      width: petSize.width + PetView.bubbleReservedWidth,
      height: petSize.height + PetView.cardReservedHeight
    )
    super.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    // —— §4.2 window attributes, applied verbatim from the plan ——
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    styleMask = [.borderless, .nonactivatingPanel]
    ignoresMouseEvents = false
    hidesOnDeactivate = false
    // —— end §4.2 attributes ——

    // Step6: the view covers the whole panel (pet + reserved bubble column on the
    // right + reserved card row below), so every overlay is drawn inside the
    // view's own bounds and the panel.
    petView.frame = NSRect(origin: .zero, size: size)
    contentView = petView

    if let screen = NSScreen.main {
      let origin = NSPoint(
        x: screen.visibleFrame.maxX - size.width - 24,
        y: screen.visibleFrame.minY + 24
      )
      setFrameOrigin(origin)
    }
    orderFrontRegardless()

    showClip(clip)
  }

  /// Switch to a new clip and (re)start the frame timer. Single-frame clips need no
  /// timer. The timer fires on the main run loop's common modes, so it keeps ticking
  /// while the panel is shown and does not starve the stdin reader.
  func showClip(_ clip: ResolvedClip) {
    frameTimer?.invalidate()
    frameTimer = nil

    petView.setClip(clip.frames, loops: clip.loops)
    guard clip.frames.count > 1 else { return }

    let interval = max(1.0 / 60.0, Double(clip.frameMs) / 1000.0)
    frameTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
      [weak self] _ in
      // The timer is scheduled on the main run loop, so it fires on the main thread.
      // Bridge into the main actor to touch the main-isolated PetView safely.
      MainActor.assumeIsolated { self?.petView.advanceFrame() }
    }
  }
}
