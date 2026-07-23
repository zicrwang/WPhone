import Foundation
import UserNotifications

enum NotificationRouting {
    static let categoryIdentifier = "app.wephone.vpn.wechat"
    static let openWeChatActionIdentifier = "app.wephone.vpn.action.open-wechat"
    static let dismissActionIdentifier = "app.wephone.vpn.action.dismiss"
    static let destinationKey = "app.wephone.vpn.destination"
    static let weChatDestination = "weixin://"

    static func registerCategories(on center: UNUserNotificationCenter = .current()) {
        let openWeChat = UNNotificationAction(
            identifier: openWeChatActionIdentifier,
            title: "打开",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: dismissActionIdentifier,
            title: "关闭",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [openWeChat, dismiss],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "微信通知",
            options: [.customDismissAction]
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
}
