// PetWindow (Step5/Step6/Step7/Step11 of the macOS native refactor).
//
// A transparent, borderless, always-on-top NSWindow (not NSPanel) that hosts an
// animated PetView. NSPanel was originally used for its "nonactivating overlay"
// semantics, but NSPanel never accepts `becomeKeyWindow`, so `makeFirstResponder`
// on the pet view always failed and `mouseDragged` never fired — the pet could
// not be dragged. Step11 switches to a plain NSWindow; the helper is launched
// as an accessory app (NSApplication.setActivationPolicy(.accessory)) so it does
// not enter the dock or steal focus.
// Window attributes are taken verbatim from the v2 plan §4.2. Frame advancement is
// driven by a `Timer` scheduled on the main run loop (common mode), so it coexists
// with `RunLoop.main.run()` and AppKit event handling without blocking the stdin
// reader (which runs off the main actor).
//
// Step6 reserves extra width on the right of the pet for the speech bubble and
// extra height below the pet for the multi-task card, so the overlays are never
// clipped by the panel bounds.
//
// Step7 adds CONFIG-driven sizing and dragging:
//   - the panel is sized by `scale` (pet + reserved regions all scaled);
//   - `applyScale` resizes live (origin-anchored) when a CONFIG message changes scale;
//   - mouse dragging moves the window (clamped to a screen) and persists the new
//     position to LayoutStore on mouse-up;
//   - startup restores a persisted position from LayoutStore when present;
//   - with reduced motion, looping clips stay on their first frame (no timer).

import AppKit

final class PetWindow: NSWindow {
  let petView = PetView()
  private var frameTimer: Timer?
  /// Unscaled panel size (pet + reserved bubble column + reserved card row).
  /// `applyScale` and the initial init multiply this by the current scale.
  private let baseSize: NSSize

  /// Build the panel and show the given clip's first frame. The window anchor is set
  /// near the bottom-right of the main screen, unless LayoutStore has a persisted
  /// position (Step7: drag persistence). `scale` (default 1) is the initial CONFIG/env
  /// scale used to size the panel.
  init(clip: ResolvedClip, scale: CGFloat = 1) {
    let petSize = PetView.fittingSize(for: clip.frames)
    baseSize = NSSize(
      width: petSize.width + PetView.bubbleReservedWidth,
      height: petSize.height + PetView.cardReservedHeight
    )
    let size = NSSize(
      width: baseSize.width * scale,
      height: baseSize.height * scale
    )
    super.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    // —— §4.2 window attributes, applied verbatim from the plan ——
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    styleMask = [.borderless]
    // Step11: intentionally NOT nonactivating — a nonactivating panel can never
    // become key, and `makeFirstResponder` only works inside a key window.
    // Making the panel briefly key during a drag is the reliable way to let
    // mouseDragged fire; the "don't steal focus" behavior is restored at mouseUp.
    ignoresMouseEvents = false
    hidesOnDeactivate = false
    // —— end §4.2 attributes ——

    // Step7: let the view know its current scale; Step6 view covers the whole panel
    // (pet + reserved bubble column on the right + reserved card row below), so every
    // overlay is drawn inside the view's own bounds and the panel.
    petView.scale = scale
    petView.frame = NSRect(origin: .zero, size: size)
    contentView = petView

    // Step7: drag wiring. The pet view reports screen-space displacement from the
    // origin captured at mouse-down; the window moves clamped to a screen and saves
    // the final position on mouse-up.
    petView.onDragDelta = { [weak self] baseOrigin, dx, dy in
      self?.applyDrag(baseOrigin: baseOrigin, dx: dx, dy: dy)
    }
    petView.onDragEnded = { [weak self] in
      self?.saveLayout()
    }

    if let screen = NSScreen.main {
      let origin = NSPoint(
        x: screen.visibleFrame.maxX - size.width - 24,
        y: screen.visibleFrame.minY + 24
      )
      setFrameOrigin(origin)
    }
    // Step7: restore a persisted position (only when a valid layout file exists;
    // LayoutStore.load returns nil on missing/corrupt data → keep the default anchor).
    if let layout = LayoutStore.load() {
      setFrameOrigin(NSPoint(x: layout.x, y: layout.y))
    }
    orderFrontRegardless()

    showClip(clip)
    petDebugLog("window created: frame=\(frame) size=\(size) level=\(level.rawValue) ignores=\(ignoresMouseEvents) opaque=\(isOpaque) visible=\(isVisible) screens=\(NSScreen.screens.map { $0.visibleFrame })")
  }

  /// Step7: resize the panel to a new scale, keeping the current origin (bottom-left)
  /// anchored. The pet view covers the whole (new) panel afterwards.
  func applyScale(_ s: CGFloat) {
    let clamped = max(0.7, min(1.4, s))
    petView.scale = clamped
    let newSize = NSSize(width: baseSize.width * clamped, height: baseSize.height * clamped)
    let current = frame
    setFrame(NSRect(origin: current.origin, size: newSize), display: true)
    petView.frame = NSRect(origin: .zero, size: newSize)
  }

  /// Step7: move the window by the drag displacement, clamped so the panel stays
  /// within the visible frame of a screen.
  func applyDrag(baseOrigin: NSPoint, dx: CGFloat, dy: CGFloat) {
    let proposed = NSPoint(x: baseOrigin.x + dx, y: baseOrigin.y + dy)
    setFrameOrigin(clampedOrigin(proposed))
  }

  /// Step7: persist the current origin to LayoutStore (non-critical; save failure is
  /// logged, never fatal).
  func saveLayout() {
    LayoutStore.save(LayoutState(x: Double(frame.origin.x), y: Double(frame.origin.y)))
  }

  /// Clamp `origin` so the panel stays at least fully inside the visible frame of the
  /// screen under the cursor (falling back to the most-overlapped screen, then main).
  private func clampedOrigin(_ origin: NSPoint) -> NSPoint {
    let proposed = NSRect(origin: origin, size: frame.size)
    let screens = NSScreen.screens
    let cursor = NSEvent.mouseLocation
    let screen =
      screens.first { $0.visibleFrame.contains(cursor) }
      ?? screens.max { lhs, rhs in
        let a = lhs.visibleFrame.intersection(proposed)
        let b = rhs.visibleFrame.intersection(proposed)
        return a.width * a.height < b.width * b.height
      }
      ?? NSScreen.main
    guard let screen else { return origin }
    let visible = screen.visibleFrame
    var x = origin.x
    var y = origin.y
    if x < visible.minX { x = visible.minX }
    if x + frame.width > visible.maxX { x = max(visible.minX, visible.maxX - frame.width) }
    if y < visible.minY { y = visible.minY }
    if y + frame.height > visible.maxY { y = max(visible.minY, visible.maxY - frame.height) }
    return NSPoint(x: x, y: y)
  }

  /// Switch to a new clip and (re)start the frame timer. Single-frame clips need no
  /// timer; Step7: looping clips with reduced motion hold their first frame, so they
  /// need no timer either. The timer fires on the main run loop's common modes, so it
  /// keeps ticking while the panel is shown and does not starve the stdin reader.
  func showClip(_ clip: ResolvedClip) {
    frameTimer?.invalidate()
    frameTimer = nil

    petView.setClip(clip.frames, loops: clip.loops)
    if petView.reducedMotion && clip.loops { return }
    guard clip.frames.count > 1 else { return }

    let interval = max(1.0 / 60.0, Double(clip.frameMs) / 1000.0)
    frameTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
      [weak self] _ in
      // Step10 (F3): the timer is scheduled on the main run loop and fires on
      // the main thread. `assumeIsolated` is a no-op runtime assertion — it runs
      // inline without an actor hop, but Swift 6 strict concurrency requires an
      // explicit bridge from this Sendable closure into the main actor.
      MainActor.assumeIsolated { self?.petView.advanceFrame() }
    }
  }
}