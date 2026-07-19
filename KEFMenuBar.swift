import SwiftUI
import AppKit
import Combine
import Carbon.HIToolbox
import CryptoKit

/// Presets row collapse/expand timing, shared by the SwiftUI row animation and
/// the panel's own height ramp so the window edge tracks the content exactly.
/// `defaults write <bundle-id> AnimDuration 2.0` slows it down for inspection
/// (and tuning); anything <= 0 or unset uses the default.
enum PanelAnim {
    static let duration: Double = {
        let d = UserDefaults.standard.double(forKey: "AnimDuration")
        return d > 0 ? d : 0.22
    }()
}

/// The panel window is a fixed-size, fully transparent canvas: it never
/// resizes, so SwiftUI owns every pixel of the card's motion. The canvas is
/// deliberately taller than any state's content; the surplus is transparent and
/// clicks pass straight through it.
enum PanelMetrics {
    static let width: CGFloat = 300
    static let cornerRadius: CGFloat = 12
    /// Room around the card for the SwiftUI shadow to render into.
    static let shadowMargin: CGFloat = 22
    static let canvasHeight: CGFloat = 820
}

// Hardcoded accent (#98A8D9): the system accent resolves differently per macOS
// version (26 gives a harder blue), so pin the macOS 27 dark-mode value.
extension Color {
    static let appAccent = Color(red: 0.5961, green: 0.6588, blue: 0.8510)
}
extension NSColor {
    static let appAccent = NSColor(srgbRed: 0.5961, green: 0.6588, blue: 0.8510, alpha: 1)
}

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

// MARK: - Bonjour discovery

/// Finds KEF speakers on the LAN. They advertise `_kef-info._tcp` with a TXT
/// record carrying the friendly name, model, serial and firmware — so a found
/// speaker can be shown as "KEF LS60 — LS60 Wireless (192.168.1.69)" rather
/// than a bare address.
///
/// Bonjour goes through mDNSResponder, so unlike raw SSDP/multicast this needs
/// no multicast entitlement. Uses NetService rather than NWBrowser: NWBrowser
/// gives no address of its own, and the documented way to get one — opening an
/// NWConnection to the endpoint just to read its path — never completed inside
/// an app bundle here (it hung in .preparing indefinitely). NetService asks
/// mDNSResponder for the addresses directly, with no connection at all.
/// Deprecated but functional, and the deprecation has no replacement that
/// returns addresses.
@MainActor
final class SpeakerDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Found: Identifiable, Equatable {
        var id: String { serviceName }
        let serviceName: String       // "8417151A0041@LS60W"
        let name: String              // "KEF LS60"
        let model: String             // "LS60 Wireless"
        let ip: String                // "192.168.1.69"

        var label: String {
            let m = model.isEmpty || model == name ? "" : " — \(model)"
            return "\(name)\(m) (\(ip))"
        }
    }

    @Published private(set) var found: [Found] = []
    @Published private(set) var isSearching = false

    static let serviceType = "_kef-info._tcp"

    private var browser: NetServiceBrowser?
    /// Services must be retained while they resolve or the callback never fires.
    private var pending: [NetService] = []

    func start() {
        guard browser == nil else { return }
        isSearching = true
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        browser = b
    }

    func stop() {
        browser?.stop()
        browser = nil
        pending.forEach { $0.stop() }
        pending.removeAll()
        isSearching = false
    }

    // MARK: NetServiceBrowserDelegate

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser,
                                       didFind service: NetService,
                                       moreComing: Bool) {
        Task { @MainActor in
            guard !self.found.contains(where: { $0.serviceName == service.name }),
                  !self.pending.contains(service) else { return }
            service.delegate = self
            self.pending.append(service)
            service.resolve(withTimeout: 6)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser,
                                       didRemove service: NetService,
                                       moreComing: Bool) {
        Task { @MainActor in
            self.found.removeAll { $0.serviceName == service.name }
        }
    }

    // MARK: NetServiceDelegate

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let ip = Self.firstIPv4(in: sender.addresses ?? [])
        let txt = Self.parseTXT(sender.txtRecordData())
        Task { @MainActor in
            self.pending.removeAll { $0 === sender }
            guard let ip, !self.found.contains(where: { $0.serviceName == sender.name })
            else { return }
            self.found.append(Found(serviceName: sender.name,
                                    name: txt["name"] ?? sender.name,
                                    model: txt["modelName"] ?? "",
                                    ip: ip))
            self.found.sort { $0.name < $1.name }
        }
    }

    nonisolated func netService(_ sender: NetService,
                                didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in self.pending.removeAll { $0 === sender } }
    }

    // MARK: helpers

    /// Bonjour hands back both families; only IPv4 goes into a URL cleanly
    /// (a link-local IPv6 needs brackets and a scope id).
    private nonisolated static func firstIPv4(in addresses: [Data]) -> String? {
        for data in addresses {
            let ip: String? = data.withUnsafeBytes { raw in
                guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                      sa.pointee.sa_family == UInt8(AF_INET) else { return nil }
                var addr = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil
                else { return nil }
                return String(cString: buf)
            }
            if let ip { return ip }
        }
        return nil
    }

    private nonisolated static func parseTXT(_ data: Data?) -> [String: String] {
        guard let data else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in NetService.dictionary(fromTXTRecord: data) {
            out[k] = String(data: v, encoding: .utf8)
        }
        return out
    }
}

// MARK: - Observable speaker state

struct EQProfileRef: Identifiable {
    let id: String
    let name: String
}

@MainActor
final class SpeakerModel: ObservableObject {
    @Published var volume = 0
    @Published var muted = false
    @Published var playState = "stopped"      // playing | paused | stopped
    @Published var title: String?
    @Published var artist: String?
    @Published var album: String?
    @Published var artwork: NSImage?
    @Published var source = "wifi"
    @Published var reachable = false
    @Published var isDraggingVolume = false
    @Published var maxVolume = 100   // speaker's volume limit when enabled
    @Published var seek: Double?     // seconds
    @Published var length: Double?   // seconds
    @Published var canSeek = false   // true when the current source advertises seekTime
    @Published var isScrubbing = false
    private var lastSeekCommand = Date.distantPast
    private var lastVolumeCommand = Date.distantPast
    @Published var panelColor = Color(white: 0.13)
    @Published var currentEqName = ""
    @Published var currentEqId = ""
    @Published var eqProfiles: [EQProfileRef] = []
    /// Incoming stream format, straight from the speaker (works for any
    /// source): trackRoles.mediaData.activeResource.
    @Published var sampleFrequency: Int?
    @Published var bitsPerSample: Int?
    /// Some sources report no numbers at all, just a quality flag — Spotify
    /// gives `quality: { spotifyHifi: true }` and nothing else.
    @Published var streamQuality: String?
    @Published var streamingService = ""
    @Published var showPresets = UserDefaults.standard.bool(forKey: "ShowVolumePresets") {
        didSet { UserDefaults.standard.set(showPresets, forKey: "ShowVolumePresets") }
    }
    /// Whether the menu bar item shows the volume number beside the icon.
    /// Defaults to ON, so `object(forKey:)` rather than `bool(forKey:)` — the
    /// latter reads an unset key as false and would silently flip the default.
    @Published var showVolumeInMenuBar =
        UserDefaults.standard.object(forKey: "ShowVolumeInMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showVolumeInMenuBar, forKey: "ShowVolumeInMenuBar") }
    }
    /// 7 preset slots in user order; 0 = empty. A hotkey can target each slot.
    @Published var presetSlots: [Int] = {
        if let s = UserDefaults.standard.array(forKey: "PresetSlots") as? [Int], s.count == 7 {
            return s
        }
        let old = (UserDefaults.standard.array(forKey: "VolumePresets") as? [Int]) ?? [30, 35, 40, 42, 45, 48]
        return Array((old + Array(repeating: 0, count: 7)).prefix(7))
    }()

    /// Non-empty presets, in slot order — what the popover row shows.
    var volumePresets: [Int] { presetSlots.filter { $0 > 0 } }

    func setPresetSlots(_ slots: [Int]) {
        var s = slots.map { max(0, min(100, $0)) }
        while s.count < 7 { s.append(0) }
        presetSlots = Array(s.prefix(7))
        UserDefaults.standard.set(presetSlots, forKey: "PresetSlots")
    }

    typealias Source = (id: String, name: String, icon: String, glyph: String?)

    /// Every input the KEF platform exposes, in factory order. USB isn't
    /// present on the LS60 but is on other models, so it stays in the list.
    /// `glyph` names a bundled template PNG for the one icon SF Symbols has no
    /// equivalent for. The user's own order/visibility is layered on top —
    /// see `orderedSources`.
    static let sources: [Source] = [
        ("wifi", "Wi-Fi", "wifi", nil),
        ("tv", "Television", "tv", nil),
        ("coaxial", "Coaxial", "circle.circle", nil),
        ("optical", "Optical", "circle.square", nil),
        ("analog", "Analog", "cable.coaxial", nil),
        ("usb", "USB", "cable.connector", nil),
        ("bluetooth", "Bluetooth", "", "bluetooth-glyph"),
    ]

    /// User's preferred order (ids). Ids missing from this list — e.g. a source
    /// added in a later build — keep their factory position at the end rather
    /// than disappearing.
    @Published var sourceOrder: [String] =
        (UserDefaults.standard.array(forKey: "SourceOrder") as? [String]) ?? []
    /// Inputs the user has switched off in the re-order window.
    @Published var hiddenSources: Set<String> =
        Set((UserDefaults.standard.array(forKey: "SourceHidden") as? [String]) ?? [])

    /// All inputs in the user's order, hidden ones included — what the
    /// re-order window lists.
    var orderedSources: [Source] {
        let rank = Dictionary(sourceOrder.enumerated().map { ($1, $0) },
                              uniquingKeysWith: { a, _ in a })
        return Self.sources.enumerated()
            .sorted { a, b in
                // Unranked ids sort after ranked ones, keeping factory order
                // among themselves; ties break on factory position so the sort
                // is deterministic (Swift's sort is not stable).
                let ra = rank[a.element.id] ?? (Self.sources.count + a.offset)
                let rb = rank[b.element.id] ?? (Self.sources.count + b.offset)
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
    }

    /// What the bottom row actually draws.
    var visibleSources: [Source] {
        orderedSources.filter { !hiddenSources.contains($0.id) }
    }

    // MARK: Radio quick-play slots

    /// A station as stored in a slot. Only what's needed to redraw the button
    /// and re-resolve the stream at play time — resources are deliberately NOT
    /// cached, since airable's stream URLs are not guaranteed to be stable.
    struct RadioStation: Equatable {
        var title: String
        var path: String
        var iconURL: String

        var dict: [String: String] { ["title": title, "path": path, "icon": iconURL] }
        init(title: String, path: String, iconURL: String) {
            self.title = title; self.path = path; self.iconURL = iconURL
        }
        init?(_ d: [String: String]) {
            guard let t = d["title"], let p = d["path"] else { return nil }
            title = t; path = p; iconURL = d["icon"] ?? ""
        }
    }

    /// 7 circles at 30pt with 10pt gaps span 270 of the 272pt content width.
    static let radioSlotCount = 7

    @Published var showRadioRow = UserDefaults.standard.bool(forKey: "ShowRadioRow") {
        didSet { UserDefaults.standard.set(showRadioRow, forKey: "ShowRadioRow") }
    }

    @Published var radioSlots: [RadioStation?] = {
        let raw = (UserDefaults.standard.array(forKey: "RadioSlots") as? [[String: String]]) ?? []
        var out = raw.map { $0.isEmpty ? nil : RadioStation($0) }
        while out.count < radioSlotCount { out.append(nil) }
        return Array(out.prefix(radioSlotCount))
    }()

    func setRadioSlots(_ slots: [RadioStation?]) {
        var s = slots
        while s.count < Self.radioSlotCount { s.append(nil) }
        radioSlots = Array(s.prefix(Self.radioSlotCount))
        UserDefaults.standard.set(radioSlots.map { $0?.dict ?? [:] }, forKey: "RadioSlots")
    }

    var hasRadioSlots: Bool { radioSlots.contains { $0 != nil } }

    /// True when the speaker is currently playing this slot's station. airable
    /// overwrites the track title with live metadata, so match on the station
    /// name being a prefix — "NPO Radio 1 - Tour de France" starts with it.
    func isPlayingRadio(_ station: RadioStation) -> Bool {
        guard streamingService.lowercased().hasPrefix("airable") else { return false }
        guard let t = title else { return false }
        return t == station.title || t.hasPrefix(station.title)
    }

    /// List endpoints hand back containers, not playable items — browse in
    /// until something carries mediaData.resources (the container's own
    /// `roles` object counts).
    private func resolvePlayable(_ path: String, depth: Int = 0) async -> [String: Any]? {
        guard depth < 4, let result = try? await api.rows(path, to: 30) else { return nil }
        func hasResources(_ item: [String: Any]) -> Bool {
            ((item["mediaData"] as? [String: Any])?["resources"] as? [[String: Any]])?
                .isEmpty == false
        }
        if hasResources(result.roles) { return result.roles }
        for row in result.rows where hasResources(row) { return row }
        // Otherwise follow the first playable audio container one level down.
        for row in result.rows
        where (row["containerPlayable"] as? Bool) == true
            && (row["audioType"] as? String) == "audioBroadcast" {
            if let next = row["path"] as? String, next != path {
                return await resolvePlayable(next, depth: depth + 1)
            }
        }
        return nil
    }

    /// Rebuild the browsed row as a `mediaRoles` payload (see KEFAPI.play).
    private func mediaRoles(from item: [String: Any]) -> [String: Any] {
        var roles: [String: Any] = [
            "containerPlayable": item["containerPlayable"] as? Bool ?? true,
            "title": item["title"] as? String ?? "",
            "path": item["path"] as? String ?? "",
            "type": (item["type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "audio",
            "containerType": item["containerType"] as? String ?? "none",
        ]
        for key in ["audioType", "icon", "id", "longDescription"] {
            if let v = item[key] as? String, !v.isEmpty { roles[key] = v }
        }
        if let md = item["mediaData"] as? [String: Any] {
            var out: [String: Any] = [:]
            if let meta = md["metaData"] as? [String: Any] {
                var m: [String: Any] = [:]
                if let s = meta["serviceID"] as? String { m["serviceID"] = s }
                for key in ["contentPlayContextPath", "prePlayPath", "playbackStateChangePath"] {
                    if let v = meta[key] as? String, !v.isEmpty { m[key] = v }
                }
                if let l = meta["live"] as? Bool, l { m["live"] = true }
                if let r = meta["radioStation"] as? Bool, r { m["radioStation"] = true }
                if let n = meta["maximumRetryCount"] as? Int, n > 0 { m["maximumRetryCount"] = n }
                out["metaData"] = m
            }
            if let res = md["resources"] as? [[String: Any]] {
                out["resources"] = res.map { r in
                    var o: [String: Any] = [:]
                    for key in ["uri", "mimeType", "codec"] {
                        if let v = r[key] as? String, !v.isEmpty { o[key] = v }
                    }
                    for key in ["bitRate", "duration"] {
                        if let v = r[key] as? Int, v > 0 { o[key] = v }
                    }
                    return o
                }
            }
            roles["mediaData"] = out
        }
        if let imgs = (item["images"] as? [String: Any])?["images"] as? [[String: Any]] {
            roles["images"] = ["images": imgs]
        }
        if let ctx = (item["context"] as? [String: Any])?["path"] as? String {
            roles["context"] = ["path": ctx]
        }
        return roles
    }

    func playRadio(_ index: Int) {
        guard let station = radioSlots.indices.contains(index)
            ? radioSlots[index] : nil else { return }
        Task { @MainActor in
            guard let item = await resolvePlayable(station.path) else { return }
            try? await api.play(mediaRoles: mediaRoles(from: item))
            try? await Task.sleep(for: .milliseconds(700))
            await refresh()
        }
    }

    /// The airable radio root, e.g.
    /// "airable:https://<accountID>.airable.io/airable/radios". The account id
    /// is per-speaker, so it is discovered rather than hardcoded.
    private func airableRadioRoot() async -> String? {
        guard let r = try? await api.rows("airable:", to: 20) else { return nil }
        for row in r.rows {
            if let p = row["path"] as? String, p.hasSuffix("/airable/radios") { return p }
        }
        return nil
    }

    /// Stations to offer in the presets picker: the speaker's own radio
    /// history and favourites. Titles are de-duplicated, history first.
    func radioPickerStations() async -> [RadioStation] {
        guard let root = await airableRadioRoot() else { return [] }
        var out: [RadioStation] = []
        var seen = Set<String>()
        for list in ["/history", "/favorites"] {
            guard let r = try? await api.rows(root + list, to: 40) else { continue }
            for row in r.rows {
                guard let title = row["title"] as? String,
                      let path = row["path"] as? String,
                      !seen.contains(title) else { continue }
                seen.insert(title)
                out.append(RadioStation(title: title, path: path,
                                        iconURL: row["icon"] as? String ?? ""))
            }
        }
        return out
    }

    func setSourceLayout(order: [String], hidden: Set<String>) {
        sourceOrder = order
        hiddenSources = hidden
        UserDefaults.standard.set(order, forKey: "SourceOrder")
        UserDefaults.standard.set(Array(hidden), forKey: "SourceHidden")
    }

    private(set) var api: KEFAPI
    private var auth: KEFAuthChannel
    private var artworkURL: String?
    private var volumeSendTask: Task<Void, Never>?

    var speakerIP: String { api.ip }
    /// False until the user has entered a speaker address.
    var isConfigured: Bool { !api.ip.isEmpty }

    /// Shared with the Speaker IP dialog, so opening it shows whatever the
    /// first-run search already turned up.
    let discovery = SpeakerDiscovery()
    private var discoverySink: AnyCancellable?

    /// Adopt a discovered speaker automatically, but only when there is exactly
    /// one and the user has not chosen one — picking for them among several
    /// would be guessing at which room they meant.
    private func autoDiscover() {
        discovery.start()
        discoverySink = discovery.$found
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                guard let self, !self.isConfigured, list.count == 1,
                      let only = list.first else { return }
                self.setSpeakerIP(only.ip)
                self.discovery.stop()
                self.discoverySink = nil
            }
    }

    /// Point the app at a different speaker; persists and rebuilds the API clients.
    func setSpeakerIP(_ ip: String) {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != api.ip else { return }
        UserDefaults.standard.set(trimmed, forKey: "SpeakerIP")
        api = KEFAPI(ip: trimmed)
        auth = KEFAuthChannel(ip: trimmed)
        reachable = false
        Task { await refresh() }
    }

    /// The 24 DSP values that constitute a KEF EQ profile (id/name stored separately).
    static let eqFields = [
        "audioPolarity", "balance", "bassExtension", "deskMode", "deskModeSetting",
        "dialogueMode", "highPassMode", "highPassModeFreq", "isEqMode", "isExpertMode",
        "phaseCorrection", "soundProfile", "subEnableStereo", "subOutLPFreq",
        "subwooferCount", "subwooferGain", "subwooferOut", "subwooferPolarity",
        "subwooferPreset", "trebleAmount", "wallMode", "wallModeSetting",
        "wallMounted", "wirelessSub",
    ]
    private let eqStoreURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KEFMenuBar/eq-profiles.json")
    private var eqStore: [[String: Any]] = []
    private var capturingEqId: String?

    var isStandby: Bool { source == "standby" }
    var isPlaying: Bool { playState == "playing" }

    /// This panel drives one output: the speaker. The `display*` names are
    /// kept so the view reads the same as its full-featured sibling.
    var effectiveMinVolume: Int { 0 }
    var effectiveMaxVolume: Int { maxVolume }
    var displayedMuted: Bool { muted }
    var displayedIsPlaying: Bool { isPlaying }
    var displaySeek: Double? { seek }
    var displayLength: Double? { length }
    var displayCanSeek: Bool { canSeek }
    var volumeControlDisabled: Bool { !reachable || isStandby }
    var transportDisabled: Bool { playState == "stopped" && title == nil }

    /// Title shown above the transport controls. Physical inputs report their
    /// own short label (e.g. "TV", "COAX") as the track title — replace those
    /// with friendly names.
    var displayTitle: String {
        switch source {
        case "tv": return "Television"
        case "coaxial": return "Coaxial"
        case "optical": return "Optical"
        case "analog": return "Analog"
        case "usb": return "USB"
        case "bluetooth": return "Bluetooth"
        default: return title ?? "Nothing playing"
        }
    }
    var displayArtist: String? { artist }
    var displayAlbum: String? { album }
    var displayedVolume: Int { muted ? 0 : volume }
    /// The menu bar label and the global hotkeys both track the speaker.
    var kefDisplayedVolume: Int { muted ? 0 : volume }

    /// True while the speaker is actually rendering a stream, so its reported
    /// format describes what you are looking at.
    var showsKEFStream: Bool { isPlaying || playState == "paused" }

    /// "spotifyHifi" -> "Lossless" (the service name is prefixed separately).
    static func humanizedQuality(_ key: String) -> String {
        // Spotify's embedded Connect SDK still calls the lossless tier "hifi".
        // Verified 2026-07-18: the flag is ABSENT when streaming quality is set
        // to High, so it really does indicate Lossless rather than capability.
        if key == "spotifyHifi" { return "Lossless" }
        var words: [String] = []
        var current = ""
        for ch in key {
            if ch.isUppercase, !current.isEmpty { words.append(current); current = "" }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words
            .map { $0.lowercased() == "hifi" ? "HiFi" : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// What's feeding the speaker: the streaming service when there is one,
    /// else the physical input.
    var sourceLabel: String? {
        if !streamingService.isEmpty {
            switch streamingService.lowercased() {
            case "airplay": return "AirPlay"
            case "roon":    return "Roon"
            case "spotify": return "Spotify"
            case "tidal":   return "Tidal"
            case "upnp":    return "UPnP"
            // airable is the backend, not something to put in front of the
            // user — it reports "airableRadios" / "airablePodcasts".
            case "airableradios":   return "Radio"
            case "airablepodcasts": return "Podcast"
            // Qobuz Connect reports its own id, which the generic capitalise
            // below turns into "Qobuzconnect".
            case "qobuz", "qobuzconnect": return "Qobuz"
            // The generic capitalise below mangles these four.
            case "amazonmusic": return "Amazon Music"
            case "avs":         return "Alexa"        // Alexa Voice Service
            case "cdrom":       return "CD"
            // The bare aggregator id — if this ever surfaces it means a
            // service we haven't mapped, so name the service, not the plumbing.
            case "airable":     return "Radio"
            default:
                return streamingService.prefix(1).uppercased() + streamingService.dropFirst()
            }
        }
        switch source {
        case "tv": return "TV"
        case "optical": return "Optical"
        case "coaxial": return "Coaxial"
        case "analog": return "Analog"
        case "usb": return "USB"
        case "bluetooth": return "Bluetooth"
        default: return nil
        }
    }

    /// e.g. "Roon · 96 kHz / 24-bit", or "Spotify · Lossless" where the source
    /// reports a quality flag instead of numbers.
    var audioFormatText: String? {
        var detail: String?
        if let rate = sampleFrequency, rate > 0 {
            let khz = Double(rate) / 1000
            let rateText = khz == khz.rounded() ? String(format: "%.0f", khz)
                                                : String(format: "%.1f", khz)
            if let bits = bitsPerSample, bits > 1 {
                detail = "\(rateText) kHz / \(bits)-bit"
            } else {
                detail = "\(rateText) kHz"
            }
        } else {
            detail = streamQuality
        }
        // Spotify reports no numbers at all — its only quality signal is the
        // `spotifyHifi` flag, which is ABSENT (not false) on the High tier.
        // So for Spotify, and only Spotify, no detail means not-lossless
        // rather than unknown.
        if detail == nil, streamingService.lowercased() == "spotify" {
            detail = "Lossy"
        }
        guard let detail else { return nil }
        guard let source = sourceLabel else { return detail }
        return "\(source) · \(detail)"
    }


    /// Placeholder keeps the value slot occupied when there is no volume to
    /// show, so the label never collapses (see MenuBarLabel).
    var menuBarTitle: String {
        if !reachable { return "––" }
        if isStandby { return "––" }
        return String(format: "%02d", kefDisplayedVolume)
    }

    var menuBarIcon: String {
        if !reachable { return "hifispeaker.2" }
        if isStandby { return "power" }
        if muted { return "speaker.slash.fill" }
        return isPlaying ? "hifispeaker.2.fill" : "hifispeaker.2"
    }

    init() {
        // No default speaker: on a fresh install there is nothing to guess at,
        // and the panel prompts for the address instead (see unreachableView).
        let ip = ProcessInfo.processInfo.environment["KEF_IP"]
            ?? UserDefaults.standard.string(forKey: "SpeakerIP")
            ?? ""
        api = KEFAPI(ip: ip)
        auth = KEFAuthChannel(ip: ip)
        loadEqStore()
        // Nothing configured yet: look for a speaker on the network and adopt
        // it if exactly one turns up, so the common case needs no setup at all.
        if ip.isEmpty { autoDiscover() }
        Task { await pollLoop() }
        // advance the progress line between polls
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if isPlaying, !isScrubbing, let s = seek, let l = length {
                    seek = min(s + 1, l)
                }
            }
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        guard isConfigured else { reachable = false; return }
        do {
            let vol = try await api.value("player:volume")["i32_"] as? Int
            // ignore stale reads briefly after we set the volume, so an in-flight
            // poll can't snap the slider back before the speaker catches up
            if let vol, !isDraggingVolume,
               Date().timeIntervalSince(lastVolumeCommand) > 1.5 {
                volume = vol
            }
            reachable = true
        } catch {
            reachable = false
            return
        }

        if let m = (try? await api.value("settings:/mediaPlayer/mute"))?["bool_"] {
            muted = (m as? Bool) ?? ((m as? String)?.lowercased() == "true")
        }
        if let s = (try? await api.value("settings:/kef/play/physicalSource"))?["kefPhysicalSource"] as? String {
            source = s
        }
        let limitOn = (try? await api.value("settings:/kef/host/volumeLimit"))?["bool_"] as? Bool ?? false
        let limit = (try? await api.value("settings:/kef/host/maximumVolume"))?["i32_"] as? Int
        maxVolume = (limitOn ? limit : nil) ?? 100
        await pollEqProfile()
        var kefIcon: String?
        if let player = try? await api.value("player:player/data") {
            playState = player["state"] as? String ?? "stopped"
            let roles = player["trackRoles"] as? [String: Any] ?? [:]
            let meta = ((roles["mediaData"] as? [String: Any])?["metaData"] as? [String: Any]) ?? [:]
            title = roles["title"] as? String
            artist = meta["artist"] as? String
            album = meta["album"] as? String
            let mediaMeta = ((player["mediaRoles"] as? [String: Any])?["mediaData"]
                             as? [String: Any])?["metaData"] as? [String: Any]
            streamingService = (meta["serviceID"] as? String)
                ?? (mediaMeta?["serviceID"] as? String) ?? ""
            let active = (roles["mediaData"] as? [String: Any])?["activeResource"] as? [String: Any]
            sampleFrequency = (active?["sampleFrequency"] as? NSNumber)?.intValue
            bitsPerSample = (active?["bitsPerSample"] as? NSNumber)?.intValue
            let quality = active?["quality"] as? [String: Any] ?? [:]
            streamQuality = quality
                .filter { ($0.value as? NSNumber)?.boolValue == true }
                .keys.sorted()
                .first
                .map(Self.humanizedQuality)
            canSeek = (player["controls"] as? [String: Any])?["seekTime"] as? Bool ?? false

            let durationMs = ((player["status"] as? [String: Any])?["duration"] as? NSNumber)?.doubleValue
            length = durationMs.map { $0 / 1000 }
            if length != nil, playState == "playing" || playState == "paused",
               !isScrubbing, Date().timeIntervalSince(lastSeekCommand) > 2,
               let playTime = (try? await api.value("player:player/data/playTime"))?["i64_"] as? NSNumber {
                seek = playTime.doubleValue / 1000
            } else if length == nil {
                seek = nil
            }

            kefIcon = roles["icon"] as? String
        }
        await loadArtwork(kefIcon)
    }

    // MARK: EQ profiles — snapshot store; auto-captures profiles set in KEF Connect,
    // applies them via the authenticated DSP channel.

    private func pollEqProfile() async {
        guard let id = (try? await api.value("settings:/kef/dsp/v2/profileId"))?["string_"] as? String,
              let name = (try? await api.value("settings:/kef/dsp/v2/profileName"))?["string_"] as? String
        else { return }
        currentEqId = id
        currentEqName = name
        guard !id.isEmpty, capturingEqId != id else { return }

        if let idx = eqStore.firstIndex(where: { ($0["id"] as? String) == id }) {
            if !name.isEmpty, (eqStore[idx]["name"] as? String) != name {  // picked up a rename
                eqStore[idx]["name"] = name
                saveEqStore(); publishEqRefs()
            }
        } else {
            capturingEqId = id
            Task { await captureProfile(id: id, name: name) }
        }
    }

    /// Snapshot all DSP values for a profile the store hasn't seen yet.
    private func captureProfile(id: String, name: String) async {
        defer { capturingEqId = nil }
        try? await Task.sleep(for: .seconds(2))   // let KEF Connect finish writing
        guard (try? await api.value("settings:/kef/dsp/v2/profileId"))?["string_"] as? String == id
        else { return }
        var values: [String: Any] = [:]
        for field in Self.eqFields {
            guard let v = try? await api.value("settings:/kef/dsp/v2/\(field)") else { return }
            values["settings:/kef/dsp/v2/\(field)"] = v
        }
        eqStore.append(["id": id, "name": name.isEmpty ? "Profile \(eqStore.count + 1)" : name,
                        "values": values])
        saveEqStore(); publishEqRefs()
    }

    func applyEqProfile(_ profile: EQProfileRef) {
        guard let entry = eqStore.first(where: { ($0["id"] as? String) == profile.id }),
              let values = entry["values"] as? [String: Any] else { return }
        currentEqId = profile.id
        currentEqName = profile.name
        Task {
            for (path, value) in values {
                guard let value = value as? [String: Any] else { continue }
                try? await auth.setData(path: path, roles: "value", value: value)
            }
            // set id/name last so KEF Connect shows the right active profile
            try? await auth.setData(path: "settings:/kef/dsp/v2/profileId", roles: "value",
                                    value: ["type": "string_", "string_": profile.id])
            try? await auth.setData(path: "settings:/kef/dsp/v2/profileName", roles: "value",
                                    value: ["type": "string_", "string_": profile.name])
            await refresh()
        }
    }

    /// Re-snapshot the active profile — for after its settings were edited in KEF Connect.
    func recaptureCurrentProfile() {
        guard !currentEqId.isEmpty else { return }
        let id = currentEqId, name = currentEqName
        Task {
            var values: [String: Any] = [:]
            for field in Self.eqFields {
                guard let v = try? await api.value("settings:/kef/dsp/v2/\(field)") else { return }
                values["settings:/kef/dsp/v2/\(field)"] = v
            }
            if let idx = eqStore.firstIndex(where: { ($0["id"] as? String) == id }) {
                eqStore[idx]["values"] = values
                if !name.isEmpty { eqStore[idx]["name"] = name }
            } else {
                eqStore.append(["id": id, "name": name, "values": values])
            }
            saveEqStore(); publishEqRefs()
        }
    }

    private func loadEqStore() {
        guard let data = try? Data(contentsOf: eqStoreURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = obj["profiles"] as? [[String: Any]] else { return }
        eqStore = profiles
        publishEqRefs()
    }

    private func saveEqStore() {
        try? FileManager.default.createDirectory(
            at: eqStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["profiles": eqStore],
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: eqStoreURL)
        }
    }

    private func publishEqRefs() {
        eqProfiles = eqStore.compactMap {
            guard let id = $0["id"] as? String, let name = $0["name"] as? String else { return nil }
            return EQProfileRef(id: id, name: name)
        }
    }

    private func loadArtwork(_ url: String?) async {
        guard url != artworkURL else { return }
        guard let url, let u = URL(string: url) else {
            artworkURL = nil
            if artwork != nil { artwork = nil }
            return
        }
        if let (data, _) = try? await URLSession.shared.data(from: u),
           let image = NSImage(data: data) {
            artwork = image
            artworkURL = url
            panelColor = Self.darkTint(from: image) ?? Color(white: 0.13)
        } else {
            // leave artworkURL unset so the next poll retries
            artworkURL = nil
            if artwork != nil { artwork = nil }
            panelColor = Color(white: 0.13)
        }
    }

    /// Dominant hue of the artwork, darkened to a panel-background level.
    /// Returns nil for effectively monochrome images.
    private static func darkTint(from image: NSImage) -> Color? {
        let size = 24
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        // histogram over 12 hue buckets, colorful pixels only
        var buckets = [(count: Int, r: CGFloat, g: CGFloat, b: CGFloat)](
            repeating: (0, 0, 0, 0), count: 12)
        for y in 0..<size {
            for x in 0..<size {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                guard c.saturationComponent > 0.2,
                      c.brightnessComponent > 0.15, c.brightnessComponent < 0.95
                else { continue }
                let bucket = min(11, Int(c.hueComponent * 12))
                buckets[bucket].count += 1
                buckets[bucket].r += c.redComponent
                buckets[bucket].g += c.greenComponent
                buckets[bucket].b += c.blueComponent
            }
        }
        guard let best = buckets.max(by: { $0.count < $1.count }),
              best.count >= 20 else { return nil }  // < ~3% colorful: treat as mono

        let n = CGFloat(best.count)
        let avg = NSColor(red: best.r / n, green: best.g / n, blue: best.b / n, alpha: 1)
        return Color(nsColor: NSColor(
            hue: avg.hueComponent,
            saturation: min(avg.saturationComponent, 0.55),
            brightness: 0.17,
            alpha: 1
        ))
    }

    // MARK: commands (optimistic UI + refresh)

    /// Panel slider/steppers. Same target as the global hotkeys: the speaker.
    func setVolume(_ v: Int) { setVolumeOnKEF(v) }

    /// Always the speaker — used by the panel in KEF modes AND by the global
    /// hotkeys in every mode (they fire with the panel closed, so they must
    /// never silently move some other room's speaker).
    func setVolumeOnKEF(_ v: Int) {
        let v = min(max(0, v), maxVolume)
        volume = v
        lastVolumeCommand = Date()
        if muted && v > 0 {   // adjusting volume while muted unmutes
            muted = false
            Task { try? await api.setMute(false) }
        }
        volumeSendTask?.cancel()
        volumeSendTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            try? await api.setVolume(v)
        }
    }

    func toggleMute() {
        muted.toggle()
        Task { try? await api.setMute(muted); await refresh() }
    }

    func control(_ c: String) {
        if c == "pause" { playState = isPlaying ? "paused" : "playing" }
        Task { try? await api.control(c); try? await Task.sleep(for: .milliseconds(300)); await refresh() }
    }

    /// Seek within the current track — only for sources that advertise
    /// seekTime (Spotify Connect, Airable; not Roon RAAT, where the KEF is a
    /// slave renderer and the speaker rejects the command).
    func seekTo(_ seconds: Double) {
        seek = seconds
        lastSeekCommand = Date()
        Task {
            try? await api.setData(path: "player:player/control", roles: "activate",
                                   value: ["control": "seekTime", "time": Int(seconds * 1000)])
        }
    }

    func setSource(_ s: String) {
        source = s
        // drop the previous source's now-playing so its label doesn't flash
        title = nil; artist = nil; album = nil
        streamingService = ""
        seek = nil; length = nil
        Task { try? await api.setSource(s); try? await Task.sleep(for: .milliseconds(300)); await refresh() }
    }

    func togglePower() {
        setSource(isStandby ? "wifi" : "standby")
    }
}

// MARK: - Popover UI

struct PlayerView: View {
    @ObservedObject var model: SpeakerModel
    @ObservedObject private var artwork = ArtworkCache.shared

    var body: some View {
        VStack(spacing: 0) {
            if !model.reachable {
                unreachableView
            } else if model.isStandby {
                standbyView
            } else {
                artworkView
                progressBar
            }
            VStack(spacing: 12) {
                if model.reachable && !model.isStandby {
                    metadataView
                    transportView
                }
                VStack(spacing: 12) {
                    volumeRow
                    // Presets belong with the volume they set, so they expand
                    // directly under that row; the format/EQ line stays put
                    // just above the divider instead of being pushed down.
                    if model.showPresets {
                        presetRow
                    }
                    audioFormatCaption
                }
                radioRow
                Divider()
                bottomRow
            }
            .padding(14)
        }
        .frame(width: PanelMetrics.width)
        .background(model.panelColor)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        // The shadow lives here, not on the window, so it follows the card as
        // SwiftUI animates its height.
        .shadow(color: .black.opacity(0.44), radius: 11, x: 0, y: 4)
        // The panel window is a fixed-size transparent canvas that never
        // resizes, so this always matches the hosting view's bounds — nothing
        // ever overflows, and the card is simply pinned to the top. SwiftUI
        // animates the card's height on its own; no window/content sync exists
        // to get wrong.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.6), value: model.panelColor)
    }

    /// Doubles as the first-run screen: with no address saved there is nothing
    /// to be "unreachable" yet, so say where to set one instead of showing a
    /// dead end.
    private var unreachableView: some View {
        VStack(spacing: 6) {
            Image(systemName: model.isConfigured ? "wifi.exclamationmark" : "hifispeaker.2")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(model.isConfigured ? "Speaker unreachable" : "No speaker set")
                .foregroundStyle(.secondary)
            Text(model.isConfigured
                 ? model.api.ip
                 : "Right-click the menu bar icon →\nSettings…")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 20)
    }

    private var standbyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "power")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Standby")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }

    private var artworkView: some View {
        Group {
            if let art = model.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 300, height: 300)
        .clipped()
    }

    /// The speaker's incoming stream format, as a quiet caption under the
    /// volume slider. Hidden when the speaker isn't rendering a stream, so the
    /// row takes no height at all — matches KEF Audio.
    @ViewBuilder private var audioFormatCaption: some View {
        if let format = model.audioFormatText, model.showsKEFStream {
            Text(format)
                .font(.subheadline)                     // a notch under the album line
                .foregroundStyle(Color(white: 0.65))   // same as the album line
                .lineLimit(1)
                .allowsHitTesting(false)
        }
    }

    /// Display-only: the KEF HTTP API exposes play position read-only.
    /// With no track duration it renders as an all-grey separator line.
    private var progressBar: some View {
        GeometryReader { geo in
            let length = model.displayLength ?? 0
            let fraction: CGFloat = length > 0 ? max(0, min(1, (model.displaySeek ?? 0) / length)) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.35))
                Rectangle().fill(Color.appAccent).frame(width: geo.size.width * fraction)
            }
            .contentShape(Rectangle().inset(by: -8))   // easier to grab than 2 pt
            .gesture(model.displayCanSeek && length > 0 ? scrubGesture(width: geo.size.width, length: length) : nil)
        }
        .frame(height: 2)
    }

    private func scrubGesture(width: CGFloat, length: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.isScrubbing = true
                model.seek = max(0, min(1, value.location.x / width)) * length
            }
            .onEnded { value in
                let target = max(0, min(1, value.location.x / width)) * length
                model.isScrubbing = false
                model.seekTo(target)
            }
    }

    private var metadataView: some View {
        VStack(spacing: 3) {
            Text(model.displayTitle)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
            if let artist = model.displayArtist {
                Text(artist)
                    .font(.body)
                    .foregroundStyle(Color(white: 0.8))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let album = model.displayAlbum {
                Text(album)
                    .font(.callout)
                    .foregroundStyle(Color(white: 0.65))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var transportView: some View {
        HStack(spacing: 28) {
            Button { model.control("previous") } label: {
                Image(systemName: "backward.end.fill").font(.title2)
            }
            Button { model.control("pause") } label: {
                Image(systemName: model.displayedIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 38))
            }
            Button { model.control("next") } label: {
                Image(systemName: "forward.end.fill").font(.title2)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.transportDisabled)
    }

    private var volumeRow: some View {
        HStack(alignment: .center, spacing: 10) {
            // Mirrors the volume-presets chevron at the far right of this row:
            // same glyph, same size, pointing at the row it opens. Only shown
            // once stations are configured — otherwise it would toggle a row
            // that has nothing in it.
            if model.hasRadioSlots {
                Button {
                    withAnimation(.easeInOut(duration: PanelAnim.duration)) {
                        model.showRadioRow.toggle()
                    }
                } label: {
                    Image(systemName: model.showRadioRow ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.showRadioRow ? "Hide radio presets" : "Show radio presets")
            }
            Button { model.toggleMute() } label: {
                Image(systemName: model.displayedMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.body)
                    .frame(width: 20, height: 20, alignment: .center)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.displayedMuted ? .red : .secondary)

            Button { model.setVolume(max(model.effectiveMinVolume, model.displayedVolume - 1)) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.volumeControlDisabled)

            Slider(
                value: Binding(
                    get: { Double(model.displayedVolume) },
                    set: { model.setVolume(Int($0)) }
                ),
                in: Double(model.effectiveMinVolume)...Double(max(model.effectiveMaxVolume, model.effectiveMinVolume + 1)),
                onEditingChanged: { model.isDraggingVolume = $0 }
            )
            .controlSize(.small)
            .tint(Color.appAccent)
            .disabled(model.volumeControlDisabled)

            Button { model.setVolume(min(model.effectiveMaxVolume, model.displayedVolume + 1)) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.volumeControlDisabled)

            Button {
                withAnimation(.easeInOut(duration: PanelAnim.duration)) {
                    model.showPresets.toggle()
                }
            } label: {
                HStack(spacing: 3) {
                    // Reserve two digits so the slider can't resize mid-drag as
                    // the value crosses 9→10. The old minWidth-40 on the whole
                    // block parked ~4pt of slack LEFT of the digits, which made
                    // the +→number gap visibly wider than the speaker→− gap.
                    Text("\(model.displayedVolume)")
                        .font(.body.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)
                    Image(systemName: model.showPresets ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 20)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.showPresets ? "Hide volume presets" : "Show volume presets")
            .disabled(model.volumeControlDisabled)
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 2) {
            ForEach(model.visibleSources, id: \.id) { src in
                sourceButton(src)
            }
            Spacer(minLength: 6)
            // Second EQ picker, alongside the one on the format line, to
            // compare the two placements. Sized for six inputs; with seven it
            // is the only flexible item here so it truncates rather than
            // overflowing.
            if !model.currentEqName.isEmpty {
                eqMenu(maxWidth: 78)
            }
            powerButton
        }
    }

    private var powerButton: some View {
        Button { model.togglePower() } label: {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.isStandby ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.appAccent))
                .frame(width: 28, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(model.isStandby ? "Wake speaker" : "Standby")
        .disabled(!model.reachable)
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(model.volumePresets, id: \.self) { preset in
                let active = model.displayedVolume == preset
                Button { model.setVolume(preset) } label: {
                    Text("\(preset)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(active ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(active ? Color.appAccent.opacity(0.18) : Color.white.opacity(0.07))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(preset > model.effectiveMaxVolume)
            }
        }
        .disabled(model.volumeControlDisabled)
    }

    private func eqMenu(maxWidth: CGFloat) -> some View {
        Menu {
            ForEach(model.eqProfiles) { profile in
                Button {
                    model.applyEqProfile(profile)
                } label: {
                    if profile.id == model.currentEqId {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            if !model.eqProfiles.isEmpty { Divider() }
            Button("Re-capture current") { model.recaptureCurrentProfile() }
        } label: {
            // Icons stay INSIDE the Text via interpolation: a standalone Image
            // in a Menu label gets tinted white by the menu style.
            // Chevron is size 9 semibold, matching the volume row's — the two
            // were once stacked and the sizes should stay in step.
            // NOTE when re-tuning position: .menuStyle(.borderlessButton)
            // carries its own trailing inset, which a plain-Text mock does NOT
            // reproduce. Measure with a real Menu or the answer is ~1.5pt out.
            Text("\(Image(systemName: "slider.horizontal.3")) \(model.currentEqName) \(Text(Image(systemName: "chevron.down")).font(.system(size: 9, weight: .semibold)))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: maxWidth, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
        // Purely visual nudge — keeps the width negotiation above untouched.
        // Kept from when this sat under the volume row; it also reads correctly
        // against the power button, so it stays rather than shifting a layout
        // that was already signed off.
        .offset(x: 1.5, y: 0)
        .help("EQ profile")
    }


    /// Station artwork, fetched once per URL and kept for the app's lifetime.
    /// Slots are few and the icons tiny, so no eviction policy is warranted.
    @MainActor
    final class ArtworkCache: ObservableObject {
        static let shared = ArtworkCache()
        @Published private(set) var images: [String: NSImage] = [:]
        private var inFlight: Set<String> = []

        func image(for url: String) -> NSImage? {
            guard !url.isEmpty else { return nil }
            if let img = images[url] { return img }
            guard !inFlight.contains(url), let u = URL(string: url) else { return nil }
            inFlight.insert(url)
            Task { @MainActor in
                defer { inFlight.remove(url) }
                guard let (data, _) = try? await URLSession.shared.data(from: u),
                      let img = NSImage(data: data) else { return }
                images[url] = img
            }
            return nil
        }
    }

    /// Up to five radio stations, as artwork circles matching the volume-preset
    /// row's rhythm. Hidden entirely when no slot is set, so the panel is
    /// unchanged for anyone not using it.
    @ViewBuilder private var radioRow: some View {
        if model.hasRadioSlots && model.showRadioRow {
            // Fixed spacing, centred as a group: a full row of 7 lands
            // symmetrically edge to edge (7×30 + 6×10 = 270 of 272), and a
            // partial row stays a tight cluster in the middle rather than
            // spreading to the corners.
            HStack(spacing: 10) {
                ForEach(Array(model.radioSlots.enumerated()), id: \.offset) { i, slot in
                    if let station = slot {
                        radioButton(i, station)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func radioButton(_ index: Int, _ station: SpeakerModel.RadioStation) -> some View {
        let active = model.isPlayingRadio(station)
        return Button { model.playRadio(index) } label: {
            ZStack {
                Circle()
                    .fill(active ? Color.appAccent.opacity(0.26) : Color.white.opacity(0.11))
                if let art = artwork.image(for: station.iconURL) {
                    Image(nsImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(Circle())
                        .opacity(active ? 1 : 0.85)
                } else {
                    // Initials until the artwork arrives (or if it never does).
                    Text(Self.initials(station.title))
                        .font(.system(size: 11))
                        .foregroundStyle(active ? AnyShapeStyle(Color.appAccent)
                                               : AnyShapeStyle(.secondary))
                }
                if active {
                    Circle().strokeBorder(Color.appAccent, lineWidth: 1.5)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!model.reachable || model.isStandby)
    }

    /// "NPO Radio 1" -> "N1", "Jazz24" -> "J2", "Classic FM" -> "CF".
    private static func initials(_ title: String) -> String {
        let words = title.split(whereSeparator: { $0 == " " || $0 == "-" })
        let letters = words.compactMap { $0.first }.filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(2)).uppercased()
    }

    /// Bundled template PNGs for inputs SF Symbols doesn't cover — Bluetooth's
    /// rune is a trademark, so there is no system symbol for it. isTemplate
    /// makes AppKit tint it from its alpha channel, exactly like a symbol.
    private static let bundledGlyphs: [String: NSImage] = {
        var out: [String: NSImage] = [:]
        for (name, size) in [("bluetooth-glyph", NSSize(width: 12, height: 14))] {
            guard let path = Bundle.main.path(forResource: name, ofType: "png"),
                  let img = NSImage(contentsOfFile: path) else { continue }
            img.isTemplate = true
            img.size = size
            out[name] = img
        }
        return out
    }()

    @ViewBuilder
    private func sourceIcon(_ src: SpeakerModel.Source) -> some View {
        if let glyph = src.glyph, let img = Self.bundledGlyphs[glyph] {
            Image(nsImage: img).renderingMode(.template)
        } else {
            Image(systemName: src.icon)
        }
    }

    private func sourceButton(_ src: SpeakerModel.Source) -> some View {
        let selected = model.source == src.id
        return Button { model.setSource(src.id) } label: {
            sourceIcon(src)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(.secondary))
                // 24pt buys the room the bottom-row EQ picker needs: six inputs
                // at 28 leave only 54pt and the "Expert" label wants 68; at 24
                // there is 78pt. (Measured — scratchpad/eqfit.swift.)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.appAccent.opacity(0.18) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(src.name)
        .disabled(!model.reachable)
    }
}

// MARK: - Menu bar label (SwiftUI, so icon and digits center-align)

struct MenuBarLabel: View {
    @ObservedObject var model: SpeakerModel

    /// Every icon the label can show; used only to reserve width.
    private static let iconVariants = ["hifispeaker.2.fill", "hifispeaker.2",
                                       "speaker.slash.fill", "power"]

    /// Icon alone, or icon + value. Building both from one place keeps the
    /// hidden width-reservation copies identical to the visible label.
    private static func labelText(icon: String, value: String?) -> Text {
        guard let value else { return Text(Image(systemName: icon)) }
        return Text("\(Image(systemName: icon)) \(Text(value).monospacedDigit())")
    }

    var body: some View {
        // The status item is exactly as wide as this label, and macOS lays menu
        // bar items out from the right — so a narrower state used to shift this
        // icon and everything left of it. Reserve the widest state's width and
        // keep the icon leading: the icon then holds its place in every state.
        // With the volume hidden the reservation still matters: the icon
        // variants are not all the same width either, so the widest is
        // reserved to stop the item shifting as the state changes.
        ZStack(alignment: .leading) {
            ForEach(Self.iconVariants, id: \.self) { icon in
                Self.labelText(icon: icon,
                               value: model.showVolumeInMenuBar ? "88" : nil)
                    .hidden()
            }
            Self.labelText(icon: model.menuBarIcon,
                           value: model.showVolumeInMenuBar ? model.menuBarTitle : nil)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Global hotkeys (customizable)

enum HotKeyAction: String, CaseIterable {
    case togglePanel, volumeUp, volumeDown, toggleMute, playPause, next, previous
    case preset1, preset2, preset3, preset4, preset5, preset6, preset7

    static let mediaActions: [HotKeyAction] =
        [.togglePanel, .volumeUp, .volumeDown, .toggleMute, .playPause, .next, .previous]
    static let presetActions: [HotKeyAction] =
        [.preset1, .preset2, .preset3, .preset4, .preset5, .preset6, .preset7]

    /// 0-based preset slot index, or nil for non-preset actions.
    var presetIndex: Int? {
        HotKeyAction.presetActions.firstIndex(of: self)
    }

    var title: String {
        switch self {
        case .togglePanel: return "Show / Hide Player"
        case .volumeUp:    return "Volume Up"
        case .volumeDown:  return "Volume Down"
        case .toggleMute:  return "Toggle Mute"
        case .playPause:   return "Play / Pause"
        case .next:        return "Next Track"
        case .previous:    return "Previous Track"
        default:           return "Preset \((presetIndex ?? 0) + 1)"
        }
    }

    /// Stable Carbon hot-key id.
    var id: UInt32 { UInt32(HotKeyAction.allCases.firstIndex(of: self)! + 1) }

    /// Nothing is bound out of the box. This app is designed to sit ALONGSIDE
    /// KEF Audio, which owns the ⌘⌥⌃ media combos; Carbon hot keys are
    /// first-come-first-served, so any shared default would just leave one
    /// app's binding silently dead. Assign what you want in
    /// Hotkeys & Volume Presets….
    var defaultShortcut: Shortcut? { nil }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier flags
    var label: String       // display label for the key itself

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label
    }

    /// Build from an NSEvent keyDown; nil if no non-shift modifier is held.
    static func from(_ event: NSEvent) -> Shortcut? {
        var carbon: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.command) { carbon |= UInt32(cmdKey) }
        if f.contains(.option) { carbon |= UInt32(optionKey) }
        if f.contains(.control) { carbon |= UInt32(controlKey) }
        if f.contains(.shift) { carbon |= UInt32(shiftKey) }
        // require at least one of cmd/opt/ctrl so global keys don't hijack typing
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: carbon,
                        label: Self.label(for: event))
    }

    private static let special: [Int: String] = [
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_Space: "␣", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
    ]

    private static func label(for event: NSEvent) -> String {
        if let sp = special[Int(event.keyCode)] { return sp }
        let ch = event.charactersIgnoringModifiers ?? ""
        return ch.uppercased()
    }
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) { handlers[id]?() }

    /// Temporarily unregister every hotkey (so combos can be re-recorded).
    /// Handlers are kept; call the app's apply routine to restore them.
    func suspend() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    func register(_ action: HotKeyAction, _ shortcut: Shortcut?, handler: @escaping () -> Void) {
        installHandler()
        if let ref = refs[action.id] { UnregisterEventHotKey(ref); refs[action.id] = nil }
        handlers[action.id] = handler
        guard let shortcut else { return }
        var ref: EventHotKeyRef?
        let hotID = EventHotKeyID(signature: OSType(0x4B45_4668), id: action.id)  // "KEFh"
        if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotID,
                               GetApplicationEventTarget(), 0, &ref) == noErr {
            refs[action.id] = ref
        }
    }
}

enum ShortcutStore {
    static func shortcut(_ action: HotKeyAction) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: "hotkey.\(action.rawValue)") else {
            return action.defaultShortcut
        }
        if data.isEmpty { return nil }   // explicitly cleared
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    static func setShortcut(_ action: HotKeyAction, _ shortcut: Shortcut?) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        UserDefaults.standard.set(data, forKey: "hotkey.\(action.rawValue)")
    }

    static var volumeStep: Int {
        let v = UserDefaults.standard.integer(forKey: "VolumeStep")
        return v > 0 ? v : 1
    }
    static func setVolumeStep(_ v: Int) {
        UserDefaults.standard.set(max(1, min(50, v)), forKey: "VolumeStep")
    }
}

/// A button that records a global shortcut into a pending value (not persisted
/// until the window's Save). Click, then press the combo.
final class ShortcutRecorderButton: NSButton {
    static weak var active: ShortcutRecorderButton?
    static func endActiveRecording() { active?.stop() }

    private(set) var shortcut: Shortcut?   // staged value
    private var recording = false
    private var monitor: Any?

    func configure(initial: Shortcut?) {
        shortcut = initial
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        updateAppearance()
    }

    private func updateAppearance() {
        if recording {
            title = "Recording…"
            bezelColor = .appAccent
        } else {
            bezelColor = nil
            title = shortcut?.display ?? "Press keys"
        }
    }

    @objc private func startRecording() {
        guard !recording else { return }
        ShortcutRecorderButton.active?.stop()   // only one records at a time
        ShortcutRecorderButton.active = self
        recording = true
        updateAppearance()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stop(); return nil }              // esc: cancel
            if event.keyCode == 51 || event.keyCode == 117 {                // delete: clear
                self.shortcut = nil; self.stop(); return nil
            }
            if let sc = Shortcut.from(event) {
                self.shortcut = sc; self.stop()
            }
            return nil   // swallow everything while recording
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if ShortcutRecorderButton.active === self { ShortcutRecorderButton.active = nil }
        updateAppearance()
    }

    func clear() { stop(); shortcut = nil; updateAppearance() }
    @objc func clearAction() { clear() }
}

// MARK: - Settings window (one tabbed window; grouped forms like System Settings)

/// Hosts the AppKit shortcut recorder inside SwiftUI so the capture logic —
/// the key monitor, esc/delete handling, the one-recorder-at-a-time rule —
/// is reused verbatim rather than rewritten.
struct ShortcutRecorderView: NSViewRepresentable {
    let button: ShortcutRecorderButton
    func makeNSView(context: Context) -> ShortcutRecorderButton { button }
    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {}
}

/// Everything the Settings window stages. Values are copied in when the window
/// opens and written back only on Save — the same semantics the old
/// per-feature windows had, now shared by every tab.
@MainActor
final class SettingsSession: ObservableObject {
    let model: SpeakerModel
    /// One live AppKit recorder per action; Save reads their staged shortcuts.
    let recorders: [HotKeyAction: ShortcutRecorderButton]

    struct SourceRow: Identifiable {
        let id: String
        let name: String
        var visible: Bool
    }

    @Published var ipText: String
    @Published var sourceRows: [SourceRow]
    @Published var presetValues: [String]        // "" = empty slot
    @Published var volumeStep: String
    @Published var showVolumeInMenuBar: Bool
    @Published var radioSelection: [String]      // station path, "" = empty
    @Published var stations: [SpeakerModel.RadioStation] = []
    @Published var stationsLoaded = false

    init(model: SpeakerModel) {
        self.model = model
        var recs: [HotKeyAction: ShortcutRecorderButton] = [:]
        for action in HotKeyAction.allCases {
            let button = ShortcutRecorderButton()
            button.configure(initial: ShortcutStore.shortcut(action))
            recs[action] = button
        }
        recorders = recs
        ipText = model.speakerIP
        sourceRows = model.orderedSources.map {
            SourceRow(id: $0.id, name: $0.name,
                      visible: !model.hiddenSources.contains($0.id))
        }
        presetValues = model.presetSlots.map { $0 > 0 ? String($0) : "" }
        volumeStep = String(ShortcutStore.volumeStep)
        showVolumeInMenuBar = model.showVolumeInMenuBar
        radioSelection = model.radioSlots.map { $0?.path ?? "" }
    }

    /// Stations already in slots are merged in, so a saved preset survives
    /// dropping off the speaker's history.
    func loadStations() async {
        var found = await model.radioPickerStations()
        for slot in model.radioSlots.compactMap({ $0 })
        where !found.contains(where: { $0.path == slot.path }) {
            found.append(slot)
        }
        stations = found
        stationsLoaded = true
    }

    func save() {
        for (action, recorder) in recorders {
            ShortcutStore.setShortcut(action, recorder.shortcut)
        }
        if let step = Int(volumeStep) { ShortcutStore.setVolumeStep(step) }
        model.setPresetSlots(presetValues.map { Int($0) ?? 0 })
        model.showVolumeInMenuBar = showVolumeInMenuBar
        model.setSourceLayout(order: sourceRows.map(\.id),
                              hidden: Set(sourceRows.filter { !$0.visible }.map(\.id)))
        model.setRadioSlots(radioSelection.map { path in
            stations.first { $0.path == path }
        })
        model.setSpeakerIP(ipText)
    }
}

struct SettingsView: View {
    @ObservedObject var session: SettingsSession
    @ObservedObject var discovery: SpeakerDiscovery
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                speakerTab
                    .tabItem { Label("Speaker", systemImage: "hifispeaker.2") }
                sourcesTab
                    .tabItem { Label("Sources", systemImage: "arrow.up.arrow.down") }
                radioTab
                    .tabItem { Label("Radio", systemImage: "radio") }
                volumeTab
                    .tabItem { Label("Volume", systemImage: "speaker.wave.2") }
                hotkeysTab
                    .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            }
            .padding(12)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 540)
    }

    // MARK: tabs

    private var speakerTab: some View {
        Form {
            Section("Speakers on your network") {
                if discovery.found.isEmpty {
                    Text(discovery.isSearching ? "Searching…" : "No speakers found")
                        .foregroundStyle(.secondary)
                }
                ForEach(discovery.found) { found in
                    Button {
                        session.ipText = found.ip
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(found.name)
                                Text("\(found.model.isEmpty ? "KEF" : found.model) · \(found.ip)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if found.ip == session.ipText {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.appAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Address") {
                TextField("IP address or hostname", text: $session.ipText)
            }
        }
        .formStyle(.grouped)
        .onAppear { discovery.start() }
    }

    private var sourcesTab: some View {
        // A List, not a Form: grouped Forms don't support row dragging, and
        // drag-to-reorder beats the old type-a-number ordering.
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(session.sourceRows) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        Toggle("", isOn: visibleBinding(row.id))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { session.sourceRows.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered)
            Text("Drag to reorder — the panel shows inputs in this order.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
        .padding(16)
    }

    private func visibleBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { session.sourceRows.first(where: { $0.id == id })?.visible ?? true },
            set: { value in
                if let i = session.sourceRows.firstIndex(where: { $0.id == id }) {
                    session.sourceRows[i].visible = value
                }
            }
        )
    }

    private var radioTab: some View {
        Form {
            if !session.stationsLoaded {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading stations from the speaker…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ForEach(0..<SpeakerModel.radioSlotCount, id: \.self) { i in
                        Picker("Slot \(i + 1)", selection: $session.radioSelection[i]) {
                            Text("—").tag("")
                            ForEach(session.stations, id: \.path) { station in
                                Text(station.title).tag(station.path)
                            }
                        }
                    }
                } footer: {
                    Text("Stations come from the speaker's radio history and "
                         + "favourites — play one in KEF Connect once and it "
                         + "appears here.")
                }
            }
        }
        .formStyle(.grouped)
        .task { if !session.stationsLoaded { await session.loadStations() } }
    }

    private var volumeTab: some View {
        Form {
            Section("Presets · value and hotkey") {
                ForEach(Array(HotKeyAction.presetActions.enumerated()), id: \.offset) { i, action in
                    HStack(spacing: 8) {
                        Text("Preset \(i + 1)")
                            .frame(width: 64, alignment: .leading)
                        // Empty label + prompt, not TextField("—", …): inside a
                        // Form the title renders as a leading row label, which
                        // put a stray dash before every field.
                        TextField("", text: $session.presetValues[i], prompt: Text("—"))
                            .labelsHidden()
                            .multilineTextAlignment(.center)
                            .frame(width: 44)
                        Spacer()
                        recorder(for: action)
                    }
                }
            }
            Section {
                LabeledContent("Volume step") {
                    TextField("", text: $session.volumeStep)
                        .labelsHidden()
                        .multilineTextAlignment(.center)
                        .frame(width: 44)
                }
                Toggle("Show volume in menu bar", isOn: $session.showVolumeInMenuBar)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeysTab: some View {
        Form {
            Section {
                ForEach(HotKeyAction.mediaActions, id: \.self) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        recorder(for: action)
                    }
                }
            } footer: {
                Text("Click a shortcut, then press the key combo — Esc cancels, "
                     + "Delete clears. Hotkeys always control the speaker, even "
                     + "with the panel closed.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func recorder(for action: HotKeyAction) -> some View {
        if let button = session.recorders[action] {
            HStack(spacing: 4) {
                ShortcutRecorderView(button: button)
                    .frame(width: 140, height: 22)
                Button {
                    button.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onFinish: () -> Void
    private let session: SettingsSession

    /// `onFinish` re-registers the global hotkeys; it runs on every close
    /// (Save or Cancel) because they are suspended while the window is open so
    /// any combo can be re-recorded.
    init(model: SpeakerModel, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        self.session = SettingsSession(model: model)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "KEF Control Settings"
        super.init(window: win)
        win.delegate = self
        let view = SettingsView(
            session: session,
            discovery: model.discovery,
            onSave: { [weak self] in
                self?.session.save()
                self?.window?.close()
            },
            onCancel: { [weak self] in self?.window?.close() }
        )
        win.contentView = NSHostingView(rootView: view)
        win.setContentSize(NSSize(width: 560, height: 540))
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        ShortcutRecorderButton.endActiveRecording()
        session.model.discovery.stop()
        onFinish()
    }
}

// MARK: - App shell: custom status item + panel flush with the menu bar

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = SpeakerModel()
    private var statusItem: NSStatusItem!
    private var panel: KeyablePanel!
    private var hosting: NSHostingView<PlayerView>!
    private var barLabel: NSHostingView<MenuBarLabel>!
    private var stateSink: AnyCancellable?
    private var outsideClickMonitor: Any?
    private var lastPanelClose = Date.distantPast
    private var settingsWC: SettingsWindowController?


    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            barLabel = NSHostingView(rootView: MenuBarLabel(model: model))
            barLabel.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(barLabel)
            NSLayoutConstraint.activate([
                barLabel.topAnchor.constraint(equalTo: button.topAnchor),
                barLabel.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                barLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                barLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            ])
        }

        // A fixed-size transparent canvas. The panel never resizes, so the
        // hosting view's bounds always match the SwiftUI root: nothing can
        // overflow, and NSHostingView (which centres overflowing content, and
        // so slid every row) never gets the chance. The card, its rounded
        // corners and its shadow are all drawn — and animated — by SwiftUI.
        hosting = NSHostingView(rootView: PlayerView(model: model))
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: PanelMetrics.width + PanelMetrics.shadowMargin * 2,
                                height: PanelMetrics.canvasHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // SwiftUI draws it, so it tracks the card
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)  // always dark
        panel.contentView = hosting

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.panel.isVisible == true {  // esc
                self?.closePanel()
                return nil
            }
            return event
        }

        stateSink = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.stateChanged() }
        }
        loadPersistedAnchor()
        stateChanged()
        scheduleAnchorWarmup()
        applyHotKeys()
    }

    /// (Re)register all global hotkeys from the saved bindings. Carbon hot keys
    /// need no accessibility permission, unlike NSEvent global monitors.
    private func applyHotKeys() {
        let hk = HotKeyCenter.shared
        hk.register(.togglePanel, ShortcutStore.shortcut(.togglePanel)) { [weak self] in
            self?.togglePanel()
        }
        hk.register(.volumeUp, ShortcutStore.shortcut(.volumeUp)) { [weak self] in
            guard let m = self?.model, m.reachable, !m.isStandby else { return }
            m.setVolumeOnKEF(m.volume + ShortcutStore.volumeStep)
        }
        hk.register(.volumeDown, ShortcutStore.shortcut(.volumeDown)) { [weak self] in
            guard let m = self?.model, m.reachable, !m.isStandby else { return }
            m.setVolumeOnKEF(m.volume - ShortcutStore.volumeStep)
        }
        hk.register(.toggleMute, ShortcutStore.shortcut(.toggleMute)) { [weak self] in
            self?.model.toggleMute()
        }
        hk.register(.playPause, ShortcutStore.shortcut(.playPause)) { [weak self] in
            self?.model.control("pause")
        }
        hk.register(.next, ShortcutStore.shortcut(.next)) { [weak self] in
            self?.model.control("next")
        }
        hk.register(.previous, ShortcutStore.shortcut(.previous)) { [weak self] in
            self?.model.control("previous")
        }
        for action in HotKeyAction.presetActions {
            hk.register(action, ShortcutStore.shortcut(action)) { [weak self] in
                guard let m = self?.model, m.reachable, !m.isStandby,
                      let i = action.presetIndex, i < m.presetSlots.count else { return }
                let v = m.presetSlots[i]
                if v > 0 { m.setVolumeOnKEF(v) }
            }
        }
    }

    private func stateChanged() {
        statusItem.length = barLabel.fittingSize.width
        refreshAnchor()
        if panel.isVisible { positionPanel() }
    }

    /// Left click toggles the panel; right click shows a menu with Quit.
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            let menu = NSMenu()
            let settings = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self
            menu.addItem(settings)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit KEF Control",
                                  action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil  // so left clicks keep toggling the panel
        } else {
            togglePanel()
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openSettings() {
        // Suspend global hotkeys while the window is open so any combo —
        // including currently bound ones — can be re-recorded; onFinish
        // restores them from the saved bindings on close.
        HotKeyCenter.shared.suspend()
        settingsWC = SettingsWindowController(model: model) { [weak self] in self?.applyHotKeys() }
        NSApp.activate(ignoringOtherApps: true)
        settingsWC?.window?.center()
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc fileprivate func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else if Date().timeIntervalSince(lastPanelClose) > 0.25 {
            // The guard stops the click on the status item from reopening the
            // panel it just closed by stealing key status (resign → close → action).
            openPanel()
        }
    }

    private func openPanel() {
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        // The status button's window can lack screen geometry until the panel
        // is on screen (macOS hosts menu bar icons out-of-process); re-anchor.
        positionPanel()
        DispatchQueue.main.async { [weak self] in self?.positionPanel() }
        for delay in [0.05, 0.15, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.positionPanel()
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        lastPanelClose = Date()
        panel.orderOut(nil)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }


    private var cachedAnchor: (bottom: CGFloat, left: CGFloat)?

    private func refreshAnchor() {
        if let a = statusItemAnchor() {
            cachedAnchor = a
            UserDefaults.standard.set(a.bottom, forKey: "PanelAnchorBottom")
            UserDefaults.standard.set(a.left, forKey: "PanelAnchorLeft")
        }
    }

    /// Restore the last known-good icon position so a relaunch doesn't fall back
    /// to the screen corner before a fresh frame is available. Menu bar layout is
    /// stable across launches, so this is right the moment the app starts.
    private func loadPersistedAnchor() {
        let d = UserDefaults.standard
        if d.object(forKey: "PanelAnchorBottom") != nil {
            cachedAnchor = (d.double(forKey: "PanelAnchorBottom"), d.double(forKey: "PanelAnchorLeft"))
        }
    }

    /// Warm the cached anchor right after launch — the menu bar icon may not be
    /// placed yet (worse with several menu bar apps starting together), so the
    /// first open would otherwise fall back to the screen corner.
    private func scheduleAnchorWarmup() {
        for delay in [0.2, 0.6, 1.2, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshAnchor()
            }
        }
    }

    /// Where the status icon actually is: the in-process button window when it
    /// has valid geometry, else the window server's answer (the in-process
    /// window can report stale frames on macOS 27's out-of-process menu bar).
    private func statusItemAnchor() -> (bottom: CGFloat, left: CGFloat)? {
        // The proxy window sometimes reports an "unplaced" default slot flush
        // against the screen's right edge (x = screenWidth - iconWidth). A real
        // status icon is never there — Control Center and friends occupy that
        // zone — so treat it as unknown and keep the last known-good position.
        if let w = statusItem.button?.window, let s = w.screen,
           w.frame.width > 0, w.frame.minY > s.frame.midY,
           w.frame.maxX < s.frame.maxX - 1 {
            return (w.frame.minY, w.frame.minX)
        }
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owner == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == NSWindow.Level.statusBar.rawValue,
                  let boundsDict = info[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary),
                  bounds.width > 0 else { continue }
            // CG coordinates are top-left origin; convert to Cocoa
            return (primaryHeight - bounds.maxY, bounds.minX)
        }
        return nil
    }

    /// Park the fixed-size canvas so the card's top-left sits exactly on the
    /// status icon's anchor. The size never depends on the content, so nothing
    /// here moves while the presets row animates.
    private func positionPanel() {
        if let anchor = statusItemAnchor() { cachedAnchor = anchor }
        guard let fallbackScreen = NSScreen.main ?? NSScreen.screens.first else { return }
        let top = (cachedAnchor?.bottom ?? fallbackScreen.visibleFrame.maxY).rounded()
        let left = cachedAnchor?.left ?? (fallbackScreen.frame.maxX - PanelMetrics.width)
        let screen = NSScreen.screens.first {
            $0.frame.contains(CGPoint(x: left + 1, y: top - 1))
        } ?? fallbackScreen
        let cardX = max(screen.frame.minX, min(left, screen.frame.maxX - PanelMetrics.width))
        let height = min(PanelMetrics.canvasHeight, top - screen.frame.minY)
        panel.setFrame(
            NSRect(x: (cardX - PanelMetrics.shadowMargin).rounded(),
                   y: (top - height).rounded(),
                   width: PanelMetrics.width + PanelMetrics.shadowMargin * 2,
                   height: height.rounded()),
            display: true
        )
    }
}

@main
struct KEFMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
