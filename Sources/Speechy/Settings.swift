import Foundation

/// User-configurable settings, persisted in UserDefaults.
/// These are the high-impact tuners surfaced from the menu; everything else
/// has a sensible hardcoded default in `Transcriber`.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let sttEngine = "sttEngine"
        static let model = "model"
        static let language = "language"
        static let postProcessingEnabled = "postProcessingEnabled"
        static let cleanupEnabled = "cleanupEnabled"
        static let selfCorrection = "selfCorrection"
        static let smartInsert = "smartInsert"
        static let cleanupModel = "cleanupModel"
        static let customPrompt = "customPrompt"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let holdKeyCode = "holdKeyCode"
        static let floatyX = "floatyX"
        static let floatyY = "floatyY"
    }

    /// Persisted floaty position (nil until the user drags it).
    var floatyOrigin: CGPoint? {
        get {
            guard defaults.object(forKey: Key.floatyX) != nil else { return nil }
            return CGPoint(
                x: defaults.double(forKey: Key.floatyX),
                y: defaults.double(forKey: Key.floatyY))
        }
        set {
            guard let p = newValue else { return }
            defaults.set(p.x, forKey: Key.floatyX)
            defaults.set(p.y, forKey: Key.floatyY)
        }
    }

    /// Speech-to-text engine: "whisper" (accurate, on-device, heavier) or
    /// "apple" (macOS built-in on-device recognizer — light, fast, no download).
    var sttEngine: String {
        get { defaults.string(forKey: Key.sttEngine) ?? "whisper" }
        set { defaults.set(newValue, forKey: Key.sttEngine) }
    }

    /// WhisperKit model identifier (substring match is fine; WhisperKit resolves it).
    /// Default: large-v3-turbo — near-large accuracy, far faster, comfortable on 16 GB.
    var model: String {
        get { defaults.string(forKey: Key.model) ?? "large-v3-v20240930_turbo" }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    /// Force language (e.g. "en") for speed + no language-switch errors. Empty = auto-detect.
    var language: String {
        get { defaults.string(forKey: Key.language) ?? "en" }
        set { defaults.set(newValue, forKey: Key.language) }
    }

    /// Master switch for all post-processing (structuring + casing). Off = paste
    /// raw Whisper output untouched.
    var postProcessingEnabled: Bool {
        get { defaults.object(forKey: Key.postProcessingEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.postProcessingEnabled) }
    }

    /// "Structuring": the local-LLM pass (paragraphs/lists), streamed in live.
    var cleanupEnabled: Bool {
        get { defaults.object(forKey: Key.cleanupEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.cleanupEnabled) }
    }

    /// Resolve spoken self-corrections ("no I mean…"). Only safe on 7B+, so it's
    /// gated to that model in Cleanup; small models mangle non-corrections.
    var selfCorrection: Bool {
        get { defaults.object(forKey: Key.selfCorrection) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.selfCorrection) }
    }

    /// Context-aware insertion: read the text before the cursor and adjust
    /// spacing + capitalization so dictation joins the existing text naturally.
    var smartInsert: Bool {
        get { defaults.object(forKey: Key.smartInsert) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.smartInsert) }
    }

    /// Local Ollama model used for the cleanup pass.
    var cleanupModel: String {
        get { defaults.string(forKey: Key.cleanupModel) ?? "qwen2.5:3b-instruct" }
        set { defaults.set(newValue, forKey: Key.cleanupModel) }
    }

    /// Custom vocabulary / initial-prompt text. The single biggest lever for domain words.
    /// Fed to Whisper as prompt tokens to bias decoding toward your jargon, names, products.
    var customPrompt: String {
        get { defaults.string(forKey: Key.customPrompt) ?? "" }
        set { defaults.set(newValue, forKey: Key.customPrompt) }
    }

    /// Virtual key code for the trigger modifier. Default 63 = Fn.
    /// Double-tap = toggle lock; held with `holdKeyCode` = push-to-talk.
    var hotkeyKeyCode: Int {
        get { defaults.object(forKey: Key.hotkeyKeyCode) as? Int ?? 63 }
        set { defaults.set(newValue, forKey: Key.hotkeyKeyCode) }
    }

    /// Companion key held together with the modifier for push-to-talk.
    /// Default 49 = Space (so the hold gesture is Fn + Space).
    var holdKeyCode: Int {
        get { defaults.object(forKey: Key.holdKeyCode) as? Int ?? 49 }
        set { defaults.set(newValue, forKey: Key.holdKeyCode) }
    }

    /// Human-readable symbol for the trigger modifier, for the floaty hint.
    var hotkeyLabel: String { Self.label(for: hotkeyKeyCode) }

    /// The push-to-talk combo, e.g. "fn + space", for the floaty hint.
    var holdComboLabel: String { "\(Self.label(for: hotkeyKeyCode)) + \(Self.label(for: holdKeyCode))" }

    private static func label(for keyCode: Int) -> String {
        switch keyCode {
        case 61, 58: return "⌥"
        case 62, 59: return "⌃"
        case 60, 56: return "⇧"
        case 55, 54: return "⌘"
        case 63: return "fn"
        case 49: return "space"
        default: return "key"
        }
    }

    /// Selectable speech-to-text engines.
    static let sttEngines: [(id: String, label: String)] = [
        ("whisper", "Whisper (accurate, on-device)"),
        ("apple", "Apple (light, fast)"),
    ]

    /// Catalog of selectable Whisper (speech-to-text) models, shown in the menu.
    static let availableModels: [(id: String, label: String)] = [
        ("large-v3-v20240930_turbo", "large-v3-turbo (default, fast + accurate)"),
        ("large-v3", "large-v3 (max accuracy, slower)"),
        ("distil-large-v3", "distil-large-v3 (fast, English-leaning)"),
    ]

    /// Catalog of selectable cleanup (text-formatting) models — Qwen + Gemma.
    /// Right-sized for a 16GB Mac — nothing over ~5GB. (Gemma 2 9B intentionally
    /// omitted: ~5.4GB is too heavy here.) Installed/needs-download state is
    /// detected live from Ollama, never hard-coded.
    static let cleanupModels: [(id: String, label: String)] = [
        ("qwen2.5:1.5b-instruct", "Qwen2.5 1.5B (fastest)"),
        ("qwen2.5:3b-instruct", "Qwen2.5 3B (default, balanced)"),
        ("qwen2.5:7b-instruct", "Qwen2.5 7B (best, slower)"),
        ("gemma2:2b", "Gemma 2 2B (small alternate)"),
    ]
}
