import Foundation
import Network

@MainActor
private final class ConfidenceSenderObservation {
    var destination: AltViewDestination?
}

/// Compiled separately against each app's actual sender/discovery/protocol sources.
@main
enum ConfidenceSenderHarness {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let receiverID = UUID(uuidString: CommandLine.arguments[2])!
        let role = CommandLine.arguments[3]
        let key = AltViewPairingKey.parse("ABCD2345")!
        let observation = ConfidenceSenderObservation()
        var connectionID = UUID()
        var connectedOnce = false
        var wantsConnection = true
        var previous = ""
        var latest: AltViewDisplayContent?
        var intent: UUID?
        let client = AltViewSenderClient(name: role) { status in
            MainActor.assumeIsolated {
                let report: [String: Any] = ["connected": status.connected, "owns": status.ownsOutput,
                    "local": observation.destination?.host == "127.0.0.1", "port": (observation.destination?.port).map { Int($0) } ?? 0,
                    "capabilities": status.capabilities.sorted(), "message": status.message]
                if let data = try? JSONSerialization.data(withJSONObject: report) {
                    try? data.write(to: directory.appendingPathComponent("\(role)-status.json"), options: .atomic)
                }
            }
        }
        let discovery = AltViewReceiverDiscovery { receivers, _ in
            guard wantsConnection, let found = receivers.first(where: { $0.receiverID == receiverID }),
                  found.isLocal, let fresh = AltViewDestination(found) else { return }
            let changed = observation.destination?.endpoint != fresh.endpoint
            observation.destination = fresh
            if !connectedOnce {
                connectedOnce = true
                client.connect(to: fresh.endpoint, key: key, expectedReceiverID: receiverID, connectionID: connectionID)
            } else if changed { client.updateEndpoint(fresh.endpoint, connectionID: connectionID) }
        }
        discovery.start()
        defer { client.disconnect(); discovery.stop() }
        while true {
            if let command = try? String(contentsOf: directory.appendingPathComponent("\(role)-command"), encoding: .utf8), command != previous {
                previous = command
                switch command {
                case "publish", "next":
                    intent = UUID()
                    let text = command == "next" ? (role == "eucaly" ? "Next primary lyric" : "Next primary verse") : role == "eucaly" ? "Primary lyric" : "Primary verse"
                    latest = AltViewDisplayContent(title: role == "eucaly" ? "Song" : "John 3:16", body: text,
                        footer: role == "eucaly" ? "" : "Primary translation", confidence: .init(title: role == "eucaly" ? "Song" : "John 3:16", body: text, footer: role == "eucaly" ? "" : "Primary translation"))
                    #if EUCALY
                    client.submit(latest!, submissionID: UUID()); client.takeOutput()
                    #else
                    latest?.confidence?.secondary = .init(body: "Secondary verse", footer: "Secondary translation")
                    client.submit(AltViewSubmission(connectionID: connectionID, content: latest, intent: intent))
                    #endif
                case "hide", "hidden-navigation":
                    latest?.visible = false
                    if command == "hidden-navigation" { latest?.body = "Hidden browsing must not take Scripture" }
                    #if EUCALY
                    if let latest { client.submit(latest, submissionID: UUID()) }
                    #else
                    client.submit(AltViewSubmission(connectionID: connectionID, content: latest, intent: intent))
                    #endif
                #if EUCALY
                case "media", "recreated", "reclaim-media":
                    let report = AltViewProjectionPresentation(sessionID: receiverID, mode: .media,
                        windowID: command == "recreated" ? 88 : 77, windowGeneration: UUID())
                    latest = AltViewDisplayContent(visible: false, projection: report)
                    client.submit(latest!, submissionID: UUID()); client.takeOutput()
                case "clear":
                    latest = .empty
                    client.submit(.empty, submissionID: UUID())
                #else
                case "primary-only":
                    latest?.confidence?.secondary = nil
                    client.submit(AltViewSubmission(connectionID: connectionID, content: latest, intent: intent))
                #endif
                case "stop":
                    latest = nil; intent = nil
                    #if EUCALY
                    client.releaseOutput()
                    #else
                    client.submit(AltViewSubmission(connectionID: connectionID, content: nil, intent: nil))
                    #endif
                case "disconnect": client.disconnect(); wantsConnection = false; connectedOnce = false; latest = nil; intent = nil
                case "reconnect":
                    wantsConnection = true; connectionID = UUID()
                    if let destination = observation.destination {
                        connectedOnce = true
                        client.connect(to: destination.endpoint, key: key, expectedReceiverID: receiverID, connectionID: connectionID)
                    }
                case "quit": return
                default: break
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
