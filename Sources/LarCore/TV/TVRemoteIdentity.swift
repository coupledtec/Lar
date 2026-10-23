import Foundation
import Security

/// The certificate the TVs know this device by: an RSA 2048 key and a self-signed certificate, both in the keychain
/// (TLS takes a client certificate only as a keychain identity). Pairing teaches a TV this certificate; a new one
/// would need every TV paired again, so it's made once and kept.
public struct TVRemoteIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let publicNumbers: RSAPublicNumbers

    /// The certificate's name, also how it's found again among the keychain's identities.
    static let commonName = "Lar - controle da TV"
    static let keyTag = Data("com.coupled.lar.tv-remote".utf8)
    static let madeKey = "tvRemoteIdentityMade"

    /// - Parameter allowReplacing: make a new one even though one was made before. Only when pairing (the person is
    /// there and the device unlocked): an identity that can't be found otherwise is most likely just unreadable
    /// (keychain locked, the iPhone woken in the background), and replacing it would unpair every TV.
    public static func loadOrCreate(allowReplacing: Bool = false) throws -> TVRemoteIdentity {
        if let saved = try find() {
            Preferences.set(true, forKey: madeKey)
            return saved
        }
        if Preferences.bool(forKey: madeKey) == true, !allowReplacing {
            throw TVRemoteError.identity("indisponível com o aparelho bloqueado; desbloqueie e tente de novo")
        }
        try create()
        Preferences.set(true, forKey: madeKey)
        guard let made = try find() else { throw TVRemoteError.identity("o Porta-chaves não montou o certificado") }
        return made
    }

    init(identity: SecIdentity) throws {
        var key: SecKey?
        SecIdentityCopyPrivateKey(identity, &key)
        guard let key, let publicKey = SecKeyCopyPublicKey(key),
              let der = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let numbers = RSAPublicNumbers(pkcs1: der)
        else { throw TVRemoteError.identity("chave ilegível") }
        self.identity = identity
        self.publicNumbers = numbers
    }

    private static func find() throws -> TVRemoteIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity]
        else { return nil }
        for identity in identities {
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            if let certificate, SecCertificateCopySubjectSummary(certificate) as String? == commonName {
                return try TVRemoteIdentity(identity: identity)
            }
        }
        return nil
    }

    /// A new key in the keychain and its certificate next to it; the keychain pairs them into an identity.
    private static func create() throws {
        // Leftovers of a half-made identity (a key without its certificate).
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: keyTag] as CFDictionary)
        var keyAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrAccessible as String: Keychain.accessibility,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrLabel as String: commonName,
        ]
        // Shared with the widgets, which switch the TVs too.
        if let group = Keychain.sharedGroup { keyAttributes[kSecAttrAccessGroup as String] = group }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: keyAttributes,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw TVRemoteError.identity(error?.takeRetainedValue().localizedDescription ?? "RSA")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicDER = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { throw TVRemoteError.identity("sem chave pública") }

        let tbs = Self.tbsCertificate(publicKeyPKCS1: publicDER, serial: Data((0..<8).map { _ in UInt8.random(in: 1...127) }),
                                      notBefore: Date().addingTimeInterval(-86_400), years: 20)
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) as Data? else {
            throw TVRemoteError.identity(error?.takeRetainedValue().localizedDescription ?? "assinatura")
        }
        let der = Self.certificate(tbs: tbs, signature: signature)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw TVRemoteError.identity("certificado inválido")
        }
        var item: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: commonName,
            kSecAttrAccessible as String: Keychain.accessibility,
        ]
        if let group = Keychain.sharedGroup { item[kSecAttrAccessGroup as String] = group }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw TVRemoteError.identity("não deu para guardar o certificado (\(status))")
        }
    }

    /// The key and certificate of older versions (readable only while unlocked), so the watch can reach the TVs
    /// through a locked iPhone. Run while unlocked.
    static func migrateAccessibility() {
        #if !os(macOS)
        var attributes: [String: Any] = [kSecAttrAccessible as String: Keychain.accessibility]
        if let group = Keychain.sharedGroup { attributes[kSecAttrAccessGroup as String] = group }
        let update = attributes as CFDictionary
        SecItemUpdate([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: keyTag] as CFDictionary, update)
        SecItemUpdate([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: commonName] as CFDictionary, update)
        #endif
    }

    // MARK: X.509

    static let sha256WithRSA: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]
    static let rsaEncryption: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
    static let commonNameOID: [UInt8] = [0x55, 0x04, 0x03]

    /// A version 1 certificate body: serial, algorithm, issuer = subject, validity and the public key.
    static func tbsCertificate(publicKeyPKCS1: Data, serial: Data, notBefore: Date, years: Int) -> Data {
        let name = DER.sequence(DER.set(DER.sequence(DER.oid(commonNameOID) + DER.tlv(0x0c, Data(commonName.utf8)))))
        let notAfter = Calendar(identifier: .gregorian).date(byAdding: .year, value: years, to: notBefore) ?? notBefore
        let validity = DER.sequence(DER.utcTime(notBefore) + DER.utcTime(notAfter))
        let keyInfo = DER.sequence(DER.sequence(DER.oid(rsaEncryption) + DER.null) + DER.bitString(publicKeyPKCS1))
        return DER.sequence(DER.tlv(0x02, serial) + DER.sequence(DER.oid(sha256WithRSA) + DER.null) + name + validity + name + keyInfo)
    }

    static func certificate(tbs: Data, signature: Data) -> Data {
        DER.sequence(tbs + DER.sequence(DER.oid(sha256WithRSA) + DER.null) + DER.bitString(signature))
    }
}

/// The few DER encodings a certificate needs.
enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            var length = withUnsafeBytes(of: UInt32(content.count).bigEndian) { Array($0) }
            while length.first == 0 { length.removeFirst() }
            out.append(0x80 | UInt8(length.count))
            out.append(contentsOf: length)
        }
        out.append(content)
        return out
    }

    static func sequence(_ content: Data) -> Data { tlv(0x30, content) }
    static func set(_ content: Data) -> Data { tlv(0x31, content) }
    static func oid(_ bytes: [UInt8]) -> Data { tlv(0x06, Data(bytes)) }
    static let null = Data([0x05, 0x00])
    static func bitString(_ content: Data) -> Data { tlv(0x03, Data([0]) + content) }

    /// "YYMMDDHHMMSSZ" in UTC (good until 2049).
    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(formatter.string(from: date).utf8))
    }
}
