import Foundation
import Network
import Security
import LocalAuthentication

enum PairingKey {
    static let codeLength = 8
    // 32 symbols give 40 bits of randomness, without ambiguous 0/O or 1/I.
    private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ".utf8)

    static func generate() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: codeLength)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        // The alphabet has exactly 32 symbols, so masking introduces no bias.
        return Data(bytes.map { alphabet[Int($0 & 31)] })
    }
    static func isValid(_ data: Data) -> Bool {
        data.count == codeLength && data.allSatisfy { alphabet.contains($0) }
    }
    static func text(_ data: Data) -> String {
        let code = String(decoding: data, as: UTF8.self)
        return "\(code.prefix(4))-\(code.dropFirst(4))"
    }
    static func parse(_ text: String) -> Data? {
        let clean = text.filter { !$0.isWhitespace && $0 != "-" }
        guard clean.count == codeLength, clean.allSatisfy({ $0.isASCII }) else { return nil }
        let data = Data(clean.uppercased().utf8)
        return isValid(data) ? data : nil
    }
}

enum SecureConnection {
    /// TLS-PSK authenticates possession of the random pairing code, without
    /// transmitting that key. Uses Apple's TLS stack, not a custom cipher.
    static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let identity = Data("AltView-v1".utf8)
        key.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                    DispatchData(bytes: keyBytes) as __DispatchData,
                    DispatchData(bytes: identityBytes) as __DispatchData)
            }
        }
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}

enum KeyStore {
    private static let service = "com.suku.AltView.pairing"
    static func read(_ account: String) throws -> Data? {
        try read(account, keychain: SystemPairingKeychain())
    }
    static func save(_ key: Data, account: String) throws {
        try save(key, account: account, keychain: SystemPairingKeychain())
    }

    static func read(_ account: String, keychain: any PairingKeychainAccess) throws -> Data? {
        var data: Data?
        do { data = try keychain.read(service: service, account: account, dataProtection: true) }
        catch where isMissingEntitlement(error) {}
        // Keep accessible protected items preferred. Unprovisioned signed apps
        // use the login Keychain's normal app-signature access controls.
        if data == nil { data = try keychain.read(service: service, account: account, dataProtection: false) }
        guard let data else { return nil }
        guard PairingKey.isValid(data) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
        }
        return data
    }
    static func save(_ key: Data, account: String, keychain: any PairingKeychainAccess) throws {
        guard PairingKey.isValid(key) else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecParam)) }
        do { try keychain.save(key, service: service, account: account, dataProtection: true) }
        catch where isMissingEntitlement(error) {
            try keychain.save(key, service: service, account: account, dataProtection: false)
        }
    }
    private static func isMissingEntitlement(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSOSStatusErrorDomain && error.code == Int(errSecMissingEntitlement)
    }
}

/// Callers run synchronous Security operations on a background queue.
protocol PairingKeychainAccess {
    func read(service: String, account: String, dataProtection: Bool) throws -> Data?
    func save(_ data: Data, service: String, account: String, dataProtection: Bool) throws
}

struct SystemPairingKeychain: PairingKeychainAccess {
    func query(service: String, account: String, dataProtection: Bool) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                kSecAttrAccount: account, kSecUseDataProtectionKeychain: dataProtection,
                kSecUseAuthenticationContext: context]
    }
    func read(service: String, account: String, dataProtection: Bool) throws -> Data? {
        var query = query(service: service, account: account, dataProtection: dataProtection)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result == errSecSuccess ? errSecDecode : result))
        }
        return data
    }
    func save(_ data: Data, service: String, account: String, dataProtection: Bool) throws {
        let query = query(service: service, account: account, dataProtection: dataProtection)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if result == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData] = data
            if dataProtection { attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
            let addResult = SecItemAdd(attributes as CFDictionary, nil)
            guard addResult == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(addResult)) }
        } else if result != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }
}
