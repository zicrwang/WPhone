import SwiftUI

@main
struct EmptyTunnelApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    @StateObject private var tunnel = TunnelController()

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
        }
        .padding()
        .task {
            await tunnel.requestNotificationAuthorization()
        }
    }
}
