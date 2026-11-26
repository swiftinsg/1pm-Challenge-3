//
//  NotificationService.swift
//  1pm Challenge 3
//

import Foundation
import UserNotifications

/// Owns the notification the app actually sends: a low-storage reminder.
///
/// Permission is only worth asking for if something is delivered, so the app
/// schedules a single reminder when free space is genuinely low and removes
/// it again once there is room. The request itself happens once, on the very
/// first launch.
enum NotificationService {
    private static let requestedKey = "hasRequestedNotificationPermission"
    private static let reminderIdentifier = "low-storage-reminder"
    static let alertsEnabledKey = "lowStorageAlertsEnabled"

    private static let reminderDelay: TimeInterval = 2 * 24 * 60 * 60
    /// Below this much free space, or below 10% of the volume, the device
    /// counts as nearly full.
    private static let lowStorageFloor: Int64 = 5_000_000_000

    static var alertsEnabled: Bool {
        UserDefaults.standard.object(forKey: alertsEnabledKey) as? Bool ?? true
    }

    static func requestOnFirstLaunch() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: requestedKey) else { return }

        // Record the attempt first: the system alert can only be shown once,
        // so a terminated app must not try to show it again on the next launch.
        defaults.set(true, forKey: requestedKey)

        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])
    }

    /// Keeps one pending reminder in step with the device. Reusing the
    /// identifier means reminders never stack, and an already scheduled one is
    /// left alone so simply opening the app does not reset its timer.
    static func updateLowStorageReminder(available: Int64?, total: Int64?) {
        guard alertsEnabled else {
            cancelLowStorageReminder()
            return
        }

        guard let available, let total, total > 0 else { return }

        let isLow = available < lowStorageFloor
            || Double(available) / Double(total) < 0.10

        guard isLow else {
            cancelLowStorageReminder()
            return
        }

        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            guard !requests.contains(where: { $0.identifier == reminderIdentifier }) else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Running low on storage"
            content.body = "Only \(StorageFormatter.capacity(available)) of storage is left on this iPhone. Open Spacer to free up space."
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: reminderDelay,
                repeats: false
            )

            center.add(
                UNNotificationRequest(
                    identifier: reminderIdentifier,
                    content: content,
                    trigger: trigger
                )
            )
        }
    }

    static func cancelLowStorageReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [reminderIdentifier])
    }
}
