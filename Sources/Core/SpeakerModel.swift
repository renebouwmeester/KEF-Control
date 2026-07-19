// Observable speaker state: polling, now-playing, volume, EQ profiles, radio
// presets. Platform-neutral — artwork goes through PlatformImage (Platform.swift).
import SwiftUI
import Combine

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
    @Published var artwork: PlatformImage?
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
           let image = PlatformImage(data: data) {
            artwork = image
            artworkURL = url
            panelColor = dominantDarkTint(from: image) ?? Color(white: 0.13)
        } else {
            // leave artworkURL unset so the next poll retries
            artworkURL = nil
            if artwork != nil { artwork = nil }
            panelColor = Color(white: 0.13)
        }
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
