// DSHNotifier (Step8 of the macOS native refactor).
//
// Delivers macOS Notification Center alerts for SUCCESS/ERROR completion states,
// built on UNUserNotificationCenter only — a system framework, no network, no
// webhook/Slack/Telegram.
//
// Discipline (plan §4.1/§6):
//   - Permission is read via notificationSettings(); we NEVER call
//     requestAuthorization, so no permission UI is ever shown and a missing
//     grant never blocks the main feature.
//   - Only .authorized / .provisional actually send: .denied / .notDetermined
//     and any request failure are reported to stderr only (never a crash, never
//     an exit, never a UI pop-up).
//   - Swift does not invent copy: the title is the fixed "大肥鱼", the body is
//     the reducer-computed message/detail; a neutral fallback (with a stderr
//     note) is used only when both are missing — never silently.
//   - Banners are visual-only: completion audio is owned by SoundPlayer
//     (NSSound, gated by the `soundEnabled` config), so a completion never
//     double-dings and the banner never makes noise on its own.
//   - Named DSHNotifier (not "NotificationCenter") to avoid colliding with
//     Foundation's NotificationCenter.
//
// Hard platform gate (observed, must never regress): on macOS,
// +[UNUserNotificationCenter currentNotificationCenter] ABORTS the process
// (SIGABRT / EXC_CRASH) when the caller has no bundle identity. A bare CLI
// executable — like this helper — reports `Bundle.main.bundleIdentifier == nil`
// (the `NSApplicationBundleIdentifier` UserDefaults trick does NOT change that),
// so calling `current()` unconditionally would violate §6.3 "通知失败绝不 crash".
// `deliver` therefore checks for a bundle identity first and, when absent, writes
// a single stderr line and returns. Only when the helper runs inside a real app
// bundle (the Step9/README distribution shape) does the notification path run —
// and even then every failure is stderr-only.
//
// This type never checks isHeadless itself: main.swift only calls deliver() from
// its !isHeadless branch, so the headless protocol path never touches
// notification code at all.

import Foundation
import UserNotifications

enum DSHNotifier {
  /// Centralized entry point: decide and deliver. All failure paths are
  /// stderr-only. Safe to call at any time — never blocks, never exits, never
  /// pops UI, never crashes. Runs the actual delivery on the main actor.
  static func deliver(state: String, message: String?, detail: String?) {
    // macOS requires a bundle identity before UNUserNotificationCenter may be
    // touched at all; without one, current() aborts the process. Guard first,
    // and degrade to a stderr note when the helper is running as a bare CLI.
    guard Bundle.main.bundleIdentifier != nil else {
      log("desktop notifications unavailable: process has no bundle identifier; skipping desktop notification")
      return
    }

    Task { @MainActor in
      let center = UNUserNotificationCenter.current()
      let settings = await center.notificationSettings()
      let status = settings.authorizationStatus
      guard status == .authorized || status == .provisional else {
        log("notification permission not granted (status: \(statusName(status))); skipping desktop notification")
        return
      }

      let content = UNMutableNotificationContent()
      content.title = "大肥鱼"
      let body = message ?? detail ?? "DSH 任务状态更新"
      if message == nil && detail == nil {
        log("notification body fell back to neutral copy: no message/detail in payload")
      }
      content.body = body
      content.userInfo = ["state": state]
      // No content.sound: completion audio is the pet's own (SoundPlayer,
      // NSSound + soundEnabled config). Adding the notification's default
      // sound here would double-ding alongside the pet chime, and a
      // soundEnabled = off setting would still make noise.
      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
      )
      do {
        try await center.add(request)
      } catch {
        log("notification request failed: \(error)")
      }
    }
  }

  /// Write one stderr line using the same `dsh-dafeiyu-helper: ` prefix as the
  /// rest of the helper, so the notification log stays greppable and uniform.
  private static func log(_ message: String) {
    FileHandle.standardError.write(Data("dsh-dafeiyu-helper: \(message)\n".utf8))
  }

  private static func statusName(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .authorized: return "authorized"
    case .provisional: return "provisional"
    case .ephemeral: return "ephemeral"
    @unknown default: return "unknown"
    }
  }
}