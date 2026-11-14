import Foundation

/// Zenlygram — a run of consent text with one style: plain, bold, a tappable https link, or both.
public struct SGConsentRun: Equatable {
    public let text: String
    public let isBold: Bool
    /// Set only for an `https://` target; any other target renders as plain text.
    public let link: URL?

    public init(text: String, isBold: Bool = false, link: URL? = nil) {
        self.text = text
        self.isBold = isBold
        self.link = link
    }
}

/// Zenlygram — one block of a consent text.
public enum SGConsentBlock: Equatable {
    /// `# ` (level 1) or `## ` (level 2).
    case heading(level: Int, runs: [SGConsentRun])
    /// One or more lines between blank lines (kept joined by LF).
    case paragraph(runs: [SGConsentRun])
    /// Consecutive `- ` lines, one run list per item.
    case list(items: [[SGConsentRun]])
}

/// Zenlygram — the consent text as the wall shows it (contract §5.5 Markdown subset, design 40
/// §4.3): `#`/`##` headings, paragraphs, `- ` bullets, inline `**bold**` and `[text](https://…)`
/// links. Parsed from the CANONICAL text (what is hashed), so `plainText()` equals that text with
/// its markup removed: what is hashed is what is shown. The final `##` section's first paragraph
/// is the age statement, the label of the required checkbox; every other block is the body.
public struct SGConsentDocument: Equatable {
    /// Every block in text order, the age statement included.
    public let blocks: [SGConsentBlock]
    /// The index in `blocks` of the age statement, or nil when the text has none.
    public let ageStatementIndex: Int?

    public init(blocks: [SGConsentBlock], ageStatementIndex: Int?) {
        self.blocks = blocks
        self.ageStatementIndex = ageStatementIndex
    }

    /// The first paragraph of the final `##` section.
    public var ageStatement: [SGConsentRun]? {
        guard let index = self.ageStatementIndex, case let .paragraph(runs) = self.blocks[index] else {
            return nil
        }
        return runs
    }

    /// The scrolling body: every block except the age statement.
    public var body: [SGConsentBlock] {
        return self.blocks.enumerated().filter { $0.offset != self.ageStatementIndex }.map(\.element)
    }

    /// The text with the markup removed: blocks joined by a blank line, list items and paragraph
    /// lines by LF, a heading or bullet without its marker, a link as its text.
    public func plainText() -> String {
        return self.blocks.map { block -> String in
            switch block {
            case let .heading(_, runs), let .paragraph(runs):
                return SGConsentDocument.plainText(of: runs)
            case let .list(items):
                return items.map(SGConsentDocument.plainText(of:)).joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }

    public static func plainText(of runs: [SGConsentRun]) -> String {
        return runs.map(\.text).joined()
    }

    // MARK: - Parsing

    /// Parses a canonical consent text (LF line ends, no trailing blanks). Never fails: anything
    /// outside the subset is shown as plain text.
    public static func parse(_ canonical: String) -> SGConsentDocument {
        var blocks: [SGConsentBlock] = []
        var paragraph: [[Unicode.Scalar]] = []
        var items: [[Unicode.Scalar]] = []
        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(runs: SGConsentDocument.inline(Array(paragraph.joined(separator: ["\n"])))))
                paragraph.removeAll()
            }
        }
        func flushList() {
            if !items.isEmpty {
                blocks.append(.list(items: items.map(SGConsentDocument.inline)))
                items.removeAll()
            }
        }
        let lines = Array(canonical.unicodeScalars).split(separator: "\n", omittingEmptySubsequences: false)
        for slice in lines {
            let line = Array(slice)
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                flushParagraph()
                flushList()
            } else if SGConsentDocument.hasPrefix(line, "## ") {
                flushParagraph()
                flushList()
                blocks.append(.heading(level: 2, runs: SGConsentDocument.inline(Array(line.dropFirst(3)))))
            } else if SGConsentDocument.hasPrefix(line, "# ") {
                flushParagraph()
                flushList()
                blocks.append(.heading(level: 1, runs: SGConsentDocument.inline(Array(line.dropFirst(2)))))
            } else if SGConsentDocument.hasPrefix(line, "- ") {
                flushParagraph()
                items.append(Array(line.dropFirst(2)))
            } else {
                flushList()
                paragraph.append(line)
            }
        }
        flushParagraph()
        flushList()

        var ageStatementIndex: Int?
        if let lastSection = blocks.lastIndex(where: { block in
            if case .heading(2, _) = block {
                return true
            }
            return false
        }) {
            for index in blocks.index(after: lastSection) ..< blocks.endIndex {
                if case .heading = blocks[index] {
                    break
                }
                if case .paragraph = blocks[index] {
                    ageStatementIndex = index
                    break
                }
            }
        }
        return SGConsentDocument(blocks: blocks, ageStatementIndex: ageStatementIndex)
    }

    /// Inline markup of one block's text: `**` toggles bold when a closing `**` follows (an unpaired
    /// one is literal); `[text](target)` with a non-empty text without `[`, `]` or LF and a target
    /// without `(`, `)` or White_Space is a link when the target is `https://…`, else its text.
    static func inline(_ scalars: [Unicode.Scalar]) -> [SGConsentRun] {
        var runs: [SGConsentRun] = []
        var current: [Unicode.Scalar] = []
        var isBold = false
        func flush() {
            if !current.isEmpty {
                runs.append(SGConsentRun(text: SGConsentCanonicalText.string(current[...]), isBold: isBold))
                current.removeAll()
            }
        }
        var index = 0
        while index < scalars.count {
            if scalars[index] == "*", index + 1 < scalars.count, scalars[index + 1] == "*" {
                if isBold || SGConsentDocument.hasPair(scalars, from: index + 2) {
                    flush()
                    isBold.toggle()
                    index += 2
                    continue
                }
            }
            if scalars[index] == "[", let link = SGConsentDocument.link(scalars, at: index) {
                flush()
                let text = SGConsentCanonicalText.string(scalars[link.text])
                let target = SGConsentCanonicalText.string(scalars[link.target])
                let url = SGConsentDocument.hasPrefix(Array(scalars[link.target]), "https://") ? URL(string: target) : nil
                runs.append(SGConsentRun(text: text, isBold: isBold, link: url))
                index = link.end
                continue
            }
            current.append(scalars[index])
            index += 1
        }
        flush()
        return runs
    }

    private static func link(_ scalars: [Unicode.Scalar], at start: Int) -> (text: Range<Int>, target: Range<Int>, end: Int)? {
        var index = start + 1
        while index < scalars.count, scalars[index] != "]" {
            if scalars[index] == "[" || scalars[index] == "\n" {
                return nil
            }
            index += 1
        }
        let textEnd = index
        guard textEnd > start + 1, textEnd + 1 < scalars.count, scalars[textEnd] == "]", scalars[textEnd + 1] == "(" else {
            return nil
        }
        index = textEnd + 2
        while index < scalars.count, scalars[index] != ")" {
            if scalars[index] == "(" || SGConsentCanonicalText.isWhiteSpace(scalars[index]) {
                return nil
            }
            index += 1
        }
        guard index < scalars.count, index > textEnd + 2 else {
            return nil
        }
        return ((start + 1) ..< textEnd, (textEnd + 2) ..< index, index + 1)
    }

    private static func hasPair(_ scalars: [Unicode.Scalar], from start: Int) -> Bool {
        var index = start
        while index + 1 < scalars.count {
            if scalars[index] == "*", scalars[index + 1] == "*" {
                return true
            }
            index += 1
        }
        return false
    }

    static func hasPrefix(_ scalars: [Unicode.Scalar], _ prefix: String) -> Bool {
        let pattern = Array(prefix.unicodeScalars)
        return scalars.count >= pattern.count && scalars[0 ..< pattern.count].elementsEqual(pattern)
    }
}
