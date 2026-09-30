import Foundation
import Network

/// All methods and callbacks are confined to the supplied queue.
final class PeerChannel {
    let id = UUID()
    let connection: NWConnection
    let queue: DispatchQueue
    var onReady: (() -> Void)?
    var onMessage: ((WireMessage) -> Void)?
    var onClose: ((String?) -> Void)?
    private(set) var retryableSetupFailure = false
    private var decoder = FrameDecoder()
    private var outbox = MessageOutbox()
    private var sending = false
    private var ready = false
    private var closed = false
    private var sendStarted: TimeInterval?
    private let connectionTimeout: TimeInterval
    private var started = ProcessInfo.processInfo.systemUptime
    private(set) var lastReceived = ProcessInfo.processInfo.systemUptime

    init(connection: NWConnection, queue: DispatchQueue, connectionTimeout: TimeInterval = AltViewProtocol.timeout) {
        self.connection = connection; self.queue = queue; self.connectionTimeout = connectionTimeout
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.ready = true
                self.lastReceived = ProcessInfo.processInfo.systemUptime
                self.onReady?()
                self.receive()
                self.pump()
            case .waiting(let error):
                // A rejected pairing key needs new input, not more time.
                if case .tls = error { self.fail(error); return }
                // Network.framework can recover when permission or the network path changes.
                // Keep this attempt alive within its existing timeout budget.
                break
            case .failed(let error): self.fail(error)
            case .cancelled: self.close(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func send(_ message: WireMessage) {
        guard !closed else { return }
        do { try outbox.enqueue(message); pump() }
        catch { close(error.localizedDescription) }
    }
    func discardPendingState() { outbox.clearState() }
    func checkTimeout(now: TimeInterval, timeout: TimeInterval = AltViewProtocol.timeout) {
        guard !closed else { return }
        let timedOut = ready ? now - lastReceived > timeout : now - started > connectionTimeout
        if timedOut || sendStarted.map({ now - $0 > timeout }) == true {
            close("Connection timed out.", retryable: !ready)
        }
    }
    private func fail(_ error: NWError) {
        if case .tls = error {
            close("The secure connection was rejected. Check the pairing code on the receiving Mac.")
        } else {
            close(error.localizedDescription, retryable: !ready)
        }
    }
    func close(_ reason: String?, retryable: Bool = false) {
        guard !closed else { return }
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
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                self.sending = false; self.sendStarted = nil
                if let error { self.close(error.localizedDescription) } else { self.pump() }
            })
        } catch { close(error.localizedDescription) }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let data, !data.isEmpty {
                    for message in try self.decoder.append(data) {
                        guard message.version == AltViewProtocol.version else { self.close("Incompatible protocol version."); return }
                        self.lastReceived = ProcessInfo.processInfo.systemUptime
                        self.onMessage?(message)
                        if self.closed { return }
                    }
                }
                if let error { self.close(error.localizedDescription) }
                else if complete { self.close("Peer disconnected.") }
                else { self.receive() }
            } catch { self.close(error.localizedDescription) }
        }
    }
}
