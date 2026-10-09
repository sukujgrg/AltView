import Foundation

struct HarnessStatus: Encodable {
    let port: UInt16?
    let connections: Int
    let owner: String?
    let body: String
    let visible: Bool
    let confidence: ConfidenceText
    let mediaWindow: UInt32?
    let localSource: Bool
}

@main
enum ConfidenceReceiverHarness {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let id = UUID(uuidString: CommandLine.arguments[2])!
        let key = PairingKey.parse("ABCD2345")!
        let receiver = ReceiverServer(receiverID: id) { status in
            let snapshot = HarnessStatus(port: status.port, connections: status.connections, owner: status.ownerName,
                body: status.content.body, visible: status.content.visible, confidence: status.confidenceContent, mediaWindow: status.confidenceMedia?.presentation.windowID, localSource: status.confidenceMedia?.process != nil)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: directory.appendingPathComponent("receiver-status.json"), options: .atomic) }
        }
        let name = "Confidence integration \(id)"
        receiver.start(name: name, key: key)
        var previous = ""
        while true {
            if let command = try? String(contentsOf: directory.appendingPathComponent("receiver-command"), encoding: .utf8), command != previous {
                previous = command
                switch command {
                case "pause": receiver.stop()
                case "resume": receiver.start(name: name, key: key)
                case "clear": receiver.clearOutput()
                case "quit": receiver.stop(); return
                default: break
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
