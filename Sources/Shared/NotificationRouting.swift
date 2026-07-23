import Foundation
import UserNotifications

enum NotificationRouting {
    static let appGroupIdentifier = "group.3970029fa0cfcf6d.1"
    static let categoryIdentifier = "app.wephone.vpn.wechat"
    static let openWeChatActionIdentifier = "app.wephone.vpn.action.open-wechat"
    static let dismissActionIdentifier = "app.wephone.vpn.action.dismiss"
    static let destinationKey = "app.wephone.vpn.destination"
    static let weChatDestination = "weixin://"

    private static let pendingDestinationKey = "app.wephone.vpn.route.pending-destination"
    private static let pendingDestinationDateKey = "app.wephone.vpn.route.pending-date"
    private static let pendingRouteLifetime: TimeInterval = 60

    static func registerCategories(on center: UNUserNotificationCenter = .current()) {
        let openWeChat = UNNotificationAction(
            identifier: openWeChatActionIdentifier,
            title: "打开微信",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [openWeChat],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "微信通知",
            options: []
        )
        center.setNotificationCategories([category])
    }

    static func routeToWeChat(_ content: UNMutableNotificationContent) {
        content.categoryIdentifier = categoryIdentifier
        content.userInfo[destinationKey] = weChatDestination
    }

    static func destination(from content: UNNotificationContent) -> URL? {
        guard let rawValue = content.userInfo[destinationKey] as? String,
              rawValue == weChatDestination else {
            return nil
        }
        return URL(string: rawValue)
    }

    static func savePendingDestination(_ destination: URL) {
        guard destination.absoluteString == weChatDestination else { return }
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        defaults?.set(destination.absoluteString, forKey: pendingDestinationKey)
        defaults?.set(Date(), forKey: pendingDestinationDateKey)
    }

    static func pendingDestination(now: Date = Date()) -> URL? {
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        guard let rawValue = defaults?.string(forKey: pendingDestinationKey),
              rawValue == weChatDestination,
              let createdAt = defaults?.object(forKey: pendingDestinationDateKey) as? Date,
              now.timeIntervalSince(createdAt) >= 0,
              now.timeIntervalSince(createdAt) <= pendingRouteLifetime else {
            clearPendingDestination()
            return nil
        }
        return URL(string: rawValue)
    }

    static func clearPendingDestination() {
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        defaults?.removeObject(forKey: pendingDestinationKey)
        defaults?.removeObject(forKey: pendingDestinationDateKey)
    }
}
