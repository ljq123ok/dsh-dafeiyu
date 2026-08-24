// PetView (Step5/Step6/Step7 of the macOS native refactor).
//
// Renders a clip's frames, one at a time, on a transparent surface. It holds the
// current frame sequence plus a cursor; the window's Timer advances `frameIndex`
// via `advanceFrame()`. The view itself is non-opaque and draws no background so
// the panel stays see-through.
//
// Step6 adds the overlay layers: a single-task speech bubble (message/detail copy
// already computed by the Node layer, plus a todo progress bar) and a multi-task
// card (≥2 active tasks). The overlays are drawn after the PNG so they float on
// top; the bubble area never intercepts mouse events.
//
// Step7 adds CONFIG consumption and dragging:
//   - `scale` scales the pet image (and the window placeholder size is scaled by
//     PetWindow); `bubbleScale` scales the bubble/card overlays around their anchors.
//   - `reducedMotion` holds looping clips on their first frame.
//   - `bubbleFilter`/`stateForBubble` decide overlay visibility per the bubble mode
//     and state (wired by main.swift to CompanionModel.shouldShowBubble).
//   - mouse down/dragged/up drive window dragging through `onDragDelta`/`onDragEnded`.

import AppKit
import QuartzCore

final class PetView: NSView {
  /// Current clip frames (empty when nothing is set).
  private var frames: [NSImage] = []
  /// Playback cursor.
  private var frameIndex = 0
  /// Step12 (crossfade): the outgoing frame plus the fade-in curve. `fadeUntil`
  /// is the media-time deadline; before it the new frame draws at an increasing
  /// fraction over the old frame (fully opaque behind).
  private var fadeFromImage: NSImage?
  private var fadeStarted: CFTimeInterval = 0
  private var fadeDuration: Double = 0
  /// Clips that always swap atomically (no crossfade), per v0.1.5 rules.
  private static let nonCrossfadeClips: Set<String> = ["blink", "glance", "dragging"]
  /// Whether the clip loops back to frame 0 after the last frame.
  private(set) var loops = true
  /// Procedural motion of the current clip (manifest `clips[name].motion`, e.g.
  /// "breathe"). nil = the pet is drawn statically. Drives the breathe/think/work/
  /// wait/bounce/shake/dizzy animation in `drawPet` (t13 F2, v0.1.5 port).
  private var motion: String?
  /// Name of the current clip — the working_search/working_command clips get their
  /// own hop override in `drawPet`, so the name must be available at draw time.
  private var clipName: String?

  /// Height of the card block (0 when hidden), captured in draw() so the bubble
  /// and card overlays can anchor relative to the pet's actual position (Step12
  /// content-driven layout; the pet rises above the card when the card shows).
  private var currentCardBlockH: CGFloat = 0

  // MARK: - Step6 overlay state

  /// Single-task bubble content (nil hides the bubble).
  private var bubble: TaskInfo?
  /// Step12: transient overlay bubble (click interactions, completion pulses).
  /// While set it REPLACES `bubble` in drawing (higher priority); it expires via
  /// `overlayTimer` and the normal bubble shows again.
  private var overlay: TaskInfo?
  private var overlayTimer: Timer?
  /// Multi-task card list (nil or <2 visible entries hides the card).
  private var card: [TaskItem] = []

  // MARK: - Step6 overlay layout

  /// Width reserved to the right of the pet for the speech bubble, and height
  /// reserved below the pet for the multi-task card. These are the single source
  /// of truth shared with PetWindow, so the panel is always large enough that the
  /// overlays land inside the window — visibility never depends on AppKit's
  /// default non-clipping view behavior.
  static let bubbleReservedWidth: CGFloat = 320
  /// 5 card rows (5 × 22) + 12 padding + 12 bottom margin.
  static let cardReservedHeight: CGFloat = 170

  // MARK: - Step7 configuration (from CONFIG / DSH_DAFEIYU_* env)

  /// Pet/window scale factor applied at draw time (0.7–1.4, default 1). PetWindow
  /// sizes the panel by the same factor.
  var scale: CGFloat = 1
  /// Bubble/card scale factor (0.8–1.2, default 1): the overlays are scaled (size and
  /// anchor) by this factor.
  var bubbleScale: CGFloat = 1
  /// Reduced motion: looping clips hold on their first frame (non-looping clips play
  /// once, unchanged).
  var reducedMotion: Bool = false
  /// Visibility filter for one state, wired by main.swift to
  /// `CompanionModel.shouldShowBubble` (bubble mode + bubbleStates). It decides
  /// whether a bubble/card carrying that state is drawn at all.
  var bubbleFilter: (String?) -> Bool = { _ in true }
  /// The companion's current active state — the state the single bubble belongs to
  /// (set alongside `setBubble` by main.swift). The multi-task card filters each
  /// item by its own state instead.
  var stateForBubble: String? = nil

  // MARK: - Step7 dragging

  /// Called on every mouse drag with the window origin captured at mouse-down and
  /// the screen-space displacement. PetWindow wires this to `setFrameOrigin`.
  var onDragDelta: ((NSPoint, CGFloat, CGFloat) -> Void)?
  /// Called when a drag ends (mouse up), so the caller can persist the new position.
  var onDragEnded: (() -> Void)?
  /// Screen-space mouse position captured at mouse-down, plus the window origin then.
  private var dragStartScreen: NSPoint?
  private var dragStartWindowOrigin: NSPoint?

  // MARK: - Step11 right-click menu

  /// Builds the context menu (size/bubble-size/etc.). Wired by PetWindow, which
  /// owns the actual menu items and their actions.
  var onRequestMenu: (() -> NSMenu?)?

  /// NSView.menu(for:) is where a right-click hands the menu to a view. The pet
  /// view covers the whole window, so every right-click on the pet routes here.
  override func menu(for event: NSEvent) -> NSMenu? {
    onRequestMenu?()
  }

  override var isOpaque: Bool { false }

  /// The nonactivating panel is never key; accept the first click so a drag can
  /// start immediately without a double click.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // MARK: - Key window (dragging requires the view to be first responder)

  // Step11: the panel is now a normal NSWindow (not NSPanel) so it CAN become
  // the key window on mouse-down and its view CAN become first responder.
  // NSPanel never accepts becomeKeyWindow, which was why mouseDragged never
  // fired. We make the window key at mouse-down and release it at mouse-up.
  override func becomeFirstResponder() -> Bool { true }
  override func resignFirstResponder() -> Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    // Step11: make the window key (NSPanel could never become key; ordinary
    // NSWindow can, so this now succeeds and mouseDragged fires).
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(self)
    dragStartScreen = NSEvent.mouseLocation
    dragStartWindowOrigin = window.frame.origin
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = dragStartScreen, let base = dragStartWindowOrigin, window != nil else { return }
    let now = NSEvent.mouseLocation
    onDragDelta?(base, now.x - start.x, now.y - start.y)
  }

  /// Step12: click interaction callback (pet-space point in view coordinates,
  /// clickCount). Wired by PetWindow to play head_pat/tail/poke + overlay bubble.
  var onClick: ((NSPoint, Int) -> Void)?

  /// Dragging threshold (screen points): a mouse-up within this distance of the
  /// mouse-down is a click, not a drag.
  private static let dragThreshold: CGFloat = 5

  override func mouseUp(with event: NSEvent) {
    // Step12: distinguish a click from a drag. A release near the press point
    // (≤5pt) is a click — route to the interaction handler; anything farther is
    // a drag and saves the layout as usual.
    if let start = dragStartScreen {
      let now = NSEvent.mouseLocation
      let distance = abs(now.x - start.x) + abs(now.y - start.y)
      if distance <= Self.dragThreshold {
        dragStartScreen = nil
        dragStartWindowOrigin = nil
        window?.resignKey()
        let point = convert(event.locationInWindow, from: nil)
        onClick?(point, event.clickCount)
        return
      }
    }
    dragStartScreen = nil
    dragStartWindowOrigin = nil
    window?.resignKey()
    onDragEnded?()
  }

  /// Replace the displayed clip. Resets the cursor to the first frame. `motion` is
  /// the manifest's clip motion (e.g. "breathe") and `name` the clip's name — both
  /// are needed to reproduce the v0.1.5 procedural animation at draw time.
  func setClip(_ frames: [NSImage], loops: Bool, motion: String? = nil, name: String? = nil) {
    // Step12 (crossfade): the outgoing frame fades into the incoming clip.
    // Different clip → 0.10 s; same clip re-shown → 0.045 s; expression clips
    // (blink/glance/dragging) swap atomically, matching v0.1.5's rules.
    if let previous = currentImage, !Self.nonCrossfadeClips.contains(name ?? ""),
       let current = frames.first {
      let sameClip = name != nil && name == self.clipName
      fadeFromImage = previous
      fadeStarted = CACurrentMediaTime()
      fadeDuration = sameClip ? 0.045 : 0.10
      _ = current
    } else {
      fadeFromImage = nil
      fadeDuration = 0
    }
    self.frames = frames
    self.loops = loops
    self.motion = motion
    self.clipName = name
    self.frameIndex = 0
    needsDisplay = true
  }

  /// Advance to the next frame. When `loops` is true the cursor wraps around;
  /// otherwise it stops on the final frame (callers reset via `setClip`).
  /// Step7: with `reducedMotion`, looping clips hold (and snap back to) frame 0;
  /// non-looping clips still play once.
  func advanceFrame() {
    guard frames.count > 1 else { return }
    if reducedMotion && loops {
      if frameIndex != 0 {
        frameIndex = 0
        needsDisplay = true
      }
      return
    }
    if frameIndex + 1 < frames.count {
      frameIndex += 1
    } else if loops {
      frameIndex = 0
    }
    // Non-looping clip: hold the last frame until `setClip` replaces it.
    needsDisplay = true
  }

  /// One animation tick driven by the window's timer: advance the frame cursor for
  /// multi-frame clips, and repaint single-frame motion clips so the procedural
  /// animation (breathe/think/…) keeps running even though the frame never changes.
  func animateTick() {
    if frames.count > 1 {
      advanceFrame()
    } else {
      needsDisplay = true
    }
  }

  /// The image currently shown.
  var currentImage: NSImage? {
    frames.isEmpty ? nil : frames[frameIndex]
  }

  // MARK: - Step6 overlay API

  /// Update the single-task bubble (pass nil to hide it).
  /// Fired when bubble/card visibility may have changed, so PetWindow can
  /// resize (shrink to the pet alone when no overlay is shown). Wired by main.swift
  /// alongside `updateContentSize`.
  var onOverlayChanged: (() -> Void)?

  /// Step12: show a short-lived overlay bubble (click interaction copy, e.g.
  /// "戳我干嘛，任务还在跑呢"). Clears automatically after `ttlMs` and the
  /// regular bubble (if any) returns. Pass nil/0 to clear immediately.
  func setOverlay(_ info: TaskInfo?, ttlMs: Int = 0) {
    overlayTimer?.invalidate()
    overlayTimer = nil
    overlay = info
    if let info, ttlMs > 0 {
      overlayTimer = Timer.scheduledTimer(withTimeInterval: Double(ttlMs) / 1000.0, repeats: false) {
        [weak self] _ in
        MainActor.assumeIsolated {
          self?.setOverlay(nil)
        }
      }
    }
    needsDisplay = true
    onOverlayChanged?()
  }

  func setBubble(_ info: TaskInfo?) {
    bubble = info
    needsDisplay = true
    onOverlayChanged?()
  }

  /// Update the multi-task card (pass nil or an empty list to hide it).
  func setCard(_ items: [TaskItem]?) {
    card = items ?? []
    needsDisplay = true
    onOverlayChanged?()
  }

  override func draw(_ dirtyRect: NSRect) {
    // No background fill: keep the panel transparent, only paint the PNG.
    guard let image = currentImage else { return }
    // Step7: the pet is anchored just above the reserved card region and scaled by
    // `scale` (AppKit coordinates: origin bottom-left, y up). The overlays are drawn
    // inside the view's own bounds, so nothing relies on AppKit's default
    // non-clipping behavior to stay visible.
    let petSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    // Step12: content-driven layout. The pet sits at the bottom (8pt edge) and
    // rises above the card when the card shows; the bubble hangs off the pet's
    // right edge. Nothing relies on the fixed reserved constants for position —
    // the window is sized to fit (PetWindow.updateContentSize), so overlays
    // always land inside the panel.
    let cardRows = cardVisibleRows
    let cardBlockH = cardRows > 0 ? (CGFloat(cardRows) * 22 * bubbleScale + 12 + 8) : 0
    currentCardBlockH = cardBlockH
    let petRect = NSRect(
      x: 0,
      y: cardBlockH + 8,
      width: petSize.width,
      height: petSize.height
    )
    drawPet(image, in: petRect)

    // Step6 overlays: bubble on the right side of the pet, task card below it.
    // Step7: visibility is filtered per the bubble mode/states.
    // Step12: overlay bubble wins over the steady bubble while it is showing.
    let shownBubble = overlay ?? bubble
    if let shownBubble, bubbleFilter(stateForBubble) {
      drawBubble(shownBubble, imageSize: petSize)
    }
    if !card.isEmpty {
      let visible = card.filter { bubbleFilter($0.state) }
      if visible.count >= 2 {
        drawCard(visible, petWidth: petSize.width)
      }
    }
  }

  // MARK: - Procedural motion (v0.1.5 drawPet port)

  /// Draw the pet image with the current clip's procedural motion applied:
  /// breathe/think/work/wait/bounce/shake/dizzy, plus a hop override for the
  /// working_search/working_command clips. `reducedMotion` disables the motion
  /// (the pet is drawn statically in place).
  ///
  /// The math is ported from v0.1.5 `drawPet`. Note the sign conventions: this
  /// view's axes point up (bottom-left origin), while the original content view
  /// was flipped (top-left origin, y down) — so the y offsets are negated and the
  /// rotation is applied as `-angle` to reproduce the original screen appearance
  /// (positive angle tilts clockwise). The phase is wall-clock time, so animation
  /// stays smooth and independent of the frame timer's cadence.
  private func drawPet(_ image: NSImage, in petRect: NSRect) {
    let phase = CACurrentMediaTime()
    var motionName = motion
    if reducedMotion { motionName = nil }
    var scaleExtra: CGFloat = 1
    var angle: CGFloat = 0
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    switch motionName {
    case "breathe":
      scaleExtra = 1 + 0.02 * CGFloat(sin(phase * 2.5))
      angle = CGFloat(sin(phase * 2.5)) * 1.5
    case "think":
      offsetY = -CGFloat(sin(phase * 2.8)) * 3
      angle = CGFloat(sin(phase * 1.3)) * 0.8
    case "work":
      offsetX = CGFloat(sin(phase * 5.4)) * 3
      angle = CGFloat(sin(phase * 3.1)) * 1.0
    case "wait":
      offsetY = -CGFloat(sin(phase * 1.8)) * 1
      angle = CGFloat(sin(phase * 1.2)) * 0.8
    case "bounce":
      offsetY = abs(CGFloat(sin(phase * 5.2))) * 8
      scaleExtra = 1 + 0.02 * CGFloat(sin(phase * 5.2))
    case "shake", "dizzy":
      offsetX = CGFloat(sin(phase * 11.0)) * 4
      angle = CGFloat(sin(phase * 11.0)) * 1.5
    default:
      break
    }
    if clipName == "working_search" || clipName == "working_command" {
      offsetY = abs(CGFloat(sin(phase * 4.5))) * 5
      angle = CGFloat(sin(phase * 9.0)) * 2.5
    }
    offsetX *= scale
    offsetY *= scale

    // Scale around the image center (the draw rect grows, the center stays put),
    // then rotate around the same center and apply the offset — same geometry as
    // the original: x = minX + (baseW - drawW)/2 + offsetX.
    let drawWidth = petRect.width * scaleExtra
    let drawHeight = petRect.height * scaleExtra
    let centerX = petRect.midX + offsetX
    let centerY = petRect.midY + offsetY

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let cg = NSGraphicsContext.current?.cgContext else { return }
    cg.translateBy(x: centerX, y: centerY)
    if angle != 0 {
      cg.rotate(by: -angle * .pi / 180)
    }
    // Step12 (crossfade): while the fade is active, draw the outgoing frame at
    // full opacity beneath and ramp the incoming frame up (pow 0.7, v0.1.5).
    let elapsed = CACurrentMediaTime() - fadeStarted
    let isFading = fadeDuration > 0 && elapsed < fadeDuration
    if isFading, let from = fadeFromImage {
      from.draw(
        in: NSRect(x: -drawWidth / 2, y: -drawHeight / 2, width: drawWidth, height: drawHeight),
        from: NSRect(origin: .zero, size: from.size),
        operation: .sourceOver,
        fraction: 1
      )
    }
    let fraction: CGFloat = isFading ? CGFloat(pow(min(1, elapsed / fadeDuration), 0.7)) : 1
    image.draw(
      in: NSRect(x: -drawWidth / 2, y: -drawHeight / 2, width: drawWidth, height: drawHeight),
      from: NSRect(origin: .zero, size: image.size),
      operation: .sourceOver,
      fraction: fraction
    )
  }

  // MARK: - Overlay drawing (pure AppKit; no third-party dependencies)

  private func drawBubble(_ info: TaskInfo, imageSize: NSSize) {
    let maxWidth: CGFloat = 240
    var lines: [NSAttributedString] = []
    if let message = info.message, !message.isEmpty {
      lines.append(attributed(message, size: 13, bold: true))
    }
    if let detail = info.detail, !detail.isEmpty {
      lines.append(attributed(detail, size: 12, bold: false))
    }
    // Progress bar state: rendered at the bottom of the bubble when present.
    var progressBar: (completed: Int, total: Int)? = nil
    if let completed = info.completed, let total = info.total, total > 0 {
      progressBar = (completed, total)
    }

    var textHeight: CGFloat = 0
    for line in lines {
      textHeight += line.size().height
    }
    let bubbleHeight = max(34, textHeight + 16 + (progressBar != nil ? 12 : 0))
    // Local rect: origin at the anchor point; the context is translated/scaled there.
    let bubbleRect = NSRect(x: 0, y: 0, width: maxWidth, height: bubbleHeight)

    // Step7: bubble sits to the right of the scaled pet, bottom-aligned with the pet's
    // bottom edge (cardReservedHeight * scale) plus a 12pt margin, so it stays inside
    // the window's reserved bubble column (width ≤ bubbleReservedWidth). The whole
    // bubble (rect and text) is scaled by `bubbleScale` around that anchor.
    guard let context = NSGraphicsContext.current else { return }
    context.saveGraphicsState()
    defer { context.restoreGraphicsState() }
    let cg = context.cgContext
    cg.translateBy(x: imageSize.width + 8, y: currentCardBlockH + imageSize.height + 12)
    cg.scaleBy(x: bubbleScale, y: bubbleScale)

    // Bubble background (semi-transparent dark so white text reads on any pet frame).
    let path = NSBezierPath(roundedRect: bubbleRect, xRadius: 10, yRadius: 10)
    NSColor(calibratedWhite: 0.12, alpha: 0.82).setFill()
    path.fill()

    var cursorY = bubbleRect.maxY - 10
    for line in lines {
      // Step12: draw within the bubble's single text line (10pt insets), so a
      // long line tail-truncates instead of spilling past the bubble edge.
      let lineRect = NSRect(x: bubbleRect.minX + 10, y: cursorY - 18, width: bubbleRect.width - 20, height: 18)
      line.draw(with: lineRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
      cursorY -= line.size().height
    }

    if let progressBar {
      let barRect = NSRect(x: bubbleRect.minX + 10, y: bubbleRect.minY + 8, width: bubbleRect.width - 20, height: 4)
      NSColor(calibratedWhite: 0.4, alpha: 0.6).setFill()
      NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()
      let ratio = CGFloat(progressBar.completed) / CGFloat(progressBar.total)
      if ratio > 0 {
        let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: barRect.width * min(ratio, 1), height: barRect.height)
        NSColor.systemGreen.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2).fill()
      }
    }
  }

  private func drawCard(_ items: [TaskItem], petWidth: CGFloat) {
    // Card below the pet: one row per task, first (highest priority) highlighted.
    // Step7: the card top hugs the pet's bottom edge (cardReservedHeight * scale) and
    // the card grows downward, scaled by `bubbleScale` around that top-left anchor.
    let rowHeight: CGFloat = 22
    let cardWidth: CGFloat = 260
    let cardHeight = CGFloat(min(items.count, 5)) * rowHeight + 12

    guard let context = NSGraphicsContext.current else { return }
    context.saveGraphicsState()
    defer { context.restoreGraphicsState() }
    let cg = context.cgContext
    cg.translateBy(x: max(0, (petWidth - cardWidth) / 2), y: 8)
    cg.scaleBy(x: bubbleScale, y: bubbleScale)

    let cardRect = NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
    let path = NSBezierPath(roundedRect: cardRect, xRadius: 10, yRadius: 10)
    NSColor(calibratedWhite: 0.12, alpha: 0.82).setFill()
    path.fill()

    // Step12: each row occupies [y - rowHeight, y], walking down from the card
    // top inset (8pt). The previous code double-subtracted rowHeight here (both
    // the start and the textColumn), pushing every row below the card's first
    // line — the second row was drawn past the card/window bottom and clipped.
    var y = cardRect.maxY - 8
    for (index, item) in items.prefix(5).enumerated() {
      let label = "\(statusMark(item.state)) \(item.title ?? item.message ?? "…")"
      let text = attributed(label, size: 12, bold: index == 0)
      if index == 0 {
        NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
        let highlight = NSRect(x: cardRect.minX + 4, y: y - 2, width: cardWidth - 8, height: rowHeight - 4)
        NSBezierPath(roundedRect: highlight, xRadius: 6, yRadius: 6).fill()
      }
      // Truncate to the card's text column (10pt insets each side) with tail
      // ellipsis; `draw(with:)` respects the rect and clips instead of
      // overflowing — the "对话看不完整" clipping bug.
      let textColumn = NSRect(x: cardRect.minX + 10, y: y - rowHeight, width: cardWidth - 20, height: rowHeight)
      text.draw(with: textColumn, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
      y -= rowHeight
    }
  }

  private func statusMark(_ state: String?) -> String {
    switch state {
    case "THINKING": return "思"
    case "WORKING": return "做"
    case "WAITING": return "等"
    case "SUCCESS": return "✓"
    case "ERROR": return "✗"
    default: return "·"
    }
  }

  // MARK: - Overlay visibility (PetWindow sizing)

  /// The pet image rectangle in this view's coordinates (bottom-left origin):
  /// x=0, y = card-block height + 8pt, size = pet image × scale. Mirrors the
  /// draw() math so click-zone logic sees the same geometry as the painter.
  var petRectInView: NSRect {
    let imageSize = currentImage?.size ?? NSSize(width: 238, height: 260)
    let petSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let cardRows = cardVisibleRows
    let cardBlockH = cardRows > 0 ? (CGFloat(cardRows) * 22 * bubbleScale + 12 + 8) : 0
    return NSRect(x: 0, y: cardBlockH + 8, width: petSize.width, height: petSize.height)
  }

  /// Whether the single-task bubble is currently drawn (per bubble mode filter).
  var bubbleVisible: Bool {
    (overlay ?? bubble) != nil && bubbleFilter(stateForBubble)
  }

  /// Height the bubble needs at the given content (0 when no bubble): message
  /// + detail lines + 16pt padding + optional 12pt progress bar, min 34. Mirrors
  /// drawBubble's height math so PetWindow can size the panel exactly.
  var bubbleHeightNeeded: CGFloat {
    guard let bubble = overlay ?? bubble else { return 0 }
    var lines: [NSAttributedString] = []
    if let message = bubble.message, !message.isEmpty {
      lines.append(attributed(message, size: 13, bold: true))
    }
    if let detail = bubble.detail, !detail.isEmpty {
      lines.append(attributed(detail, size: 12, bold: false))
    }
    var textHeight: CGFloat = 0
    for line in lines { textHeight += line.size().height }
    let hasBar = (bubble.completed ?? 0) > 0 && (bubble.total ?? 0) > 0
    return max(34, textHeight + 16 + (hasBar ? 12 : 0))
  }

  /// Number of task rows the multi-task card would draw (0 = card hidden).
  var cardVisibleRows: Int {
    guard !card.isEmpty else { return 0 }
    return card.filter { bubbleFilter($0.state) }.count >= 2
      ? min(card.filter { bubbleFilter($0.state) }.count, 5)
      : 0
  }

  private func attributed(_ string: String, size: CGFloat, bold: Bool) -> NSAttributedString {
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    // Step12: tail truncation for every overlay string. `draw(with:)` on an
    // NSAttributedString only clips when the paragraph style allows it; without
    // this, a long task title draws (and clips!) past the card edge — the
    // "文字显示不全" bug.
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    return NSAttributedString(
      string: string,
      attributes: [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
      ]
    )
  }

  /// Step5 sizes the window to the clip's first frame (baseSize 238). PetWindow
  /// multiplies by `scale` for the final panel size.
  static func fittingSize(for frames: [NSImage]) -> NSSize {
    frames.first?.size ?? NSSize(width: 238, height: 260)
  }
}