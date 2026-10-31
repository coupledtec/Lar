import CommonCrypto
import CryptoKit
import Foundation

/// The hashes and ciphers the brands' clouds use to sign requests and wrap messages (old ones included: MD5 and
/// AES in ECB mode are what the robots speak, not a choice).
enum BrandCrypto {
    static func md5(_ data: Data) -> Data { Data(Insecure.MD5.hash(data: data)) }
    static func md5Hex(_ text: String) -> String { hex(md5(Data(text.utf8))) }
    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }

    static func hmacSHA256(key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// AES (128, 192 or 256 by the key's length) with PKCS#7 padding: ECB when `iv` is nil, otherwise CBC.
    static func aes(_ encrypt: Bool, key: Data, iv: Data? = nil, _ data: Data, padding: Bool = true) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        var options = CCOptions(padding ? kCCOptionPKCS7Padding : 0)
        if iv == nil { options |= CCOptions(kCCOptionECBMode) }
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    (iv ?? Data()).withUnsafeBytes { v in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), options,
                                k.baseAddress, key.count, iv == nil ? nil : v.baseAddress,
                                d.baseAddress, data.count, o.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ProviderError.api(tr("Mensagem do aparelho ilegível")) }
        return out.prefix(moved)
    }

    /// RC4 (Xiaomi's cloud wraps its requests in it), dropping the first 1024 bytes of the stream as Xiaomi does.
    static func rc4(key: Data, _ data: Data, drop: Int = 1024) -> Data {
        var s = Array(0...255).map(UInt8.init)
        let k = [UInt8](key)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(k[i % k.count])) & 0xff
            s.swapAt(i, j)
        }
        var i = 0
        j = 0
        func next() -> UInt8 {
            i = (i + 1) & 0xff
            j = (j + Int(s[i])) & 0xff
            s.swapAt(i, j)
            return s[(Int(s[i]) + Int(s[j])) & 0xff]
        }
        for _ in 0..<drop { _ = next() }
        return Data(data.map { $0 ^ next() })
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// CRC-32 (the zlib one).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffff_ffff
    }

    static func randomHex(_ bytes: Int) -> String {
        hex(Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }))
    }

    static func randomAlphanumeric(_ count: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<count).map { _ in letters.randomElement()! })
    }
}

/// JSON requests to the brands' clouds: form or JSON bodies, query parameters and the answer as a dictionary.
struct BrandHTTP: Sendable {
    let transport: HTTPTransport

    nonisolated(nonsending) func json(_ method: String, _ url: String, query: [String: String] = [:], form: [String: String]? = nil,
              body: Any? = nil, headers: [String: String] = [:]) async throws -> [String: Any] {
        let data = try await raw(method, url, query: query, form: form, body: body, headers: headers)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.api(tr("Resposta inesperada do servidor"))
        }
        return object
    }

    nonisolated(nonsending) func raw(_ method: String, _ url: String, query: [String: String] = [:], form: [String: String]? = nil,
             body: Any? = nil, headers: [String: String] = [:]) async throws -> Data {
        guard var components = URLComponents(string: url) else { throw ProviderError.api("URL") }
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // "+" is a space to most servers: send it encoded.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let address = components.url else { throw ProviderError.api("URL") }
        var request = URLRequest(url: address, timeoutInterval: 20)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.formEncoded(form).utf8)
        } else if let body {
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.httpBody = try body as? Data ?? JSONSerialization.data(withJSONObject: body)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport(request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        if let status = (response as? HTTPURLResponse)?.statusCode, status == 401 || status == 403 {
            throw ProviderError.unauthorized
        }
        return data
    }

    static func formEncoded(_ values: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let text = self[key] as? String { return text }
        if let number = self[key] as? NSNumber { return number.stringValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let number = self[key] as? NSNumber { return number.intValue }
        return (self[key] as? String).flatMap { Int($0) }
    }

    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func list(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
}
