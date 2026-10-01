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

    static func match(terms: [Substring], appName: String, title: String?) -> Match? {
        guard !terms.isEmpty else { return Match(score: 0, appRanges: [], titleRanges: []) }
        let app = fold(appName)
        let titleFolded = title.map(fold)
        var score = 0
        var appRanges: [Range<Int>] = []
        var titleRanges: [Range<Int>] = []
        for term in terms {
            let folded = fold(String(term))
            let inApp = match(term: folded, in: app)
            let inTitle = titleFolded.flatMap { match(term: folded, in: $0) }
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
        return Match(score: score, appRanges: merged(appRanges), titleRanges: merged(titleRanges))
    }

    /// Stable sort by descending score: equal scores keep their incoming (recency) order.
    static func ranked<Item>(_ items: [Item], terms: [Substring],
                             fields: (Item) -> (appName: String, title: String?)) -> [Item] {
        guard !terms.isEmpty else { return items }
        let scored: [(index: Int, item: Item, score: Int)] = items.enumerated().compactMap { index, item in
            let field = fields(item)
            guard let match = match(terms: terms, appName: field.appName, title: field.title) else { return nil }
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
        var position = 0
        var offsets: [Int] = []
        var wordStartHits = 0
        for character in term {
            var found: Int?
            var scan = position
            while scan < field.count {
                if field[scan] == character {
                    if isWordStart(field, at: scan) { found = scan; break }
                    if found == nil { found = scan }
                    // Keep looking only a little further for a word-start occurrence.
                    if scan - found! > 24 { break }
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
