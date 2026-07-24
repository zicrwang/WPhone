import AlarmKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
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

    func applicationDidBecomeActive(_ application: UIApplication) {
        guard WPhoneAlarmStore.consumePendingOpen() else { return }
        openWeChat(completion: nil)
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
            stopIncomingCallAlarm(for: request.content)
            center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
            openWeChat(destination: destination, completion: completionHandler)
        case NotificationRouting.dismissActionIdentifier,
             UNNotificationDismissActionIdentifier:
            stopIncomingCallAlarm(for: request.content)
            center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
            SharedLogger.shared.info("Notification dismissed by user")
            completionHandler()
        default:
            completionHandler()
        }
    }

    private func stopIncomingCallAlarm(for content: UNNotificationContent) {
        guard let callKey = NotificationRouting.incomingCallKey(from: content),
              let record = WPhoneAlarmStore.activeAlarm(),
              record.callKey == callKey else {
            return
        }
        try? AlarmManager.shared.stop(id: record.id)
        try? AlarmManager.shared.cancel(id: record.id)
        WPhoneAlarmStore.clear(alarmID: record.id)
        SharedLogger.shared.info("AlarmKit alarm stopped from incoming-call notification")
    }

    private func openWeChat(
        destination: URL? = URL(string: NotificationRouting.weChatDestination),
        completion: (() -> Void)?
    ) {
        guard let destination else {
            SharedLogger.shared.error("Invalid WeChat destination")
            completion?()
            return
        }
        UIApplication.shared.open(destination, options: [:]) { opened in
            if opened {
                SharedLogger.shared.info("WeChat opened from user action")
            } else {
                SharedLogger.shared.error("Unable to open WeChat using weixin://")
            }
            completion?()
        }
    }
}

private struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var tunnel = TunnelController()
    @State private var logText = ""
    @State private var showingLog = false
    @State private var showingSoundImporter = false

    var body: some View {
        NavigationView {
            Form {
                Section("AlarmKit") {
                    LabeledContent("权限", value: tunnel.alarmAuthorizationStatus)
                    LabeledContent("测试", value: tunnel.alarmTestStatus)
                    LabeledContent("时效通知", value: tunnel.notificationTimeSensitiveStatus)
                    LabeledContent("横幅风格", value: tunnel.notificationBannerStyle)
                    LabeledContent("最长响铃", value: "50秒")

                    HStack(spacing: 12) {
                        Button {
                            Task { await tunnel.scheduleAlarmKitTest() }
                        } label: {
                            Label("测试闹铃", systemImage: "alarm.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            tunnel.stopAlarmKitTest()
                        } label: {
                            Label("停止", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        openNotificationSettings()
                    } label: {
                        Label("通知设置", systemImage: "bell.badge.fill")
                    }
                }

                Section("来电铃声") {
                    LabeledContent("当前") {
                        Text(tunnel.incomingCallSoundStatus)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }

                    HStack(spacing: 12) {
                        Button {
                            showingSoundImporter = true
                        } label: {
                            Label("选择铃声", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            tunnel.restoreBundledIncomingCallSound()
                        } label: {
                            Label("恢复内置", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!NotificationRouting.isUsingCustomIncomingCallSound)
                    }

                    if let soundError = tunnel.incomingCallSoundError {
                        Text(soundError)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section("中继站") {
                    TextField("地址", text: $tunnel.relayHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .disabled(tunnel.status == .connected || tunnel.status == .connecting)
                    TextField("端口", text: $tunnel.relayPort)
                        .keyboardType(.numberPad)
                        .disabled(tunnel.status == .connected || tunnel.status == .connecting)
                }

                Section("VPN 后台通道") {
                    LabeledContent("状态", value: tunnel.statusText)

                    HStack(spacing: 12) {
                        Button {
                            Task { await tunnel.start() }
                        } label: {
                            Label("启动", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tunnel.status == .connected || tunnel.status == .connecting)

                        Button {
                            tunnel.stop()
                        } label: {
                            Label("停止", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(tunnel.status == .disconnected || tunnel.status == .invalid)
                    }
                }

                if let lastError = tunnel.lastError {
                    Section {
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
                        Label("查看日志", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            .navigationTitle("手机信息通知")
        }
        .task {
            await tunnel.load()
            await tunnel.requestNotificationAuthorization()
            await tunnel.requestAlarmAuthorization()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await tunnel.refreshNotificationSettings() }
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
        .fileImporter(
            isPresented: $showingSoundImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await tunnel.installIncomingCallSound(from: url) }
            case .failure(let error):
                tunnel.recordIncomingCallSoundImportError(error)
            }
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }
}
