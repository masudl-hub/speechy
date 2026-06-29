import Foundation

/// Cleans raw Whisper output into Wispr-style finished text.
/// Primary path: a small local LLM via Ollama (localhost). If Ollama isn't
/// reachable, falls back to fast rule-based cleanup so dictation never blocks.
enum Cleanup {

    private static let ollamaURL = URL(string: "http://127.0.0.1:11434/api/generate")!

    /// Returns cleaned text. Never throws — worst case it returns rule-based output.
    static func process(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard Settings.shared.cleanupEnabled else { return ruleBased(trimmed) }
        if let llm = await llmCleanup(trimmed) { return llm }
        return ruleBased(trimmed)
    }

    /// Preload the cleanup model so it's warm by the time we need it. Called when
    /// recording starts, so the cold-load overlaps speaking + transcription
    /// instead of stalling the paste. Fire-and-forget; safe if Ollama is down.
    static func warmup() async {
        var request = URLRequest(url: ollamaURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": Settings.shared.cleanupModel,
            "prompt": "",  // empty prompt just loads the model into memory
            "stream": false,
            "keep_alive": "5m",
        ])
        request.timeoutInterval = 30
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - LLM path (Ollama)

    // Prompt copy is long-form by nature.
    // swiftlint:disable line_length

    /// Structure-only: never changes a word (the safe default, any model).
    private static let structurePrompt = """
        Add structure to this text — paragraph breaks, and bullet lists only for explicit lists. Change nothing else.
        - Default to paragraphs: group related sentences, with a blank line between paragraphs.
        - Use a bulleted list only when the speaker explicitly lists three or more distinct items. Never bullet ordinary prose.
        Keep every word EXACTLY as written — never paraphrase, simplify, reword, reorder, add, or remove anything. Your job is to prettify, not rewrite. Output only the restructured text.
        """

    /// Structure + self-correction: also resolves spoken corrections. Only used
    /// on a 7B model (small models invert meaning on non-corrections).
    private static let correctionPrompt = """
        Clean up and lightly structure this dictation.
        - If the speaker clearly corrects themselves ("no I mean", "actually no", "sorry I mean", "scratch that", "wait"), apply it: keep what they ended up meaning, drop the retracted part. If there is no clear correction, keep every word.
        - Group sentences into paragraphs (blank line between); use bullets only for an explicit list of three or more items.
        - Otherwise never paraphrase, reword, or change anything.
        Output only the cleaned text.
        """
    // swiftlint:enable line_length

    /// Self-correction is opt-in AND gated to 7B (small models are unsafe at it).
    private static var activePrompt: String {
        let on = Settings.shared.selfCorrection && Settings.shared.cleanupModel.contains("7b")
        return on ? correctionPrompt : structurePrompt
    }

    private static func requestBody(_ text: String, stream: Bool) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "model": Settings.shared.cleanupModel,
            "prompt": "\(activePrompt)\n\nTranscript:\n\(text)\n\nFormatted:",
            "stream": stream,
            "keep_alive": "5m",  // warm while actively dictating, release after 5 min idle
            "options": ["temperature": 0.2],
        ])
    }

    private static func llmCleanup(_ text: String) async -> String? {
        var request = URLRequest(url: ollamaURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody(text, stream: false)
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let out = json["response"] as? String
            else { return nil }
            let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil  // Ollama not running / timed out → caller falls back.
        }
    }

    // MARK: - Fallback

    /// When the LLM is unavailable, fall back to the deterministic Prettifier so
    /// dictation never blocks.
    static func ruleBased(_ input: String) -> String {
        let cleaned = Prettifier.clean(input)
        return cleaned.rangeOfCharacter(from: .alphanumerics) == nil ? "" : cleaned
    }
}
