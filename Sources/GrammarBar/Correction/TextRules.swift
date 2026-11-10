import Foundation

// MARK: - Unchanged check

enum TextComparison {
    /// True when `corrected` is identical to `original` apart from whitespace
    /// differences. Case and punctuation changes count as real changes.
    static func isUnchanged(_ corrected: String, from original: String) -> Bool {
        func normalized(_ s: String) -> String {
            s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return normalized(corrected) == normalized(original)
    }
}

// MARK: - Custom dictionary enforcement

/// Puts protected words back after the model has rewritten the text.
///
/// The dictionary is also given to the model as an instruction, but small local
/// models often ignore it. This is the safety net: wherever a protected word was
/// altered, the original spelling is restored.
enum DictionaryGuard {

    private static let edgePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "\"", "“", "”", "‘", "’", "'",
        "(", ")", "[", "]", "{", "}", "…"
    ]

    /// Splits a word into (leading punctuation, core, trailing punctuation).
    static func split(_ word: String) -> (lead: String, core: String, trail: String) {
        var chars = Substring(word)
        var lead = ""
        var trail = ""
        while let first = chars.first, edgePunctuation.contains(first) {
            lead.append(first)
            chars = chars.dropFirst()
        }
        var trailReversed = ""
        while let last = chars.last, edgePunctuation.contains(last) {
            trailReversed.append(last)
            chars = chars.dropLast()
        }
        trail = String(trailReversed.reversed())
        return (lead, String(chars), trail)
    }

    /// The word without surrounding punctuation ("Zed," -> "Zed").
    static func core(of word: String) -> String {
        split(word).core
    }

    static func restore(original: String, corrected: String, dictionary: [String]) -> String {
        let terms = dictionary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return corrected }

        var result = corrected

        // 1. Single-word terms: align words and repair any that were altered.
        let singleTerms = Set(terms.filter { !$0.contains(where: { $0.isWhitespace }) })
        if !singleTerms.isEmpty {
            let segments = WordDiff.segments(original: original, corrected: corrected)
            var words: [String] = []
            var changed = false

            for segment in segments {
                switch segment.content {
                case .same(let text):
                    words.append(text)
                case .change(let change):
                    switch (change.original, change.corrected) {
                    case let (original?, model?):
                        if let fixed = restoredWord(original: original, model: model, terms: singleTerms) {
                            words.append(fixed)
                            changed = true
                        } else {
                            words.append(model)
                        }
                    case let (original?, nil):
                        // The model dropped a word; bring it back if it was protected.
                        if protectedTerm(in: original, terms: singleTerms) != nil {
                            words.append(original)
                            changed = true
                        }
                    case let (nil, model?):
                        words.append(model)
                    case (nil, nil):
                        break
                    }
                }
            }
            if changed { result = WordDiff.join(words) }
        }

        // 2. Phrases and case: if a term appears verbatim in the original, any
        //    differently-cased copy in the output goes back to the exact spelling.
        //    The one exception: a term that starts lowercase is capitalized when it
        //    opens a sentence ("wanna" -> "Wanna" at the start of a sentence).
        for term in terms.sorted(by: { $0.count > $1.count }) {
            let pattern = boundedPattern(for: term)
            guard original.range(of: pattern, options: .regularExpression) != nil else { continue }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }

            let capitalized = capitalizingFirstLetter(term)
            let canCapitalize = capitalized != term
            let output = NSMutableString(string: result)
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: output.length))

            // Back to front so earlier ranges stay valid while we replace.
            for match in matches.reversed() {
                let atSentenceStart = canCapitalize && isSentenceStart(in: output, at: match.range.location)
                output.replaceCharacters(in: match.range, with: atSentenceStart ? capitalized : term)
            }
            result = output as String
        }

        return result
    }

    // MARK: - Helpers

    /// "wanna" -> "Wanna". Returns the input unchanged unless it starts with a lowercase
    /// letter and has no other capitals, so brand-style terms like "iOS" or "eBay" are left alone.
    static func capitalizingFirstLetter(_ term: String) -> String {
        guard let first = term.first, first.isLowercase,
              !term.dropFirst().contains(where: { $0.isUppercase }) else { return term }
        return first.uppercased() + term.dropFirst()
    }

    /// True when the text before `location` is the start of the text, a line break,
    /// or sentence-ending punctuation (ignoring spaces and opening quotes/brackets).
    static func isSentenceStart(in text: NSString, at location: Int) -> Bool {
        let skippable: Set<Character> = ["\"", "“", "‘", "'", "(", "[", "{"]
        var index = location - 1
        while index >= 0 {
            guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            let ch = Character(scalar)
            if ch == "\n" || ch == "\r" { return true }
            if ch == " " || ch == "\t" || skippable.contains(ch) {
                index -= 1
                continue
            }
            return ch == "." || ch == "!" || ch == "?" || ch == "…"
        }
        return true
    }

    /// The protected term this original word represents, if any.
    private static func protectedTerm(in word: String, terms: Set<String>) -> String? {
        if terms.contains(word) { return word }
        let core = core(of: word)
        return terms.contains(core) ? core : nil
    }

    /// If the model altered a protected word, returns the repaired word (keeping any
    /// punctuation the model added around it); otherwise nil.
    private static func restoredWord(original: String, model: String, terms: Set<String>) -> String? {
        guard let term = protectedTerm(in: original, terms: terms) else { return nil }
        if model == term { return nil }
        let parts = split(model)
        if parts.core == term { return nil }
        return parts.lead + term + parts.trail
    }

    private static func boundedPattern(for term: String) -> String {
        "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}_])"
    }
}
