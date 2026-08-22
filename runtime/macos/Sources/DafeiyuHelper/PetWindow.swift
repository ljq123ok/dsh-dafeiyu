// PetWindow (Step4 of the macOS native refactor).
//
// A transparent, borderless, always-on-top NSPanel that hosts the idle PetView.
// Window attributes are taken verbatim from the v2 plan §4.2.

import AppKit

final class PetWindow: NSPanel {
  let petView = PetView()

  init(image: NSImage) {
    let size = PetView.fittingSize(for: image)
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

    petView.image = image
    petView.frame = NSRect(origin: .zero, size: size)
    contentView = petView

    // Step4: anchor near the bottom-right of the main screen. Position persistence
    // (drag + LayoutStore) is Step7.
    if let screen = NSScreen.main {
      let origin = NSPoint(
        x: screen.visibleFrame.maxX - size.width - 24,
        y: screen.visibleFrame.minY + 24
      )
      setFrameOrigin(origin)
    }
    orderFrontRegardless()
  }
}
