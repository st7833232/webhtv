import Foundation

/// One entry of the configuration's `lives` (IOS-POC-59 U1). Android's `Live.java`, decoded field
/// by field so a wrong type costs that field, not the live (Android drops the whole live, N-2).
public struct LiveSource: Decodable, Equatable, Sendable {
    public var name: String
    public var url: String
    /// Missing or null is 0; an unreadable value is nil, which keeps the live out of `isURLList`.
    public var type: Int?
    public var api: String
    public var ua: String?
    public var origin: String?
    public var referer: String?
    public var header: [String: String]
    public var timeout: Int?
    public var pass: Bool
    public var epg: String?
    public var playerType: Int?

    public init(name: String, url: String, ua: String? = nil, origin: String? = nil, referer: String? = nil,
                header: [String: String] = [:], timeout: Int? = nil, pass: Bool = false, epg: String? = nil) {
        self.name = name
        self.url = url
        type = 0
        api = ""
        self.ua = ua
        self.origin = origin
        self.referer = referer
        self.header = header
        self.timeout = timeout
        self.pass = pass
        self.epg = epg
        playerType = nil
    }

    enum CodingKeys: String, CodingKey {
        case name, url, type, api, ua, origin, referer, header, timeout, pass, epg, playerType
    }

    struct MissingField: Error {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            ((try? values.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        }
        // Gson reads an Integer from a number or a numeric string.
        func integer(_ key: CodingKeys) -> Int? {
            if let value = (try? values.decodeIfPresent(Int.self, forKey: key)) ?? nil { return value }
            return text(key).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        guard let name = text(.name), let url = text(.url) else { throw MissingField() }
        self.name = name
        self.url = url
        let typeIsAbsent = (try? values.decodeNil(forKey: .type)) ?? true
        type = typeIsAbsent ? 0 : integer(.type)
        api = text(.api) ?? ""
        ua = text(.ua)
        origin = text(.origin)
        referer = text(.referer)
        // A header object keeps its string values; anything else is no header.
        header = ((try? values.decodeIfPresent([String: Lenient<String>].self, forKey: .header)) ?? nil)?
            .compactMapValues(\.value) ?? [:]
        timeout = integer(.timeout)
        // Gson's boolean: a string is Boolean.parseBoolean, a number is != 0 (N-1).
        if let value = (try? values.decodeIfPresent(Bool.self, forKey: .pass)) ?? nil {
            pass = value
        } else if let value = (try? values.decodeIfPresent(Int.self, forKey: .pass)) ?? nil {
            pass = value != 0
        } else {
            pass = text(.pass)?.lowercased() == "true"
        }
        epg = text(.epg)
        playerType = integer(.playerType)
    }

    /// A list fetched from `url`. A csp `api` live or another type is not one L1 can show.
    public var isURLList: Bool { type == 0 && api.isEmpty }

    /// Seconds one line may take to start: the source's `timeout`, but never under 10 (D§6.3.3).
    /// shortcut: no upper bound (a `timeout` of 600 waits ten minutes); U3 revisits it with real use.
    public var lineBudget: Int { max(timeout ?? 15, 10) }

    /// What the list itself is fetched with: `Live.getHeaders()`.
    public var listHeaders: [String: String] {
        var headers = header
        LiveHeaders.set(&headers, "User-Agent", ua)
        LiveHeaders.set(&headers, "Origin", origin)
        LiveHeaders.set(&headers, "Referer", referer)
        return headers
    }
}

enum LiveHeaders {
    /// Sets one header, replacing any other spelling of its name (Android's map is case-sensitive,
    /// which would send both `user-agent` and `User-Agent`).
    static func set(_ headers: inout [String: String], _ name: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        for key in headers.keys where key.caseInsensitiveCompare(name) == .orderedSame { headers[key] = nil }
        headers[name] = value
    }
}
