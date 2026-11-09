import Foundation
import Testing

// W-251: `TaiwanDisplay` is an `ObservableObject` so the app runs on iOS 16, and a view only redraws
// when the converter arrives if it holds the object itself. Pinned by reading the app's source, the
// way `FavoriteAppWiringTests` pins its rules: the compiler cannot see a forgotten subscription.

@Test func everyViewThatCallsZhTWRedrawsWhenTheConverterArrives() throws {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("WebHTVApp/Sources")
    let header = try NSRegularExpression(pattern: #"^(?:private )?struct (\w+): View \{$"#, options: .anchorsMatchLines)
    var checked = 0
    for file in ["WebHTVApp.swift", "LiveTVView.swift"] {
        let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
        for match in header.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let start = try #require(Range(match.range, in: source))
            // A top-level declaration ends at the first closing brace in the first column.
            let end = source[start.upperBound...].range(of: "\n}\n")?.upperBound ?? source.endIndex
            let body = source[start.lowerBound..<end]
            guard body.contains("zhTW(") || body.contains("Text(zhTW:") else { continue }
            let name = String(source[try #require(Range(match.range(at: 1), in: source))])
            #expect(body.contains("@ObservedObject private var displayModel = TaiwanDisplay.shared"),
                    "\(file): \(name) calls zhTW but does not observe TaiwanDisplay")
            checked += 1
        }
    }
    #expect(checked >= 20)
}
