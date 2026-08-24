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
  /// Last clip passed to `showClip` — kept so the reduced-motion toggle can
  /// re-show it (restarting/stopping the frame timer per the new setting).
  private var lastClip: ResolvedClip?
  /// Unscaled panel size (pet + reserved bubble column + reserved card row).
  /// `applyScale` and the initial init multiply this by the current scale.
  private let baseSize: NSSize

  /// Build the panel and show the given clip's first frame. The window anchor is set
  /// near the bottom-right of the main screen, unless LayoutStore has a persisted
  /// position (Step7: drag persistence). `scale` (default 1) is the initial CONFIG/env
  /// scale used to size the panel.
  init(clip: ResolvedClip, scale: CGFloat = 1) {
    // Step11: a saved menu scale (right-click menu) overrides the env default when
    // present — env is the startup value, but the persisted menu choice wins so the
    // pet keeps the size the user picked. The bubble scale is read the same way.
    var initialScale = scale
    var initialBubbleScale: CGFloat? = nil
    if let layout = LayoutStore.load() {
      if let savedScale = layout.scale {
        initialScale = CGFloat(savedScale)
      }
      if let savedBubble = layout.bubbleScale {
        initialBubbleScale = CGFloat(savedBubble)
      }
    }
    let petSize = PetView.fittingSize(for: clip.frames)
    baseSize = NSSize(
      width: petSize.width + PetView.bubbleReservedWidth,
      height: petSize.height + PetView.cardReservedHeight
    )
    let size = NSSize(
      width: baseSize.width * initialScale,
      height: baseSize.height * initialScale
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
    petView.scale = initialScale
    petView.bubbleScale = initialBubbleScale ?? 1
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
    // Step11: right-click on the pet shows the context menu. NSView.menu(for:)
    // routes the event here via the PetView callback.
    petView.onRequestMenu = { [weak self] in
      self?.buildContextMenu()
    }
    // Step12: bubble/card visibility changes resize the window to fit the shown
    // content (pet alone when no overlay is visible).
    petView.onOverlayChanged = { [weak self] in
      self?.updateContentSize()
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
    // Step12: shrink to content immediately (pet alone at startup; the window
    // grows when the first bubble/card arrives).
    updateContentSize()
    petDebugLog("window created: frame=\(frame) size=\(size) level=\(level.rawValue) ignores=\(ignoresMouseEvents) opaque=\(isOpaque) visible=\(isVisible) screens=\(NSScreen.screens.map { $0.visibleFrame })")
  }

  /// Step7: resize the panel to a new scale, keeping the current origin (bottom-left)
  /// anchored. The pet view covers the whole (new) panel afterwards. Step11: the
  /// right-click menu also calls this, so it persists the new scale too.
  func applyScale(_ s: CGFloat) {
    let clamped = max(0.55, min(1.4, s))
    petView.scale = clamped
    let newSize = NSSize(width: baseSize.width * clamped, height: baseSize.height * clamped)
    let current = frame
    setFrame(NSRect(origin: current.origin, size: newSize), display: true)
    petView.frame = NSRect(origin: .zero, size: newSize)
    updateContentSize()
    saveLayout()
  }

  /// Step12: resize the panel to fit exactly what is shown — the pet alone when
  /// no overlay is visible (a much smaller window), plus the bubble column when
  /// the bubble shows and the card row when the card shows. The origin (bottom-
  /// left) is kept anchored. Called after every bubble/card state change.
  func updateContentSize() {
    // Step12: size the panel to exactly what draw() paints. The bubble column is
    // 240pt wide plus an 8pt gap right of the pet, scaled by bubbleScale; the card
    // block is rows×22pt + 12 + 8, scaled by bubbleScale. Mirrored constants with
    // PetView.draw so the content always fits (and the window shrinks to the pet
    // alone when no overlay is shown).
    let petSize = PetView.fittingSize(for: petView.currentImage.map { [$0] } ?? [])
    let petW = petSize.width * petView.scale
    let petH = petSize.height * petView.scale

    var width = petW + 8 + 8
    var height = petH + 8 + 8

    // Bubble column: sits right of the pet (8pt gap, 240pt wide, 8pt margin),
    // scaled by bubbleScale. Its TOP must be inside the window — the bubble
    // hangs above the pet's top edge (12pt) plus its own height.
    if petView.bubbleVisible {
      width += 240 * petView.bubbleScale
      height = petH + 12 + petView.bubbleHeightNeeded * petView.bubbleScale + 8
    }
    // Card block: sits below the pet, anchored at the window bottom.
    let rows = petView.cardVisibleRows
    if rows > 0 {
      // The card is 260pt wide (scaled) and centered under the pet; when the pet
      // is small (e.g. 0.6 mini) the card is wider than petW+16, so the window
      // must widen to fit it — otherwise the card's right edge clips.
      width = max(width, 260 * petView.bubbleScale + 16)
      height += CGFloat(rows) * 22 * petView.bubbleScale + 12 + 8
    }

    let newSize = NSSize(width: max(width, petW + 1), height: max(height, petH + 1))
    petDebugLog("contentSize: pet=\(petW)x\(petH) bubble=\(petView.bubbleVisible) rows=\(rows) new=\(newSize) frame=\(frame.size)")
    guard newSize != frame.size else { return }
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
  /// logged, never fatal). Step11: also persist the menu-driven scale/bubbleScale so
  /// the size choice survives a restart.
  func saveLayout() {
    LayoutStore.save(LayoutState(
      x: Double(frame.origin.x),
      y: Double(frame.origin.y),
      scale: petView.scale,
      bubbleScale: petView.bubbleScale
    ))
  }

  /// Step11: set a new bubble/card scale (0.8–1.2) from the right-click menu.
  func applyBubbleScale(_ s: CGFloat) {
    let clamped = max(0.8, min(1.2, s))
    petView.bubbleScale = clamped
    petView.needsDisplay = true
    saveLayout()
  }

  // MARK: - Step11 right-click menu

  /// Right-click menu: size / bubble-size / reduced-motion / WebUI / hide / quit.
  /// Mirrors the original Python version's context menu. Rebuilt each time so
  /// checkmarks reflect the current state; actions apply live and persist via
  /// LayoutStore (size/bubble size only). NSView.menu(for:) is the AppKit hook,
  /// so PetView routes right-clicks here through `onRequestMenu`.
  func buildContextMenu() -> NSMenu {
    let menu = NSMenu()

    let sizeMenu = NSMenu()
    for (label, value) in [("迷你", 0.6), ("小", 0.8), ("标准", 1.0), ("大", 1.25)] {
      let item = NSMenuItem(title: label, action: #selector(applyMenuScale(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = value
      item.state = abs(petView.scale - value) < 0.01 ? .on : .off
      sizeMenu.addItem(item)
    }
    let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
    sizeItem.submenu = sizeMenu
    menu.addItem(sizeItem)

    let bubbleMenu = NSMenu()
    for (label, value) in [("小", 0.8), ("标准", 1.0), ("大", 1.2)] {
      let item = NSMenuItem(title: label, action: #selector(applyMenuBubbleScale(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = value
      item.state = abs(petView.bubbleScale - value) < 0.01 ? .on : .off
      bubbleMenu.addItem(item)
    }
    let bubbleItem = NSMenuItem(title: "气泡大小", action: nil, keyEquivalent: "")
    bubbleItem.submenu = bubbleMenu
    menu.addItem(bubbleItem)

    let reducedItem = NSMenuItem(title: "减少动态", action: #selector(toggleReducedMotion(_:)), keyEquivalent: "")
    reducedItem.target = self
    reducedItem.state = petView.reducedMotion ? .on : .off
    menu.addItem(reducedItem)

    menu.addItem(.separator())

    let openItem = NSMenuItem(title: "打开 WebUI", action: #selector(openWebUI(_:)), keyEquivalent: "")
    openItem.target = self
    menu.addItem(openItem)

    let hideItem = NSMenuItem(title: "本次隐藏", action: #selector(hidePet(_:)), keyEquivalent: "")
    hideItem.target = self
    menu.addItem(hideItem)

    let exitItem = NSMenuItem(title: "本次关闭", action: #selector(closePet(_:)), keyEquivalent: "")
    exitItem.target = self
    menu.addItem(exitItem)

    return menu
  }

  @objc private func applyMenuScale(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? NSNumber else { return }
    applyScale(value.doubleValue)
    logToStderr("menu scale -> \(value.doubleValue) (resized to \(frame.size))")
  }

  @objc private func applyMenuBubbleScale(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? NSNumber else { return }
    applyBubbleScale(value.doubleValue)
  }

  @objc private func toggleReducedMotion(_ sender: NSMenuItem) {
    petView.reducedMotion.toggle()
    logToStderr("menu reducedMotion -> \(petView.reducedMotion)")
    // Re-show the current clip: showClip re-evaluates `reducedMotion && loops`
    // and stops/starts the frame timer accordingly (a looping clip freezes on
    // its first frame when reduced motion is on).
    if let clip = lastClip {
      showClip(clip)
    } else {
      petView.needsDisplay = true
    }
  }

  @objc private func openWebUI(_ sender: NSMenuItem) {
    if let url = URL(string: "http://127.0.0.1:3080") {
      NSWorkspace.shared.open(url)
    }
  }

  @objc private func hidePet(_ sender: NSMenuItem) {
    orderOut(nil)
    petDebugLog("menu: hidden (right-click on the hidden pet is gone; re-show at next helper launch)")
  }

  @objc private func closePet(_ sender: NSMenuItem) {
    petDebugLog("menu: closing (CLOSED reply, no restart)")
    // Tell the Node side not to restart the helper: the original Python version
    // emitted `closed`; the Node sets restartSuppressed on that reply. The helper
    // then exits — the user asked to close this pet session.
    emitClosed(reason: "user")
    NSApplication.shared.terminate(nil)
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

  /// Switch to a new clip and (re)start the animation timer. The same timer drives
  /// frame advancement for multi-frame clips AND continuous repainting for
  /// single-frame clips with procedural motion (breathe/think/…), so a motion clip
  /// animates even though its frame never changes. Step7: looping clips with reduced
  /// motion hold their first frame (and motion is disabled in the view), so they
  /// need no timer either. The timer fires on the main run loop's common modes, so it
  /// keeps ticking while the panel is shown and does not starve the stdin reader.
  func showClip(_ clip: ResolvedClip) {
    frameTimer?.invalidate()
    frameTimer = nil
    lastClip = clip

    petView.setClip(clip.frames, loops: clip.loops, motion: clip.motion, name: clip.name)
    if petView.reducedMotion && clip.loops { return }
    let frameAnimates = clip.frames.count > 1
    let motionAnimates = !petView.reducedMotion && clip.motion != nil
    guard frameAnimates || motionAnimates else { return }

    // Frame playback follows the clip's frameMs; a motion-only clip (single frame)
    // repaints at 1/30 s so the procedural animation stays smooth.
    let interval: TimeInterval = frameAnimates
      ? max(1.0 / 60.0, Double(clip.frameMs) / 1000.0)
      : 1.0 / 30.0
    frameTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
      [weak self] _ in
      // Step10 (F3): the timer is scheduled on the main run loop and fires on
      // the main thread. `assumeIsolated` is a no-op runtime assertion — it runs
      // inline without an actor hop, but Swift 6 strict concurrency requires an
      // explicit bridge from this Sendable closure into the main actor.
      MainActor.assumeIsolated { self?.petView.animateTick() }
    }
  }
}