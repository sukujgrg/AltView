import Foundation
import Network
import CryptoKit
import Darwin

/// A public, boot-scoped machine marker, shared by processes on this Mac.
/// It contains no pairing material and is used only to choose loopback routing.
enum LocalReceiverMarker {
    static let current: String? = {
        var length = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0, (1...128).contains(length) else { return nil }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0 else { return nil }
        let value = String(cString: bytes)
        guard !value.isEmpty else { return nil }
        return SHA256.hash(data: Data("AltView local v1:\(value)".utf8)).map { String(format: "%02x", $0) }.joined()
    }()
}

struct DiscoveredReceiver {
    let name: String
    let endpoint: NWEndpoint
    var receiverID: UUID?
}

final class ReceiverDiscovery {
    private let queue = DispatchQueue(label: "com.suku.AltView.discovery")
    private var browser: NWBrowser?
    // UI entry points and delivery generations are main-queue owned.
    private var generation = UUID()
    private let excludingReceiverID: UUID?
    private let onChange: ([DiscoveredReceiver], String?) -> Void
    init(excludingReceiverID: UUID? = nil, onChange: @escaping ([DiscoveredReceiver], String?) -> Void) {
        self.excludingReceiverID = excludingReceiverID; self.onChange = onChange
    }
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation = UUID()
        let generation = generation
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelBrowser()
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: AltViewProtocol.serviceType, domain: nil), using: .tcp)
            self.browser = browser
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                guard let self, let browser, self.browser === browser else { return }
                let receivers = results.compactMap {
                    self.receiver(endpoint: $0.endpoint, metadata: $0.metadata)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.deliver(receivers, error: nil, generation: generation)
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                guard let self, let browser, self.browser === browser else { return }
                if case .failed(let error) = state {
                    self.cancelBrowser()
                    self.deliver([], error: error.localizedDescription, generation: generation)
                }
                if case .waiting(let error) = state {
                    self.deliver([], error: "Discovery waiting: \(error.localizedDescription)", generation: generation)
                }
            }
            browser.start(queue: self.queue)
        }
    }
    // Keep identity parsing and filtering independent of live Bonjour availability.
    func receiver(endpoint: NWEndpoint, metadata: NWBrowser.Result.Metadata) -> DiscoveredReceiver? {
        guard case .service(let name, _, _, _) = endpoint else { return nil }
        let id: UUID?
        if case .bonjour(let record) = metadata { id = record["receiverID"].flatMap(UUID.init(uuidString:)) }
        else { id = nil }
        if let id, id == excludingReceiverID { return nil }
        return DiscoveredReceiver(name: name, endpoint: endpoint, receiverID: id)
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation = UUID()
        queue.async { [weak self] in self?.cancelBrowser() }
    }
    private func cancelBrowser() {
        browser?.browseResultsChangedHandler = nil
        browser?.stateUpdateHandler = nil
        browser?.cancel(); browser = nil
    }
    private func deliver(_ receivers: [DiscoveredReceiver], error: String?, generation: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onChange(receivers, error)
        }
    }
}
