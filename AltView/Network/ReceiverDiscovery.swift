import Foundation
import Network

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
                let receivers = results.compactMap { result -> DiscoveredReceiver? in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    let id: UUID?
                    if case .bonjour(let record) = result.metadata { id = record["receiverID"].flatMap(UUID.init(uuidString:)) }
                    else { id = nil }
                    if let id, id == self.excludingReceiverID { return nil }
                    return DiscoveredReceiver(name: name, endpoint: result.endpoint, receiverID: id)
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
