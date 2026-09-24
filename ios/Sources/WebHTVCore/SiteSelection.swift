import Foundation

public enum SiteSelection {
    public static func token(for id: Site.ID) -> String {
        Data(id.utf8).base64EncodedString()
    }

    static func resolveIdentity(_ storedID: Site.ID, in sites: [Site]) -> Site.ID? {
        if let exact = sites.first(where: { $0.id == storedID }) { return exact.id }
        guard let separator = storedID.firstIndex(of: "\u{0}") else { return nil }
        let key = String(storedID[..<separator])
        let extend = String(storedID[storedID.index(after: separator)...])
        let canonical = canonicalStructuredExtend(extend)
        return sites.first {
            $0.key == key &&
            $0.hasStructuredExtIdentity &&
            $0.id == $0.key + "\u{0}" + canonical
        }?.id
    }

    public static func resolve(_ stored: String?, in sites: [Site]) -> Site.ID? {
        guard let stored, !stored.isEmpty else { return nil }
        if let data = Data(base64Encoded: stored),
           let id = String(data: data, encoding: .utf8) {
            if let match = resolveIdentity(id, in: sites) { return match }
            // IOS-POC-19: the site's `ext` changed but its key did not. A key the configuration
            // uses once still names one site; a repeated one would be a guess.
            if let separator = id.firstIndex(of: "\u{0}") {
                let key = String(id[..<separator])
                let named = sites.filter { $0.key == key }
                if named.count == 1 { return named[0].id }
            }
        }
        return sites.first { $0.key == stored }?.id
    }

    /// IOS-POC-19 — which site a configuration opens on: the one remembered for its source, else
    /// the one already showing if the configuration still has it, else its first.
    public static func choose(remembered: String?, current: Site.ID?, in sites: [Site]) -> Site.ID? {
        resolve(remembered, in: sites) ?? sites.first { $0.id == current }?.id ?? sites.first?.id
    }

    static func canonicalStructuredExtend(_ extend: String) -> String {
        guard let first = extend.first, first == "{" || first == "[" else { return extend }
        guard let data = extend.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let stable = try? JSONSerialization.data(
                  withJSONObject: object, options: [.sortedKeys]
              )
        else { return extend }
        return String(decoding: stable, as: UTF8.self)
    }
}
