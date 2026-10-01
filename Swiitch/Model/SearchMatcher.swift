import Foundation

/// Ranks switcher candidates for a typed query. Every query word must match either the app
/// name or the window title of the same candidate (so words found only in different
/// windows never combine), as before; what is new is a score per word so the list can be
/// ordered by how well it matches, with recency as the tiebreaker, plus the matched
/// character ranges for highlighting.
///
/// Per word, the best of: prefix of the field (100), start of a word inside it (80), any
/// substring (60), or, for words of two or more characters, an in-order subsequence
/// (`vsc` → Visual Studio Code, `gcal` → Google Calendar) scored below every substring
/// match and higher the more of its characters land on word starts.
enum SearchMatcher {
    struct FieldMatch: Equatable {
        let score: Int
        /// Character offsets into the original field, for highlighting.
        let ranges: [Range<Int>]
    }

    struct Match: Equatable {
        let score: Int
        let appRanges: [Range<Int>]
        let titleRanges: [Range<Int>]
    }

    static let prefixScore = 100
    static let wordStartScore = 80
    static let substringScore = 60
    static let fuzzyBaseScore = 30
    static let fuzzyWordStartBonus = 8
    static let fuzzyMaximumScore = 59

    /// Case- and diacritic-folded characters, one entry per original character so offsets
    /// map straight back for highlighting.
    static func fold(_ text: String) -> [String] {
        text.map { String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
    }

    /// Case folding can expand a character (ß → ss). Match the expanded sequence but
    /// keep a map back to the original graphemes so highlights never shift or split them.
    private struct FoldedField {
        let characters: [String]
        let originalOffsets: [Int]

        init(_ text: String) {
            let parts = fold(text)
            characters = parts.flatMap { $0.map(String.init) }
            originalOffsets = parts.enumerated().flatMap { offset, part in part.map { _ in offset } }
        }

        func originalRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
            merged(ranges.map { originalOffsets[$0.lowerBound]..<(originalOffsets[$0.upperBound - 1] + 1) })
        }
    }

    static func match(terms: [Substring], appName: String, title: String?) -> Match? {
        match(foldedTerms: terms.map { fold(String($0)).flatMap { $0.map(String.init) } },
              app: FoldedField(appName), titleFolded: title.map(FoldedField.init))
    }

    /// Owned by one switcher model and cleared when its app snapshot changes. Field
    /// normalization is shared across keystrokes, and each query/candidate is scored
    /// only once even when selection, layout and highlighting read it repeatedly.
    final class Cache {
        private struct Candidate: Hashable {
            let appName: String
            let title: String?
        }
        private struct Result { let match: Match? }
        private var fields: [String: FoldedField] = [:]
        private var results: [Candidate: Result] = [:]
        private var query: String?
        private var foldedTerms: [[String]] = []
        private var locale = Locale.current

        func reset() {
            fields.removeAll()
            results.removeAll()
            query = nil
            foldedTerms = []
            locale = .current
        }

        func match(query: String, appName: String, title: String?) -> Match? {
            if locale != .current { reset() }
            if self.query != query {
                self.query = query
                foldedTerms = query.split(whereSeparator: \.isWhitespace).map {
                    fold(String($0)).flatMap { $0.map(String.init) }
                }
                results.removeAll(keepingCapacity: true)
            }
            let candidate = Candidate(appName: appName, title: title)
            if let result = results[candidate] { return result.match }
            let result = SearchMatcher.match(foldedTerms: foldedTerms, app: field(appName),
                                             titleFolded: title.map(field))
            results[candidate] = Result(match: result)
            return result
        }

        private func field(_ text: String) -> FoldedField {
            if let field = fields[text] { return field }
            let field = FoldedField(text)
            fields[text] = field
            return field
        }
    }

    private static func match(foldedTerms: [[String]], app: FoldedField, titleFolded: FoldedField?) -> Match? {
        guard !foldedTerms.isEmpty else { return Match(score: 0, appRanges: [], titleRanges: []) }
        var score = 0
        var appRanges: [Range<Int>] = []
        var titleRanges: [Range<Int>] = []
        for folded in foldedTerms {
            let inApp = match(term: folded, in: app.characters)
            let inTitle = titleFolded.flatMap { match(term: folded, in: $0.characters) }
            switch (inApp, inTitle) {
            case (nil, nil):
                return nil
            case let (some?, nil):
                score += some.score; appRanges += some.ranges
            case let (nil, some?):
                score += some.score; titleRanges += some.ranges
            case let (a?, t?):
                if a.score >= t.score { score += a.score; appRanges += a.ranges }
                else { score += t.score; titleRanges += t.ranges }
            }
        }
        return Match(score: score, appRanges: app.originalRanges(appRanges),
                     titleRanges: titleFolded?.originalRanges(titleRanges) ?? [])
    }

    /// Stable sort by descending score: equal scores keep their incoming (recency) order.
    static func ranked<Item>(_ items: [Item], terms: [Substring],
                             fields: (Item) -> (appName: String, title: String?)) -> [Item] {
        guard !terms.isEmpty else { return items }
        return ranked(items) { item in
            let field = fields(item)
            return match(terms: terms, appName: field.appName, title: field.title)
        }
    }

    static func ranked<Item>(_ items: [Item], match: (Item) -> Match?) -> [Item] {
        let scored: [(index: Int, item: Item, score: Int)] = items.enumerated().compactMap { index, item in
            guard let match = match(item) else { return nil }
            return (index, item, match.score)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.item)
    }

    // MARK: - Single term against one field

    static func match(term: [String], in field: [String]) -> FieldMatch? {
        guard !term.isEmpty, !field.isEmpty, term.count <= field.count else { return nil }
        if let substring = substringMatch(term: term, in: field) { return substring }
        guard term.count >= 2 else { return nil }
        return fuzzyMatch(term: term, in: field)
    }

    private static func substringMatch(term: [String], in field: [String]) -> FieldMatch? {
        var firstAnywhere: Int?
        for start in 0...(field.count - term.count) {
            guard field[start..<(start + term.count)].elementsEqual(term) else { continue }
            if start == 0 { return FieldMatch(score: prefixScore, ranges: [0..<term.count]) }
            if isWordStart(field, at: start) { return FieldMatch(score: wordStartScore, ranges: [start..<(start + term.count)]) }
            if firstAnywhere == nil { firstAnywhere = start }
        }
        guard let start = firstAnywhere else { return nil }
        return FieldMatch(score: substringScore, ranges: [start..<(start + term.count)])
    }

    /// Greedy in-order subsequence that prefers landing each character on a word start.
    private static func fuzzyMatch(term: [String], in field: [String]) -> FieldMatch? {
        // Find the latest viable position for every character in one reverse pass.
        // A preferred word start may only be chosen if the remaining suffix still fits.
        var latest = [Int](repeating: 0, count: term.count)
        var end = field.count
        for index in term.indices.reversed() {
            var found: Int?
            while end > 0 {
                end -= 1
                if field[end] == term[index] { found = end; break }
            }
            guard let found else { return nil }
            latest[index] = found
        }
        var position = 0
        var offsets: [Int] = []
        var wordStartHits = 0
        for (index, character) in term.enumerated() {
            var found: Int?
            var scan = position
            while scan <= latest[index] {
                // Keep looking only a little further for a word-start occurrence.
                if let found, scan - found > 24 { break }
                if field[scan] == character {
                    if isWordStart(field, at: scan) { found = scan; break }
                    if found == nil { found = scan }
                }
                scan += 1
            }
            guard let found else { return nil }
            if isWordStart(field, at: found) { wordStartHits += 1 }
            offsets.append(found)
            position = found + 1
        }
        // An acronym (every character on a word start) is penalized for nothing; otherwise
        // the characters skipped inside the matched span count against it.
        let gaps = wordStartHits == term.count ? 0 : (offsets.last! - offsets.first! + 1) - term.count
        let score = min(fuzzyMaximumScore, max(1, fuzzyBaseScore + wordStartHits * fuzzyWordStartBonus - min(15, gaps)))
        return FieldMatch(score: score, ranges: merged(offsets.map { $0..<($0 + 1) }))
    }

    static func isWordStart(_ field: [String], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = field[index - 1]
        return previous.unicodeScalars.allSatisfy { !CharacterSet.alphanumerics.contains($0) }
    }

    /// Coalesces overlapping or touching ranges and sorts them, so highlighting is a single pass.
    static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<Int>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
