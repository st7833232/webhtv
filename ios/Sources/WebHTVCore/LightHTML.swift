import Foundation

/// IOS-POC-45 — the smallest HTML reader the online subtitle providers need.
///
/// **Why not a dependency.** Core has none, and a provider only needs elements, attributes and
/// text: which links a page has, and what text sits around each. SwiftSoup would be the whole
/// HTML5 tree-construction algorithm for that, and WebKit's parser lives on the main thread.
///
/// **Tolerant, not strict.** Real pages are not well-formed, so: void elements never open,
/// `<script>`/`<style>` bodies are skipped whole, a comment or doctype is skipped, an end tag
/// with no matching open element is ignored, an end tag closes everything opened inside it, and
/// the usual implied ends are applied (a new `<li>`, `<tr>`, `<td>`, `<option>` or `<p>` closes
/// the previous one, a nested `<a>` closes the open one). Nothing throws: any input gives a tree.
enum LightHTML {
    final class Element {
        let name: String
        let attributes: [String: String]
        fileprivate(set) var children = [Node]()
        fileprivate(set) weak var parent: Element?

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        func attribute(_ name: String) -> String? { attributes[name] }

        /// Every element below this one, in document order.
        var descendants: [Element] {
            var result = [Element]()
            func walk(_ element: Element) {
                for case .element(let child) in element.children {
                    result.append(child)
                    walk(child)
                }
            }
            walk(self)
            return result
        }

        /// This element's text, whitespace collapsed to single spaces.
        var text: String {
            var parts = [String]()
            func walk(_ element: Element) {
                for child in element.children {
                    switch child {
                    case .text(let value): parts.append(value)
                    case .element(let element):
                        if element.name == "br" { parts.append(" ") }
                        walk(element)
                    }
                }
            }
            walk(self)
            return parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        /// Ancestors, nearest first.
        var ancestors: [Element] {
            var result = [Element]()
            var next = parent
            while let current = next {
                result.append(current)
                next = current.parent
            }
            return result
        }
    }

    enum Node {
        case element(Element)
        case text(String)
    }

    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source",
        "track", "wbr",
    ]
    static let rawTextElements: Set<String> = ["script", "style", "textarea", "noscript"]

    /// The document as a tree under a synthetic `#root`.
    static func parse(_ html: String) -> Element {
        let root = Element(name: "#root", attributes: [:])
        var stack = [root]
        let bytes = Array(html.utf8)
        var index = 0
        var textStart = 0

        func flushText(until end: Int) {
            guard end > textStart else { return }
            let raw = String(decoding: bytes[textStart..<end], as: UTF8.self)
            let decoded = decodeEntities(raw)
            if !decoded.allSatisfy(\.isWhitespace) {
                append(.text(decoded), to: stack[stack.count - 1])
            }
        }

        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<"), index + 1 < bytes.count else {
                index += 1
                continue
            }
            let next = bytes[index + 1]
            if next == UInt8(ascii: "!") || next == UInt8(ascii: "?") {
                flushText(until: index)
                if starts(bytes, at: index, with: "<!--") {
                    index = find(bytes, "-->", from: index + 4).map { $0 + 3 } ?? bytes.count
                } else {
                    index = find(bytes, ">", from: index + 2).map { $0 + 1 } ?? bytes.count
                }
                textStart = index
                continue
            }
            let isEnd = next == UInt8(ascii: "/")
            let nameStart = index + (isEnd ? 2 : 1)
            guard nameStart < bytes.count, isLetter(bytes[nameStart]) else {
                index += 1   // a bare "<" in text
                continue
            }
            flushText(until: index)
            guard let tag = readTag(bytes, from: nameStart) else {
                textStart = index
                index = bytes.count
                break
            }
            index = tag.end
            textStart = index
            if isEnd {
                close(tag.name, in: &stack)
                continue
            }
            impliedEnds(before: tag.name, in: &stack)
            let element = Element(name: tag.name, attributes: tag.attributes)
            append(.element(element), to: stack[stack.count - 1])
            if voidElements.contains(tag.name) || tag.selfClosing { continue }
            if rawTextElements.contains(tag.name) {
                // Skipped whole: a script's "<a href=…>" is not a link on the page.
                let closing = "</\(tag.name)"
                index = findCaseInsensitive(bytes, closing, from: index) ?? bytes.count
                textStart = index
                continue
            }
            stack.append(element)
        }
        flushText(until: bytes.count)
        return root
    }

    // MARK: Tree building

    private static func append(_ node: Node, to parent: Element) {
        if case .element(let child) = node { child.parent = parent }
        parent.children.append(node)
    }

    /// An end tag closes the nearest open element of its name and everything opened inside it.
    /// With no such element open it is ignored, so a stray `</div>` cannot empty the stack.
    private static func close(_ name: String, in stack: inout [Element]) {
        guard let position = stack.lastIndex(where: { $0.name == name }), position > 0 else { return }
        stack.removeSubrange(position...)
    }

    /// The implied ends real pages rely on, within the nearest enclosing boundary.
    private static func impliedEnds(before name: String, in stack: inout [Element]) {
        let closes: Set<String>
        let boundary: Set<String>
        switch name {
        case "li": closes = ["li"]; boundary = ["ul", "ol", "table"]
        case "tr": closes = ["tr", "td", "th"]; boundary = ["table", "tbody", "thead", "tfoot"]
        case "td", "th": closes = ["td", "th"]; boundary = ["tr", "table"]
        case "option": closes = ["option"]; boundary = ["select", "datalist"]
        case "dt", "dd": closes = ["dt", "dd"]; boundary = ["dl"]
        case "a": closes = ["a"]; boundary = ["table", "td", "th", "li", "div"]
        case "p", "div", "table", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6":
            // A block opening closes an open paragraph, as browsers do.
            if stack.last?.name == "p" { stack.removeLast() }
            return
        default: return
        }
        for position in stride(from: stack.count - 1, to: 0, by: -1) {
            let open = stack[position].name
            if boundary.contains(open) { return }
            if closes.contains(open) {
                stack.removeSubrange(position...)
                return
            }
        }
    }

    // MARK: Tokenizing

    private struct Tag {
        let name: String
        let attributes: [String: String]
        let selfClosing: Bool
        let end: Int
    }

    /// A start or end tag from its name to its `>`. Attribute values may be double-quoted,
    /// single-quoted or bare; a quoted value may contain `>`.
    private static func readTag(_ bytes: [UInt8], from start: Int) -> Tag? {
        var index = start
        while index < bytes.count, isNameByte(bytes[index]) { index += 1 }
        let name = String(decoding: bytes[start..<index], as: UTF8.self).lowercased()
        var attributes = [String: String]()
        var selfClosing = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: ">") {
                return Tag(name: name, attributes: attributes, selfClosing: selfClosing, end: index + 1)
            }
            if isSpace(byte) { index += 1; continue }
            if byte == UInt8(ascii: "/") { selfClosing = true; index += 1; continue }
            selfClosing = false
            let keyStart = index
            while index < bytes.count, !isSpace(bytes[index]),
                  ![UInt8(ascii: "="), UInt8(ascii: ">"), UInt8(ascii: "/")].contains(bytes[index]) {
                index += 1
            }
            guard index > keyStart else { index += 1; continue }
            let key = String(decoding: bytes[keyStart..<index], as: UTF8.self).lowercased()
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            var value = ""
            if index < bytes.count, bytes[index] == UInt8(ascii: "=") {
                index += 1
                while index < bytes.count, isSpace(bytes[index]) { index += 1 }
                if index < bytes.count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
                    let quote = bytes[index]
                    let valueStart = index + 1
                    guard let close = bytes[valueStart...].firstIndex(of: quote) else { return nil }
                    value = String(decoding: bytes[valueStart..<close], as: UTF8.self)
                    index = close + 1
                } else {
                    let valueStart = index
                    while index < bytes.count, !isSpace(bytes[index]), bytes[index] != UInt8(ascii: ">") {
                        index += 1
                    }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                }
            }
            if attributes[key] == nil { attributes[key] = decodeEntities(value) }
        }
        return nil
    }

    /// The named entities pages use for text and URLs, and every numeric one.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "#39": "'",
        ]
        var result = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let after = rest[rest.index(after: ampersand)...]
            guard let semicolon = after.prefix(10).firstIndex(of: ";") else {
                result += "&"
                rest = after
                continue
            }
            let entity = String(after[..<semicolon])
            var replacement: String?
            if let value = named[entity.lowercased()] {
                replacement = value
            } else if entity.hasPrefix("#") {
                let digits = entity.dropFirst()
                let scalar = digits.first == "x" || digits.first == "X"
                    ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                replacement = scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            }
            if let replacement {
                result += replacement
                rest = after[after.index(after: semicolon)...]
            } else {
                result += "&"
                rest = after
            }
        }
        result += rest
        return result
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte | 0x20)
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ":")
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    private static func starts(_ bytes: [UInt8], at index: Int, with text: String) -> Bool {
        let needle = Array(text.utf8)
        guard index + needle.count <= bytes.count else { return false }
        return Array(bytes[index..<index + needle.count]) == needle
    }

    private static func find(_ bytes: [UInt8], _ text: String, from start: Int) -> Int? {
        let needle = Array(text.utf8)
        guard !needle.isEmpty, start <= bytes.count - needle.count else { return nil }
        var index = start
        while index <= bytes.count - needle.count {
            if bytes[index] == needle[0], Array(bytes[index..<index + needle.count]) == needle { return index }
            index += 1
        }
        return nil
    }

    private static func findCaseInsensitive(_ bytes: [UInt8], _ text: String, from start: Int) -> Int? {
        let needle = Array(text.lowercased().utf8)
        guard !needle.isEmpty, start <= bytes.count - needle.count else { return nil }
        var index = start
        while index <= bytes.count - needle.count {
            var matched = true
            for offset in 0..<needle.count {
                let byte = bytes[index + offset]
                let lowered = isLetter(byte) ? byte | 0x20 : byte
                if lowered != needle[offset] { matched = false; break }
            }
            if matched { return index }
            index += 1
        }
        return nil
    }
}
