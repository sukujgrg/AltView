import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import AltView

private final class FixturePairingKeychain: PairingKeychainAccess {
    struct Call: Equatable {
        let operation: String
        let service: String
        let account: String
        let dataProtection: Bool
    }
    var protectedError: Error?
    var loginError: Error?
    var values: [Bool: [String: Data]] = [:]
    var calls: [Call] = []

    private func record(_ operation: String, service: String, account: String, dataProtection: Bool) throws {
        calls.append(Call(operation: operation, service: service, account: account, dataProtection: dataProtection))
        if let error = dataProtection ? protectedError : loginError { throw error }
    }
    func read(service: String, account: String, dataProtection: Bool) throws -> Data? {
        try record("read", service: service, account: account, dataProtection: dataProtection)
        return values[dataProtection]?[account]
    }
    func save(_ data: Data, service: String, account: String, dataProtection: Bool) throws {
        try record("save", service: service, account: account, dataProtection: dataProtection)
        values[dataProtection, default: [:]][account] = data
    }
}

final class KeyStoreTests: XCTestCase {
    private let key = Data("ABCD2345".utf8)
    private let replacement = Data("EFGH6789".utf8)
    private let accounts = ["receiver", "sender.receiver.local:54321", "sender.service.Output Mac"]
    private func status(_ code: OSStatus) -> NSError { NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }
    private func assertStatus(_ code: OSStatus, _ work: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try work(), file: file, line: line) {
            XCTAssertEqual(($0 as NSError).domain, NSOSStatusErrorDomain, file: file, line: line)
            XCTAssertEqual(($0 as NSError).code, Int(code), file: file, line: line)
        }
    }

    func testProtectedItemsAndSavesRemainPreferredForEveryAccount() throws {
        for account in accounts {
            let backend = FixturePairingKeychain()
            backend.values = [true: [account: key], false: [account: replacement]]
            XCTAssertEqual(try KeyStore.read(account, keychain: backend), key)
            try KeyStore.save(replacement, account: account, keychain: backend)
            XCTAssertEqual(backend.calls.map(\.dataProtection), [true, true])
            XCTAssertEqual(backend.values[true]?[account], replacement)
        }
    }

    func testMissingEntitlementPersistsAndUpdatesReceiverAndBothRemoteAccountForms() throws {
        let backend = FixturePairingKeychain()
        backend.protectedError = status(errSecMissingEntitlement)
        for (index, account) in accounts.enumerated() {
            let value = index == 1 ? replacement : key
            try KeyStore.save(value, account: account, keychain: backend)
            XCTAssertEqual(try KeyStore.read(account, keychain: backend), value)
        }
        try KeyStore.save(replacement, account: "receiver", keychain: backend)
        XCTAssertEqual(try KeyStore.read("receiver", keychain: backend), replacement)
        XCTAssertEqual(try KeyStore.read(accounts[2], keychain: backend), key, "Updating receiver must preserve the remote pairing")
        XCTAssertTrue(backend.calls.allSatisfy { $0.service == "com.suku.AltView.pairing" })
        XCTAssertEqual(Set(backend.calls.map(\.account)), Set(accounts))
        XCTAssertEqual(backend.calls.map(\.dataProtection), Array(repeating: [true, false], count: 9).flatMap { $0 })
    }

    func testAbsentProtectedItemReadsLoginEvenWhenEntitlementBecomesAvailable() throws {
        for account in accounts {
            let backend = FixturePairingKeychain()
            backend.values[false] = [account: key]
            XCTAssertEqual(try KeyStore.read(account, keychain: backend), key)
            XCTAssertEqual(backend.calls.map(\.dataProtection), [true, false])
        }
    }

    func testAbsentItemInBothKeychainsReturnsNil() throws {
        let backend = FixturePairingKeychain()
        XCTAssertNil(try KeyStore.read("receiver", keychain: backend))
        XCTAssertEqual(backend.calls.map(\.dataProtection), [true, false])
        backend.protectedError = status(errSecMissingEntitlement)
        XCTAssertNil(try KeyStore.read("receiver", keychain: backend))
    }

    func testOtherProtectedErrorsAreVisibleWithoutLoginReadOrSave() {
        for code in [errSecInteractionNotAllowed, errSecAuthFailed, errSecDecode, errSecNotAvailable, errSecParam] {
            for account in accounts {
                let backend = FixturePairingKeychain()
                backend.protectedError = status(code)
                backend.values[false] = [account: key]
                assertStatus(code) { _ = try KeyStore.read(account, keychain: backend) }
                assertStatus(code) { try KeyStore.save(replacement, account: account, keychain: backend) }
                XCTAssertEqual(backend.calls.map(\.dataProtection), [true, true])
                XCTAssertEqual(backend.values[false]?[account], key)
            }
        }
    }

    func testMatchingErrorCodeInAnotherDomainDoesNotPermitFallback() {
        let backend = FixturePairingKeychain()
        backend.protectedError = NSError(domain: "fixture", code: Int(errSecMissingEntitlement))
        XCTAssertThrowsError(try KeyStore.read("receiver", keychain: backend))
        XCTAssertThrowsError(try KeyStore.save(key, account: "receiver", keychain: backend))
        XCTAssertEqual(backend.calls.map(\.dataProtection), [true, true])
    }

    func testLoginErrorsPropagateForBothReadFallbackReasonsAndSave() {
        for protectedError in [nil, status(errSecMissingEntitlement)] {
            for code in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
                let backend = FixturePairingKeychain()
                backend.protectedError = protectedError
                backend.loginError = status(code)
                assertStatus(code) { _ = try KeyStore.read("receiver", keychain: backend) }
                XCTAssertEqual(backend.calls.map(\.dataProtection), [true, false])
                backend.protectedError = status(errSecMissingEntitlement)
                assertStatus(code) { try KeyStore.save(key, account: "receiver", keychain: backend) }
                XCTAssertEqual(backend.calls.map(\.dataProtection), [true, false, true, false])
            }
        }
    }

    func testMalformedProtectedItemsDoNotFallBackAndMalformedLoginItemsFailValidation() {
        let malformed = [Data(), Data("short".utf8), Data("abcd2345".utf8), Data("ABCD0123".utf8),
                         Data(repeating: 65, count: 64), Data(repeating: 255, count: 8)]
        for account in accounts {
            for data in malformed {
                let backend = FixturePairingKeychain()
                backend.values = [true: [account: data], false: [account: key]]
                assertStatus(errSecDecode) { _ = try KeyStore.read(account, keychain: backend) }
                XCTAssertEqual(backend.calls.map(\.dataProtection), [true])
                backend.values = [false: [account: data]]
                backend.calls = []
                assertStatus(errSecDecode) { _ = try KeyStore.read(account, keychain: backend) }
                XCTAssertEqual(backend.calls.map(\.dataProtection), [true, false])
                backend.calls = []
                assertStatus(errSecParam) { try KeyStore.save(data, account: account, keychain: backend) }
                XCTAssertTrue(backend.calls.isEmpty, "Invalid codes must never reach either Keychain")
            }
        }
    }

    func testQueriesSuppressAuthenticationInteractionAndRetainDefaultSignatureAccess() throws {
        for protected in [true, false] {
            let query = SystemPairingKeychain().query(service: "fixture", account: "receiver", dataProtection: protected)
            XCTAssertEqual(query[kSecAttrService] as? String, "fixture")
            XCTAssertEqual(query[kSecAttrAccount] as? String, "receiver")
            XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, protected)
            XCTAssertTrue(try XCTUnwrap(query[kSecUseAuthenticationContext] as? LAContext).interactionNotAllowed)
            XCTAssertNil(query[kSecAttrAccess], "Use the login Keychain's default application signature ACL")
            XCTAssertNil(query[kSecAttrAccessGroup])
            XCTAssertNil(query[kSecAttrSynchronizable])
        }
    }
}
