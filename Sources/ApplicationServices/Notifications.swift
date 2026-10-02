import Foundation
import UserNotifications

extension AppModel {
    func requestNotifications() async {
        guard settings.notifications, Bundle.main.bundleURL.pathExtension == "app" else { return }
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { log("Notifications unavailable: \(error.localizedDescription)") }
    }
    func notify(key: String, title: String, text: String, minimumInterval: TimeInterval = 5) async {
        guard settings.notifications, Bundle.main.bundleURL.pathExtension == "app" else { return }
        if let last = notificationDates[key], Date().timeIntervalSince(last) < minimumInterval { return }
        notificationDates[key] = Date()
        let content = UNMutableNotificationContent()
        content.title = title; content.body = String(text.prefix(240)); content.sound = .default
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil)) }
        catch { log("Could not deliver notification: \(error.localizedDescription)") }
    }
}
