import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct WaypointWatchApp: App {
    @State private var relay = WatchRelay()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 10) {
                Button("Repeat direction", systemImage: "arrow.clockwise", action: relay.repeatDirection)
                    .handGestureShortcut(.primaryAction)
                Text(relay.status).font(.footnote)
            }
            .padding()
        }
    }
}

@MainActor
@Observable
final class WatchRelay: NSObject, WCSessionDelegate {
    var status = "Open Waypoint on iPhone and start a session."

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func repeatDirection() {
        guard WCSession.default.isReachable else {
            status = "Open Waypoint on your paired iPhone."
            return
        }
        status = "Requesting direction…"
        WCSession.default.sendMessage(["action": "repeat"], replyHandler: { [weak self] reply in
            let repeated = reply["repeated"] as? Bool == true
            Task { @MainActor in
                self?.status = repeated ? "Direction repeated." : "Start a session on iPhone first."
                if repeated { WKInterfaceDevice.current().play(.click) }
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.status = "Couldn’t reach iPhone. Try again." }
        })
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
}
