import Foundation

/// Checks that LLM structuring preserved the speaker's meaning + tone. The model
/// may add structure (line breaks, bullets, punctuation) and drop filler/list
/// connectives, but it must NOT introduce new or substituted content words.
///
/// Tolerates harmless cases so it doesn't cry wolf: grammatical glue words and
/// split/joined variants of existing words (e.g. "realtime" → "real time").
/// Flags real rewordings ("ship" → "schedule") and inventions ("functionality").
enum FidelityGuard {

    /// Returns true if `output` kept the meaning/tone of `source`.
    static func isFaithful(source: String, output: String) -> Bool {
        let sourceWords = Set(words(source))

        for word in words(output) where !sourceWords.contains(word) {
            if word.count <= 2 { continue }  // tiny tokens / artifacts
            if functionWords.contains(word) { continue }  // grammatical glue
            // A split/join of an existing word ("real"/"time" ⊂ "realtime") — fine.
            if sourceWords.contains(where: { $0.contains(word) || word.contains($0) }) { continue }
            return false  // genuine new/substituted content word
        }
        return true
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "to", "of", "in", "on", "at", "for",
        "is", "are", "was", "were", "be", "do", "does", "did", "not", "it", "its", "as",
        "by", "with", "that", "this", "we", "you", "he", "she", "they", "then", "if",
    ]
}
