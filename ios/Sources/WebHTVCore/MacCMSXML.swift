import Foundation

/// Decodes a MacCMS XML payload (`type` 0) into the same `CMSResponse` the JSON sites produce, so
/// everything downstream — category grouping, pagination, `Vod.flags`, `Episode.parse`, the player —
/// cannot tell the two apart. Android does this with SimpleXML in `Result.fromXml`
/// (`bean/Result.java:121-127`); `XMLParser` is Foundation's equivalent and needs no dependency.
/// `XMLDocument` would be simpler to read but does not exist on iOS.
///
/// The shape, confirmed against both configured endpoints:
///
///     <rss><list page="1" …>
///       <video><id>1</id><name><![CDATA[…]]></name><pic>…</pic><note><![CDATA[…]]></note>
///         <dl><dd flag="m3u8"><![CDATA[第01集$https://…#第02集$https://…]]></dd></dl>
///       </video>
///     </list><class><ty id="1">国产动漫</ty></class></rss>
final class MacCMSXMLDecoder: NSObject, XMLParserDelegate {
    private var classes = [CMSCategory]()
    private var list = [Vod]()

    /// Character data for the element currently open. CDATA and plain text both land here.
    private var text = ""
    private var categoryID = ""

    private var inVideo = false
    private var id = ""
    private var name = ""
    private var picture = ""
    private var remarks = ""
    private var flags = [String]()
    private var urls = [String]()
    private var flag = ""

    /// A payload that cannot be parsed yields an empty response, matching `Result.fromXml`'s catch.
    static func decode(_ data: Data) -> CMSResponse {
        let decoder = MacCMSXMLDecoder()
        let parser = XMLParser(data: data)
        parser.delegate = decoder
        guard parser.parse() else { return CMSResponse(classes: [], list: []) }
        return CMSResponse(classes: decoder.classes, list: decoder.list)
    }

    func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        text = ""
        switch element {
        case "video":
            inVideo = true
            id = ""
            name = ""
            picture = ""
            remarks = ""
            flags = []
            urls = []
        case "ty":
            categoryID = attributes["id"] ?? ""
        case "dd":
            flag = attributes["flag"] ?? ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        text += String(decoding: block, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "ty":
            classes.append(CMSCategory(id: categoryID, name: value, parentID: 0))
        case "id" where inVideo:
            id = value
        case "name" where inVideo:
            name = value
        case "pic" where inVideo:
            picture = value
        case "note" where inVideo:
            remarks = value
        case "dd" where inVideo:
            // One <dd> per flag; Vod.flags zips the two "$$$"-joined lists back together.
            flags.append(flag)
            urls.append(value)
        case "video":
            list.append(Vod(
                id: id, name: name, picture: picture, remarks: remarks,
                playFrom: flags.joined(separator: "$$$"),
                playURL: urls.joined(separator: "$$$")
            ))
            inVideo = false
        default:
            // last, tid, dt, lang, area, year, state, actor, director, des: nothing downstream
            // reads them, so they are parsed past rather than carried.
            break
        }
        text = ""
    }
}
