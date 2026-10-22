import AppKit
import InkRelayCore
import UserNotifications

/// What the app tells you about, through macOS notifications: problems when they appear, new notes if asked,
/// a daily review nudge, and a newer version. Quiet otherwise. Only works from a bundled app; `swift run` has
/// no bundle and gets nothing.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called on the main queue when the review reminder is clicked.
    var onOpenReview: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        return UNUserNotificationCenter.current()
    }

    func prepare() {
        center?.delegate = self
    }

    /// Problems new since the last notice, or older than a day. A stuck problem isn't repeated every pass.
    func problems(_ problems: [String], now: Date = Date()) {
        var notified = defaults.dictionary(forKey: "notifiedProblems") as? [String: Double] ?? [:]
        let fresh = problems.filter { problem in
            guard let at = notified[problem] else { return true }
            return now.timeIntervalSince1970 - at > 24 * 3600
        }
        notified = notified.filter { problems.contains($0.key) }
        for problem in fresh { notified[problem] = now.timeIntervalSince1970 }
        defaults.set(notified, forKey: "notifiedProblems")
        guard !fresh.isEmpty else { return }
        let title = fresh.count == 1 ? "InkRelay needs you" : "InkRelay needs you: \(fresh.count) problems"
        deliver(id: "problems", title: title, body: fresh.prefix(2).joined(separator: "\n"))
    }

    func newNotes(_ titles: [String]) {
        guard !titles.isEmpty else { return }
        let title = titles.count == 1 ? "1 note synced" : "\(titles.count) notes synced"
        deliver(id: "new-notes", title: title, body: titles.prefix(3).joined(separator: ", "))
    }

    /// A daily reminder at `hour:minute` with the current count; replaced after every sync, removed when nothing waits.
    func reviewReminder(hour: Int, minute: Int, count: Int) {
        guard let center else { return }
        center.removePendingNotificationRequests(withIdentifiers: ["review-reminder"])
        guard count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = count == 1 ? "1 card to review" : "\(count) cards to review"
        content.body = "Flip through your tablet's new pages when you have a minute."
        content.sound = .default
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        authorized { center.add(UNNotificationRequest(identifier: "review-reminder", content: content, trigger: trigger)) }
    }

    /// Once per version.
    func updateAvailable(_ release: ReleaseInfo) {
        guard defaults.string(forKey: "notifiedUpdate") != release.version else { return }
        defaults.set(release.version, forKey: "notifiedUpdate")
        deliver(id: "update", title: "InkRelay \(release.version) is available", body: "You have \(InkRelayCore.version). Open the InkRelay menu to download it.")
    }

    private func deliver(id: String, title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        authorized { center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
    }

    /// Asks once; macOS remembers the answer.
    private func authorized(_ body: @escaping () -> Void) {
        center?.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { body() }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // A menu bar app is never "in front", so banners always show.
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        DispatchQueue.main.async { [weak self] in
            if id == "review-reminder" {
                self?.onOpenReview?()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }
}
