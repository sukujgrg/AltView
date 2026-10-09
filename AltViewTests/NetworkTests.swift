import XCTest
import Network
import Darwin
@testable import AltView

final class NetworkTests: XCTestCase {
    private final class ListenerProbe {
        private let lock = NSLock()
        private var listeners: [NWListener] = []
        func make(_ parameters: NWParameters, _ port: NWEndpoint.Port) throws -> NWListener {
            let listener = try NWListener(using: parameters, on: port)
            lock.lock(); listeners.append(listener); lock.unlock()
            return listener
        }
        var all: [NWListener] { lock.lock(); defer { lock.unlock() }; return listeners }
    }
    private final class StatusBox {
        private let lock = NSLock()
        private var status = SenderStatus()
        func set(_ status: SenderStatus) { lock.lock(); self.status = status; lock.unlock() }
        var value: SenderStatus { lock.lock(); defer { lock.unlock() }; return status }
    }
    func testWaitingReceiverPreservesListenerAndOwnershipUntilNetworkResumes() throws {
        let key = try PairingKey.generate(), probe = ListenerProbe()
        var output = ReceiverStatus(), status = SenderStatus()
        let server = ReceiverServer(receiverID: UUID(), makeListener: probe.make) { output = $0 }
        let sender = SenderClient(name: "Network interruption") { status = $0 }
        defer { sender.disconnect(); server.stop() }
        server.start(name: "Waiting receiver", key: key, advertise: false)
        eventually("listener ready") { output.listening }
        let port = try XCTUnwrap(output.port), listener = try XCTUnwrap(probe.all.first)
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), key: key)
        eventually("sender connected") { status.connected }
        sender.submit(.scripture); sender.takeOutput()
        eventually("output accepted") { status.feedback.accepted && output.content == .scripture }
        let queue = try XCTUnwrap(listener.queue)
        queue.async { listener.stateUpdateHandler?(.waiting(.posix(.ENETDOWN))) }
        eventually("listener waiting") { output.starting && !output.listening }
        XCTAssertEqual(output.port, port); XCTAssertEqual(output.ownerID, sender.senderID)
        XCTAssertEqual(output.connections, 1); XCTAssertEqual(output.content, .scripture)
        XCTAssertEqual(probe.all.count, 1)
        queue.async { listener.stateUpdateHandler?(.ready) }
        eventually("same listener resumes") { output.listening && !output.starting }
        sender.submit(.lyrics)
        eventually("existing ownership still publishes") { status.feedback.accepted && output.content == .lyrics }
        XCTAssertEqual(probe.all.count, 1)
    }
    func testFailedRunningListenerRecoversOnSameAutomaticPortAndCredentials() throws {
        let key = try PairingKey.generate(), id = UUID(), probe = ListenerProbe()
        var output = ReceiverStatus(), status = SenderStatus()
        let server = ReceiverServer(receiverID: id, startupRetryTimeout: 0.05, startupRetryInterval: 0.05,
                                    makeListener: probe.make) { output = $0 }
        let sender = SenderClient(name: "Reconnected sender") { status = $0 }
        defer { sender.disconnect(); server.stop() }
        server.updateTemplatePolicy(.fixed(.lyrics))
        server.start(name: "Recovery", key: key, advertise: false)
        eventually("listener ready") { output.listening }
        let port = try XCTUnwrap(output.port), listener = try XCTUnwrap(probe.all.first)
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), key: key, expectedReceiverID: id)
        eventually("sender connected") { status.connected }
        sender.submit(.lyrics); sender.takeOutput()
        eventually("output accepted") { output.content == .lyrics && status.feedback.accepted }
        // Runtime recovery remains available after the initial-start deadline.
        let queue = try XCTUnwrap(listener.queue)
        queue.async { listener.stateUpdateHandler?(.failed(.posix(.ENETDOWN))) }
        eventually("listener recreated and sender restored", timeout: 15) {
            probe.all.count == 2 && output.listening && output.content == .lyrics && status.feedback.accepted
        }
        XCTAssertEqual(output.port, port); XCTAssertEqual(status.receiverID, id)
        XCTAssertEqual(status.templateCapabilities.policy, .fixed(.lyrics))
    }
    func testStoppingReceiverCancelsScheduledRuntimeRecovery() throws {
        let probe = ListenerProbe()
        var output = ReceiverStatus()
        let server = ReceiverServer(receiverID: UUID(), startupRetryInterval: 0.5, makeListener: probe.make) { output = $0 }
        defer { server.stop() }
        server.start(name: "Cancelled recovery", key: try PairingKey.generate(), advertise: false)
        eventually("listener ready") { output.listening }
        let listener = try XCTUnwrap(probe.all.first), queue = try XCTUnwrap(listener.queue)
        queue.async { listener.stateUpdateHandler?(.failed(.posix(.ENETDOWN))) }
        eventually("recovery scheduled") { output.starting && output.message.contains("retrying") }
        server.stop()
        eventually("receiver stopped") { !output.starting && !output.listening }
        let settled = expectation(description: "scheduled recovery cancelled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(probe.all.count, 1); XCTAssertFalse(output.listening)
    }
    func testLongUnicodeSenderNamePairsWithinTheWireLimit() throws {
        let key = try PairingKey.generate()
        var output = ReceiverStatus(), status = SenderStatus()
        let server = ReceiverServer(receiverID: UUID()) { output = $0 }
        let prefix = "AltView Custom Text · "
        let sender = SenderClient(name: prefix + String(repeating: "👩🏽‍💻é", count: 30)) { status = $0 }
        defer { sender.disconnect(); server.stop() }
        XCTAssertTrue(sender.name.hasPrefix(prefix))
        XCTAssertLessThanOrEqual(sender.name.utf8.count, AltViewProtocol.maximumSenderNameBytes)
        XCTAssertTrue(sender.name.hasSuffix("é"), "Truncate at whole grapheme boundaries")
        XCTAssertEqual(SenderClient(name: " \n ") { _ in }.name, "AltView")
        server.start(name: "Unicode names", key: key, advertise: false)
        eventually("listener ready") { output.listening }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!), key: key)
        eventually("sender paired") { status.connected && output.connectedSenders.first?.name == sender.name }
    }
    func testCoalescedTransportGrantAndTakeoverLeaveComposerReadyToPublishAgain() throws {
        let key = try PairingKey.generate(), box = StatusBox()
        let callbacks = DispatchQueue(label: "coalesced-sender-status")
        var output = ReceiverStatus(), otherStatus = SenderStatus(), suspended = false
        let server = ReceiverServer(receiverID: UUID()) { output = $0 }
        let sender = SenderClient(name: "Custom Text", callbackQueue: callbacks) { box.set($0) }
        let other = SenderClient(name: "Other presenter") { otherStatus = $0 }
        defer { if suspended { callbacks.resume() }; sender.disconnect(); other.disconnect(); server.stop() }
        server.start(name: "Coalescing", key: key, advertise: false)
        eventually("listener ready") { output.listening }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!)
        sender.connect(to: endpoint, key: key); other.connect(to: endpoint, key: key)
        eventually("both connected") { box.value.connected && otherStatus.connected }
        let composer = TextComposerSession(sender: sender, draft: .scripture)
        composer.receive(box.value)
        callbacks.suspend(); suspended = true
        composer.show()
        eventually("composer granted") { output.ownerID == sender.senderID && output.content == .scripture }
        other.submit(.lyrics); other.takeOutput()
        eventually("other presenter granted") { output.ownerID == other.senderID && otherStatus.ownsOutput }
        let settled = expectation(description: "ownership messages processed before status delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        callbacks.resume(); suspended = false
        eventually("latest non-owner status delivered") { box.value.ownerName == other.name && !box.value.ownsOutput }
        composer.receive(box.value)
        XCTAssertNotNil(box.value.lastGrantedLease)
        XCTAssertFalse(composer.takingOutput); XCTAssertTrue(composer.canShow)
        XCTAssertEqual(output.ownerID, other.senderID, "Recovery must not automatically take output")
        composer.show()
        eventually("explicit publish takes output again") { output.ownerID == sender.senderID && output.content == .scripture }
    }
    func testEndpointUpdateKeepsSessionGuardsAndDoesNotStealOccupiedOutput() throws {
        let receiverID = UUID(), key = try PairingKey.generate(), connectionID = UUID()
        var originalOutput = ReceiverStatus(), movedOutput = ReceiverStatus()
        var status = SenderStatus(), otherStatus = SenderStatus()
        let original = ReceiverServer(receiverID: receiverID) { originalOutput = $0 }
        let moved = ReceiverServer(receiverID: receiverID) { movedOutput = $0 }
        let sender = SenderClient(name: "Local composer") { status = $0 }
        let other = SenderClient(name: "Other sender") { otherStatus = $0 }
        defer { sender.disconnect(); other.disconnect(); original.stop(); moved.stop() }
        // Keep both listeners alive to force different ports and exercise an
        // address update before the old transport reports disconnection.
        original.start(name: "Original", key: key, advertise: false)
        moved.start(name: "Moved", key: key, advertise: false)
        eventually("both listeners ready") { originalOutput.listening && movedOutput.listening }
        let originalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(originalOutput.port))!)
        let movedEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(movedOutput.port))!)
        XCTAssertNotEqual(originalEndpoint, movedEndpoint)
        sender.connect(to: originalEndpoint, key: key, expectedReceiverID: receiverID, connectionID: connectionID)
        other.connect(to: movedEndpoint, key: key, expectedReceiverID: receiverID)
        eventually("senders connected") { status.connected && otherStatus.connected }
        sender.submit(.lyrics); sender.takeOutput()
        other.submit(.scripture); other.takeOutput()
        eventually("both own their output") { status.ownsOutput && otherStatus.ownsOutput }

        sender.updateEndpoint(movedEndpoint, connectionID: UUID())
        sender.submit(.multilingual)
        eventually("stale update leaves the active session alone") { originalOutput.content == .multilingual && status.feedback.accepted }
        sender.updateEndpoint(movedEndpoint, connectionID: connectionID)
        eventually("active session moves to the occupied receiver") {
            originalOutput.connections == 0 && movedOutput.connections == 2 && status.connected && status.ownerName == other.name
        }
        XCTAssertEqual(status.connectionID, connectionID)
        XCTAssertEqual(status.receiverID, receiverID)
        XCTAssertFalse(status.ownsOutput)
        XCTAssertEqual(movedOutput.ownerID, other.senderID)
        XCTAssertEqual(movedOutput.content, .scripture)

        sender.disconnect()
        sender.updateEndpoint(originalEndpoint, connectionID: connectionID)
        eventually("disconnected sender stays disconnected") { status.connectionID == nil && movedOutput.connections == 1 }
        let settled = expectation(description: "endpoint refresh cannot restart a cancelled session")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(originalOutput.connections, 0)
        XCTAssertNil(status.connectionID)
    }

    func testBonjourSenderReconnectsAfterReceiverChangesPort() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["ALTVIEW_SKIP_BONJOUR_TEST"] == "1",
                      "Live Bonjour needs local multicast discovery.")
        let key = try PairingKey.generate(), receiverID = UUID()
        let name = "AltView port \(receiverID)"
        var output = ReceiverStatus(), status = SenderStatus(), receivers: [DiscoveredReceiver] = []
        let server = ReceiverServer(receiverID: receiverID) { output = $0 }
        let sender = SenderClient(name: "Bonjour reconnect") { status = $0 }
        let discovery = ReceiverDiscovery { receivers = $0; _ = $1 }
        defer { sender.disconnect(); discovery.stop(); server.stop() }
        server.start(name: name, key: key)
        discovery.start()
        eventually("automatic port advertised") { output.listening && receivers.contains { $0.receiverID == receiverID } }
        let endpoint = try XCTUnwrap(receivers.first { $0.receiverID == receiverID }?.endpoint)
        let previousPort = try XCTUnwrap(output.port)
        // Reserve a different port while the first listener still owns its port,
        // so this test does not depend on the OS allocator choosing a new number.
        let nextPort = try OccupiedReceiverPort()
        defer { nextPort.release() }
        XCTAssertNotEqual(previousPort, nextPort.port)
        sender.connect(to: endpoint, key: key, expectedReceiverID: receiverID)
        eventually("Bonjour connection ready") { status.connected }
        sender.submit(.lyrics); sender.takeOutput()
        eventually("initial snapshot accepted") { status.feedback.accepted && output.content == .lyrics }
        server.stop()
        eventually("old service removed") { !output.listening && !status.connected && !receivers.contains { $0.receiverID == receiverID } }
        nextPort.release()
        server.start(name: name, key: key, port: nextPort.port)
        eventually("same saved service resolves new port and restores output", timeout: 20) {
            output.port == nextPort.port && output.content == .lyrics && status.ownsOutput && status.feedback.accepted
        }
        XCTAssertEqual(status.receiverID, receiverID)
    }

    func testReceiverRecoversWhenOccupiedPortBecomesAvailable() throws {
        let occupied = try OccupiedReceiverPort()
        defer { occupied.release() }
        let key = try PairingKey.generate(), receiverID = UUID()
        var output = ReceiverStatus(), status = SenderStatus()
        let server = ReceiverServer(receiverID: receiverID, startupRetryTimeout: 5, startupRetryInterval: 0.1) { output = $0 }
        let sender = SenderClient(name: "Recovery") { status = $0 }
        defer { sender.disconnect(); server.stop() }
        server.updateTemplatePolicy(.fixed(.lyrics))
        server.start(name: "Recovery", key: key, port: occupied.port, advertise: false)
        eventually("port conflict is being retried") { output.starting && output.message.contains("retrying") }
        XCTAssertFalse(output.listening)
        XCTAssertNil(output.port)
        XCTAssertEqual(output.content, .empty)
        occupied.release()
        eventually("same port recovers without another start") { output.listening && !output.starting && output.port == occupied.port }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: occupied.port)!), key: key, expectedReceiverID: receiverID)
        eventually("original pairing and template policy survive") { status.connected && status.templateCapabilities.policy == .fixed(.lyrics) }
        XCTAssertNil(output.ownerID)
        sender.submit(.lyrics); sender.takeOutput()
        eventually("recovered receiver accepts text") { output.content == .lyrics && status.feedback.accepted }
    }

    func testPersistentPortConflictStopsRetryingAndAllowsManualResume() throws {
        let occupied = try OccupiedReceiverPort()
        defer { occupied.release() }
        let key = try PairingKey.generate()
        var output = ReceiverStatus()
        let server = ReceiverServer(receiverID: UUID(), startupRetryTimeout: 0.5, startupRetryInterval: 0.05) { output = $0 }
        defer { server.stop() }
        server.start(name: "Busy", key: key, port: occupied.port, advertise: false)
        eventually("retry budget expires", timeout: 3) { !output.starting && output.message.hasPrefix("Could not receive: port") }
        XCTAssertFalse(output.listening)
        XCTAssertTrue(output.message.contains("resume receiving"))
        occupied.release()
        let settled = expectation(description: "no more automatic starts after deadline")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertFalse(output.listening)
        XCTAssertFalse(output.starting)
        server.start(name: "Busy", key: key, port: occupied.port, advertise: false)
        eventually("manual resume gets a fresh attempt") { output.listening && output.port == occupied.port }
    }

    func testNewReceiverStartSupersedesPendingPortRetry() throws {
        let occupied = try OccupiedReceiverPort()
        defer { occupied.release() }
        let key = try PairingKey.generate()
        var output = ReceiverStatus()
        let server = ReceiverServer(receiverID: UUID(), startupRetryTimeout: 5, startupRetryInterval: 0.2) { output = $0 }
        defer { server.stop() }
        server.start(name: "Old start", key: key, port: occupied.port, advertise: false)
        eventually("old start is retrying") { output.starting && output.message.contains("retrying") }
        server.start(name: "New start", key: key, advertise: false)
        eventually("new listener ready") { output.listening }
        let newPort = try XCTUnwrap(output.port)
        XCTAssertNotEqual(newPort, occupied.port)
        occupied.release()
        let settled = expectation(description: "old retry cannot replace new listener")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertTrue(output.listening)
        XCTAssertEqual(output.port, newPort)
    }

    func testTemplateCatalogueAndLiveOverridesReachOwnersAndConnectedObservers() throws {
        let key = try PairingKey.generate()
        var output = ReceiverStatus(), aStatus = SenderStatus(), bStatus = SenderStatus()
        let server = ReceiverServer(receiverID: UUID()) { output = $0 }
        server.updateTemplatePolicy(.fixed(.scripture))
        server.start(name: "Templates", key: key, advertise: false)
        let a = SenderClient(name: "Owner") { aStatus = $0 }
        let b = SenderClient(name: "Observer") { bStatus = $0 }
        defer { a.disconnect(); b.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!)
        a.connect(to: endpoint, key: key); b.connect(to: endpoint, key: key)
        eventually("catalogue available without taking output") {
            aStatus.connected && bStatus.connected && aStatus.templateCapabilities.policy == .fixed(.scripture)
                && bStatus.templateCapabilities.templates == TemplateDescriptor.builtIns
        }
        XCTAssertNil(output.ownerID)
        let content = DisplayContent(body: "Lyrics", template: .lyrics)
        a.submit(content); a.takeOutput()
        eventually("snapshot accepted") { output.content == content && aStatus.feedback.accepted }
        let revision = aStatus.feedback.acceptedRevision
        server.updateTemplatePolicy(.custom)
        eventually("override broadcast to all senders") { aStatus.templateCapabilities.policy == .custom && bStatus.templateCapabilities.policy == .custom }
        XCTAssertEqual(output.content, content)
        XCTAssertEqual(output.ownerID, a.senderID)
        XCTAssertEqual(aStatus.feedback.acceptedRevision, revision)
        XCTAssertTrue(aStatus.templateDetail.contains("overrides"))
        XCTAssertEqual(bStatus.feedback.acceptedRevision, 0)
        server.updateTemplatePolicy(.sender)
        eventually("sender choice enabled again") { aStatus.templateCapabilities.policy == .sender && bStatus.templateCapabilities.policy == .sender }
        XCTAssertEqual(aStatus.feedback.sentRevision, revision, "Metadata updates must not republish text")
        a.disconnect()
        eventually("disconnect forgets discovery") { !aStatus.connected && aStatus.templateCapabilities.templates == nil }
    }

    func testFutureTemplateIDsRefreshAndFallbackAcrossReconnects() throws {
        let key = try PairingKey.generate()
        let future = TemplateDescriptor(id: ContentTemplate(rawValue: "speaker-intro"), name: "Speaker introduction")
        let capabilities = TemplateCapabilities(templates: [future], policy: .sender)
        let receiver = try TemplateTestReceiver(key: key, capabilities: capabilities)
        let listening = expectation(description: "listener")
        receiver.start { listening.fulfill() }
        defer { receiver.stop() }
        wait(for: [listening], timeout: 3)
        var status = SenderStatus(), received: [DisplayContent] = []
        receiver.onContent = { received.append($0) }
        let sender = SenderClient(name: "Future-compatible sender") { status = $0 }
        defer { sender.disconnect() }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(receiver.port)), key: key)
        eventually("future ID discovered") { status.connected && status.templateCapabilities == capabilities }
        let content = DisplayContent(title: "Speaker", body: "Jordan Lee", footer: "Host", template: future.id)
        sender.submit(content); sender.takeOutput()
        eventually("opaque ID sent unchanged") { received.last == content }
        receiver.updateCapabilities(TemplateCapabilities(templates: [], policy: .sender))
        eventually("catalogue removal received") { status.templateCapabilities.templates == [] }
        XCTAssertEqual(received.count, 1, "Discovery updates must not publish anything")
        var hidden = content; hidden.visible = false
        sender.submit(hidden)
        var unmarked = hidden; unmarked.template = nil
        eventually("removed template omitted") { received.last == unmarked }
        XCTAssertEqual(status.requestedTemplate, future.id, "Keep the desired choice for a future reconnect")
        receiver.updateCapabilities(TemplateCapabilities(), reconnect: true)
        eventually("disconnect clears old catalogue") { !status.connected && status.templateCapabilities.templates == nil }
        eventually("older receiver reconnects and restores without template", timeout: 12) { status.ownsOutput && received.count == 3 }
        XCTAssertEqual(received.last, unmarked)
        XCTAssertNil(status.templateCapabilities.templates)
        XCTAssertTrue(status.templateDetail.contains("does not advertise"))
        receiver.updateCapabilities(capabilities, reconnect: true)
        eventually("new catalogue restores originally requested ID", timeout: 12) { status.ownsOutput && received.count == 4 && received.last == hidden }
        XCTAssertEqual(status.templateCapabilities, capabilities)
    }

    func testSenderTemplateChangesWithSnapshotsAndClearsWhenOmitted() throws {
        let key = try PairingKey.generate()
        var output = ReceiverStatus(), status = SenderStatus()
        let server = ReceiverServer(receiverID: UUID()) { output = $0 }
        let sender = SenderClient(name: "Template sender") { status = $0 }
        server.start(name: "Templates", key: key, advertise: false)
        defer { sender.disconnect(); server.stop() }
        eventually("listener ready") { output.port != nil }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!), key: key)
        eventually("connected") { status.connected }
        XCTAssertNil(output.ownerID, "Connecting alone does not apply a template")
        let scripture = DisplayContent(title: "PSALM 23:1", body: "The LORD is my shepherd", footer: "King James Version", template: .scripture)
        sender.submit(scripture); sender.takeOutput()
        eventually("scripture accepted") { output.content == scripture && status.feedback.accepted }
        let lyrics = DisplayContent(body: "Amazing grace", template: .lyrics)
        sender.submit(lyrics)
        eventually("lyrics accepted") { output.content == lyrics && status.feedback.accepted }
        var hidden = lyrics; hidden.visible = false
        sender.submit(hidden)
        eventually("hidden snapshot keeps template") { output.content == hidden }
        let generic = DisplayContent(body: "Announcement")
        sender.submit(generic)
        eventually("omitted template restores custom layout") { output.content == generic }
        sender.releaseOutput()
        eventually("release clears template and text") { output.ownerID == nil && output.content == .empty }
    }

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
    func testIndividualDisconnectPreservesOtherSenderAndRefusesRetriesUntilAllowed() throws {
        let key = try PairingKey.generate()
        var output = ReceiverStatus(), activeStatus = SenderStatus(), idleStatus = SenderStatus()
        let server = ReceiverServer(receiverID: UUID()) { output = $0 }
        let active = SenderClient(name: "Same Name") { activeStatus = $0 }
        let idle = SenderClient(name: "Same Name") { idleStatus = $0 }
        defer { active.disconnect(); idle.disconnect(); server.stop() }
        server.start(name: "Individual disconnect test", key: key, advertise: false)
        eventually("listening") { output.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!)
        active.connect(to: endpoint, key: key); idle.connect(to: endpoint, key: key)
        eventually("both connected") { output.connections == 2 && activeStatus.connected && idleStatus.connected }
        active.submit(.scripture); active.takeOutput()
        eventually("one presenting") { output.ownerID == active.senderID && output.content == .scripture }
        let idleConnection = try XCTUnwrap(output.senderConnections.first { $0.senderID == idle.senderID })
        XCTAssertFalse(idleConnection.isPresenting)
        server.disconnectConnection(idleConnection.id)
        eventually("idle disconnected independently") { output.connections == 1 && !idleStatus.connected && output.senderConnections.contains { $0.senderID == idle.senderID && $0.isDisconnected } }
        XCTAssertEqual(output.content, .scripture)
        XCTAssertEqual(output.ownerID, active.senderID)
        // Force a new connection with the same authenticated sender identity;
        // an operator disconnect must not be undone by an automatic retry.
        idle.connect(to: endpoint, key: key)
        eventually("retry refused") { idleStatus.failureReason != nil }
        XCTAssertEqual(output.connections, 1)
        server.allowReconnect(senderID: idle.senderID)
        idle.connect(to: endpoint, key: key)
        eventually("allowed idle sender reconnects") { output.connections == 2 && idleStatus.connected }
        server.disconnectConnection(idleConnection.id)
        let settled = expectation(description: "stale disconnect cannot close the replacement session")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(output.connections, 2)
        let activeConnection = try XCTUnwrap(output.senderConnections.first { $0.senderID == active.senderID })
        XCTAssertTrue(activeConnection.isPresenting)
        server.disconnectConnection(activeConnection.id)
        eventually("active sender disconnected and both outputs cleared") { output.connections == 1 && output.ownerID == nil && output.content == .empty && output.confidenceContent == .empty }
        XCTAssertTrue(idleStatus.connected)
        XCTAssertTrue(output.listening)
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

/// A real listener without port sharing, used to reproduce EADDRINUSE deterministically.
final class OccupiedReceiverPort {
    let port: UInt16
    private var descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard bound == 0, named == 0, listen(descriptor, 1) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
        port = UInt16(bigEndian: address.sin_port)
    }

    func release() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}

/// A future or older v2 receiver for discovery interoperability tests.
final class TemplateTestReceiver {
    private let queue = DispatchQueue(label: "template-test-receiver")
    private let listener: NWListener
    private let receiverID = UUID()
    private var capabilities: TemplateCapabilities
    private var peer: PeerChannel?
    var onContent: ((DisplayContent) -> Void)?
    var port: NWEndpoint.Port? { listener.port }

    init(key: Data, capabilities: TemplateCapabilities) throws {
        self.capabilities = capabilities
        listener = try NWListener(using: SecureConnection.parameters(key: key), on: .any)
    }
    func start(onReady: @escaping () -> Void) {
        listener.stateUpdateHandler = { state in
            if case .ready = state { DispatchQueue.main.async(execute: onReady) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let peer = PeerChannel(connection: connection, queue: self.queue)
            self.peer = peer
            peer.onMessage = { [weak self, weak peer] message in
                guard let self, let peer else { return }
                switch message.kind {
                case .hello:
                    peer.send(WireMessage(kind: .welcome, receiverID: self.receiverID,
                                          templates: self.capabilities.templates, templatePolicy: self.capabilities.policy))
                case .take, .resume: peer.send(WireMessage(kind: .granted, lease: UUID()))
                case .state:
                    if let content = message.content { DispatchQueue.main.async { self.onContent?(content) } }
                case .heartbeat: peer.send(WireMessage(kind: .heartbeat))
                default: break
                }
            }
            peer.start()
        }
        listener.start(queue: queue)
    }
    func updateCapabilities(_ capabilities: TemplateCapabilities, reconnect: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            self.capabilities = capabilities
            if reconnect { self.peer?.close(nil); self.peer = nil }
            else { self.peer?.send(WireMessage(kind: .feedback, outputReadiness: .closed,
                                               templates: capabilities.templates, templatePolicy: capabilities.policy)) }
        }
    }
    func stop() {
        queue.sync { listener.cancel(); peer?.onMessage = nil; peer?.close(nil); peer = nil }
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
