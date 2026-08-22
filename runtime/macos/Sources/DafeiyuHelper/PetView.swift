// PetView (Step5 of the macOS native refactor).
//
// Renders a clip's frames, one at a time, on a transparent surface. It holds the
// current frame sequence plus a cursor; the window's Timer advances `frameIndex`
// via `advanceFrame()`. The view itself is non-opaque and draws no background so
// the panel stays see-through. Bubbles and task cards arrive in Step6.

import AppKit

final class PetView: NSView {
  /// Current clip frames (empty when nothing is set).
  private var frames: [NSImage] = []
  /// Playback cursor.
  private var frameIndex = 0
  /// Whether the clip loops back to frame 0 after the last frame.
  private(set) var loops = true

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

  override func draw(_ dirtyRect: NSRect) {
    // No background fill: keep the panel transparent, only paint the PNG.
    guard let image = currentImage else { return }
    image.draw(in: bounds)
  }

  /// Step5 sizes the window to the clip's first frame (baseSize 238). Scale and
  /// drag handling arrive in Step7 via LayoutStore.
  static func fittingSize(for frames: [NSImage]) -> NSSize {
    frames.first?.size ?? NSSize(width: 238, height: 260)
  }
}
