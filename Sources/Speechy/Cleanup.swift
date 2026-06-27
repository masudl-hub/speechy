import Foundation

/// Cleans raw Whisper output into Wispr-style finished text.
/// Primary path: a small local LLM via Ollama (localhost). If Ollama isn't
/// reachable, falls back to fast rule-based cleanup so dictation never blocks.
enum Cleanup {

    private static let ollamaURL = URL(string: "http://127.0.0.1:11434/api/generate")!

    /// Returns cleaned text (non-streaming). Never throws.
    static func process(_ raw: String) async -> String {
        await processStreaming(raw) { _ in }
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
            "prompt": "",          // empty prompt just loads the model into memory
            "stream": false,
            "keep_alive": "5m"
        ])
        request.timeoutInterval = 30
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - LLM path (Ollama)

    private static let systemPrompt = """
    Add structure to this text — paragraph breaks, and bullet lists only for explicit lists. Change nothing else.
    - Default to paragraphs: group related sentences, with a blank line between paragraphs.
    - Use a bulleted list only when the speaker explicitly lists three or more distinct items. Never bullet ordinary prose.
    Keep every word EXACTLY as written — never paraphrase, simplify, reword, reorder, add, or remove anything. Your job is to prettify, not rewrite. Output only the restructured text.
    """

    private static func requestBody(_ text: String, stream: Bool) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "model": Settings.shared.cleanupModel,
            "prompt": "\(systemPrompt)\n\nTranscript:\n\(text)\n\nFormatted:",
            "stream": stream,
            "keep_alive": "5m",             // warm while actively dictating, release after 5 min idle
            "options": ["temperature": 0.2]
        ])
    }

    /// Streaming cleanup: invokes `onChunk` with each token as it's generated so
    /// the caller can insert text live (perceived-instant). Returns the full text.
    /// Never throws — falls back to rule-based (emitted as one chunk) if Ollama is down.
    static func processStreaming(_ raw: String, onChunk: @escaping (String) async -> Void) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard Settings.shared.cleanupEnabled else {
            let r = ruleBased(trimmed); await onChunk(r); return r
        }
        if let full = await streamLLM(trimmed, onChunk: onChunk) { return full }
        let r = ruleBased(trimmed); await onChunk(r); return r
    }

    private static func streamLLM(_ text: String, onChunk: @escaping (String) async -> Void) async -> String? {
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
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let piece = json["response"] as? String, !piece.isEmpty {
                    full += piece
                    await onChunk(piece)
                }
                if (json["done"] as? Bool) == true { break }
            }
            return full.isEmpty ? nil : full.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil   // Ollama not running / timed out → caller falls back.
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
