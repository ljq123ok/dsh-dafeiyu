// PetView (Step5/Step6 of the macOS native refactor).
//
// Renders a clip's frames, one at a time, on a transparent surface. It holds the
// current frame sequence plus a cursor; the window's Timer advances `frameIndex`
// via `advanceFrame()`. The view itself is non-opaque and draws no background so
// the panel stays see-through.
//
// Step6 adds the overlay layers: a single-task speech bubble (message/detail copy
// already computed by the Node layer, plus a todo progress bar) and a multi-task
// card (≥2 active tasks). The overlays are drawn after the PNG so they float on
// top; the bubble area never intercepts mouse events (interaction arrives in Step7).

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
  /// Multi-task card list (nil or <2 entries hides the card).
  private var card: [TaskItem] = []

  override var isOpaque: Bool { false }

  /// Replace the displayed clip. Resets the cursor to the first frame.
  func setClip(_ frames: [NSImage], loops: Bool) {
    self.frames = frames
    self.loops = loops
    self.frameIndex = 0
    needsDisplay = true
  }

  /// Advance to the next frame. When `loops` is true the cursor wraps around;
  /// otherwise it stops on the final frame (callers reset via `setClip`).
  func advanceFrame() {
    guard frames.count > 1 else { return }
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
    image.draw(in: bounds)

    // Step6 overlays: bubble on the right side of the pet, task card below it.
    if let bubble {
      drawBubble(bubble, imageSize: image.size)
    }
    if card.count >= 2 {
      drawCard(card)
    }
  }

  // MARK: - Overlay drawing (pure AppKit; no third-party dependencies)

  private func drawBubble(_ info: TaskInfo, imageSize: NSSize) {
    let bubbleOriginX = imageSize.width + 8
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
    let bubbleRect = NSRect(x: bubbleOriginX, y: 12, width: maxWidth, height: bubbleHeight)

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
    let rowHeight: CGFloat = 22
    let cardWidth: CGFloat = 260
    let cardHeight = CGFloat(min(items.count, 5)) * rowHeight + 12
    let cardRect = NSRect(x: 0, y: -cardHeight - 8, width: cardWidth, height: cardHeight)

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

  /// Step5 sizes the window to the clip's first frame (baseSize 238). Scale and
  /// drag handling arrive in Step7 via LayoutStore.
  static func fittingSize(for frames: [NSImage]) -> NSSize {
    frames.first?.size ?? NSSize(width: 238, height: 260)
  }
}
