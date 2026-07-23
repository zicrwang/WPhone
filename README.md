# Empty Tunnel sample

This directory contains the core source for a small SwiftUI app and a Packet Tunnel extension. It is intentionally not an `.xcodeproj`: create an iOS app target and a Network Extension target in Xcode, then add the files to the target memberships described below.

## Important platform limits

`NEPacketTunnelProvider` is not an unlimited-background or process-persistence API. iOS can stop a provider, revoke its configuration, or suspend networking. An empty tunnel must have a legitimate user-facing purpose and may be rejected by App Review if it exists only to evade lifecycle policy. The sample does not read `packetFlow` and explicitly excludes the default route, but no code can guarantee that future iOS releases will preserve this behavior.

Local notifications do not provide a continuously playing alarm and removing a delivered notification cannot stop a sound that is already playing. The extension submits a single time-sensitive notification and removes pending/delivered requests on `STOP_RING`. Critical alerts require Apple approval and a critical-alert entitlement; a foreground audio experience is a separate product requirement.

## Target setup

1. Create an iOS app target named `EmptyTunnel` with bundle ID `com.example.emptytunnel`.
2. Add a **Network Extension > Packet Tunnel Provider** target named `PacketTunnel` with bundle ID `com.example.emptytunnel.PacketTunnel`.
3. Add `Sources/Shared/SharedLogger.swift` to both targets. Add the HostApp files only to the app target and `PacketTunnelProvider.swift` only to the extension target.
4. Set the app target's Info.plist to `InfoPlist/Main-Info.plist` and the extension target's Info.plist to `InfoPlist/PacketTunnel-Info.plist`.
5. Add the matching entitlements files to the two targets. Register the App Group `group.com.example.emptytunnel` and the Network Extension capability in the Developer portal first.
6. In the Xcode target build settings, set the app provisioning profile to `$(APP_PROVISIONING_PROFILE_SPECIFIER)` and the extension profile to `$(EXT_PROVISIONING_PROFILE_SPECIFIER)`. This is required because the two targets have different application identifiers.

The host app passes `192.168.1.10` as the allowlisted LAN client. Change `TunnelController.allowedClientIPv4` before building. The listener accepts raw `START_RING`/`STOP_RING` text and simple HTTP requests such as `POST /START_RING`.

## Capabilities and keys

The containing app needs **Personal VPN** (and App Groups). The Packet Tunnel target needs **Network Extensions > Packet Tunnel Provider** and App Groups. Both targets must use the same App Group identifier. The app also needs `NSLocalNetworkUsageDescription`; no background-mode entitlement is used. If critical alerts are approved, add the Critical Alerts capability and the corresponding entitlement to the target that schedules the notification, then request `.criticalAlert` authorization explicitly.

The extension's `NSExtensionPointIdentifier` must be `com.apple.networkextension.packet-tunnel`, and its principal class must resolve to `$(PRODUCT_MODULE_NAME).PacketTunnelProvider`.

## GitHub Actions secrets

`.github/workflows/ios.yml` expects these repository secrets:

- `APPLE_TEAM_ID`
- `IOS_P12_BASE64`
- `IOS_P12_PASSWORD`
- `IOS_APP_MOBILEPROVISION_BASE64`
- `IOS_EXTENSION_MOBILEPROVISION_BASE64`

`APPLE_SIGNING_CERTIFICATE` is optional and defaults to `Apple Distribution`; set it when the imported P12 uses a different certificate common name.

The supplied certificate ZIP contains one profile whose application identifier is `84V4S488EQ.app.star6979.lettuce4401`; it does not match the sample bundle IDs and cannot be used for this sample unchanged. An app plus extension needs profiles for both target identifiers. Export a second profile for the Packet Tunnel App ID, then set the sample IDs to the registered values. Never commit the ZIP, `.p12`, password, or decoded profiles.
