import Foundation
import Network

struct SenderStatus: Equatable {
    var connectionID: UUID?
    var connected = false
    var ownsOutput = false
    var receiverID: UUID?
    var ownerName: String?
    var message = "Not connected"
    var failureReason: String?
    var feedback = DeliveryFeedback()
    var templateCapabilities = TemplateCapabilities()
    var requestedTemplate: ContentTemplate?
    var templateDetail: String { templateCapabilities.detail(requested: requestedTemplate) }
}

/// No network operation or serialization runs on the caller's UI thread.
final class SenderClient {
    let senderID: UUID
    let name: String
    private let queue = DispatchQueue(label: "com.suku.AltView.sender", qos: .userInitiated)
    private var peer: PeerChannel?
    private var endpoint: NWEndpoint?
    private var key: Data?
    private var expectedReceiverID: UUID?
    private var reconnectWork: DispatchWorkItem?
    private var attempts = 0
    private var initialConnectionDeadline: TimeInterval?
    private var timer: DispatchSourceTimer?
    private var lease: UUID?
    private var revision: UInt64 = 0
    private var latest = DisplayContent.empty
    private var wantsConnection = false
    private var shouldRestoreOwnership = false
    private var status = SenderStatus()
    private let delivery: SnapshotMailbox<SenderStatus>
    private lazy var submissions = SnapshotMailbox<DisplayContent>(queue: queue) { [weak self] content in
        guard let self else { return }
        self.latest = content
        self.status.requestedTemplate = content.template
        self.sendLatest()
    }

    init(name: String, senderID: UUID = UUID(), callbackQueue: DispatchQueue = .main, onStatus: @escaping (SenderStatus) -> Void) {
        self.name = name; self.senderID = senderID
        delivery = SnapshotMailbox(queue: callbackQueue, consume: onStatus)
        // Initialize on the creating thread before concurrent calls can arrive.
        _ = submissions
    }
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID? = nil, connectionID: UUID = UUID()) {
        queue.async { [weak self] in
            guard let self else { return }
            self.disconnectOnQueue()
            self.status.connectionID = connectionID
            self.endpoint = endpoint; self.key = key
            self.expectedReceiverID = expectedReceiverID
            self.wantsConnection = true; self.attempts = 0
            self.initialConnectionDeadline = ProcessInfo.processInfo.systemUptime + AltViewProtocol.connectionTimeout
            self.openConnection()
        }
    }
    func submit(_ content: DisplayContent) { submissions.offer(content) }
    func takeOutput() {
        queue.async { [weak self] in
            guard let self, self.status.connected else { return }
            guard self.latest.isValid else { self.status.message = "Text is too long to send"; self.publish(); return }
            self.peer?.discardPendingState()
            self.peer?.send(WireMessage(kind: .take))
        }
    }
    func releaseOutput() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRestoreOwnership = false
            self.peer?.discardPendingState()
            if let lease = self.lease { self.peer?.send(WireMessage(kind: .release, lease: lease)) }
            self.lease = nil
            self.status.ownsOutput = false
            self.status.feedback.resetSnapshot()
            self.publish()
        }
    }
    func disconnect() { queue.async { [weak self] in self?.disconnectOnQueue(); self?.publish() } }
    private func disconnectOnQueue() {
        wantsConnection = false; shouldRestoreOwnership = false
        initialConnectionDeadline = nil
        reconnectWork?.cancel(); reconnectWork = nil
        timer?.cancel(); timer = nil
        peer?.onClose = nil; peer?.close(nil); peer = nil
        lease = nil; status = SenderStatus()
    }
    private func openConnection() {
        guard wantsConnection, let endpoint, let key else { return }
        let setupTimeout: TimeInterval
        if let deadline = initialConnectionDeadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                failInitialConnection("Connection timed out. Check that the receiving Mac is ready and AltView has Local Network access in System Settings.")
                return
            }
            setupTimeout = min(AltViewProtocol.connectionAttemptTimeout, remaining)
            status.message = attempts == 0 ? "Connecting…" : "Connecting… Retrying the network connection."
        } else {
            setupTimeout = AltViewProtocol.connectionTimeout
            status.message = "Reconnecting…"
        }
        status.failureReason = nil
        publish()
        let peer = PeerChannel(connection: NWConnection(to: endpoint, using: SecureConnection.parameters(key: key)),
                               queue: queue, connectionTimeout: setupTimeout)
        self.peer = peer
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer else { return }
            peer.send(WireMessage(kind: .hello, senderID: self.senderID, name: self.name))
            // The application handshake starts after the transport is ready.
            self.queue.asyncAfter(deadline: .now() + AltViewProtocol.timeout) { [weak self, weak peer] in
                guard let self, let peer, self.peer === peer, !self.status.connected else { return }
                peer.close("Receiver did not complete the handshake.")
            }
        }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer, self.peer === peer else { return }
            self.handle(message)
        }
        peer.onClose = { [weak self, weak peer] reason in
            guard let self, let peer, self.peer === peer else { return }
            self.shouldRestoreOwnership = self.status.ownsOutput || self.shouldRestoreOwnership
            self.peer = nil; self.lease = nil
            self.status.connected = false; self.status.ownsOutput = false
            self.status.feedback = DeliveryFeedback()
            self.status.templateCapabilities = TemplateCapabilities()
            self.timer?.cancel(); self.timer = nil
            if let deadline = self.initialConnectionDeadline {
                if self.wantsConnection, peer.retryableSetupFailure, ProcessInfo.processInfo.systemUptime < deadline {
                    // A Bonjour connection can remain stuck in preparing after Local Network
                    // access changes. Use a fresh connection without cancelling the user's action.
                    self.status.message = "Connecting… Retrying the network connection."
                    self.publish()
                    self.scheduleReconnect()
                } else {
                    self.failInitialConnection(reason ?? "The receiving Mac closed the connection.")
                }
                return
            }
            self.status.failureReason = reason
            self.status.message = "Disconnected. \(reason ?? "") Retrying…"
            self.publish()
            self.scheduleReconnect()
        }
        peer.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self, weak peer] in
            guard let self, let peer else { return }
            if self.status.connected { peer.send(WireMessage(kind: .heartbeat)) }
            if self.status.feedback.checkTimeout(now: ProcessInfo.processInfo.systemUptime) { self.publish() }
            peer.checkTimeout(now: ProcessInfo.processInfo.systemUptime)
        }
        self.timer = timer; timer.resume()
    }
    private func handle(_ message: WireMessage) {
        guard message.version == AltViewProtocol.version else { wantsConnection = false; peer?.close("Incompatible AltView protocol. Update both apps."); return }
        switch message.kind {
        case .welcome:
            guard !status.connected, let receiverID = message.receiverID else { peer?.close("Invalid welcome."); return }
            let capabilities = TemplateCapabilities(templates: message.templates, policy: message.templatePolicy)
            guard capabilities.isValid else { peer?.close("Invalid template catalogue."); return }
            if let expectedReceiverID, expectedReceiverID != receiverID {
                wantsConnection = false
                peer?.close("Receiver identity changed. Pair again.")
                status.message = "Receiver identity changed. Pair again."
                publish()
                return
            }
            status.feedback = DeliveryFeedback()
            status.templateCapabilities = capabilities
            status.requestedTemplate = latest.template
            expectedReceiverID = receiverID
            initialConnectionDeadline = nil
            attempts = 0; status.connected = true; status.receiverID = receiverID
            status.ownerName = message.ownerName
            status.message = "Connected — ready to take output"
            if shouldRestoreOwnership && message.ownerID == nil { peer?.send(WireMessage(kind: .resume)) }
            else if message.ownerID != nil { shouldRestoreOwnership = false }
            publish()
        case .granted:
            guard status.connected, let lease = message.lease else { return }
            self.lease = lease; revision = 0
            status.feedback.resetSnapshot()
            status.ownsOutput = true; shouldRestoreOwnership = true
            status.message = "Controlling output"
            sendLatest(); publish()
        case .ownership:
            status.ownerName = message.ownerName
            if message.ownerID != senderID || message.lease != lease {
                lease = nil; status.ownsOutput = false; shouldRestoreOwnership = false
                status.feedback.resetSnapshot()
                peer?.discardPendingState()
                status.message = message.ownerName.map { "Output controlled by \($0)" } ?? "Connected — output is clear"
            }
            publish()
        case .feedback:
            guard status.connected, message.outputReadiness != nil,
                  (message.lease == nil && message.revision == nil) || (message.lease != nil && message.revision.map { $0 > 0 } == true) else {
                peer?.close("Unexpected output feedback."); return
            }
            let capabilities = TemplateCapabilities(templates: message.templates, policy: message.templatePolicy)
            guard capabilities.isValid else { peer?.close("Invalid template catalogue."); return }
            status.templateCapabilities = capabilities
            status.feedback.receive(message, lease: lease, now: ProcessInfo.processInfo.systemUptime)
            publish()
        case .heartbeat: break
        case .error: status.message = message.detail ?? "Receiver rejected the message"; publish()
        default: peer?.close("Unexpected receiver message.")
        }
    }
    private func sendLatest() {
        guard latest.isValid else { status.message = "Text is too long to send"; publish(); return }
        guard let lease, status.connected else { return }
        guard revision < UInt64.max else { peer?.close("Session revision exhausted."); return }
        revision += 1
        status.feedback.sent(revision, now: ProcessInfo.processInfo.systemUptime)
        peer?.send(WireMessage(kind: .state, lease: lease, revision: revision,
                              content: status.templateCapabilities.contentForSending(latest)))
        publish()
    }
    private func scheduleReconnect() {
        guard wantsConnection else { return }
        let delay = initialConnectionDeadline.map { min(1, max(0, $0 - ProcessInfo.processInfo.systemUptime)) }
            ?? min(8.0, pow(2.0, Double(min(attempts, 3))))
        attempts += 1
        let connectionID = status.connectionID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantsConnection, self.status.connectionID == connectionID, self.peer == nil else { return }
            self.reconnectWork = nil
            self.openConnection()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func failInitialConnection(_ reason: String) {
        wantsConnection = false; initialConnectionDeadline = nil
        reconnectWork?.cancel(); reconnectWork = nil
        status.failureReason = reason
        status.message = "Disconnected. \(reason)"
        publish()
    }
    private func publish() { delivery.offer(status) }
}
