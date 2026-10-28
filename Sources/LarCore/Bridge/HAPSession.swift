import CryptoKit
import Foundation
import Network

/// One controller's connection to the bridge: pairing (setup and verify) in the clear, then HTTP sealed in frames
/// with the keys pair-verify derived.
@MainActor
final class HAPSession {
    private let connection: NWConnection
    private unowned let bridge: HAPBridge
    var onClose: (() -> Void)?
    /// The controller's pairing identifier, once verified.
    private(set) var controller: String?
    private(set) var subscriptions: Set<String> = []

    /// A request answered later (a camera still): the ones after it wait, so replies keep their order.
    private var waiting = false
    private var incoming = Data()
    private var plain = Data()
    private var readKey: SymmetricKey?
    private var writeKey: SymmetricKey?
    private var readCount: UInt64 = 0
    private var writeCount: UInt64 = 0
    private var closed = false

    private var setup: HAPSRPServer?
    private var setupKey: Data?
    private var verifyKey: Curve25519.KeyAgreement.PrivateKey?
    private var verifyShared: Data?
    private var verifyController: Data?

    /// Pair-setup at most once at a time across the bridge, and a limit on failed codes.
    private static var setupOwner: ObjectIdentifier?
    private static var failedSetups = 0

    init(connection: NWConnection, bridge: HAPBridge) {
        self.connection = connection
        self.bridge = bridge
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: MainActor.assumeIsolated { self?.finish() }
            default: break
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func close() {
        connection.cancel()
        finish()
    }

    /// After the reply in flight.
    func closeSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.close()
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        if Self.setupOwner == ObjectIdentifier(self) { Self.setupOwner = nil }
        onClose?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty { self.received(data) }
                if isComplete || error != nil { self.close() } else if !self.closed { self.receive() }
            }
        }
    }

    private func received(_ data: Data) {
        if let readKey {
            incoming.append(data)
            while incoming.count >= 2 {
                let length = Int(incoming[incoming.startIndex]) | Int(incoming[incoming.startIndex + 1]) << 8
                guard incoming.count >= 2 + length + 16 else { break }
                let aad = Data(incoming.prefix(2))
                let sealed = Data(incoming.dropFirst(2).prefix(length + 16))
                incoming = Data(incoming.dropFirst(2 + length + 16))
                guard let opened = HAPCrypto.open(sealed, key: readKey, nonce: HAPCrypto.nonce(readCount), aad: aad) else {
                    HAPBridge.log.error("a frame didn't open")
                    close()
                    return
                }
                readCount += 1
                plain.append(opened)
            }
        } else {
            plain.append(data)
        }
        handleQueued()
    }

    private func handleQueued() {
        while !waiting, let request = HTTPRequest.parse(&plain) { handle(request) }
    }

    /// The Mac's address on this connection (the camera's stream says where it comes from).
    private var localAddress: String? {
        guard case .hostPort(let host, _) = connection.currentPath?.localEndpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    // MARK: Requests

    private func handle(_ request: HTTPRequest) {
        let verified = readKey != nil
        switch (request.method, request.path) {
        case ("POST", "/pair-setup"):
            reply(200, type: "application/pairing+tlv8", body: pairSetup(HAPTLV(decoding: request.body)).encoded)
        case ("POST", "/pair-verify"):
            let (response, ready) = pairVerify(HAPTLV(decoding: request.body))
            reply(200, type: "application/pairing+tlv8", body: response.encoded)
            if let ready { (readKey, writeKey) = ready }
        case ("POST", "/identify"):
            if bridge.identity.isPaired {
                reply(400, type: "application/hap+json", body: Data(#"{"status":-70401}"#.utf8))
            } else {
                reply(204)
            }
        case (_, _) where !verified:
            reply(470, type: "application/hap+json", body: Data(#"{"status":-70401}"#.utf8))
        case ("GET", "/accessories"):
            reply(200, type: "application/hap+json", body: bridge.accessoriesJSON())
        case ("GET", "/characteristics"):
            readCharacteristics(request)
        case ("PUT", "/characteristics"):
            writeCharacteristics(request)
        case ("POST", "/resource"):
            let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let aid = (json?["aid"] as? NSNumber)?.intValue ?? 0
            let width = (json?["image-width"] as? NSNumber)?.intValue ?? 640
            waiting = true
            Task {
                let image = await bridge.snapshot(aid: aid, width: width)
                if let image {
                    reply(200, type: "image/jpeg", body: image)
                } else {
                    reply(404, type: "application/hap+json", body: Data(#"{"status":-70402}"#.utf8))
                }
                waiting = false
                handleQueued()
            }
        case ("PUT", "/prepare"):
            reply(200, type: "application/hap+json", body: Data(#"{"status":0}"#.utf8))
        case ("POST", "/pairings"):
            reply(200, type: "application/pairing+tlv8", body: pairings(HAPTLV(decoding: request.body)).encoded)
        default:
            reply(404)
        }
    }

    private func readCharacteristics(_ request: HTTPRequest) {
        let ids = (request.query["id"] ?? "").split(separator: ",").compactMap { pair -> (Int, Int)? in
            let parts = pair.split(separator: ".")
            guard parts.count == 2, let aid = Int(parts[0]), let iid = Int(parts[1]) else { return nil }
            return (aid, iid)
        }
        var failed = false
        let results: [[String: Any]] = ids.map { aid, iid in
            let (value, status) = bridge.read(aid: aid, iid: iid)
            if status != .ok {
                failed = true
                return ["aid": aid, "iid": iid, "status": status.rawValue]
            }
            return ["aid": aid, "iid": iid, "value": value ?? NSNull()]
        }
        let list = failed ? results.map { item -> [String: Any] in
            var item = item
            if item["status"] == nil { item["status"] = 0 }
            return item
        } : results
        let body = (try? JSONSerialization.data(withJSONObject: ["characteristics": list])) ?? Data()
        reply(failed ? 207 : 200, type: "application/hap+json", body: body)
    }

    private func writeCharacteristics(_ request: HTTPRequest) {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let items = json["characteristics"] as? [[String: Any]] else {
            reply(400, type: "application/hap+json", body: Data(#"{"status":-70410}"#.utf8))
            return
        }
        var statuses = [HAPStatus](repeating: .ok, count: items.count)
        var writes: [(aid: Int, iid: Int, value: Any)] = []
        var writeIndexes: [Int] = []
        for (index, item) in items.enumerated() {
            guard let aid = (item["aid"] as? NSNumber)?.intValue, let iid = (item["iid"] as? NSNumber)?.intValue else {
                statuses[index] = .invalidValue
                continue
            }
            if let ev = item["ev"] {
                let on = (ev as? NSNumber)?.boolValue ?? false
                if bridge.read(aid: aid, iid: iid).status == .notFound {
                    statuses[index] = .notFound
                } else if on {
                    subscriptions.insert("\(aid).\(iid)")
                } else {
                    subscriptions.remove("\(aid).\(iid)")
                }
            }
            if let value = item["value"] {
                writes.append((aid, iid, value))
                writeIndexes.append(index)
            }
        }
        for (index, status) in zip(writeIndexes, bridge.write(writes, local: localAddress)) where statuses[index] == .ok { statuses[index] = status }
        if statuses.allSatisfy({ $0 == .ok }) {
            reply(204)
        } else {
            let list: [[String: Any]] = items.enumerated().map { index, item in
                ["aid": item["aid"] ?? 0, "iid": item["iid"] ?? 0, "status": statuses[index].rawValue]
            }
            reply(207, type: "application/hap+json",
                  body: (try? JSONSerialization.data(withJSONObject: ["characteristics": list])) ?? Data())
        }
    }

    func sendEvent(_ characteristics: [[String: Any]]) {
        guard writeKey != nil, let body = try? JSONSerialization.data(withJSONObject: ["characteristics": characteristics])
        else { return }
        send(Data("EVENT/1.0 200 OK\r\nContent-Type: application/hap+json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body)
    }

    // MARK: Pair-setup

    private func pairSetup(_ tlv: HAPTLV) -> HAPTLV {
        let identity = bridge.identity
        switch tlv.byte(.state) {
        case 1:
            if identity.isPaired { return .error(state: 2, .unavailable) }
            if Self.failedSetups >= 100 { return .error(state: 2, .maxTries) }
            if let owner = Self.setupOwner, owner != ObjectIdentifier(self) { return .error(state: 2, .busy) }
            Self.setupOwner = ObjectIdentifier(self)
            let server = HAPSRPServer(code: identity.setupCode)
            setup = server
            return HAPTLV([(.state, Data([2])), (.salt, server.salt), (.publicKey, server.publicKey)])
        case 3:
            guard let setup, let a = tlv[.publicKey], let proof = tlv[.proof],
                  let (key, serverProof) = setup.verify(clientKey: a, proof: proof) else {
                Self.failedSetups += 1
                Self.setupOwner = nil
                self.setup = nil
                return .error(state: 4, .authentication)
            }
            setupKey = key
            return HAPTLV([(.state, Data([4])), (.proof, serverProof)])
        case 5:
            guard let setupKey, let sealed = tlv[.encryptedData] else { return .error(state: 6, .authentication) }
            let key = HAPCrypto.key(setupKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
            guard let opened = HAPCrypto.open(sealed, key: key, nonce: HAPCrypto.nonce("PS-Msg05")) else {
                return .error(state: 6, .authentication)
            }
            let sub = HAPTLV(decoding: opened)
            guard let pairingID = sub[.identifier], let ltpk = sub[.publicKey], let signature = sub[.signature],
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: ltpk) else {
                return .error(state: 6, .authentication)
            }
            let controllerX = HAPCrypto.bytes(HAPCrypto.key(setupKey, salt: "Pair-Setup-Controller-Sign-Salt",
                                                            info: "Pair-Setup-Controller-Sign-Info"))
            guard publicKey.isValidSignature(signature, for: controllerX + pairingID + ltpk) else {
                return .error(state: 6, .authentication)
            }
            bridge.savePairing(String(decoding: pairingID, as: UTF8.self), publicKey: ltpk, admin: true)

            let accessoryX = HAPCrypto.bytes(HAPCrypto.key(setupKey, salt: "Pair-Setup-Accessory-Sign-Salt",
                                                           info: "Pair-Setup-Accessory-Sign-Info"))
            let signingKey = identity.signingKey
            let accessoryID = Data(identity.id.utf8)
            let accessoryLTPK = signingKey.publicKey.rawRepresentation
            guard let accessorySignature = try? signingKey.signature(for: accessoryX + accessoryID + accessoryLTPK) else {
                return .error(state: 6, .unknown)
            }
            let reply = HAPTLV([(.identifier, accessoryID), (.publicKey, accessoryLTPK), (.signature, accessorySignature)])
            Self.setupOwner = nil
            Self.failedSetups = 0
            self.setup = nil
            self.setupKey = nil
            return HAPTLV([(.state, Data([6])),
                           (.encryptedData, HAPCrypto.seal(reply.encoded, key: key, nonce: HAPCrypto.nonce("PS-Msg06")))])
        default:
            return .error(state: (tlv.byte(.state) ?? 0) + 1, .unknown)
        }
    }

    // MARK: Pair-verify

    /// The reply, and the session keys (read, write) once verified.
    private func pairVerify(_ tlv: HAPTLV) -> (HAPTLV, (SymmetricKey, SymmetricKey)?) {
        let identity = bridge.identity
        switch tlv.byte(.state) {
        case 1:
            guard let theirs = tlv[.publicKey],
                  let theirKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs) else {
                return (.error(state: 2, .authentication), nil)
            }
            let mine = Curve25519.KeyAgreement.PrivateKey()
            guard let shared = try? mine.sharedSecretFromKeyAgreement(with: theirKey) else {
                return (.error(state: 2, .authentication), nil)
            }
            let secret = shared.withUnsafeBytes { Data($0) }
            let myPublic = mine.publicKey.rawRepresentation
            let accessoryID = Data(identity.id.utf8)
            guard let signature = try? identity.signingKey.signature(for: myPublic + accessoryID + theirs) else {
                return (.error(state: 2, .unknown), nil)
            }
            verifyKey = mine
            verifyShared = secret
            verifyController = theirs
            let key = HAPCrypto.key(secret, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
            let sub = HAPTLV([(.identifier, accessoryID), (.signature, signature)])
            return (HAPTLV([(.state, Data([2])), (.publicKey, myPublic),
                            (.encryptedData, HAPCrypto.seal(sub.encoded, key: key, nonce: HAPCrypto.nonce("PV-Msg02")))]), nil)
        case 3:
            guard let secret = verifyShared, let mine = verifyKey, let theirs = verifyController,
                  let sealed = tlv[.encryptedData] else { return (.error(state: 4, .authentication), nil) }
            let key = HAPCrypto.key(secret, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
            guard let opened = HAPCrypto.open(sealed, key: key, nonce: HAPCrypto.nonce("PV-Msg03")) else {
                return (.error(state: 4, .authentication), nil)
            }
            let sub = HAPTLV(decoding: opened)
            guard let pairingID = sub[.identifier], let signature = sub[.signature],
                  let pairing = identity.pairings[String(decoding: pairingID, as: UTF8.self)],
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pairing.publicKey),
                  publicKey.isValidSignature(signature, for: theirs + pairingID + mine.publicKey.rawRepresentation) else {
                return (.error(state: 4, .authentication), nil)
            }
            controller = String(decoding: pairingID, as: UTF8.self)
            verifyKey = nil
            verifyShared = nil
            let read = HAPCrypto.key(secret, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
            let write = HAPCrypto.key(secret, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
            return (HAPTLV([(.state, Data([4]))]), (read, write))
        default:
            return (.error(state: (tlv.byte(.state) ?? 0) + 1, .unknown), nil)
        }
    }

    // MARK: Pairings

    private func pairings(_ tlv: HAPTLV) -> HAPTLV {
        guard let controller, bridge.identity.pairings[controller]?.admin == true else {
            return .error(state: 2, .authentication)
        }
        switch tlv.byte(.method) {
        case 3:
            guard let id = tlv[.identifier], let key = tlv[.publicKey] else { return .error(state: 2, .unknown) }
            let name = String(decoding: id, as: UTF8.self)
            if let existing = bridge.identity.pairings[name], existing.publicKey != key { return .error(state: 2, .unknown) }
            bridge.savePairing(name, publicKey: key, admin: (tlv.byte(.permissions) ?? 0) & 1 == 1)
            return HAPTLV([(.state, Data([2]))])
        case 4:
            guard let id = tlv[.identifier] else { return .error(state: 2, .unknown) }
            bridge.removePairing(String(decoding: id, as: UTF8.self))
            return HAPTLV([(.state, Data([2]))])
        case 5:
            var list = HAPTLV([(.state, Data([2]))])
            for (index, (id, pairing)) in bridge.identity.pairings.sorted(by: { $0.key < $1.key }).enumerated() {
                if index > 0 { list.append(.separator, Data()) }
                list.append(.identifier, Data(id.utf8))
                list.append(.publicKey, pairing.publicKey)
                list.append(.permissions, pairing.admin ? 1 : 0)
            }
            return list
        default:
            return .error(state: 2, .unknown)
        }
    }

    // MARK: Sending

    private func reply(_ status: Int, type: String? = nil, body: Data = Data()) {
        let reason = [200: "OK", 204: "No Content", 207: "Multi-Status", 400: "Bad Request", 404: "Not Found",
                      470: "Connection Authorization Required"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        send(Data(head.utf8) + body)
    }

    private func send(_ data: Data) {
        var out = Data()
        if let writeKey {
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = min(offset + 1024, data.endIndex)
                let length = UInt16(end - offset)
                let aad = withUnsafeBytes(of: length.littleEndian) { Data($0) }
                out += aad + HAPCrypto.seal(Data(data[offset..<end]), key: writeKey, nonce: HAPCrypto.nonce(writeCount), aad: aad)
                writeCount += 1
                offset = end
            }
        } else {
            out = data
        }
        connection.send(content: out, completion: .idempotent)
    }
}

/// An HTTP/1.1 request as the controllers send them (one at a time, with Content-Length).
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data

    /// The first complete request at the start of `buffer`, removed from it.
    static func parse(_ buffer: inout Data) -> HTTPRequest? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        var length = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { return nil }
        let body = Data(buffer[end.upperBound..<buffer.index(end.upperBound, offsetBy: length)])
        buffer = Data(buffer[buffer.index(end.upperBound, offsetBy: length)...])
        let target = first.count > 1 ? String(first[1]) : "/"
        let pieces = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                query[String(kv[0])] = kv.count == 2 ? String(kv[1]).removingPercentEncoding ?? String(kv[1]) : ""
            }
        }
        return HTTPRequest(method: first.first.map(String.init) ?? "", path: String(pieces.first ?? "/"), query: query,
                           body: body)
    }
}
