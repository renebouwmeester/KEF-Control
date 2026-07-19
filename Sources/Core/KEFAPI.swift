// Speaker HTTP API and the HMAC-authenticated DSP channel. Pure Foundation +
// CryptoKit — shared verbatim by every platform shell.
import Foundation
import CryptoKit
import Security

// MARK: - KEF HTTP API (same endpoints as kef.sh)

struct KEFAPI {
    let ip: String
    private let session: URLSession

    init(ip: String) {
        self.ip = ip
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        cfg.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: cfg)
    }

    func value(_ path: String) async throws -> [String: Any] {
        var comps = URLComponents(string: "http://\(ip)/api/getData")!
        comps.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "roles", value: "@all"),
        ]
        let (data, _) = try await session.data(from: comps.url!)
        let json = try JSONSerialization.jsonObject(with: data)
        if let dict = json as? [String: Any], let value = dict["value"] as? [String: Any] {
            return value
        }
        throw URLError(.cannotParseResponse)
    }

    func setData(path: String, roles: String, value: [String: Any]) async throws {
        var req = URLRequest(url: URL(string: "http://\(ip)/api/setData")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": path, "roles": roles, "value": value,
        ])
        _ = try await session.data(for: req)
    }

    func setVolume(_ v: Int) async throws {
        try await setData(path: "player:volume", roles: "value",
                          value: ["type": "i32_", "i32_": v])
    }

    func setMute(_ m: Bool) async throws {
        try await setData(path: "settings:/mediaPlayer/mute", roles: "value",
                          value: ["type": "bool_", "bool_": m])
    }

    func setSource(_ s: String) async throws {
        try await setData(path: "settings:/kef/play/physicalSource", roles: "value",
                          value: ["type": "kefPhysicalSource", "kefPhysicalSource": s])
    }

    func control(_ c: String) async throws {
        try await setData(path: "player:player/control", roles: "activate",
                          value: ["control": c])
    }

    /// Browse a container (airable, ui:, presets:, …). Returns the rows plus
    /// the container's own `roles` object, which for a radio station is itself
    /// the playable item.
    func rows(_ path: String, from: Int = 0, to: Int = 40) async throws
        -> (rows: [[String: Any]], roles: [String: Any]) {
        var comps = URLComponents(string: "http://\(ip)/api/getRows")!
        comps.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "roles", value: "@all"),
            URLQueryItem(name: "from", value: "\(from)"),
            URLQueryItem(name: "to", value: "\(to)"),
        ]
        // Browsing goes out to airable's servers, so it needs far longer than
        // the 3s budget the local status polls run on.
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        let (data, _) = try await session.data(for: req)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        if let err = dict["error"] as? [String: Any] {
            throw NSError(domain: "KEF", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                      (err["message"] as? String) ?? "browse failed"])
        }
        return ((dict["rows"] as? [[String: Any]]) ?? [],
                (dict["roles"] as? [String: Any]) ?? [:])
    }

    /// Start playing a browsed item. The item is the PAYLOAD, not the target:
    /// activating an airable row's own path returns 200 and does nothing.
    /// Recipe from github.com/hilli/go-kef-w2 (playItem).
    func play(mediaRoles: [String: Any]) async throws {
        try await setData(path: "player:player/control", roles: "activate",
                          value: ["type": "none", "control": "play",
                                  "mediaRoles": mediaRoles])
    }
}

// MARK: - Authenticated DSP channel (TLS :4430, HMAC_SHA256)

/// The KEF firmware write-protects the DSP/EQ tree behind an HMAC-signed
/// channel on TLS port 4430. Credentials and signing scheme were recovered by
/// the go-kef-w2 project (github.com/hilli/go-kef-w2) from the KEF Connect app.
/// This lets us apply EQ profiles the same way KEF Connect does.
final class KEFAuthChannel: NSObject, URLSessionDelegate {
    private let ip: String
    private let username = "7f3c2a91-4d0b-4f65-9b3a-8e2f1c6d4a13"
    private let password: String
    private var provisioned = false
    private lazy var session: URLSession = URLSession(
        configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(ip: String) {
        self.ip = ip
        let material = Data("yek_\(username)_user".utf8)
        password = Insecure.MD5.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    /// Accept the speaker's self-signed cert on the 4430 endpoint only.
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func setData(path: String, roles: String, value: [String: Any]) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["path": path, "roles": roles, "value": value])
        if try await signedPost("/api/setData", body: body) == 401 {
            try await provision()
            _ = try await signedPost("/api/setData", body: body)
        }
    }

    private func provision() async throws {
        // Bootstrap POST (unsigned) registering our user; idempotent.
        let body = try JSONSerialization.data(withJSONObject: [
            "path": "webserver:addUser", "role": "activate",
            "value": ["name": username, "password": password, "title": ""],
        ])
        var req = URLRequest(url: URL(string: "https://\(ip):4430/api/setData")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        _ = try? await session.data(for: req)
        provisioned = true
    }

    private func signedPost(_ path: String, body: Data) async throws -> Int {
        let url = URL(string: "https://\(ip):4430\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authHeader(fullURL: url.absoluteString, body: body),
                     forHTTPHeaderField: "Authorization")
        req.httpBody = body
        let (_, resp) = try await session.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func authHeader(fullURL: String, body: Data) -> String {
        var nonceRaw = Data(count: 6)
        _ = nonceRaw.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 6, $0.baseAddress!) }
        let nonce = nonceRaw.base64EncodedString()
        let nonceB64 = Data(nonce.utf8).base64EncodedString()
        let userB64 = Data(username.utf8).base64EncodedString()
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))

        let key = SymmetricKey(data: SHA256.hash(data: Data(nonce.utf8) + Data(password.utf8)))
        // canonical = username.nonceB64.timestamp.fullURL.<raw body bytes>
        var message = Data("\(username).\(nonceB64).\(ts).\(fullURL).".utf8)
        message.append(body)                     // append raw body bytes, not a hash
        let sig = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
            .base64EncodedString()

        return "HMAC_SHA256 \(userB64).\(nonceB64).\(ts).\(sig)"
    }
}
