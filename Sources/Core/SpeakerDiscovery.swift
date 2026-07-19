// Bonjour discovery of KEF speakers. NetService works on iOS too; the
// NSBonjourServices plist keys are already in Info.plist.
import Foundation
import Combine

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
