import Foundation
import Security

/// This executable is compiled with the real KeyStore. It only accesses
/// UUID-namespaced fixture accounts, never the operator's pairing entries.
@main
struct KeychainPersistenceFixture {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count == 3, let runID = UUID(uuidString: args[2]) else {
                throw NSError(domain: "FixtureArguments", code: 1)
            }
            let prefix = "fixture.\(runID.uuidString)."
            let accounts = [prefix + "receiver", prefix + "sender.receiver.local:54321", prefix + "sender.service.Output Mac"]
            let keys = [Data("ABCD2345".utf8), Data("EFGH6789".utf8), Data("JKLM2345".utf8)]
            let replacement = Data("PQRS6789".utf8)
            let system = SystemPairingKeychain()
            switch args[1] {
            case "save":
                // An unprovisioned Developer ID sandboxed app must exercise the
                // real missing-entitlement path, rather than a mocked backend.
                do {
                    try system.save(keys[0], service: "com.suku.AltView.pairing", account: accounts[0], dataProtection: true)
                    throw NSError(domain: "ProtectedKeychainUnexpectedlyAvailable", code: 1)
                } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == Int(errSecMissingEntitlement) {}
                for (account, key) in zip(accounts, keys) { try KeyStore.save(key, account: account) }
            case "read", "read-updated":
                for (index, account) in accounts.enumerated() {
                    let expected = args[1] == "read-updated" && index == 0 ? replacement : keys[index]
                    guard try KeyStore.read(account) == expected,
                          try system.read(service: "com.suku.AltView.pairing", account: account, dataProtection: false) == expected else {
                        throw NSError(domain: "PairingDidNotPersistInLoginKeychain", code: index)
                    }
                }
            case "update":
                try KeyStore.save(replacement, account: accounts[0])
            case "cleanup":
                for account in accounts {
                    for protected in [true, false] {
                        let query = system.query(service: "com.suku.AltView.pairing", account: account, dataProtection: protected)
                        let status = SecItemDelete(query as CFDictionary)
                        guard status == errSecSuccess || status == errSecItemNotFound || (protected && status == errSecMissingEntitlement) else {
                            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                        }
                    }
                }
            case "read-empty":
                for account in accounts {
                    guard try KeyStore.read(account) == nil else { throw NSError(domain: "FixtureCleanupFailed", code: 1) }
                }
            default:
                throw NSError(domain: "FixtureArguments", code: 2)
            }
            print("\(args[1]): verified (three isolated accounts)")
        } catch {
            let error = error as NSError
            fputs("Keychain fixture failed: \(error.domain) \(error.code): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
