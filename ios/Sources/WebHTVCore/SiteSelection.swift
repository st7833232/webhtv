import Foundation

/// Remembering which source the viewer was last on.
///
/// This exists because `Site.id` **cannot be written to `UserDefaults` as-is**. The id is
/// `key + "\u{0}" + rawExtJSON`, and CFPreferences truncates a string at the NUL: measured on the
/// simulator, storing 薦片's id left `php_无水印资源` on disk — the key alone, nine characters, no
/// `ext`. Reading it back matched no site, so the app fell through to `sites.first` and always
/// reopened on the first source. The write looked fine and the read looked fine; only the stored
/// bytes showed it.
///
/// Base64 is what makes the round trip exact. It lives in core rather than in the app target so it
/// can be tested — the app target has no test host.
public enum SiteSelection {
    /// What to persist for a given site identity.
    public static func token(for id: Site.ID) -> String {
        Data(id.utf8).base64EncodedString()
    }

    /// The site a stored token refers to, or `nil` when nothing matches.
    ///
    /// Accepts the **legacy truncated form** as well: installs that ran before this fix hold a bare
    /// site key, so those are matched on `key`. That recovers the viewer's actual last source on the
    /// first launch after upgrading instead of silently resetting them to the top of the list. A
    /// duplicate key resolves to the first match, which is the best a truncated value can support —
    /// and it stops being ambiguous as soon as the next selection is written in the new form.
    public static func resolve(_ stored: String?, in sites: [Site]) -> Site.ID? {
        guard let stored, !stored.isEmpty else { return nil }
        if let data = Data(base64Encoded: stored), let id = String(data: data, encoding: .utf8),
           let match = sites.first(where: { $0.id == id }) {
            return match.id
        }
        return sites.first { $0.key == stored }?.id
    }
}
