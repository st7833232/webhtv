import Foundation
#if canImport(Security)
import Security
#endif

/// IOS-POC-45C — the keys the viewer gave the API subtitle providers.
///
/// The viewer's own, typed into 設定 › 線上字幕來源: none ships with the app, the repository, a
/// test or a log. Kept in the Keychain, readable on this device only after its first unlock, and
/// never shown back: the settings page says whether one is set, not what it is.
public enum SubtitleCredentialKey: String, CaseIterable, Sendable {
    case openSubtitlesAPIKey = "opensubtitles.api-key"
    case assrtToken = "assrt.token"
}

public protocol SubtitleCredentialStore: Sendable {
    func value(for key: SubtitleCredentialKey) -> String?
    /// Nil or blank removes it. False when the store refused the change.
    @discardableResult
    func setValue(_ value: String?, for key: SubtitleCredentialKey) -> Bool
}

public struct KeychainSubtitleCredentials: SubtitleCredentialStore {
    static let service = "com.webhtv.ios.subtitle-credentials"

    public init() {}

    public func value(for key: SubtitleCredentialKey) -> String? {
        #if canImport(Security)
        var query = Self.item(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
        #else
        return nil
        #endif
    }

    @discardableResult
    public func setValue(_ value: String?, for key: SubtitleCredentialKey) -> Bool {
        #if canImport(Security)
        let removed = SecItemDelete(Self.item(key) as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else { return false }
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return true }
        var item = Self.item(key)
        item[kSecValueData as String] = Data(text.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }

    #if canImport(Security)
    private static func item(_ key: SubtitleCredentialKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }
    #endif
}

/// Every provider the subtitle panel offers, in the panel's order. Subtitle Cat stays first and
/// so stays the default for a viewer who has set up nothing; 射手網's website (IOS-POC-45G) needs
/// no key and comes next; a provider without its key is listed as not set up. Read once per
/// playback session.
public enum OnlineSubtitleProviders {
    public static func make(credentials: any SubtitleCredentialStore = KeychainSubtitleCredentials(),
                            userAgent: String = OpenSubtitlesProvider.defaultUserAgent) -> [any SubtitleProvider] {
        [SubtitleCatProvider(),
         AssrtWebProvider(),
         OpenSubtitlesProvider(apiKey: credentials.value(for: .openSubtitlesAPIKey), userAgent: userAgent),
         AssrtProvider(token: credentials.value(for: .assrtToken))]
    }
}
