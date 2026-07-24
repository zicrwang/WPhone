import Foundation
import UserNotifications

enum NotificationRouting {
    static let categoryIdentifier = "app.wephone.vpn.wechat"
    static let openWeChatActionIdentifier = "app.wephone.vpn.action.open-wechat"
    static let dismissActionIdentifier = "app.wephone.vpn.action.dismiss"
    static let destinationKey = "app.wephone.vpn.destination"
    static let incomingCallKey = "app.wephone.vpn.incoming-call-key"
    static let weChatDestination = "weixin://"
    static let incomingCallSoundName = "WPhoneIncomingCall.wav"

    static func hasIncomingCallSound(in bundle: Bundle = .main) -> Bool {
        bundle.url(
            forResource: "WPhoneIncomingCall",
            withExtension: "wav"
        ) != nil
    }

    static func incomingCallNotificationSound(
        in bundle: Bundle = .main
    ) -> UNNotificationSound {
        guard hasIncomingCallSound(in: bundle) else { return .default }
        return UNNotificationSound(
            named: UNNotificationSoundName(rawValue: incomingCallSoundName)
        )
    }

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

    static func routeIncomingCallToWeChat(
        _ content: UNMutableNotificationContent,
        callKey: String
    ) {
        routeToWeChat(content)
        content.userInfo[incomingCallKey] = callKey
    }

    static func incomingCallKey(from content: UNNotificationContent) -> String? {
        content.userInfo[incomingCallKey] as? String
    }

    static func destination(from content: UNNotificationContent) -> URL? {
        guard let rawValue = content.userInfo[destinationKey] as? String,
              rawValue == weChatDestination else {
            return nil
        }
        return URL(string: rawValue)
    }
}
