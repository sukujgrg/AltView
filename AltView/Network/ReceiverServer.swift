import Foundation
import Network
import os

struct ReceiverStatus: Equatable {
    var listening = false
    var port: UInt16?
    var connections = 0
    var connectedSenders: [SenderIdentity] = []
    var ownerID: UUID?
    var ownerName: String?
    var content = DisplayContent.empty
    var message = "Receiving is off"
}

final class ReceiverServer {
    let receiverID: UUID
    private let queue = DispatchQueue(label: "com.suku.AltView.receiver", qos: .userInitiated)
    private var listener: NWListener?
    private var peers: [UUID: PeerChannel] = [:]
    private var outputReadiness = OutputReadiness.closed
    private var templatePolicy = TemplatePolicy.sender
    private var state = ReceiverState()
    private var status = ReceiverStatus()
    private var timer: DispatchSourceTimer?
    private let delivery: SnapshotMailbox<ReceiverStatus>

    init(receiverID: UUID, callbackQueue: DispatchQueue = .main, onStatus: @escaping (ReceiverStatus) -> Void) {
        self.receiverID = receiverID
        delivery = SnapshotMailbox(queue: callbackQueue, consume: onStatus)
    }
    func start(name: String, key: Data, port: UInt16 = 0, advertise: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            do {
                let listener = try NWListener(using: SecureConnection.parameters(key: key), on: NWEndpoint.Port(rawValue: port)!)
                self.listener = listener
                if advertise {
                    // Public identity lets discovery omit this Mac; pairing secrets never leave TLS.
                    listener.service = NWListener.Service(name: name, type: AltViewProtocol.serviceType,
                        txtRecord: NWTXTRecord(["receiverID": self.receiverID.uuidString]))
                }
                listener.stateUpdateHandler = { [weak self, weak listener] newState in
                    guard let self, let listener, self.listener === listener else { return }
                    switch newState {
                    case .ready:
                        self.status.listening = true
                        self.status.port = listener.port?.rawValue
                        self.status.message = "Ready for senders"
                        AltViewLog.receiver.notice("listener_ready port=\(self.status.port ?? 0) protocol=\(AltViewProtocol.version)")
                        self.publish()
                    case .failed(let error), .waiting(let error):
                        AltViewLog.receiver.error("listener_failed code=\(AltViewLog.errorCode(error), privacy: .public)")
                        self.stopOnQueue()
                        self.status.message = "Could not receive: \(error.localizedDescription)"
                        self.publish()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: self.queue)
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    for peer in Array(self.peers.values) {
                        peer.send(WireMessage(kind: .heartbeat))
                        peer.checkTimeout(now: now)
                    }
                }
                self.timer = timer
                timer.resume()
            } catch {
                AltViewLog.receiver.error("listener_start_failed")
                self.status.message = "Could not start receiver: \(error.localizedDescription)"
                self.publish()
            }
        }
    }
    func updateOutputReadiness(_ readiness: OutputReadiness) {
        queue.async { [weak self] in
            guard let self, self.outputReadiness != readiness else { return }
            self.outputReadiness = readiness
            AltViewLog.receiver.notice("output_readiness state=\(readiness.rawValue, privacy: .public)")
            self.broadcastFeedback()
        }
    }
    func updateTemplatePolicy(_ policy: TemplatePolicy) {
        queue.async { [weak self] in
            guard let self, self.templatePolicy != policy,
                  TemplateCapabilities(templates: TemplateDescriptor.builtIns, policy: policy).isValid else { return }
            self.templatePolicy = policy
            self.broadcastFeedback()
        }
    }
    func stop() { queue.async { [weak self] in self?.stopOnQueue(); self?.publish() } }
    func clearOutput() {
        queue.async { [weak self] in
            guard let self else { return }
            AltViewLog.receiver.notice("ownership_cleared peer=\(self.state.ownerConnection?.uuidString ?? "none", privacy: .public) lease=\(self.state.lease?.uuidString ?? "none", privacy: .public) revision=\(self.state.revision)")
            self.state.clearOwner()
            self.status.message = "Ready for senders"
            self.broadcastOwnership()
            self.publish()
        }
    }
    private func stopOnQueue() {
        if listener != nil || !peers.isEmpty {
            AltViewLog.receiver.notice("receiver_stopped peers=\(self.peers.count) owner_peer=\(self.state.ownerConnection?.uuidString ?? "none", privacy: .public) lease=\(self.state.lease?.uuidString ?? "none", privacy: .public) revision=\(self.state.revision)")
        }
        timer?.cancel(); timer = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        let closing = Array(peers.values)
        peers.removeAll()
        for peer in closing { peer.onClose = nil; peer.close(nil) }
        state = ReceiverState()
        status = ReceiverStatus()
    }
    private func accept(_ connection: NWConnection) {
        guard peers.count < AltViewProtocol.maximumClients else {
            AltViewLog.receiver.notice("connection_rejected cause=capacity peers=\(self.peers.count)")
            connection.cancel(); return
        }
        let peer = PeerChannel(connection: connection, queue: queue)
        peers[peer.id] = peer
        AltViewLog.receiver.notice("connection_accepted peer=\(peer.id.uuidString, privacy: .public)")
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            self.handle(message, from: peer)
        }
        peer.onClose = { [weak self, weak peer] reason in
            guard let self, let peer, self.peers.removeValue(forKey: peer.id) != nil else { return }
            let wasOwner = self.state.ownerConnection == peer.id
            AltViewLog.receiver.notice("sender_disconnected peer=\(peer.id.uuidString, privacy: .public) cause=\(peer.closeCause?.rawValue ?? "unknown", privacy: .public) was_owner=\(wasOwner) accepted_revision=\(wasOwner ? self.state.revision : 0) lease=\(wasOwner ? (self.state.lease?.uuidString ?? "none") : "none", privacy: .public)")
            self.state.disconnect(peer.id)
            if wasOwner { self.status.message = "Sender disconnected — output cleared" }
            self.broadcastOwnership()
            self.publish()
        }
        peer.start()
        // An authenticated peer must identify itself, even if it sends heartbeats.
        queue.asyncAfter(deadline: .now() + AltViewProtocol.timeout) { [weak self, weak peer] in
            guard let self, let peer, self.peers[peer.id] != nil, self.state.senders[peer.id] == nil else { return }
            peer.close("Sender did not identify itself.", cause: peer.isTransportReady ? .handshakeTimeout : .setupTimeout)
        }
    }
    private func handle(_ message: WireMessage, from peer: PeerChannel) {
        guard message.version == AltViewProtocol.version else { peer.close("Unsupported protocol version."); return }
        if message.kind == .hello {
            guard let id = message.senderID, let name = message.name, state.register(connection: peer.id, senderID: id, name: name) else {
                peer.close("Invalid sender identity."); return
            }
            peer.markHandshakeComplete()
            AltViewLog.receiver.notice("sender_identified peer=\(peer.id.uuidString, privacy: .public) occupied=\(self.state.ownerConnection != nil)")
            peer.send(WireMessage(kind: .welcome, receiverID: receiverID, ownerID: state.owner?.id, ownerName: state.owner?.name,
                                 templates: TemplateDescriptor.builtIns, templatePolicy: templatePolicy))
            sendFeedback(to: peer)
            publish()
            return
        }
        guard state.senders[peer.id] != nil else { peer.close("Identify sender first."); return }
        switch message.kind {
        case .take, .resume:
            let previousOwner = state.ownerConnection
            guard let lease = state.take(connection: peer.id, onlyIfUnowned: message.kind == .resume) else {
                AltViewLog.receiver.notice("ownership_denied peer=\(peer.id.uuidString, privacy: .public) request=\(message.kind.rawValue, privacy: .public) cause=occupied")
                broadcastOwnership(); return
            }
            AltViewLog.receiver.notice("ownership_granted peer=\(peer.id.uuidString, privacy: .public) request=\(message.kind.rawValue, privacy: .public) previous_peer=\(previousOwner?.uuidString ?? "none", privacy: .public) lease=\(lease.uuidString, privacy: .public)")
            status.message = "Receiving from \(state.owner!.name)"
            peer.send(WireMessage(kind: .granted, lease: lease))
            broadcastOwnership()
            publish()
        case .state:
            guard let lease = message.lease, let revision = message.revision, let content = message.content, content.isValid else {
                peer.close("Invalid content snapshot."); return
            }
            if state.apply(connection: peer.id, lease: lease, revision: revision, content: content) {
                AltViewLog.receiver.info("snapshot_accepted peer=\(peer.id.uuidString, privacy: .public) lease=\(lease.uuidString, privacy: .public) revision=\(revision) visible=\(content.visible) title_bytes=\(content.title.utf8.count) body_bytes=\(content.body.utf8.count) footer_bytes=\(content.footer.utf8.count) output=\(self.outputReadiness.rawValue, privacy: .public)")
                publish()
                sendFeedback(to: peer)
            } else {
                let rejection = state.ownerConnection != peer.id ? "not_owner" : state.lease != lease ? "stale_lease" : "stale_revision"
                AltViewLog.receiver.info("snapshot_rejected peer=\(peer.id.uuidString, privacy: .public) lease=\(lease.uuidString, privacy: .public) revision=\(revision) cause=\(rejection, privacy: .public)")
            }
        case .release:
            if state.release(connection: peer.id, lease: message.lease) {
                AltViewLog.receiver.notice("ownership_released peer=\(peer.id.uuidString, privacy: .public) lease=\(message.lease?.uuidString ?? "none", privacy: .public)")
                status.message = "Ready for senders"
                broadcastOwnership()
                publish()
            }
        case .heartbeat: break
        default: peer.close("Unexpected sender message.")
        }
    }
    private func broadcastOwnership() {
        let message = WireMessage(kind: .ownership, lease: state.lease, ownerID: state.owner?.id, ownerName: state.owner?.name)
        for (id, peer) in peers where state.senders[id] != nil { peer.send(message) }
        broadcastFeedback()
    }
    private func broadcastFeedback() {
        for peer in peers.values { sendFeedback(to: peer) }
    }
    private func sendFeedback(to peer: PeerChannel) {
        guard state.senders[peer.id] != nil else { return }
        let hasSnapshot = state.ownerConnection == peer.id && state.revision > 0
        peer.send(WireMessage(kind: .feedback, lease: hasSnapshot ? state.lease : nil,
                              revision: hasSnapshot ? state.revision : nil, outputReadiness: outputReadiness,
                              templates: TemplateDescriptor.builtIns, templatePolicy: templatePolicy))
    }
    private func publish() {
        status.connections = state.senders.count
        status.connectedSenders = state.senders.values.sorted {
            $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name
        }
        status.ownerID = state.owner?.id
        status.ownerName = state.owner?.name
        status.content = state.content
        delivery.offer(status)
    }
}
