import SwiftUI

/// Renders the characters that matched the typed query in bold accent, so the user can
/// see why a tile is in the list and where the next keystroke will narrow it.
enum SearchHighlight {
    static func attributed(_ text: String, ranges: [Range<Int>], color: Color) -> AttributedString {
        var result = AttributedString(text)
        guard !ranges.isEmpty else { return result }
        let count = text.count
        for range in ranges where range.lowerBound >= 0 && range.upperBound <= count && !range.isEmpty {
            let start = result.index(result.startIndex, offsetByCharacters: range.lowerBound)
            let end = result.index(result.startIndex, offsetByCharacters: range.upperBound)
            result[start..<end].inlinePresentationIntent = .stronglyEmphasized
            result[start..<end].foregroundColor = color
        }
        return result
    }
}
