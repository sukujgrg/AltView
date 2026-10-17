import XCTest
@testable import AltView

final class SRTMediaDiscoveryTests: XCTestCase {
    func testMediaProvisioningIsBoundedAndUsesTheControlReceiverIdentity() throws {
        let id = UUID()
        let offer = MediaOffer(receiverID: id, port: 10000, ready: false, passphrase: "generated-secret-123456")
        XCTAssertTrue(offer.isValid)
        XCTAssertEqual(try JSONDecoder().decode(MediaOffer.self, from: JSONEncoder().encode(offer)), offer)
        for port in [0, 65536] {
            XCTAssertFalse(MediaOffer(receiverID: id, port: port, ready: true, passphrase: offer.passphrase).isValid)
        }
        for key in ["ABCD2345", String(repeating: "a", count: 80), "invalid secret with spaces"] {
            XCTAssertFalse(MediaOffer(receiverID: id, port: 10000, ready: true, passphrase: key).isValid)
        }
        var settings = SRTMediaSettings(); settings.host = "paired.receiver"; settings.receiverID = id
        let saved = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertFalse(saved.contains(offer.passphrase)); XCTAssertFalse(saved.contains("passphrase"))
    }
}

actor TestMediaSecrets: SRTMediaSecretStoring {
    private var values: [String: String] = [:]
    func read(_ account: String) -> String? { values[account] }
    func save(_ value: String, account: String) { values[account] = value }
}
