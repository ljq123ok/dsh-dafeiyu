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

final class PetView: NSView {
  /// Current clip frames (empty when nothing is set).
  private var frames: [NSImage] = []
  /// Playback cursor.
  private var frameIndex = 0
  /// Whether the clip loops back to frame 0 after the last frame.
  private(set) var loops = true

  // MARK: - Step6 overlay state

  /// Single-task bubble content (nil hides the bubble).
  private var bubble: TaskInfo?
  /// Multi-task card list (nil or <2 visible entries hides the card).
  private var card: [TaskItem] = []

  // MARK: - Step6 overlay layout

  /// Width reserved to the right of the pet for the speech bubble, and height
  /// reserved below the pet for the multi-task card. These are the single source
  /// of truth shared with PetWindow, so the panel is always large enough that the
  /// overlays land inside the window — visibility never depends on AppKit's
  /// default non-clipping view behavior.
  static let bubbleReservedWidth: CGFloat = 256
  /// 5 card rows (5 × 22) + 12 padding + 12 bottom margin.
  static let cardReservedHeight: CGFloat = 134

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

  override var isOpaque: Bool { false }

  /// The nonactivating panel is never key; accept the first click so a drag can
  /// start immediately without a double click.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // MARK: - First responder (dragging requires first-responder state)

  // Step11: a nonactivating NSPanel never becomes key, so the system will not
  // automatically make its view the first responder. Without this, mouseDown fires
  // but mouseDragged never does — the drag never moves the window. We manually
  // grab first-responder status at the start of a drag and give it back on mouse-up.
  override func becomeFirstResponder() -> Bool { true }
  override func resignFirstResponder() -> Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    // Step11: without becoming first responder, mouseDragged is never delivered to
    // a view inside a nonactivating panel — this is the root cause of "cannot drag".
    // Use `self.window`, not NSApp.mainWindow: a nonactivating panel is never key,
    // so NSApp.mainWindow can be nil or another app's window and the call silently
    // fails. We must install first responder within the pet window itself.
    window.makeFirstResponder(self)
    dragStartScreen = NSEvent.mouseLocation
    dragStartWindowOrigin = window.frame.origin
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = dragStartScreen, let base = dragStartWindowOrigin, window != nil else { return }
    let now = NSEvent.mouseLocation
    onDragDelta?(base, now.x - start.x, now.y - start.y)
  }

  override func mouseUp(with event: NSEvent) {
    dragStartScreen = nil
    dragStartWindowOrigin = nil
    // Step11: release first-responder status so the view can be re-activated on the
    // next drag; keeping it would steal focus from other apps while the pet is idle.
    window?.resignFirstResponder()
    onDragEnded?()
  }

  /// Replace the displayed clip. Resets the cursor to the first frame.
  func setClip(_ frames: [NSImage], loops: Bool) {
    self.frames = frames
    self.loops = loops
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

  /// The image currently shown.
  var currentImage: NSImage? {
    frames.isEmpty ? nil : frames[frameIndex]
  }

  // MARK: - Step6 overlay API

  /// Update the single-task bubble (pass nil to hide it).
  func setBubble(_ info: TaskInfo?) {
    bubble = info
    needsDisplay = true
  }

  /// Update the multi-task card (pass nil or an empty list to hide it).
  func setCard(_ items: [TaskItem]?) {
    card = items ?? []
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    // No background fill: keep the panel transparent, only paint the PNG.
    guard let image = currentImage else { return }
    // Step7: the pet is anchored just above the reserved card region and scaled by
    // `scale` (AppKit coordinates: origin bottom-left, y up). The overlays are drawn
    // inside the view's own bounds, so nothing relies on AppKit's default
    // non-clipping behavior to stay visible.
    let petSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let petRect = NSRect(
      x: 0,
      y: Self.cardReservedHeight * scale,
      width: petSize.width,
      height: petSize.height
    )
    image.draw(in: petRect)

    // Step6 overlays: bubble on the right side of the pet, task card below it.
    // Step7: visibility is filtered per the bubble mode/states.
    if let bubble, bubbleFilter(stateForBubble) {
      drawBubble(bubble, imageSize: petSize)
    }
    if !card.isEmpty {
      let visible = card.filter { bubbleFilter($0.state) }
      if visible.count >= 2 {
        drawCard(visible)
      }
    }
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
    cg.translateBy(x: imageSize.width + 8, y: Self.cardReservedHeight * scale + 12)
    cg.scaleBy(x: bubbleScale, y: bubbleScale)

    // Bubble background (semi-transparent dark so white text reads on any pet frame).
    let path = NSBezierPath(roundedRect: bubbleRect, xRadius: 10, yRadius: 10)
    NSColor(calibratedWhite: 0.12, alpha: 0.82).setFill()
    path.fill()

    var cursorY = bubbleRect.maxY - 10
    for line in lines {
      let size = line.size()
      line.draw(at: NSPoint(x: bubbleRect.minX + 10, y: cursorY - size.height))
      cursorY -= size.height
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

  private func drawCard(_ items: [TaskItem]) {
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
    cg.translateBy(x: 0, y: Self.cardReservedHeight * scale - 8)
    cg.scaleBy(x: bubbleScale, y: bubbleScale)

    let cardRect = NSRect(x: 0, y: -cardHeight, width: cardWidth, height: cardHeight)
    let path = NSBezierPath(roundedRect: cardRect, xRadius: 10, yRadius: 10)
    NSColor(calibratedWhite: 0.12, alpha: 0.82).setFill()
    path.fill()

    var y = cardRect.maxY - 8 - rowHeight
    for (index, item) in items.prefix(5).enumerated() {
      let label = "\(statusMark(item.state)) \(item.title ?? item.message ?? "…")"
      let text = attributed(label, size: 12, bold: index == 0)
      if index == 0 {
        NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
        let highlight = NSRect(x: cardRect.minX + 4, y: y - 2, width: cardWidth - 8, height: rowHeight - 4)
        NSBezierPath(roundedRect: highlight, xRadius: 6, yRadius: 6).fill()
      }
      let size = text.size()
      text.draw(at: NSPoint(x: cardRect.minX + 10, y: y - size.height / 2 - 2))
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

  private func attributed(_ string: String, size: CGFloat, bold: Bool) -> NSAttributedString {
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    return NSAttributedString(
      string: string,
      attributes: [.font: font, .foregroundColor: NSColor.white]
    )
  }

  /// Step5 sizes the window to the clip's first frame (baseSize 238). PetWindow
  /// multiplies by `scale` for the final panel size.
  static func fittingSize(for frames: [NSImage]) -> NSSize {
    frames.first?.size ?? NSSize(width: 238, height: 260)
  }
}