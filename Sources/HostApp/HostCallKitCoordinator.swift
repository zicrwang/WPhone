import CallKit
import CoreFoundation
import Foundation
import UserNotifications

private let callKitBridgeNotificationCallback: CFNotificationCallback = {
    _, observer, _, _, _ in
    guard let observer else { return }
    let coordinator = Unmanaged<HostCallKitCoordinator>
        .fromOpaque(observer)
        .takeUnretainedValue()
    coordinator.commandsDidChange()
}

final class HostCallKitCoordinator: NSObject, CXProviderDelegate {
    static let shared = HostCallKitCoordinator()
    static let preferredRingtoneFileName = "WPhoneRingtone.caf"

    private struct ActiveCall {
        let commandID: String
        let key: String
        let caller: String
        let handoffNotificationIdentifier: String
    }

    private let log = SharedLogger.shared
    private let callQueue = DispatchQueue(label: "app.wephone.vpn.host-callkit", qos: .userInitiated)
    private var provider: CXProvider?
    private var callsByUUID: [UUID: ActiveCall] = [:]
    private var uuidByKey: [String: UUID] = [:]
    private var state = CallKitBridgeState.initial
    private var started = false
    private var heartbeatTimer: DispatchSourceTimer?
    private var rebuildWorkItem: DispatchWorkItem?
    private var recentResetDates: [Date] = []

    private override init() {
        super.init()
    }

    deinit {
        heartbeatTimer?.cancel()
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(rawValue: CallKitBridge.notificationName as CFString),
            nil
        )
    }

    func start() {
        callQueue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.installCommandObserver()
            self.state = CallKitBridge.loadState() ?? .initial
            self.state.hostApplicationState = "active"
            self.startHeartbeat()
            self.installProvider(reason: "app-launch")
            self.processPendingCommandsOnQueue()
        }
    }

    func applicationDidBecomeActive() {
        callQueue.async { [weak self] in
            guard let self else { return }
            self.state.hostApplicationState = "active"
            self.state.hostUpdatedAt = Date()
            self.persistState()
            self.processPendingCommandsOnQueue()
        }
    }

    func applicationDidEnterBackground() {
        callQueue.async { [weak self] in
            guard let self else { return }
            self.state.hostApplicationState = "background"
            self.state.hostUpdatedAt = Date()
            self.persistState()
        }
    }

    func applicationWillTerminate() {
        callQueue.sync { [weak self] in
            guard let self else { return }
            self.state.providerReady = false
            self.state.lifecycle = "terminated"
            self.state.hostApplicationState = "terminated"
            self.state.hostUpdatedAt = Date()
            self.persistState()
        }
    }

    func commandsDidChange() {
        callQueue.async { [weak self] in
            self?.processPendingCommandsOnQueue()
        }
    }

    func receiveLocalPushIncomingCall(
        key: String,
        caller: String,
        hasVideo: Bool,
        notificationIdentifier: String
    ) {
        let command = CallKitBridgeCommand.incoming(
            key: key,
            caller: caller,
            hasVideo: hasVideo,
            action: "LOCAL_PUSH_CALLKIT_INCOMING",
            notificationIdentifier: notificationIdentifier
        )
        callQueue.async { [weak self] in
            guard let self else { return }
            self.log.info("Local Push incoming call handed to main-app CallKit key=\(key)")
            self.process(command)
        }
    }

    func providerDidBegin(_ provider: CXProvider) {
        guard self.provider === provider else { return }
        state.providerReady = true
        state.lifecycle = "ready"
        state.lastAction = "CALLKIT_PROVIDER_READY"
        state.lastActionAt = Date()
        state.lastError = nil
        state.hostUpdatedAt = Date()
        persistState()
        log.info("Main app CallKit provider began")
        processPendingCommandsOnQueue()
    }

    func providerDidReset(_ provider: CXProvider) {
        guard self.provider === provider else { return }

        let resetCalls = Array(callsByUUID.values)
        callsByUUID.removeAll(keepingCapacity: false)
        uuidByKey.removeAll(keepingCapacity: false)
        state.providerReady = false
        state.lifecycle = "reset"
        state.activeCallCount = 0
        state.activeCallKey = nil
        state.caller = nil
        state.lastAction = "CALLKIT_PROVIDER_RESET"
        state.lastActionAt = Date()
        state.lastError = "The system reset the main-app CallKit provider"
        state.hostUpdatedAt = Date()
        resetCalls.forEach { state.recordProcessedCommand($0.commandID) }
        persistState()
        log.error("Main app CallKit provider reset activeCalls=\(resetCalls.count)")

        resetCalls.forEach {
            submitFallbackNotification(
                identifier: $0.handoffNotificationIdentifier,
                caller: $0.caller,
                action: "CALLKIT_RESET_FALLBACK_NOTIFICATION"
            )
        }
        scheduleProviderRebuildAfterReset()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard self.provider === provider,
              let call = remove(uuid: action.callUUID) else {
            action.fail()
            return
        }

        action.fulfill()
        provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .remoteEnded)
        updateActiveCallState()
        state.lastAction = "CALLKIT_ANSWERED"
        state.lastActionAt = Date()
        state.lastError = nil
        state.hostUpdatedAt = Date()
        persistState()
        log.info("Main app CallKit answered and ended key=\(call.key)")
        submitHandoffNotification(
            identifier: call.handoffNotificationIdentifier,
            caller: call.caller
        )
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard self.provider === provider else {
            action.fail()
            return
        }

        let call = remove(uuid: action.callUUID)
        action.fulfill()
        updateActiveCallState()
        state.lastAction = "CALLKIT_DECLINED"
        state.lastActionAt = Date()
        state.lastError = nil
        state.hostUpdatedAt = Date()
        persistState()
        log.info("Main app CallKit declined key=\(call?.key ?? "unknown")")
    }

    private func installCommandObserver() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            callKitBridgeNotificationCallback,
            CallKitBridge.notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: callQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.state.hostUpdatedAt = Date()
            self.persistState()
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func installProvider(reason: String) {
        let configuration = CXProviderConfiguration(localizedName: "手机信息通知")
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false

        if Bundle.main.url(forResource: "WPhoneRingtone", withExtension: "caf") != nil {
            configuration.ringtoneSound = Self.preferredRingtoneFileName
            state.customRingtone = Self.preferredRingtoneFileName
        } else {
            state.customRingtone = nil
        }

        let newProvider = CXProvider(configuration: configuration)
        provider = newProvider
        callsByUUID.removeAll(keepingCapacity: false)
        uuidByKey.removeAll(keepingCapacity: false)
        updateActiveCallState()
        state.providerReady = true
        state.lifecycle = "registered"
        state.lastAction = "CALLKIT_PROVIDER_REGISTERED"
        state.lastActionAt = Date()
        state.lastError = nil
        state.hostUpdatedAt = Date()
        persistState()
        newProvider.setDelegate(self, queue: callQueue)
        log.info(
            "Main app CallKit provider registered reason=\(reason) ringtone=\(state.customRingtone ?? "system")"
        )
    }

    private func scheduleProviderRebuildAfterReset() {
        let now = Date()
        recentResetDates = recentResetDates.filter { now.timeIntervalSince($0) < 10 }
        recentResetDates.append(now)

        guard recentResetDates.count <= 3 else {
            state.lifecycle = "failed"
            state.lastError = "CallKit provider reset more than three times in ten seconds"
            state.hostUpdatedAt = Date()
            persistState()
            log.error("Main app CallKit provider rebuild stopped after repeated resets")
            return
        }

        rebuildWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.provider = nil
            self.installProvider(reason: "system-reset")
            self.processPendingCommandsOnQueue()
        }
        rebuildWorkItem = workItem
        callQueue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func processPendingCommandsOnQueue() {
        let commands = CallKitBridge.drainPendingCommands()
        guard !commands.isEmpty else { return }
        log.debug("Main app received \(commands.count) CallKit bridge command(s)")
        commands.forEach(process)
    }

    private func process(_ command: CallKitBridgeCommand) {
        switch command.kind {
        case .incoming:
            guard let key = command.key,
                  let caller = command.caller,
                  let action = command.action,
                  let notificationIdentifier = command.notificationIdentifier else {
                completeInvalid(command, message: "Incoming CallKit command is incomplete")
                return
            }
            state.recordProcessedCommand(command.id)
            persistState()
            reportIncoming(
                commandID: command.id,
                key: key,
                caller: caller,
                hasVideo: command.hasVideo,
                action: action,
                handoffNotificationIdentifier: notificationIdentifier
            )
        case .end:
            if let key = command.key {
                _ = end(key: key, reason: .remoteEnded)
            }
            complete(commandID: command.id, action: command.action ?? "CALLKIT_ENDED")
        case .endAll:
            endAll(reason: .remoteEnded)
            complete(commandID: command.id, action: command.action ?? "CALLKIT_ENDED_ALL")
        }
    }

    private func reportIncoming(
        commandID: String,
        key: String,
        caller: String,
        hasVideo: Bool,
        action: String,
        handoffNotificationIdentifier: String
    ) {
        guard state.providerReady, let provider else {
            complete(
                commandID: commandID,
                action: "CALLKIT_HOST_PROVIDER_UNAVAILABLE",
                error: "Main-app CallKit provider is not ready"
            )
            submitFallbackNotification(
                identifier: handoffNotificationIdentifier,
                caller: caller,
                action: "CALLKIT_HOST_UNAVAILABLE_FALLBACK_NOTIFICATION"
            )
            return
        }

        endAll(reason: .unanswered)
        let uuid = UUID()
        callsByUUID[uuid] = ActiveCall(
            commandID: commandID,
            key: key,
            caller: caller,
            handoffNotificationIdentifier: handoffNotificationIdentifier
        )
        uuidByKey[key] = uuid
        updateActiveCallState()
        state.lifecycle = "reporting"
        state.lastAction = "\(action)_REPORTING"
        state.lastActionAt = Date()
        state.lastError = nil
        state.hostUpdatedAt = Date()
        persistState()

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: caller)
        update.localizedCallerName = caller
        update.hasVideo = hasVideo
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsHolding = false
        update.supportsUngrouping = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            guard let self else { return }
            if let error {
                _ = self.remove(uuid: uuid)
                let message = Self.describe(error)
                self.updateActiveCallState()
                self.complete(
                    commandID: commandID,
                    action: "\(action)_FAILED",
                    error: message
                )
                self.log.error("Main app CallKit report failed key=\(key): \(message)")
                self.submitFallbackNotification(
                    identifier: handoffNotificationIdentifier,
                    caller: caller,
                    action: "CALLKIT_REPORT_FAILED_FALLBACK_NOTIFICATION"
                )
            } else if self.callsByUUID[uuid] != nil {
                self.state.lifecycle = "ready"
                self.complete(commandID: commandID, action: action)
                self.log.info("\(action) main-app CallKit call reported key=\(key)")
            } else if !self.state.hasProcessed(commandID) {
                self.complete(
                    commandID: commandID,
                    action: "\(action)_ABORTED",
                    error: "CallKit provider reset before the report completed"
                )
                self.submitFallbackNotification(
                    identifier: handoffNotificationIdentifier,
                    caller: caller,
                    action: "CALLKIT_REPORT_ABORTED_FALLBACK_NOTIFICATION"
                )
            }
        }
    }

    @discardableResult
    private func end(key: String, reason: CXCallEndedReason) -> Bool {
        guard let uuid = uuidByKey[key], remove(uuid: uuid) != nil else { return false }
        provider?.reportCall(with: uuid, endedAt: Date(), reason: reason)
        updateActiveCallState()
        return true
    }

    private func endAll(reason: CXCallEndedReason) {
        let uuids = Array(callsByUUID.keys)
        callsByUUID.removeAll(keepingCapacity: false)
        uuidByKey.removeAll(keepingCapacity: false)
        let endedAt = Date()
        uuids.forEach { provider?.reportCall(with: $0, endedAt: endedAt, reason: reason) }
        updateActiveCallState()
    }

    private func remove(uuid: UUID) -> ActiveCall? {
        guard let call = callsByUUID.removeValue(forKey: uuid) else { return nil }
        uuidByKey.removeValue(forKey: call.key)
        return call
    }

    private func updateActiveCallState() {
        state.activeCallCount = callsByUUID.count
        state.activeCallKey = callsByUUID.values.first?.key
        state.caller = callsByUUID.values.first?.caller
        state.hostUpdatedAt = Date()
    }

    private func completeInvalid(_ command: CallKitBridgeCommand, message: String) {
        complete(commandID: command.id, action: "CALLKIT_COMMAND_INVALID", error: message)
        log.error("CallKit bridge command invalid id=\(command.id): \(message)")
    }

    private func complete(commandID: String, action: String, error: String? = nil) {
        state.recordProcessedCommand(commandID)
        state.lastAction = action
        state.lastActionAt = Date()
        state.lastError = error
        persistState()
    }

    private func submitHandoffNotification(identifier: String, caller: String) {
        let content = UNMutableNotificationContent()
        content.title = "打开微信"
        content.body = "\(caller)，点按直接进入微信"
        content.threadIdentifier = "app.wephone.vpn.callkit-handoff"
        content.interruptionLevel = .timeSensitive
        NotificationRouting.routeToWeChat(content)
        submitNotification(
            identifier: identifier,
            content: content,
            action: "CALLKIT_HANDOFF_NOTIFICATION"
        )
    }

    private func submitFallbackNotification(identifier: String, caller: String, action: String) {
        let content = UNMutableNotificationContent()
        content.title = "微信来电"
        content.body = "\(caller)，点按打开微信"
        content.sound = .default
        content.threadIdentifier = "app.wephone.vpn.callkit-fallback"
        content.interruptionLevel = .timeSensitive
        NotificationRouting.routeToWeChat(content)
        submitNotification(identifier: identifier, content: content, action: action)
    }

    private func submitNotification(
        identifier: String,
        content: UNMutableNotificationContent,
        action: String
    ) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error {
                self?.log.error("\(action) failed: \(error.localizedDescription)")
            } else {
                self?.log.info("\(action) notification submitted by main app")
            }
        }
    }

    private func persistState() {
        do {
            try CallKitBridge.saveState(state)
        } catch {
            log.error("Unable to save main-app CallKit state: \(error.localizedDescription)")
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain); code=\(nsError.code); description=\(nsError.localizedDescription)"
    }
}
