import Foundation

/// Zero-latency, deterministic text prettifier — the mechanical layer.
/// Handles the "solved" stuff: spoken punctuation/format commands, filler
/// removal, capitalization, and spacing. It NEVER changes the user's words or
/// meaning — it only corrects and tidies. The LLM layer (Cleanup) sits on top
/// of this and only adds higher-level structure.
enum Prettifier {

    static func clean(_ input: String) -> String {
        var t = input

        // 1. Spoken punctuation / formatting commands.
        for (spoken, symbol) in spokenCommands {
            t = t.replacingOccurrences(
                of: "\\b\(spoken)\\b", with: symbol,
                options: [.regularExpression, .caseInsensitive])
        }

        // 2. Filler words (conservative — only unambiguous fillers; an optional
        //    trailing comma is swallowed with them).
        for f in fillers {
            t = t.replacingOccurrences(
                of: "\\b\(f)\\b,?", with: "",
                options: [.regularExpression, .caseInsensitive])
        }

        // 3. Spacing tidy-ups (safe ones only — no reformatting of numbers/code):
        //    no space before punctuation, collapse space runs, strip trailing space before newline.
        t = t.replacingOccurrences(of: " +([,.!?;:])", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " +\\n", with: "\n", options: .regularExpression)

        // 4. Capitalization: sentence starts + standalone "i" → "I".
        t = capitalizeSentences(t)
        t = t.replacingOccurrences(of: "\\bi\\b", with: "I", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\bi'", with: "I'", options: .regularExpression)

        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tables

    private static let spokenCommands: [(String, String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("bullet point", "\n- "),
        ("new bullet", "\n- "),
        ("comma", ","),
        ("period", "."),
        ("full stop", "."),
        ("question mark", "?"),
        ("exclamation mark", "!"),
        ("exclamation point", "!"),
        ("colon", ":"),
        ("semicolon", ";"),
    ]

    private static let fillers = ["um", "uh", "erm", "uhh", "uhm", "hmm", "you know"]

    private static func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for char in text {
            if capitalizeNext, char.isLetter {
                result.append(Character(char.uppercased()))
                capitalizeNext = false
            } else {
                result.append(char)
                if char == "." || char == "!" || char == "?" || char == "\n" {
                    capitalizeNext = true
                } else if !char.isWhitespace {
                    capitalizeNext = false
                }
            }
        }
        return result
    }
}
