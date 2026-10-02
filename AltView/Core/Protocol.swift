import Foundation

enum AltViewProtocol {
    static let version = 2
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

/// Stable, opaque IDs let senders select future receiver templates without an app update.
struct ContentTemplate: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let scripture = Self(rawValue: "scripture")
    static let lyrics = Self(rawValue: "lyrics")
    static let builtIns: [Self] = [.scripture, .lyrics]
    var name: String {
        switch self { case .scripture: return "Scripture"; case .lyrics: return "Lyrics"; default: return rawValue }
    }
    var isValid: Bool {
        (1...64).contains(rawValue.utf8.count) && rawValue.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        self.init(rawValue: try value.decode(String.self))
        guard isValid else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid template ID") }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

struct TemplateDescriptor: Codable, Equatable, Sendable {
    let id: ContentTemplate
    let name: String
    static let builtIns = ContentTemplate.builtIns.map { Self(id: $0, name: $0.name) }
    var isValid: Bool { id.isValid && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 128 }
}

/// Receiver policy is independent of sender ownership and snapshot acceptance.
struct TemplatePolicy: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case sender, custom, fixed }
    var mode: Mode
    var template: ContentTemplate?
    static let sender = Self(mode: .sender)
    static let custom = Self(mode: .custom)
    static func fixed(_ template: ContentTemplate) -> Self { Self(mode: .fixed, template: template) }
}

struct TemplateCapabilities: Equatable, Sendable {
    // nil means discovery is unavailable (older receiver); [] means no templates.
    var templates: [TemplateDescriptor]?
    var policy: TemplatePolicy?
    var isValid: Bool {
        if let templates {
            guard templates.count <= 64, templates.allSatisfy(\.isValid),
                  Set(templates.map(\.id)).count == templates.count else { return false }
        }
        guard let policy else { return true }
        guard templates != nil else { return false }
        return policy.mode == .fixed ? policy.template.map(supports) == true : policy.template == nil
    }
    func supports(_ id: ContentTemplate) -> Bool { templates?.contains { $0.id == id } == true }
    func contentForSending(_ content: DisplayContent) -> DisplayContent {
        var result = content
        if let id = content.template, !supports(id) { result.template = nil }
        return result
    }
    func detail(requested: ContentTemplate?) -> String {
        if let policy {
            switch policy.mode {
            case .custom: return "AltView overrides sender templates with its custom layout."
            case .fixed:
                let name = templates?.first { $0.id == policy.template }?.name ?? "a fixed template"
                return "AltView uses \(name) for every message."
            case .sender: break
            }
        }
        guard let requested else { return "" }
        guard templates != nil else { return "This receiver does not advertise templates; using its saved layout." }
        guard let descriptor = templates?.first(where: { $0.id == requested }) else {
            return "The requested template is unavailable; using AltView’s custom layout."
        }
        return "Requested template: \(descriptor.name)."
    }
}

struct DisplayContent: Codable, Equatable {
    var title = ""
    var body = ""
    var footer = ""
    var visible = true
    var emptyRegions = EmptyRegionBehavior.collapse
    var template: ContentTemplate?

    var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasFooter: Bool { !footer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static let empty = DisplayContent(visible: false)
    static let scripture = DisplayContent(title: "PSALM 23:1", body: "The LORD is my shepherd;\nI shall not want.", footer: "King James Version")
    static let lyrics = DisplayContent(title: "AMAZING GRACE", body: "Amazing grace! How sweet the sound\nThat saved a wretch like me!", footer: "John Newton · Public domain")
    static let multilingual = DisplayContent(title: "MULTILINGUAL TEST", body: "സമാധാനം · Peace\nשלום · سلام\nஅமைதி · शांति", footer: "Check font fallback and line spacing")

    var isValid: Bool {
        title.utf8.count <= 512 && body.utf8.count <= 24_000 && footer.utf8.count <= 1_024 && (template?.isValid ?? true)
    }
}

extension DisplayContent {
    private enum CodingKeys: String, CodingKey { case title, body, footer, visible, emptyRegions, template }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Each snapshot replaces the previous one: omitted labels clear them.
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try values.decode(String.self, forKey: .body)
        footer = try values.decodeIfPresent(String.self, forKey: .footer) ?? ""
        visible = try values.decode(Bool.self, forKey: .visible)
        emptyRegions = try values.decodeIfPresent(EmptyRegionBehavior.self, forKey: .emptyRegions) ?? .collapse
        template = try values.decodeIfPresent(ContentTemplate.self, forKey: .template)
    }
}

/// Every state message is a complete snapshot. All optional fields are validated
/// by the receiver before use. Unknown message types cannot change output.
struct WireMessage: Codable, Equatable {
    enum Kind: String, Codable {
        case hello, welcome, take, resume, granted, state, ownership, release, heartbeat, error, feedback
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
    var outputReadiness: OutputReadiness?
    var templates: [TemplateDescriptor]?
    var templatePolicy: TemplatePolicy?
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

/// A slow socket retains one latest snapshot, one feedback message, one heartbeat, and a bounded set
/// of controls. It never accumulates a history of text updates.
struct MessageOutbox {
    private var controls: [WireMessage] = []
    private(set) var latestState: WireMessage?
    private var feedback: WireMessage?
    private var heartbeat: WireMessage?
    var count: Int { controls.count + (latestState == nil ? 0 : 1) + (heartbeat == nil ? 0 : 1) + (feedback == nil ? 0 : 1) }
    mutating func enqueue(_ message: WireMessage) throws {
        switch message.kind {
        case .state: latestState = message
        case .feedback: feedback = message
        case .heartbeat: heartbeat = message
        default:
            guard controls.count < 16 else { throw ProtocolFailure.overloaded }
            controls.append(message)
        }
    }
    mutating func next() -> WireMessage? {
        if !controls.isEmpty { return controls.removeFirst() }
        if let state = latestState { latestState = nil; return state }
        if let message = feedback { feedback = nil; return message }
        defer { heartbeat = nil }
        return heartbeat
    }
    mutating func clearState() { latestState = nil }
}

/// Software output availability, independent of snapshot acceptance or HDMI delivery.
enum OutputReadiness: String, Codable, Sendable {
    case closed, ready, preview, displayMissing, minimized, unavailable, asleep

    var summary: String {
        switch self {
        case .closed: return "Output window closed"
        case .ready: return "Output window open"
        case .preview: return "Preview window only"
        case .displayMissing: return "Output display disconnected"
        case .minimized: return "Output window minimized"
        case .unavailable: return "Output unavailable — check artwork in AltView"
        case .asleep: return "Receiver display asleep"
        }
    }
}

/// Queue-confined, bounded feedback. Missing acknowledgements never gate publication.
struct DeliveryFeedback: Equatable, Sendable {
    private(set) var output: OutputReadiness?
    private(set) var sentRevision: UInt64 = 0
    private(set) var acceptedRevision: UInt64 = 0
    private(set) var overdue = false
    private var pendingSince: TimeInterval?
    var accepted: Bool { sentRevision > 0 && acceptedRevision == sentRevision }

    var detail: String {
        let snapshot = sentRevision == 0 ? "No snapshot sent"
            : accepted ? "Latest snapshot accepted by AltView"
            : overdue ? "Snapshot acknowledgement delayed; sending continues"
            : "Waiting for snapshot acknowledgement"
        return "\(snapshot). \(output?.summary ?? "Waiting for display status")."
    }
    mutating func resetSnapshot() {
        sentRevision = 0; acceptedRevision = 0; pendingSince = nil; overdue = false
    }
    mutating func sent(_ revision: UInt64, now: TimeInterval) {
        sentRevision = revision
        if pendingSince == nil { pendingSince = now }
    }
    mutating func receive(_ message: WireMessage, lease: UUID?, now: TimeInterval) {
        guard message.kind == .feedback, let output = message.outputReadiness else { return }
        self.output = output
        // A delayed response from a previous owner/lease can never confirm current text.
        guard let lease, message.lease == lease, let revision = message.revision,
              revision > acceptedRevision, revision <= sentRevision else { return }
        acceptedRevision = revision
        pendingSince = accepted ? nil : now
        overdue = false
    }
    @discardableResult
    mutating func checkTimeout(now: TimeInterval) -> Bool {
        let value = pendingSince.map { now - $0 >= AltViewProtocol.timeout } ?? false
        guard value != overdue else { return false }
        overdue = value
        return true
    }
}
