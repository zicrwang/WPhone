import SwiftUI
import UIKit
import UserNotifications

@main
struct WPhoneApp: App {
    @UIApplicationDelegateAdaptor(WPhoneAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class WPhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        NotificationRouting.registerCategories(on: center)
        SharedLogger.shared.debug("Notification actions registered")
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        switch response.actionIdentifier {
        case NotificationRouting.openWeChatActionIdentifier,
             UNNotificationDefaultActionIdentifier:
            guard let destination = NotificationRouting.destination(from: request.content) else {
                SharedLogger.shared.error("Notification does not contain an approved destination")
                completionHandler()
                return
            }
            UIApplication.shared.open(destination, options: [:]) { opened in
                if opened {
                    SharedLogger.shared.info("WeChat opened from notification action")
                } else {
                    SharedLogger.shared.error("Unable to open WeChat using weixin://")
                }
                completionHandler()
            }
        case NotificationRouting.dismissActionIdentifier,
             UNNotificationDismissActionIdentifier:
            center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
            SharedLogger.shared.info("Notification dismissed by user")
            completionHandler()
        default:
            completionHandler()
        }
    }
}

private struct ContentView: View {
    @StateObject private var tunnel = TunnelController()
    @State private var logText = ""
    @State private var showingLog = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Tunnel: \(tunnel.statusText)")
                .font(.headline)

            HStack(spacing: 12) {
                Button("Start") {
                    Task { await tunnel.start() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(tunnel.status == .connected || tunnel.status == .connecting)

                Button("Stop") {
                    tunnel.stop()
                }
                .buttonStyle(.bordered)
                .disabled(tunnel.status == .disconnected || tunnel.status == .invalid)
            }

            if let lastError = tunnel.lastError {
                Text(lastError)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            Button("View log") {
                logText = SharedLogger.shared.recentLog()
                showingLog = true
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .task {
            await tunnel.load()
            await tunnel.requestNotificationAuthorization()
        }
        .sheet(isPresented: $showingLog) {
            NavigationView {
                ScrollView {
                    Text(logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("debug.log")
                .toolbar {
                    Button("Refresh") {
                        logText = SharedLogger.shared.recentLog()
                    }
                }
            }
        }
    }
}
