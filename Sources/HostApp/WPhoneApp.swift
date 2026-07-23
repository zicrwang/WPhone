import SwiftUI
import UIKit
import UserNotifications

@main
struct WPhoneApp: App {
    @UIApplicationDelegateAdaptor(WPhoneAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var weChatRouter = WeChatLaunchCoordinator.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .fullScreenCover(isPresented: $weChatRouter.isShowingFallback) {
                    WeChatGatewayView(router: weChatRouter)
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        weChatRouter.applicationDidBecomeActive()
                    }
                }
        }
    }
}

final class WPhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        HostCallKitCoordinator.shared.start()
        LocalPushController.shared.initialize()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        NotificationRouting.registerCategories(on: center)
        SharedLogger.shared.debug("Notification actions registered")
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        HostCallKitCoordinator.shared.applicationDidBecomeActive()
        WeChatLaunchCoordinator.shared.applicationDidBecomeActive()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        HostCallKitCoordinator.shared.applicationDidEnterBackground()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        HostCallKitCoordinator.shared.applicationWillTerminate()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.sound == nil {
            completionHandler([.banner, .list])
        } else {
            completionHandler([.banner, .list, .sound])
        }
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
            center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
            DispatchQueue.main.async {
                WeChatLaunchCoordinator.shared.requestOpen(destination)
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

final class WeChatLaunchCoordinator: ObservableObject {
    static let shared = WeChatLaunchCoordinator()

    @Published var isShowingFallback = false

    private var scheduledAttempt: DispatchWorkItem?
    private var isOpening = false

    private init() {}

    func requestOpen(_ destination: URL) {
        NotificationRouting.savePendingDestination(destination)
        SharedLogger.shared.info("WeChat handoff requested from notification action")
        scheduleOpenAttempt()
    }

    func applicationDidBecomeActive() {
        guard NotificationRouting.pendingDestination() != nil else { return }
        scheduleOpenAttempt()
    }

    func openFromFallback() {
        guard let destination = URL(string: NotificationRouting.weChatDestination) else { return }
        NotificationRouting.savePendingDestination(destination)
        attemptOpen()
    }

    func dismissFallback() {
        scheduledAttempt?.cancel()
        scheduledAttempt = nil
        NotificationRouting.clearPendingDestination()
        isShowingFallback = false
        SharedLogger.shared.info("WeChat handoff fallback dismissed")
    }

    private func scheduleOpenAttempt() {
        guard UIApplication.shared.applicationState == .active else { return }
        scheduledAttempt?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptOpen()
        }
        scheduledAttempt = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func attemptOpen() {
        guard !isOpening,
              UIApplication.shared.applicationState == .active,
              let destination = NotificationRouting.pendingDestination() else {
            return
        }

        scheduledAttempt = nil
        isOpening = true
        UIApplication.shared.open(destination, options: [:]) { [weak self] opened in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isOpening = false
                if opened {
                    NotificationRouting.clearPendingDestination()
                    self.isShowingFallback = false
                    SharedLogger.shared.info("WeChat opened from WPhone handoff")
                } else {
                    self.isShowingFallback = true
                    SharedLogger.shared.error("Automatic WeChat handoff failed; showing fallback")
                }
            }
        }
    }
}

private struct ContentView: View {
    @StateObject private var tunnel = TunnelController()
    @StateObject private var localPush = LocalPushController.shared
    @State private var logText = ""
    @State private var showingLog = false

    var body: some View {
        NavigationView {
            Form {
                Section("Local Push") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Label(
                            localPush.statusText,
                            systemImage: localPush.isActive
                                ? "checkmark.circle.fill"
                                : "clock.fill"
                        )
                        .foregroundStyle(localPush.isActive ? Color.green : Color.secondary)
                    }

                    TextField("Wi-Fi SSID", text: $localPush.ssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Relay host or IP", text: $localPush.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Relay port", text: $localPush.portText)
                        .keyboardType(.numberPad)

                    HStack(spacing: 12) {
                        Button {
                            localPush.saveAndEnable()
                        } label: {
                            Label("Enable", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .buttonStyle(.borderedProminent)

                        Button(role: .destructive) {
                            localPush.disable()
                        } label: {
                            Label("Disable", systemImage: "stop.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!localPush.isEnabled)
                    }

                    if let lastError = localPush.lastError {
                        Text(lastError)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section("Packet Tunnel compatibility") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(tunnel.statusText)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            Task { await tunnel.start() }
                        } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tunnel.status == .connected || tunnel.status == .connecting)

                        Button {
                            tunnel.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(tunnel.status == .disconnected || tunnel.status == .invalid)
                    }

                    if let lastError = tunnel.lastError {
                        Text(lastError)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button {
                        logText = SharedLogger.shared.recentLog()
                        showingLog = true
                    } label: {
                        Label("View log", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            .navigationTitle("手机信息通知")
        }
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

private struct WeChatGatewayView: View {
    @ObservedObject var router: WeChatLaunchCoordinator

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("打开微信")
                .font(.title2.bold())
            Button {
                router.openFromFallback()
            } label: {
                Label("打开微信", systemImage: "arrow.up.forward.app.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                router.dismissFallback()
            } label: {
                Label("返回 WPhone", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(28)
        .interactiveDismissDisabled()
    }
}
