import Foundation

enum AltViewProtocol {
    static let version = 1
    static let serviceType = "_altview._tcp"
    static let maximumFrameSize = 65_536
    static let maximumClients = 8
    static let heartbeatInterval: TimeInterval = 1
    // Initial setup may need Bonjour resolution and macOS Local Network consent.
    static let connectionTimeout: TimeInterval = 30
    static let connectionAttemptTimeout: TimeInterval = 10
    static let timeout: TimeInterval = 5
}

enum EmptyRegionBehavior: String, Codable { case collapse, reserve }

struct DisplayContent: Codable, Equatable {
    var title = ""
    var body = ""
    var footer = ""
    var visible = true
    var emptyRegions = EmptyRegionBehavior.collapse

    var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasFooter: Bool { !footer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static let empty = DisplayContent(visible: false)
    static let scripture = DisplayContent(title: "PSALM 23:1", body: "The LORD is my shepherd;\nI shall not want.", footer: "King James Version")
    static let lyrics = DisplayContent(title: "AMAZING GRACE", body: "Amazing grace! How sweet the sound\nThat saved a wretch like me!", footer: "John Newton · Public domain")
    static let multilingual = DisplayContent(title: "MULTILINGUAL TEST", body: "സമാധാനം · Peace\nשלום · سلام\nஅமைதி · शांति", footer: "Check font fallback and line spacing")

    var isValid: Bool {
        title.utf8.count <= 512 && body.utf8.count <= 24_000 && footer.utf8.count <= 1_024
    }
}

extension DisplayContent {
    private enum CodingKeys: String, CodingKey { case title, body, footer, visible, emptyRegions }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Each snapshot replaces the previous one: omitted labels clear them.
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try values.decode(String.self, forKey: .body)
        footer = try values.decodeIfPresent(String.self, forKey: .footer) ?? ""
        visible = try values.decode(Bool.self, forKey: .visible)
        emptyRegions = try values.decodeIfPresent(EmptyRegionBehavior.self, forKey: .emptyRegions) ?? .collapse
    }
}

/// Every state message is a complete snapshot. All optional fields are validated
/// by the receiver before use. Unknown message types cannot change output.
struct WireMessage: Codable, Equatable {
    enum Kind: String, Codable {
        case hello, welcome, take, resume, granted, state, ownership, release, heartbeat, error
    }
    var version = AltViewProtocol.version
    var kind: Kind
    var senderID: UUID?
    var name: String?
    var receiverID: UUID?
    var lease: UUID?
    var revision: UInt64?
    var content: DisplayContent?
    var ownerID: UUID?
    var ownerName: String?
    var detail: String?
}

enum ProtocolFailure: Error, LocalizedError {
    case invalidFrame, invalidContent, overloaded
    var errorDescription: String? {
        switch self {
        case .invalidFrame: return "The peer sent an invalid or oversized message."
        case .invalidContent: return "Content exceeds AltView’s text limits."
        case .overloaded: return "The connection cannot keep up with control messages."
        }
    }
}

enum FrameCodec {
    static func encode(_ message: WireMessage) throws -> Data {
        let data = try JSONEncoder().encode(message)
        guard !data.isEmpty, data.count <= AltViewProtocol.maximumFrameSize else { throw ProtocolFailure.invalidFrame }
        var length = UInt32(data.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(data)
        return framed
    }
}

struct FrameDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [WireMessage] {
        buffer.append(data)
        var messages: [WireMessage] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= AltViewProtocol.maximumFrameSize else { throw ProtocolFailure.invalidFrame }
            guard buffer.count >= length + 4 else { break }
            messages.append(try JSONDecoder().decode(WireMessage.self, from: buffer.dropFirst(4).prefix(length)))
            buffer.removeFirst(length + 4)
        }
        return messages
    }
}

/// A slow socket retains one latest snapshot, one heartbeat, and a bounded set
/// of controls. It never accumulates a history of text updates.
struct MessageOutbox {
    private var controls: [WireMessage] = []
    private(set) var latestState: WireMessage?
    private var heartbeat: WireMessage?
    var count: Int { controls.count + (latestState == nil ? 0 : 1) + (heartbeat == nil ? 0 : 1) }
    mutating func enqueue(_ message: WireMessage) throws {
        switch message.kind {
        case .state: latestState = message
        case .heartbeat: heartbeat = message
        default:
            guard controls.count < 16 else { throw ProtocolFailure.overloaded }
            controls.append(message)
        }
    }
    mutating func next() -> WireMessage? {
        if !controls.isEmpty { return controls.removeFirst() }
        if let state = latestState { latestState = nil; return state }
        defer { heartbeat = nil }
        return heartbeat
    }
    mutating func clearState() { latestState = nil }
}
