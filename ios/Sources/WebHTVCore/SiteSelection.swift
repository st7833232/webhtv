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
           let id = String(data: data, encoding: .utf8),
           let match = resolveIdentity(id, in: sites) {
            return match
        }
        return sites.first { $0.key == stored }?.id
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
