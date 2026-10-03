import Foundation
import Network
import os

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
        AltViewLog.sender.info("snapshot_submitted connection=\(self.status.connectionID?.uuidString ?? "none", privacy: .public) connected=\(self.status.connected) owns_output=\(self.status.ownsOutput) visible=\(content.visible) title_bytes=\(content.title.utf8.count) body_bytes=\(content.body.utf8.count) footer_bytes=\(content.footer.utf8.count)")
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
            guard let self else { return }
            guard self.status.connected else {
                AltViewLog.sender.notice("ownership_request_skipped connection=\(self.status.connectionID?.uuidString ?? "none", privacy: .public) cause=not_connected")
                return
            }
            guard self.latest.isValid else { self.status.message = "Text is too long to send"; self.publish(); return }
            self.peer?.discardPendingState()
            AltViewLog.sender.notice("ownership_requested peer=\(self.peer?.id.uuidString ?? "none", privacy: .public) request=take")
            self.peer?.send(WireMessage(kind: .take))
        }
    }
    func releaseOutput() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRestoreOwnership = false
            AltViewLog.sender.notice("ownership_release_requested peer=\(self.peer?.id.uuidString ?? "none", privacy: .public) lease=\(self.lease?.uuidString ?? "none", privacy: .public)")
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
        if status.connectionID != nil {
            AltViewLog.sender.notice("disconnect_requested connection=\(self.status.connectionID?.uuidString ?? "none", privacy: .public) owns_output=\(self.status.ownsOutput)")
        }
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
                AltViewLog.sender.error("connection_setup_budget_exhausted connection=\(self.status.connectionID?.uuidString ?? "none", privacy: .public)")
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
        AltViewLog.sender.notice("connection_attempt connection=\(self.status.connectionID?.uuidString ?? "none", privacy: .public) peer=\(peer.id.uuidString, privacy: .public) attempt=\(self.attempts + 1) restoring=\(self.shouldRestoreOwnership)")
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer else { return }
            peer.send(WireMessage(kind: .hello, senderID: self.senderID, name: self.name))
            // The application handshake starts after the transport is ready.
            self.queue.asyncAfter(deadline: .now() + AltViewProtocol.timeout) { [weak self, weak peer] in
                guard let self, let peer, self.peer === peer, !self.status.connected else { return }
                peer.close("Receiver did not complete the handshake.", cause: .handshakeTimeout)
            }
        }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer, self.peer === peer else { return }
            self.handle(message)
        }
        peer.onClose = { [weak self, weak peer] reason in
            guard let self, let peer, self.peer === peer else { return }
            AltViewLog.sender.notice("receiver_disconnected connection=\(self.status.connectionID?.uuidString ?? "none", privacy: .public) peer=\(peer.id.uuidString, privacy: .public) cause=\(peer.closeCause?.rawValue ?? "unknown", privacy: .public) owned_output=\(self.status.ownsOutput) sent_revision=\(self.status.feedback.sentRevision) accepted_revision=\(self.status.feedback.acceptedRevision)")
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
            if self.status.feedback.checkTimeout(now: ProcessInfo.processInfo.systemUptime) {
                AltViewLog.sender.notice("snapshot_ack_delayed peer=\(peer.id.uuidString, privacy: .public) sent_revision=\(self.status.feedback.sentRevision) accepted_revision=\(self.status.feedback.acceptedRevision)")
                self.publish()
            }
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
                peer?.close("Receiver identity changed. Pair again.", cause: .identityChanged)
                status.message = "Receiver identity changed. Pair again."
                publish()
                return
            }
            status.feedback = DeliveryFeedback()
            peer?.markHandshakeComplete()
            status.templateCapabilities = capabilities
            status.requestedTemplate = latest.template
            expectedReceiverID = receiverID
            initialConnectionDeadline = nil
            attempts = 0; status.connected = true; status.receiverID = receiverID
            status.ownerName = message.ownerName
            status.message = "Connected — ready to take output"
            AltViewLog.sender.notice("receiver_connected peer=\(self.peer?.id.uuidString ?? "none", privacy: .public) occupied=\(message.ownerID != nil) resume_requested=\(self.shouldRestoreOwnership && message.ownerID == nil)")
            if shouldRestoreOwnership && message.ownerID == nil { peer?.send(WireMessage(kind: .resume)) }
            else if message.ownerID != nil { shouldRestoreOwnership = false }
            publish()
        case .granted:
            guard status.connected, let lease = message.lease else { return }
            self.lease = lease; revision = 0
            status.feedback.resetSnapshot()
            status.ownsOutput = true; shouldRestoreOwnership = true
            AltViewLog.sender.notice("ownership_granted peer=\(self.peer?.id.uuidString ?? "none", privacy: .public) lease=\(lease.uuidString, privacy: .public)")
            status.message = "Controlling output"
            sendLatest(); publish()
        case .ownership:
            status.ownerName = message.ownerName
            if message.ownerID != senderID || message.lease != lease {
                AltViewLog.sender.notice("ownership_lost peer=\(self.peer?.id.uuidString ?? "none", privacy: .public) previous_lease=\(self.lease?.uuidString ?? "none", privacy: .public) occupied=\(message.ownerID != nil)")
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
            let previousRevision = status.feedback.acceptedRevision
            let previousOutput = status.feedback.output
            status.feedback.receive(message, lease: lease, now: ProcessInfo.processInfo.systemUptime)
            if status.feedback.acceptedRevision != previousRevision {
                AltViewLog.sender.info("snapshot_acknowledged peer=\(self.peer?.id.uuidString ?? "none", privacy: .public) lease=\(self.lease?.uuidString ?? "none", privacy: .public) accepted_revision=\(self.status.feedback.acceptedRevision) sent_revision=\(self.status.feedback.sentRevision)")
            }
            if status.feedback.output != previousOutput {
                AltViewLog.sender.notice("receiver_output_readiness peer=\(self.peer?.id.uuidString ?? "none", privacy: .public) state=\(self.status.feedback.output?.rawValue ?? "unknown", privacy: .public)")
            }
            publish()
        case .heartbeat: break
        case .error:
            AltViewLog.sender.error("receiver_reported_error peer=\(self.peer?.id.uuidString ?? "none", privacy: .public)")
            status.message = message.detail ?? "Receiver rejected the message"; publish()
        default: peer?.close("Unexpected receiver message.")
        }
    }
    private func sendLatest() {
        guard latest.isValid else {
            AltViewLog.sender.error("snapshot_rejected_locally cause=invalid_content")
            status.message = "Text is too long to send"; publish(); return
        }
        guard let lease, status.connected else {
            AltViewLog.sender.info("snapshot_not_sent connection=\(self.status.connectionID?.uuidString ?? "none", privacy: .public) connected=\(self.status.connected) has_lease=\(self.lease != nil)")
            return
        }
        guard revision < UInt64.max else { peer?.close("Session revision exhausted."); return }
        revision += 1
        status.feedback.sent(revision, now: ProcessInfo.processInfo.systemUptime)
        AltViewLog.sender.info("snapshot_queued peer=\(self.peer?.id.uuidString ?? "none", privacy: .public) lease=\(lease.uuidString, privacy: .public) revision=\(self.revision) visible=\(self.latest.visible)")
        peer?.send(WireMessage(kind: .state, lease: lease, revision: revision,
                              content: status.templateCapabilities.contentForSending(latest)))
        publish()
    }
    private func scheduleReconnect() {
        guard wantsConnection else { return }
        let delay = initialConnectionDeadline.map { min(1, max(0, $0 - ProcessInfo.processInfo.systemUptime)) }
            ?? min(8.0, pow(2.0, Double(min(attempts, 3))))
        attempts += 1
        AltViewLog.sender.notice("reconnect_scheduled connection=\(self.status.connectionID?.uuidString ?? "none", privacy: .public) delay_s=\(delay) attempt=\(self.attempts) restoring=\(self.shouldRestoreOwnership)")
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
        AltViewLog.sender.notice("connection_setup_failed connection=\(self.status.connectionID?.uuidString ?? "none", privacy: .public)")
        wantsConnection = false; initialConnectionDeadline = nil
        reconnectWork?.cancel(); reconnectWork = nil
        status.failureReason = reason
        status.message = "Disconnected. \(reason)"
        publish()
    }
    private func publish() { delivery.offer(status) }
}
