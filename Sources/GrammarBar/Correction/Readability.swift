import Foundation

/// Local text statistics and Flesch Reading Ease score — no model call required.
struct Readability {
    let wordCount: Int
    let sentenceCount: Int
    let syllableCount: Int
    /// Flesch Reading Ease (0–100, higher = easier).
    let fleschScore: Double
    let grade: ReadabilityGrade
    let hasLongSentences: Bool
    let passiveVoiceHints: Int

    /// Analyse the given text and return a populated `Readability` value.
    static func analyse(_ text: String) -> Readability {
        let words = tokenizeWords(text)
        let sentences = tokenizeSentences(text)
        let syllables = words.reduce(0) { $0 + countSyllables(in: $1) }

        let wordCount = words.count
        let sentenceCount = max(sentences.count, 1)
        let syllableCount = syllables

        // Flesch Reading Ease = 206.835 − 1.015×(words/sentences) − 84.6×(syllables/words)
        let asl = Double(wordCount) / Double(sentenceCount)
        let asw = wordCount > 0 ? Double(syllableCount) / Double(wordCount) : 1
        let score = max(0, min(100, 206.835 - 1.015 * asl - 84.6 * asw))

        let longSentences = sentences.filter { $0.split(separator: " ").count > 25 }
        let passiveCount = countPassiveHints(in: text)

        return Readability(
            wordCount: wordCount,
            sentenceCount: sentenceCount,
            syllableCount: syllableCount,
            fleschScore: score,
            grade: ReadabilityGrade(fleschScore: score),
            hasLongSentences: !longSentences.isEmpty,
            passiveVoiceHints: passiveCount
        )
    }

    // MARK: - Private helpers

    private static func tokenizeWords(_ text: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: "\\b[a-zA-Z']+\\b")
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern?.matches(in: text, range: range) ?? []
        return matches.compactMap { match -> String? in
            guard let r = Range(match.range, in: text) else { return nil }
            return String(text[r])
        }
    }

    private static func tokenizeSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sentences.append(s)
            }
        }
        return sentences.isEmpty ? [text] : sentences
    }

    /// Naïve syllable counter using vowel-group heuristics.
    private static func countSyllables(in word: String) -> Int {
        let lower = word.lowercased()
        guard !lower.isEmpty else { return 1 }

        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var count = 0
        var prevWasVowel = false

        for ch in lower {
            let isVowel = vowels.contains(ch)
            if isVowel && !prevWasVowel { count += 1 }
            prevWasVowel = isVowel
        }

        // Silent trailing 'e'
        if lower.hasSuffix("e") && count > 1 { count -= 1 }

        return max(count, 1)
    }

    /// Count simple passive-voice signals ("is/are/was/were/been + past-participle-like word").
    private static func countPassiveHints(in text: String) -> Int {
        let lower = text.lowercased()
        let auxiliaries = ["is being", "are being", "was being", "were being",
                           "has been", "have been", "had been",
                           "will be", "would be", "can be", "could be",
                           "should be", "may be", "might be", "must be"]
        return auxiliaries.reduce(0) { count, aux in
            var c = 0
            var search = lower
            while let r = search.range(of: aux) {
                c += 1
                search = String(search[r.upperBound...])
            }
            return count + c
        }
    }
}

// MARK: - Grade

enum ReadabilityGrade: String {
    case veryEasy = "Very Easy"
    case easy = "Easy"
    case fairlyEasy = "Fairly Easy"
    case standard = "Standard"
    case fairlyDifficult = "Fairly Difficult"
    case difficult = "Difficult"
    case veryDifficult = "Very Difficult"

    init(fleschScore: Double) {
        switch fleschScore {
        case 90...:       self = .veryEasy
        case 80..<90:     self = .easy
        case 70..<80:     self = .fairlyEasy
        case 60..<70:     self = .standard
        case 50..<60:     self = .fairlyDifficult
        case 30..<50:     self = .difficult
        default:          self = .veryDifficult
        }
    }
}
