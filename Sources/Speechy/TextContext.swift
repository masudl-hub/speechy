import AppKit
import ApplicationServices

/// Reads the text immediately before the insertion point in the focused field
/// (via the Accessibility API) and adjusts inserted text to join naturally —
/// spacing, sentence-start capitalization, mid-sentence continuation.
///
/// Where AX is unavailable (some Electron/web/terminal fields), it returns nil
/// and the pipeline pastes the text unchanged.
enum TextContext {

    /// Up to `maxChars` of text right before the cursor, or nil if unreadable.
    /// Returns "" when the cursor is at the very start of an (empty) field.
    static func precedingText(maxChars: Int = 48) -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
                == .success,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        // Safe: guarded by the CFGetTypeID check above; CFTypeRef→AXUIElement has no `as?` bridge.
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement

        // Cursor position (UTF-16 offset).
        var rangeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
                == .success,
            let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return nil }
        guard selection.location > 0 else { return "" }

        // Efficient path: ask only for the substring before the cursor.
        let start = max(0, selection.location - maxChars)
        var subRange = CFRange(location: start, length: selection.location - start)
        if let axRange = AXValueCreate(.cfRange, &subRange) {
            var sub: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &sub) == .success,
                let s = sub as? String
            {
                return s
            }
        }

        // Fallback: read the whole value and slice (works in more fields).
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
            let full = valueRef as? String
        {
            let ns = full as NSString
            let loc = min(selection.location, ns.length)
            let st = max(0, loc - maxChars)
            return ns.substring(with: NSRange(location: st, length: loc - st))
        }
        return nil
    }
}

/// Adjusts inserted text to join cleanly onto whatever precedes the cursor.
enum SmartJoin {

    static func adjust(_ text: String, preceding: String?) -> String {
        guard !text.isEmpty else { return text }
        guard let preceding else { return text }  // unknown context → leave as-is

        var out = text

        // --- Capitalization ---
        let lastChar = preceding.last
        let atSentenceStart: Bool
        if lastChar == nil {
            atSentenceStart = true  // empty field
        } else if lastChar == "\n" {
            atSentenceStart = true  // fresh line
        } else if let c = preceding.last(where: { !$0.isWhitespace }) {
            atSentenceStart = ".!?".contains(c)
        } else {
            atSentenceStart = true
        }
        out = atSentenceStart ? capitalizingFirst(out) : continuingFirst(out)

        // --- Leading space ---
        let needsSpace: Bool
        switch lastChar {
        case nil:
            needsSpace = false  // empty field
        case let c? where c.isWhitespace:
            needsSpace = false  // already spaced
        case let c? where "([{<\"'\u{201C}\u{2018}".contains(c):
            needsSpace = false  // after an opener/quote
        default:
            needsSpace = true  // joining onto a word/punctuation
        }
        if needsSpace { out = " " + out }
        return out
    }

    private static func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first, first.isLetter, first.isLowercase else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// Lowercase the first letter for a mid-sentence continuation, unless it's a
    /// word we shouldn't touch ("I", "I'm"…) or an all-caps acronym.
    private static func continuingFirst(_ s: String) -> String {
        guard let first = s.first, first.isLetter, first.isUppercase else { return s }
        let firstWord = s.prefix { !$0.isWhitespace }
        if firstWord == "I" || firstWord.hasPrefix("I'") || firstWord.hasPrefix("I\u{2019}") { return s }
        // Acronym (e.g. "API", "NASA") — leave it.
        if firstWord.count > 1, firstWord.allSatisfy({ $0.isUppercase || !$0.isLetter }) { return s }
        return first.lowercased() + s.dropFirst()
    }
}

/// Inserts streamed cleanup tokens live: drops leading whitespace, applies the
/// context-aware join (spacing/casing) to the first real content, holds back
/// trailing whitespace, and types each piece via `TextInjector.type` (which
/// never emits a Return key).
@MainActor
final class StreamInserter {
    private let preceding: String?
    private let casing: Bool
    private var started = false
    private var pendingWhitespace = ""

    init(preceding: String?, casing: Bool) {
        self.preceding = preceding
        self.casing = casing
    }

    func feed(_ piece: String) {
        if !started {
            let stripped = String(piece.drop(while: { $0.isWhitespace }))
            guard !stripped.isEmpty else { return }  // ignore leading-whitespace tokens
            started = true
            TextInjector.type(casing ? SmartJoin.adjust(stripped, preceding: preceding) : stripped)
        } else if piece.allSatisfy({ $0.isWhitespace }) {
            pendingWhitespace += piece  // hold — might be trailing
        } else {
            TextInjector.type(pendingWhitespace + piece)
            pendingWhitespace = ""
        }
    }
    // Any leftover pendingWhitespace is trailing → intentionally dropped.
}
