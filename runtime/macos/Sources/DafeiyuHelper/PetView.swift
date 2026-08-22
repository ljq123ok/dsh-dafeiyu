// PetView (Step4 of the macOS native refactor).
//
// Renders a single idle PNG, transparent. No animation, bubbles, or task cards yet
// — those are Step5/Step6. The view itself is non-opaque and draws no background so
// the panel stays see-through.

import AppKit

final class PetView: NSView {
  var image: NSImage? {
    didSet { needsDisplay = true }
  }

  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    // No background fill: keep the panel transparent, only paint the PNG.
    guard let image = image else { return }
    image.draw(in: bounds)
  }

  /// Step4 sizes the window to the image's intrinsic size (baseSize 238). Scale and
  /// drag handling arrive in Step7 via LayoutStore.
  static func fittingSize(for image: NSImage) -> NSSize {
    return image.size
  }
}
