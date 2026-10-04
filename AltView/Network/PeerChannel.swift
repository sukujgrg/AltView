import Foundation
import Network
import os

/// Native unified logging only. Never pass content, credentials, endpoints or peer-provided text.
enum AltViewLog {
    static let connection = Logger(subsystem: "com.suku.AltView", category: "connection")
    static let receiver = Logger(subsystem: "com.suku.AltView", category: "receiver")
    static let sender = Logger(subsystem: "com.suku.AltView", category: "sender")
    static func errorCode(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "posix:\(code.rawValue)"
        case .dns(let code): return "dns:\(code)"
        case .tls(let code): return "tls:\(code)"
        case .wifiAware(let code): return "wifi_aware:\(code)"
        @unknown default: return "unknown"
        }
    }
}

enum PeerCloseCause: String {
    case localStop = "local_stop", peerClosed = "peer_closed", transportCancelled = "transport_cancelled"
    case transportFailure = "transport_failure", tlsRejected = "tls_rejected"
    case setupTimeout = "transport_setup_timeout", handshakeTimeout = "application_handshake_timeout"
    case receiveInactivity = "receive_inactivity", sendStalled = "send_stalled"
    case invalidFrame = "invalid_frame", overloaded = "outbox_overloaded", protocolViolation = "protocol_violation"
    case identityChanged = "receiver_identity_changed"

    /// Same deadlines as before; classify them without conflating the three clocks.
    static func timeout(now: TimeInterval, started: TimeInterval, ready: Bool, handshakeComplete: Bool,
                        lastReceived: TimeInterval, sendStarted: TimeInterval?, setupTimeout: TimeInterval,
                        timeout: TimeInterval) -> Self? {
        if !ready && now - started > setupTimeout { return .setupTimeout }
        if let sendStarted, now - sendStarted > timeout { return .sendStalled }
        if ready && now - lastReceived > timeout { return handshakeComplete ? .receiveInactivity : .handshakeTimeout }
        return nil
    }
}

/// All methods and callbacks are confined to the supplied queue.
final class PeerChannel {
    let id = UUID()
    let connection: NWConnection
    let queue: DispatchQueue
    var onReady: (() -> Void)?
    var onMessage: ((WireMessage) -> Void)?
    var onClose: ((String?) -> Void)?
    private(set) var retryableSetupFailure = false
    private(set) var closeCause: PeerCloseCause?
    private var decoder = FrameDecoder()
    private var outbox = MessageOutbox()
    private var sending = false
    private var ready = false
    var isTransportReady: Bool { ready }
    private var handshakeComplete = false
    private var closed = false
    private var sendStarted: TimeInterval?
    private var sendingKind: WireMessage.Kind?
    private var sendingRevision: UInt64?
    private var sentFrames: UInt64 = 0, receivedFrames: UInt64 = 0
    private var sentHeartbeats: UInt64 = 0, receivedHeartbeats: UInt64 = 0
    private var lastReceivedKind: WireMessage.Kind?
    private let connectionTimeout: TimeInterval
    private var started = ProcessInfo.processInfo.systemUptime
    private(set) var lastReceived = ProcessInfo.processInfo.systemUptime

    init(connection: NWConnection, queue: DispatchQueue, connectionTimeout: TimeInterval = AltViewProtocol.timeout) {
        self.connection = connection; self.queue = queue; self.connectionTimeout = connectionTimeout
    }
    func start() {
        AltViewLog.connection.notice("peer_start peer=\(self.id.uuidString, privacy: .public) setup_timeout_s=\(self.connectionTimeout)")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.ready = true
                self.lastReceived = ProcessInfo.processInfo.systemUptime
                AltViewLog.connection.notice("transport_ready peer=\(self.id.uuidString, privacy: .public)")
                self.onReady?()
                self.receive()
                self.pump()
            case .waiting(let error):
                AltViewLog.connection.notice("transport_waiting peer=\(self.id.uuidString, privacy: .public) code=\(AltViewLog.errorCode(error), privacy: .public)")
                // A rejected pairing key needs new input, not more time.
                if case .tls = error { self.fail(error); return }
                // Network.framework can recover when permission or the network path changes.
                // Keep this attempt alive within its existing timeout budget.
                break
            case .failed(let error): self.fail(error)
            case .cancelled: self.close(nil, cause: .transportCancelled)
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func send(_ message: WireMessage) {
        guard !closed else { return }
        do { try outbox.enqueue(message); pump() }
        catch { close(error.localizedDescription, cause: .overloaded) }
    }
    func markHandshakeComplete() { handshakeComplete = true }
    func discardPendingState() { outbox.clearState() }
    func checkTimeout(now: TimeInterval, timeout: TimeInterval = AltViewProtocol.timeout) {
        guard !closed else { return }
        if let cause = PeerCloseCause.timeout(now: now, started: started, ready: ready, handshakeComplete: handshakeComplete,
                                             lastReceived: lastReceived, sendStarted: sendStarted,
                                             setupTimeout: connectionTimeout, timeout: timeout) {
            close("Connection timed out.", retryable: !ready, cause: cause)
        }
    }
    private func fail(_ error: NWError) {
        if case .tls = error {
            close("The secure connection was rejected. Check the pairing code on the receiving Mac.", cause: .tlsRejected, networkError: error)
        } else {
            close(error.localizedDescription, retryable: !ready, cause: .transportFailure, networkError: error)
        }
    }
    func close(_ reason: String?, retryable: Bool = false, cause: PeerCloseCause? = nil, networkError: NWError? = nil) {
        guard !closed else { return }
        let cause = cause ?? (reason == nil ? .localStop : .protocolViolation)
        closeCause = cause
        let now = ProcessInfo.processInfo.systemUptime
        let sendAge = sendStarted.map { now - $0 } ?? 0
        // Do not log reason: decoding errors and remote error messages can contain user text.
        AltViewLog.connection.notice("peer_closed peer=\(self.id.uuidString, privacy: .public) cause=\(cause.rawValue, privacy: .public) code=\(networkError.map(AltViewLog.errorCode) ?? "none", privacy: .public) ready=\(self.ready) handshake=\(self.handshakeComplete) retryable=\(retryable) lifetime_s=\(now - self.started) receive_idle_s=\(now - self.lastReceived) send_age_s=\(sendAge) in_flight=\(self.sendingKind?.rawValue ?? "none", privacy: .public) in_flight_revision=\(self.sendingRevision ?? 0) last_received=\(self.lastReceivedKind?.rawValue ?? "none", privacy: .public) sent_frames=\(self.sentFrames) received_frames=\(self.receivedFrames) sent_heartbeats=\(self.sentHeartbeats) received_heartbeats=\(self.receivedHeartbeats)")
        closed = true
        retryableSetupFailure = retryable
        connection.stateUpdateHandler = nil
        connection.cancel()
        let callback = onClose
        onClose = nil; onMessage = nil; onReady = nil
        callback?(reason)
    }
    private func pump() {
        guard ready, !closed, !sending, let message = outbox.next() else { return }
        do {
            let frame = try FrameCodec.encode(message)
            sending = true
            sendStarted = ProcessInfo.processInfo.systemUptime
            sendingKind = message.kind; sendingRevision = message.revision
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if let error { self.close(error.localizedDescription, cause: .transportFailure, networkError: error); return }
                self.sentFrames &+= 1
                if message.kind == .heartbeat { self.sentHeartbeats &+= 1 }
                if message.kind == .state || message.kind == .hello || message.kind == .welcome {
                    AltViewLog.connection.info("frame_sent peer=\(self.id.uuidString, privacy: .public) kind=\(message.kind.rawValue, privacy: .public) revision=\(message.revision ?? 0) bytes=\(frame.count)")
                }
                self.sending = false; self.sendStarted = nil; self.sendingKind = nil; self.sendingRevision = nil
                self.pump()
            })
        } catch { close(error.localizedDescription, cause: .invalidFrame) }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let data, !data.isEmpty {
                    for message in try self.decoder.append(data) {
                        guard message.version == AltViewProtocol.version else { self.close("Incompatible protocol version."); return }
                        self.lastReceived = ProcessInfo.processInfo.systemUptime
                        self.receivedFrames &+= 1; self.lastReceivedKind = message.kind
                        if message.kind == .heartbeat { self.receivedHeartbeats &+= 1 }
                        self.onMessage?(message)
                        if self.closed { return }
                    }
                }
                if let error { self.close(error.localizedDescription, cause: .transportFailure, networkError: error) }
                else if complete { self.close("Peer disconnected.", cause: .peerClosed) }
                else { self.receive() }
            } catch { self.close(error.localizedDescription, cause: .invalidFrame) }
        }
    }
}
