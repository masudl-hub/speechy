import Foundation

/// Cleans raw Whisper output into Wispr-style finished text.
/// Primary path: a small local LLM via Ollama (localhost). If Ollama isn't
/// reachable, falls back to fast rule-based cleanup so dictation never blocks.
enum Cleanup {

    private static let ollamaURL = URL(string: "http://127.0.0.1:11434/api/generate")!

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

    /// Structure-only, taught by example: preserves meaning + tone.
    private static let structurePrompt = """
        You format dictated speech for readability. Keep the speaker's exact wording, casual tone, and meaning. Your only job is to join the words into natural sentences and paragraphs, and to use a bulleted list ONLY for a genuine list of parallel items. Never bullet ordinary sentences or trailing-off fragments like "and..." or "yeah, so...".
        Do NOT expand abbreviations (keep "deps", "auth", "app", "repo"). Do NOT expand contractions, formalize, or swap words for fancier synonyms. Do NOT add words. You may drop pure filler (um, uh) and list connectives.

        Example A
        Input: i think the design is off the menu is cluttered separately the performance is bad the cold load is too slow
        Output:
        I think the design is off, the menu is cluttered.

        Separately, the performance is bad. The cold load is too slow.

        Example B
        Input: for launch we need to finish the landing page set up the email campaign and reach out to beta users
        Output:
        For launch we need to:
        - Finish the landing page
        - Set up the email campaign
        - Reach out to beta users
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
            "prompt": "\(activePrompt)\n\nNow format this:\nInput: \(text)\nOutput:",
            "stream": stream,
            "keep_alive": "5m",  // warm while actively dictating, release after 5 min idle
            "options": ["temperature": 0.1],
        ])
    }

    /// Streaming cleanup: invokes `onChunk` with each token as it's generated so
    /// the caller can insert text live. Returns the full text. Never throws —
    /// falls back to the deterministic Prettifier (one chunk) if Ollama is down.
    static func processStreaming(_ raw: String, onChunk: @escaping (String) async -> Void) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard Settings.shared.cleanupEnabled else {
            let r = ruleBased(trimmed); await onChunk(r); return r
        }
        if let full = await streamLLM(trimmed, onChunk: onChunk) { return full }
        let r = ruleBased(trimmed); await onChunk(r); return r
    }

    private static func streamLLM(
        _ text: String, onChunk: @escaping (String) async -> Void
    ) async
        -> String?
    {
        var request = URLRequest(url: ollamaURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody(text, stream: true)
        request.timeoutInterval = 30

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            var full = ""
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let piece = json["response"] as? String, !piece.isEmpty {
                    full += piece
                    await onChunk(piece)
                }
                if (json["done"] as? Bool) == true { break }
            }
            return full.isEmpty ? nil : full.trimmingCharacters(in: .whitespacesAndNewlines)
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
