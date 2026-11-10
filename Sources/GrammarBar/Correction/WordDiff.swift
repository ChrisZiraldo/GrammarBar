import Foundation

// MARK: - Model

/// One run of text inside a change, used purely for display.
struct DiffToken: Identifiable {
    enum Kind { case same, removed, added }
    let id = UUID()
    let text: String
    let kind: Kind
    /// Whether a space separates this token from the previous one. False for the
    /// pieces of a single word that changed only partway through (e.g. "it" + "'" + "s").
    var spaceBefore: Bool = true
}

/// A single reviewable edit: one word replaced, inserted or deleted.
struct DiffChange: Identifiable {
    /// Stable within one diff (0, 1, 2 … in reading order).
    let id: Int
    /// The original word; nil for a pure insertion.
    let original: String?
    /// The corrected word; nil for a pure deletion.
    let corrected: String?
    /// How to draw the edit (unchanged / removed / added pieces).
    let pieces: [DiffToken]
}

struct DiffSegment: Identifiable {
    enum Content {
        /// An unchanged word, or a line-break token ("\n", "\n\n", …).
        case same(String)
        case change(DiffChange)
    }
    let id: Int
    let content: Content
}

// MARK: - Diff

enum WordDiff {

    /// Builds a word-level diff between two strings.
    ///
    /// Words are compared exactly (case and punctuation included). Line breaks are
    /// kept as their own tokens and never count as edits. A word that changed only
    /// slightly is split into unchanged / removed / added pieces so just the edit
    /// is highlighted.
    static func segments(original: String, corrected: String) -> [DiffSegment] {
        let origWords = words(original)
        let corrWords = words(corrected)
        let m = origWords.count
        let n = corrWords.count

        // LCS table
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: 1, through: m, by: 1) {
            for j in stride(from: 1, through: n, by: 1) {
                if matches(origWords[i - 1], corrWords[j - 1]) {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Trace back into raw same / added / removed words (reading order).
        enum Raw { case same(String), added(String), removed(String) }
        var raw: [Raw] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && matches(origWords[i - 1], corrWords[j - 1]) {
                raw.append(.same(corrWords[j - 1]))
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                raw.append(.added(corrWords[j - 1]))
                j -= 1
            } else {
                raw.append(.removed(origWords[i - 1]))
                i -= 1
            }
        }
        raw.reverse()

        // Group runs of edits, pair them up, and emit segments.
        var segments: [DiffSegment] = []
        var changeID = 0
        var pendingRemoved: [String] = []
        var pendingAdded: [String] = []

        func append(_ content: DiffSegment.Content) {
            segments.append(DiffSegment(id: segments.count, content: content))
        }

        func flushPending() {
            let pairCount = min(pendingRemoved.count, pendingAdded.count)
            for k in 0..<pairCount {
                let removed = pendingRemoved[k]
                let added = pendingAdded[k]
                let pieces = characterDiff(removed: removed, added: added) ?? [
                    DiffToken(text: removed, kind: .removed),
                    DiffToken(text: added, kind: .added)
                ]
                append(.change(DiffChange(id: changeID, original: removed, corrected: added, pieces: pieces)))
                changeID += 1
            }
            for word in pendingRemoved.dropFirst(pairCount) {
                append(.change(DiffChange(
                    id: changeID, original: word, corrected: nil,
                    pieces: [DiffToken(text: word, kind: .removed)]
                )))
                changeID += 1
            }
            for word in pendingAdded.dropFirst(pairCount) {
                append(.change(DiffChange(
                    id: changeID, original: nil, corrected: word,
                    pieces: [DiffToken(text: word, kind: .added)]
                )))
                changeID += 1
            }
            pendingRemoved.removeAll()
            pendingAdded.removeAll()
        }

        for token in raw {
            switch token {
            case .same(let text):
                flushPending()
                append(.same(text))
            case .removed(let text):
                // A dropped line break is just layout, not a reviewable edit.
                if !isBreak(text) { pendingRemoved.append(text) }
            case .added(let text):
                if isBreak(text) {
                    // An inserted line break is kept as-is, in position.
                    flushPending()
                    append(.same(text))
                } else {
                    pendingAdded.append(text)
                }
            }
        }
        flushPending()

        return segments
    }

    /// Re-assembles the text, using the original word for every change whose id is
    /// in `rejected` and the corrected word for the rest.
    static func compose(_ segments: [DiffSegment], rejected: Set<Int>) -> String {
        var words: [String] = []
        for segment in segments {
            switch segment.content {
            case .same(let text):
                words.append(text)
            case .change(let change):
                if let word = rejected.contains(change.id) ? change.original : change.corrected {
                    words.append(word)
                }
            }
        }
        return join(words)
    }

    /// Joins words with single spaces, with no space next to a line-break token.
    static func join(_ words: [String]) -> String {
        var out = ""
        var previousWasBreak = true
        for word in words {
            let isLineBreak = isBreak(word)
            if !out.isEmpty && !isLineBreak && !previousWasBreak { out += " " }
            out += word
            previousWasBreak = isLineBreak
        }
        return out
    }

    static func isBreak(_ token: String) -> Bool {
        token.first == "\n"
    }

    // MARK: - Tokenising

    /// Splits text into words. Spaces and tabs separate words; each run of line
    /// breaks becomes one token made of "\n" characters.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var word = ""
        var breaks = ""

        for ch in text {
            if ch.isNewline {
                if !word.isEmpty { result.append(word); word = "" }
                breaks.append("\n")
            } else if ch.isWhitespace {
                if !word.isEmpty { result.append(word); word = "" }
            } else {
                if !breaks.isEmpty { result.append(breaks); breaks = "" }
                word.append(ch)
            }
        }
        if !word.isEmpty { result.append(word) }
        if !breaks.isEmpty { result.append(breaks) }
        return result
    }

    /// Any line break matches any other; words must match exactly.
    private static func matches(_ a: String, _ b: String) -> Bool {
        a == b || (isBreak(a) && isBreak(b))
    }

    // MARK: - Character-level refinement

    /// Splits a replaced word into shared prefix / removed middle / added middle /
    /// shared suffix. Returns nil when the words are too different for that to read
    /// better than a plain whole-word replacement (e.g. "i" -> "I", "teh" -> "the").
    static func characterDiff(removed: String, added: String) -> [DiffToken]? {
        let r = Array(removed), a = Array(added)

        var prefix = 0
        while prefix < r.count, prefix < a.count, r[prefix] == a[prefix] { prefix += 1 }

        var suffix = 0
        while suffix < r.count - prefix, suffix < a.count - prefix,
              r[r.count - 1 - suffix] == a[a.count - 1 - suffix] { suffix += 1 }

        // Require that most of the longer word is unchanged.
        guard (prefix + suffix) * 2 > max(r.count, a.count) else { return nil }

        var pieces: [(String, DiffToken.Kind)] = []
        func add(_ chars: ArraySlice<Character>, _ kind: DiffToken.Kind) {
            if !chars.isEmpty { pieces.append((String(chars), kind)) }
        }
        add(r[0..<prefix], .same)
        add(r[prefix..<(r.count - suffix)], .removed)
        add(a[prefix..<(a.count - suffix)], .added)
        add(r[(r.count - suffix)...], .same)

        return pieces.enumerated().map { offset, piece in
            DiffToken(text: piece.0, kind: piece.1, spaceBefore: offset == 0)
        }
    }
}
