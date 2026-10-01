import Foundation

/// Turns a reviewed diagnostics report into a prefilled GitHub issue, so a bug report
/// arrives with the same facts a conversation would otherwise have to ask for first.
/// Only the diagnostics JSON travels in the URL; it carries no titles, URLs, paths, or
/// app list. The window census is larger and names running apps, so it stays a
/// deliberate copy-and-paste step.
enum IssueReport {
    static let repository = URL(string: "https://github.com/pernielsentikaer/swiitch")!
    /// With templates configured, GitHub sends a bare `issues/new` to the chooser; naming
    /// the template keeps its labels while `body` replaces its content.
    static let template = "bug_report.md"

    /// Browsers and GitHub reject very long URLs; stay well under the usual 8 KB.
    static let maximumURLLength = 7_500

    struct Prepared: Equatable {
        let url: URL
        /// False when the report did not fit in the URL; the caller then puts it on the
        /// clipboard and the issue body asks for it to be pasted.
        let includesDiagnostics: Bool
    }

    static func prepare(diagnostics: String, repository: URL = repository,
                        maximumURLLength: Int = maximumURLLength) -> Prepared? {
        if let url = issueURL(body: body(diagnostics: diagnostics), repository: repository),
           url.absoluteString.count <= maximumURLLength {
            return Prepared(url: url, includesDiagnostics: true)
        }
        guard let url = issueURL(body: body(diagnostics: nil), repository: repository) else { return nil }
        return Prepared(url: url, includesDiagnostics: false)
    }

    /// Markdown for the issue body: the bug template's sections, with the report folded
    /// away at the end so the description stays on top.
    static func body(diagnostics: String?) -> String {
        var lines = [
            "## What happened?",
            "<!-- A short description of the bug. -->",
            "",
            "## Steps to reproduce",
            "1.",
            "2.",
            "3.",
            "",
            "## Expected behavior",
            "<!-- What did you expect Swiitch to do? -->",
            "",
            "## Diagnostics",
            "<details><summary>Report from Preferences → About → Review Diagnostics (versions, permissions, anonymous counts and timings)</summary>",
            "",
        ]
        if let diagnostics {
            lines += ["```json", diagnostics, "```"]
        } else {
            lines += ["_The report was too long for a link. It is on your clipboard: paste it here._"]
        }
        lines += [
            "",
            "</details>",
            "",
            "<!-- Windows missing or shown twice? Also paste the Window Census from the same Diagnostics screen. -->",
        ]
        return lines.joined(separator: "\n")
    }

    /// RFC 3986 unreserved characters only. URLComponents would leave `&`, `+` and `=`
    /// alone, and GitHub reads those as query syntax or spaces.
    private static let unreserved = CharacterSet(charactersIn: "-._~").union(.alphanumerics)

    private static func issueURL(body: String, repository: URL) -> URL? {
        guard let encoded = body.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: repository.absoluteString + "/issues/new?template=" + template + "&body=" + encoded)
    }
}
