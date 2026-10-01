@testable import Swiitch
import XCTest

final class SearchMatcherTests: XCTestCase {
    private func terms(_ query: String) -> [Substring] { query.split(whereSeparator: \.isWhitespace) }

    func testMatchClassesRankPrefixAboveWordStartAboveSubstringAboveFuzzy() {
        let prefix = SearchMatcher.match(terms: terms("saf"), appName: "Safari", title: nil)
        let wordStart = SearchMatcher.match(terms: terms("stu"), appName: "Visual Studio Code", title: nil)
        let substring = SearchMatcher.match(terms: terms("urs"), appName: "Cursor", title: nil)
        let fuzzy = SearchMatcher.match(terms: terms("vsc"), appName: "Visual Studio Code", title: nil)
        XCTAssertEqual(prefix?.score, 100)
        XCTAssertEqual(wordStart?.score, 80)
        XCTAssertEqual(substring?.score, 60)
        XCTAssertEqual(fuzzy?.score, 54, "an acronym: three word-start hits and no gap penalty")
        XCTAssertLessThan(fuzzy!.score, substring!.score, "A fuzzy match never outranks a real substring match")
        XCTAssertEqual(prefix?.appRanges, [0..<3])
        XCTAssertEqual(wordStart?.appRanges, [7..<10])
        XCTAssertEqual(fuzzy?.appRanges, [0..<1, 7..<8, 14..<15])
    }

    func testEveryWordMustMatchTheSameCandidateAcrossAppNameAndTitle() {
        let both = SearchMatcher.match(terms: terms("dia calendar"), appName: "Dia", title: "Calendar — Team")
        XCTAssertEqual(both?.score, 200)
        XCTAssertEqual(both?.appRanges, [0..<3])
        XCTAssertEqual(both?.titleRanges, [0..<8])
        XCTAssertNil(SearchMatcher.match(terms: terms("dia resume"), appName: "Dia", title: "Calendar — Team"))
        XCTAssertNil(SearchMatcher.match(terms: terms("dia"), appName: "Safari", title: nil))
    }

    func testFoldingIgnoresCaseAndAccentsAndKeepsPunctuationLiteral() {
        let accent = SearchMatcher.match(terms: terms("RESUME [q1]"), appName: "Dia", title: "Résumé [Q1]")
        XCTAssertEqual(accent?.score, 100 + 80)
        XCTAssertEqual(accent?.titleRanges, [0..<6, 7..<11])
        XCTAssertNil(SearchMatcher.match(terms: terms("(q1)"), appName: "Dia", title: "Résumé [Q1]"))
    }

    func testSingleCharactersNeverFuzzyMatchAndInitialsDo() {
        XCTAssertNil(SearchMatcher.match(terms: terms("z"), appName: "Visual Studio Code", title: nil))
        let initials = SearchMatcher.match(terms: terms("gc"), appName: "Google Calendar", title: nil)
        XCTAssertEqual(initials?.score, 46)
        XCTAssertEqual(initials?.appRanges, [0..<1, 7..<8])
        let scattered = SearchMatcher.match(terms: terms("oe"), appName: "Google Calendar", title: nil)
        XCTAssertNotNil(scattered)
        XCTAssertLessThan(scattered!.score, initials!.score, "Characters inside words score lower than initials")
    }

    func testRankingOrdersByScoreAndKeepsRecencyOrderWithinATie() {
        struct Item: Equatable { let name: String; let title: String? }
        let recentFirst = [
            Item(name: "Cursor", title: "main.swift"),
            Item(name: "Slack", title: "#general"),
            Item(name: "Visual Studio Code", title: "notes"),
            Item(name: "Safari", title: "Swift forums"),
        ]
        let ranked = SearchMatcher.ranked(recentFirst, terms: terms("s")) { ($0.name, $0.title) }
        // Slack and Safari are prefix matches and keep their recency order between them.
        // Cursor ("main.swift", word start after the dot) and Visual Studio Code ("Studio")
        // are both word-start matches, again in recency order, after the prefixes.
        XCTAssertEqual(ranked.map(\.name), ["Slack", "Safari", "Cursor", "Visual Studio Code"])
        XCTAssertEqual(SearchMatcher.ranked(recentFirst, terms: []) { ($0.name, $0.title) }, recentFirst)
        XCTAssertEqual(SearchMatcher.ranked(recentFirst, terms: terms("zzz")) { ($0.name, $0.title) }, [])
    }

    func testMergedRangesCoalesceOverlapsAndSort() {
        XCTAssertEqual(SearchMatcher.merged([5..<7, 0..<2, 1..<3, 7..<8]), [0..<3, 5..<8])
        XCTAssertEqual(SearchMatcher.merged([]), [])
    }
}
