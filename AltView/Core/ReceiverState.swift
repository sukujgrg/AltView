import Foundation

struct SenderIdentity: Equatable {
    let id: UUID
    let name: String
}

/// Pure ownership rules, confined to ReceiverServer's serial queue in production.
struct ReceiverState {
    private(set) var senders: [UUID: SenderIdentity] = [:]
    private(set) var ownerConnection: UUID?
    private(set) var lease: UUID?
    private(set) var revision: UInt64 = 0
    private(set) var content = DisplayContent.empty
    var owner: SenderIdentity? { ownerConnection.flatMap { senders[$0] } }

    mutating func register(connection: UUID, senderID: UUID, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard senders[connection] == nil, !name.isEmpty, name.utf8.count <= 128 else { return false }
        senders[connection] = SenderIdentity(id: senderID, name: name)
        return true
    }
    mutating func take(connection: UUID, onlyIfUnowned: Bool = false) -> UUID? {
        guard senders[connection] != nil, !onlyIfUnowned || ownerConnection == nil else { return nil }
        ownerConnection = connection
        lease = UUID()
        revision = 0
        content = .empty
        return lease
    }
    @discardableResult
    mutating func apply(connection: UUID, lease: UUID, revision: UInt64, content: DisplayContent) -> Bool {
        guard ownerConnection == connection, self.lease == lease, revision > self.revision, content.isValid else { return false }
        self.revision = revision
        self.content = content
        return true
    }
    @discardableResult
    mutating func release(connection: UUID, lease: UUID?) -> Bool {
        guard ownerConnection == connection, self.lease == lease else { return false }
        clearOwner()
        return true
    }
    mutating func disconnect(_ connection: UUID) {
        senders.removeValue(forKey: connection)
        if ownerConnection == connection { clearOwner() }
    }
    mutating func clearOwner() {
        ownerConnection = nil
        lease = nil
        revision = 0
        content = .empty
    }
}
