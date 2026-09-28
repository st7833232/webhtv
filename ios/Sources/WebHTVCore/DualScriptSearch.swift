import Foundation

/// IOS-POC-33: a search sends the keyword in the Simplified form the sources index (IOS-POC-20,
/// `TraditionalSimplified`) and, when it differs, as typed, so a site whose titles are Traditional
/// finds them too. Each site's answers are merged before they are shown. The CMS sites' provide API
/// matches `vod_name LIKE '%wd%'` code point by code point (maccms10 `Provide.php:70-71`), so the two
/// forms find different titles. The shape follows MacCMS's own 繁简同搜
/// (`OpenccConverter::searchVariants`): send only the forms that differ, and keep the union.
///
/// A Simplified, Latin or numeric keyword has one form, so for it nothing changes: one call, and the
/// list exactly as the source sent it. A site's forms are asked one after the other, never at once:
/// a spider runs one call at a time anyway, and two first calls at once could build two sessions.
public enum DualScriptSearch {
    /// The Simplified form first, so what was found before stays first, then the keyword as typed
    /// when that is different.
    public static func forms(of keyword: String) -> [String] {
        let simplified = TraditionalSimplified.toSimplified(keyword)
        return simplified == keyword ? [keyword] : [simplified, keyword]
    }

    /// Page 1 of every form, one after the other, merged: the first answer's list exactly as the
    /// source sent it, then the titles only a later form found, by `vod.id` within this one site.
    /// One form answering is enough; the first error is thrown only when every form failed. No later
    /// form is asked once the task is cancelled. `page` is the first answer, for what a response
    /// carries besides its titles.
    ///
    /// `cursor` is where 載入更多 starts: a form that answered asks for page 2, a form cut off by a
    /// cancel (or never asked) asks for page 1, a form that failed is not asked again, and a later form
    /// whose page 1 added nothing is not paged either, since its pages would repeat the first form's.
    /// `progress` gets the merged list and that cursor after each form that answered, so a caller with
    /// a deadline can still show, and page on from, what arrived in time.
    public static func firstPage<Page: Sendable>(
        forms: [String],
        titles: @Sendable (Page) -> [Vod],
        progress: @Sendable (_ form: Int, _ merged: [Vod], _ cursor: Cursor) -> Void = { _, _, _ in },
        search: @Sendable (_ keyword: String) async throws -> Page
    ) async throws -> (page: Page, vods: [Vod], cursor: Cursor) {
        var answer: (page: Page, vods: [Vod])?
        var failure: (any Error)?
        var paged = [Cursor.Form]()
        var asked = 0
        for (index, form) in forms.enumerated() {
            if index > 0, Task.isCancelled { break }
            do {
                let page = try await search(form)
                asked = index + 1
                let vods: [Vod]
                if let previous = answer {
                    vods = previous.vods.merging(newTitlesFrom: titles(page))
                    if vods.count > previous.vods.count { paged.append(Cursor.Form(keyword: form, page: 2)) }
                    answer = (page: previous.page, vods: vods)
                } else {
                    vods = titles(page)
                    paged.append(Cursor.Form(keyword: form, page: 2))
                    answer = (page: page, vods: vods)
                }
                progress(index, vods, Cursor(pending: paged + unasked(forms.dropFirst(asked))))
            } catch {
                if failure == nil { failure = error }
                // Cut off rather than refused: 載入更多 asks this form again from page 1.
                if Task.isCancelled { break }
                asked = index + 1
            }
        }
        if let answer {
            return (page: answer.page, vods: answer.vods, cursor: Cursor(pending: paged + unasked(forms.dropFirst(asked))))
        }
        throw failure ?? CancellationError()
    }

    private static func unasked(_ forms: ArraySlice<String>) -> [Cursor.Form] {
        forms.map { Cursor.Form(keyword: $0, page: 1) }
    }

    /// The next page of every form still adding titles, one after the other, merged onto `shown`. A
    /// form whose page adds nothing (the end of its list, or a source that ignores the page number and
    /// repeats itself) or fails is not asked again; the others carry on. With one form this is the
    /// rule 載入更多 has always had.
    public static func nextPage(
        after shown: [Vod], cursor: Cursor,
        search: @Sendable (_ keyword: String, _ page: Int) async throws -> [Vod]
    ) async -> (vods: [Vod], cursor: Cursor) {
        var vods = shown
        var pending = [Cursor.Form]()
        for form in cursor.pending {
            guard !Task.isCancelled else {
                pending.append(form)
                continue
            }
            guard let page = try? await search(form.keyword, form.page) else { continue }
            let merged = vods.merging(newTitlesFrom: page)
            guard merged.count > vods.count else { continue }
            vods = merged
            pending.append(Cursor.Form(keyword: form.keyword, page: form.page + 1))
        }
        return (vods, Cursor(pending: pending))
    }

    /// Where one site's 載入更多 is: the page each form still adding titles asks for next.
    /// `firstPage` makes the first one.
    public struct Cursor: Sendable, Equatable {
        public struct Form: Sendable, Equatable {
            public let keyword: String
            public let page: Int
        }

        /// In the order the forms were first asked.
        public let pending: [Form]
        public var isFinished: Bool { pending.isEmpty }

        init(pending: [Form]) {
            self.pending = pending
        }
    }
}
