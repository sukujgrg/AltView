import XCTest
import Network
@testable import AltView

final class NetworkTests: XCTestCase {
    func testDiscoveryExcludesThisMacByIdentity() throws {
        let localID = UUID(), remoteID = UUID()
        let discovery = ReceiverDiscovery(excludingReceiverID: localID) { _, _ in }
        let endpoint = NWEndpoint.service(name: "Same receiver name", type: AltViewProtocol.serviceType,
                                          domain: "local.", interface: nil)
        XCTAssertNil(discovery.receiver(endpoint: endpoint, metadata: .bonjour(NWTXTRecord(["receiverID": localID.uuidString]))))
        let remote = try XCTUnwrap(discovery.receiver(endpoint: endpoint,
            metadata: .bonjour(NWTXTRecord(["receiverID": remoteID.uuidString]))))
        XCTAssertEqual(remote.receiverID, remoteID)
        XCTAssertEqual(remote.name, "Same receiver name", "Names must not be used to identify this Mac")
        XCTAssertEqual(remote.endpoint, endpoint)
        let unfiltered = ReceiverDiscovery { _, _ in }
        XCTAssertNotNil(unfiltered.receiver(endpoint: endpoint, metadata: .bonjour(NWTXTRecord(["receiverID": localID.uuidString]))))
    }
    func testDiscoveryKeepsServicesWithMissingOrInvalidIdentity() throws {
        let discovery = ReceiverDiscovery(excludingReceiverID: UUID()) { _, _ in }
        let endpoint = NWEndpoint.service(name: "Receiver", type: AltViewProtocol.serviceType,
                                          domain: "local.", interface: nil)
        for metadata: NWBrowser.Result.Metadata in [.none, .bonjour(NWTXTRecord()), .bonjour(NWTXTRecord(["receiverID": "invalid"]))] {
            let receiver = try XCTUnwrap(discovery.receiver(endpoint: endpoint, metadata: metadata))
            XCTAssertNil(receiver.receiverID)
            XCTAssertEqual(receiver.endpoint, endpoint)
        }
        XCTAssertNil(discovery.receiver(endpoint: .hostPort(host: "127.0.0.1", port: 49721), metadata: .none))
    }
    func testBonjourDiscoveryExcludesThisMacByIdentity() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["ALTVIEW_SKIP_BONJOUR_TEST"] == "1",
                      "Live Bonjour needs local multicast discovery; identity filtering is tested separately.")
        let localID = UUID(), remoteID = UUID()
        let key = try PairingKey.generate()
        let local = ReceiverServer(receiverID: localID) { _ in }
        let remote = ReceiverServer(receiverID: remoteID) { _ in }
        var receivers: [DiscoveredReceiver] = []
        let discovery = ReceiverDiscovery(excludingReceiverID: localID) { receivers = $0; _ = $1 }
        local.start(name: "Local \(localID)", key: key)
        remote.start(name: "Remote \(remoteID)", key: key)
        discovery.start()
        defer { discovery.stop(); local.stop(); remote.stop() }
        eventually("remote receiver discovered") { receivers.contains { $0.receiverID == remoteID } }
        XCTAssertFalse(receivers.contains { $0.receiverID == localID })
    }
    private func eventually(_ description: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, _ predicate: @escaping () -> Bool) {
        let done = expectation(description: description)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func check() {
            if predicate() { done.fulfill() }
            else if ProcessInfo.processInfo.systemUptime < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check) }
        }
        check()
        wait(for: [done], timeout: timeout + 0.5)
    }
    func testEncryptedRoundTripOwnershipBlankClearAndReconnect() throws {
        let key = try PairingKey.generate()
        var output = ReceiverStatus()
        let server = ReceiverServer(receiverID: UUID()) { output = $0 }
        server.start(name: "AltView Test", key: key, advertise: false)
        defer { server.stop() }
        eventually("listener ready") { output.port != nil }
        let port = try XCTUnwrap(output.port)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        var aState = SenderStatus(), bState = SenderStatus()
        let a = SenderClient(name: "A") { aState = $0 }
        let b = SenderClient(name: "B") { bState = $0 }
        defer { a.disconnect(); b.disconnect() }
        let typedKey = try XCTUnwrap(PairingKey.parse(PairingKey.text(key).lowercased()))
        a.connect(to: endpoint, key: typedKey); b.connect(to: endpoint, key: typedKey)
        eventually("both connected") { aState.connected && bState.connected }
        a.submit(.scripture); a.takeOutput()
        eventually("A content") { output.content == .scripture && aState.ownsOutput }
        b.submit(DisplayContent(body: String(repeating: "x", count: 24_001))); b.takeOutput()
        eventually("invalid content rejected before takeover") { bState.message == "Text is too long to send" }
        XCTAssertEqual(output.ownerName, "A")
        XCTAssertEqual(output.content, .scripture)
        b.submit(.lyrics); b.takeOutput()
        eventually("B takes output") { output.content == .lyrics && bState.ownsOutput && !aState.ownsOutput }
        a.submit(.multilingual); a.releaseOutput(); a.disconnect()
        var blank = DisplayContent.lyrics; blank.visible = false
        b.submit(blank)
        eventually("blank retains text") { output.content == blank && output.ownerName == "B" }
        b.submit(.empty)
        eventually("clear") { output.content == .empty && output.ownerName == "B" }
        b.submit(.lyrics)
        eventually("restore") { output.content == .lyrics }
        server.stop()
        eventually("disconnect clears") { !output.listening && output.content == .empty && !bState.connected }
        server.start(name: "AltView Test", key: key, port: port, advertise: false)
        eventually("reconnect restores latest snapshot", timeout: 15) { output.content == .lyrics && bState.ownsOutput }
        for index in 0..<2_000 { b.submit(DisplayContent(body: "Update \(index)")) }
        b.submit(.multilingual)
        eventually("latest burst wins") { output.content == .multilingual }
        b.disconnect()
        eventually("owner disconnect clears") { output.content == .empty && output.ownerName == nil }
    }
    func testSnapshotAcceptanceAndDisplayReadinessAreIndependent() throws {
        let key = try PairingKey.generate()
        var output = ReceiverStatus(), status = SenderStatus()
        let server = ReceiverServer(receiverID: UUID()) { output = $0 }
        let sender = SenderClient(name: "Feedback") { status = $0 }
        server.start(name: "Feedback", key: key, advertise: false)
        defer { sender.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!), key: key)
        eventually("feedback received") { status.connected && status.feedback.output == .closed }
        XCTAssertFalse(status.feedback.accepted)
        sender.submit(.scripture); sender.takeOutput()
        eventually("accepted with output closed") { status.feedback.accepted && output.content == .scripture }
        XCTAssertEqual(status.feedback.output, .closed)
        let revision = status.feedback.acceptedRevision
        for readiness: OutputReadiness in [.ready, .displayMissing, .preview, .minimized, .unavailable, .asleep, .closed] {
            server.updateOutputReadiness(readiness)
            eventually("readiness changes without text") { status.feedback.output == readiness }
            XCTAssertEqual(status.feedback.acceptedRevision, revision)
        }
        for index in 0..<2_000 { sender.submit(DisplayContent(body: "Verse \(index)")) }
        sender.submit(DisplayContent(body: "Final", visible: false))
        eventually("latest burst accepted") { output.content.body == "Final" && status.feedback.sentRevision > revision && status.feedback.accepted }
        XCTAssertFalse(output.content.visible)
        sender.releaseOutput()
        eventually("release clears acceptance") { !status.ownsOutput && output.ownerID == nil }
        XCTAssertEqual(status.feedback.acceptedRevision, 0)
        sender.disconnect()
        eventually("disconnect clears readiness") { !status.connected && status.feedback.output == nil }
    }
    func testWrongPairingKeyCannotConnect() throws {
        let key = try XCTUnwrap(PairingKey.parse("ABCD2345"))
        var output = ReceiverStatus()
        let server = ReceiverServer(receiverID: UUID()) { output = $0 }
        server.start(name: "Authentication Test", key: key, advertise: false)
        defer { server.stop() }
        eventually("listener ready") { output.port != nil }
        var senderStatus = SenderStatus()
        let sender = SenderClient(name: "Wrong key") { senderStatus = $0 }
        defer { sender.disconnect() }
        let wrongKey = try XCTUnwrap(PairingKey.parse("ABCD2346"))
        sender.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(output.port))!), key: wrongKey)
        eventually("authentication rejected") { senderStatus.message.contains("Disconnected") }
        XCTAssertFalse(senderStatus.connected)
        XCTAssertEqual(output.connections, 0)
        XCTAssertNil(output.ownerName)
    }
    func testTemporaryNetworkWaitCanCompletePairingOnTheSameConnection() throws {
        let key = try PairingKey.generate()
        let receiverID = UUID()
        var output = ReceiverStatus()
        let server = ReceiverServer(receiverID: receiverID) { output = $0 }
        server.start(name: "Waiting connection test", key: key, advertise: false)
        defer { server.stop() }
        eventually("listener ready") { output.port != nil }
        let queue = DispatchQueue(label: "waiting-client")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(output.port))!, using: SecureConnection.parameters(key: key))
        let peer = PeerChannel(connection: connection, queue: queue)
        let paired = expectation(description: "original connection completes pairing")
        peer.onReady = { peer.send(WireMessage(kind: .hello, senderID: UUID(), name: "Waiting sender")) }
        peer.onMessage = { message in
            if message.kind == .welcome {
                XCTAssertEqual(message.receiverID, receiverID)
                paired.fulfill()
            }
        }
        peer.onClose = { reason in XCTFail("Temporary waiting must not cancel pairing: \(reason ?? "unknown")") }
        defer { queue.sync { peer.onClose = nil; peer.close(nil) } }
        queue.async {
            peer.start()
            // Deliver a transient path update before the real TLS handshake.
            connection.stateUpdateHandler?(.waiting(.posix(.ENETDOWN)))
        }
        wait(for: [paired], timeout: 5)
    }
    func testSlowInitialPairingDoesNotUseHeartbeatTimeout() throws {
        let key = try PairingKey.generate()
        let receiverID = UUID()
        let queue = DispatchQueue(label: "slow-pairing-receiver")
        let listener = try NWListener(using: SecureConnection.parameters(key: key), on: .any)
        let listening = expectation(description: "slow receiver listening")
        var peers: [PeerChannel] = []
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            let peer = PeerChannel(connection: connection, queue: queue)
            peers.append(peer)
            peer.onMessage = { message in
                if message.kind == .hello { peer.send(WireMessage(kind: .welcome, receiverID: receiverID)) }
            }
            // Hold TLS setup past the live connection's five-second heartbeat limit.
            queue.asyncAfter(deadline: .now() + 6) { peer.start() }
        }
        listener.start(queue: queue)
        defer { queue.sync {
            listener.cancel()
            for peer in peers { peer.close(nil) }
        } }
        wait(for: [listening], timeout: 3)
        var status = SenderStatus()
        let sender = SenderClient(name: "Slow first pairing") {
            status = $0
            XCTAssertFalse($0.message.hasPrefix("Disconnected"), "The first attempt must survive slow setup")
        }
        defer { sender.disconnect() }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port)), key: key)
        eventually("first attempt pairs after slow setup", timeout: 9) { status.connected }
        XCTAssertEqual(status.receiverID, receiverID)
        queue.sync { XCTAssertEqual(peers.count, 1, "Pairing must succeed without starting another connection") }
    }
    func testWaitingConnectionStillHasABoundedTimeout() throws {
        let queue = DispatchQueue(label: "waiting-timeout-client")
        let connection = NWConnection(host: "127.0.0.1", port: 1, using: SecureConnection.parameters(key: try PairingKey.generate()))
        let peer = PeerChannel(connection: connection, queue: queue, connectionTimeout: AltViewProtocol.connectionTimeout)
        let closed = expectation(description: "unrecovered connection times out")
        var didClose = false
        peer.onClose = { reason in
            didClose = true
            XCTAssertEqual(reason, "Connection timed out.")
            closed.fulfill()
        }
        queue.async {
            peer.start()
            connection.stateUpdateHandler?(.waiting(.posix(.ENETDOWN)))
            peer.checkTimeout(now: ProcessInfo.processInfo.systemUptime + AltViewProtocol.timeout + 1)
            XCTAssertFalse(didClose, "Initial setup gets longer than the live heartbeat timeout")
            peer.checkTimeout(now: ProcessInfo.processInfo.systemUptime + AltViewProtocol.connectionTimeout + 1)
        }
        wait(for: [closed], timeout: 2)
    }
    func testSilentAuthenticatedClientExpires() throws {
        let key = try PairingKey.generate()
        var output = ReceiverStatus()
        let server = ReceiverServer(receiverID: UUID()) { output = $0 }
        server.start(name: "Timeout Test", key: key, advertise: false)
        defer { server.stop() }
        eventually("listener ready") { output.port != nil }
        let queue = DispatchQueue(label: "silent-client")
        let peer = PeerChannel(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(output.port))!, using: SecureConnection.parameters(key: key)), queue: queue)
        let closed = expectation(description: "silent connection expired")
        peer.onClose = { _ in closed.fulfill() }
        queue.async { peer.start() }
        wait(for: [closed], timeout: 9)
        XCTAssertEqual(output.connections, 0)
    }
    func testCancellingInitialRetryDoesNotOpenAnotherConnection() throws {
        let key = try PairingKey.generate()
        let receiver = try PairingRetryTestReceiver(key: key, stalledConnections: .max)
        defer { receiver.stop() }
        let listening = expectation(description: "retry receiver listening")
        receiver.start { listening.fulfill() }
        wait(for: [listening], timeout: 3)
        var status = SenderStatus()
        let sender = SenderClient(name: "Cancel retry") { status = $0 }
        defer { sender.disconnect() }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(receiver.port)), key: key)
        eventually("automatic retry scheduled", timeout: 13) { status.message.contains("Retrying the network") }
        sender.disconnect()
        eventually("cancelled") { status.connectionID == nil }
        let settled = expectation(description: "retry delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertEqual(receiver.acceptedConnections, 1)
        XCTAssertFalse(status.connected)
    }
    func testInitialRetriesStopAtTheOverallDeadline() throws {
        let key = try PairingKey.generate()
        let receiver = try PairingRetryTestReceiver(key: key, stalledConnections: .max)
        defer { receiver.stop() }
        let listening = expectation(description: "unresponsive receiver listening")
        receiver.start { listening.fulfill() }
        wait(for: [listening], timeout: 3)
        var status = SenderStatus()
        let sender = SenderClient(name: "Bounded retry") { status = $0 }
        defer { sender.disconnect() }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(receiver.port)), key: key)
        eventually("initial connection gives up", timeout: AltViewProtocol.connectionTimeout + 2) {
            status.message.hasPrefix("Disconnected.")
        }
        XCTAssertNotNil(status.failureReason)
        XCTAssertFalse(status.connected)
        let attempts = receiver.acceptedConnections
        XCTAssertGreaterThan(attempts, 1)
        let settled = expectation(description: "no further retries")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertEqual(receiver.acceptedConnections, attempts)
    }
}

/// Models a stale initial network operation: the first sockets never finish TLS,
/// while a fresh socket can pair and receive the originally requested content.
final class PairingRetryTestReceiver {
    private let queue = DispatchQueue(label: "pairing-retry-test-receiver")
    private let listener: NWListener
    private let stalledConnections: Int
    private let receiverID = UUID()
    private var connections: [NWConnection] = []
    private var peers: [PeerChannel] = []
    var onContent: ((DisplayContent) -> Void)?
    var port: NWEndpoint.Port? { listener.port }
    var acceptedConnections: Int { queue.sync { connections.count } }

    init(key: Data, stalledConnections: Int = 1) throws {
        self.stalledConnections = stalledConnections
        listener = try NWListener(using: SecureConnection.parameters(key: key), on: .any)
    }
    func start(onReady: @escaping () -> Void) {
        listener.stateUpdateHandler = { state in
            if case .ready = state { DispatchQueue.main.async(execute: onReady) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            guard self.connections.count > self.stalledConnections else { return }
            let peer = PeerChannel(connection: connection, queue: self.queue)
            self.peers.append(peer)
            peer.onMessage = { [weak self, weak peer] message in
                guard let self, let peer else { return }
                switch message.kind {
                case .hello: peer.send(WireMessage(kind: .welcome, receiverID: self.receiverID))
                case .take: peer.send(WireMessage(kind: .granted, lease: UUID()))
                case .state:
                    if let content = message.content { DispatchQueue.main.async { self.onContent?(content) } }
                default: break
                }
            }
            peer.start()
        }
        listener.start(queue: queue)
    }
    func stop() {
        queue.sync {
            listener.cancel()
            for peer in peers { peer.close(nil) }
            for connection in connections { connection.cancel() }
        }
    }
}
