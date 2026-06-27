import Foundation
import WhisperKit

/// Wraps WhisperKit: loads the model and runs transcription with our tuned
/// DecodingOptions. See README for what each knob does.
actor Transcriber {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    var isReady: Bool { whisperKit != nil }

    /// Load (downloading if needed) the configured model.
    /// `onProgress` reports real download progress (0...1) by polling the model
    /// folder on disk, so the UI no longer sits at a misleading fixed percentage.
    func load(model: String, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        if loadedModel == model, whisperKit != nil { return }
        onProgress(0.02)

        // Self-heal: a previously truncated (0-byte) download would hang load
        // forever — delete it so WhisperKit re-fetches a clean copy.
        Self.removeIfCorrupt(model: model)

        let expectedMB = Self.expectedSizeMB(for: model)
        let progressTask = Task<Void, Never> {
            while !Task.isCancelled {
                let mb = Self.modelSizeMB(for: model)
                if expectedMB > 0 {
                    onProgress(max(0.02, min(0.9, Double(mb) / Double(expectedMB))))
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        let config = WhisperKitConfig(
            model: model, verbose: false, logLevel: .error,
            prewarm: true, load: true, download: true
        )
        do {
            let kit = try await WhisperKit(config)
            progressTask.cancel()
            onProgress(1.0)
            whisperKit = kit
            loadedModel = model
        } catch {
            progressTask.cancel()
            throw error
        }
    }

    // MARK: - Model folder helpers (download progress + integrity)

    private static let modelsRoot = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)

    private static func modelFolder(for model: String) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: modelsRoot.path) else {
            return nil
        }
        let match =
            entries.first(where: { $0.hasSuffix(model) }) ?? entries.first(where: { $0.contains(model) })
        return match.map { modelsRoot.appendingPathComponent($0, isDirectory: true) }
    }

    private static func modelSizeMB(for model: String) -> Int {
        guard let folder = modelFolder(for: model),
            let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total = 0
        for case let f as URL in en {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total / 1_000_000
    }

    private static func removeIfCorrupt(model: String) {
        guard let folder = modelFolder(for: model) else { return }
        let decoder = folder.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin")
        let attrs = try? FileManager.default.attributesOfItem(atPath: decoder.path)
        if (attrs?[.size] as? Int) == 0 {
            try? FileManager.default.removeItem(at: folder)  // truncated decoder → reset
        }
    }

    private static func expectedSizeMB(for model: String) -> Int {
        if model.contains("turbo") { return 1570 }
        if model.contains("distil") { return 1500 }
        if model.contains("large-v3") { return 3100 }
        return 1570
    }

    /// Transcribe 16 kHz mono Float samples to text using tuned options.
    func transcribe(samples: [Float]) async throws -> String {
        guard let whisperKit else { throw TranscriberError.notLoaded }

        // Silence guards — stop Whisper hallucinating ("you", "thank you", "Hmm")
        // on near-empty audio, which would otherwise paste junk on a stray tap.
        guard samples.count > 8_000 else { return "" }  // < ~0.5s → ignore
        var sum: Float = 0
        for v in samples { sum += v * v }
        let rms = sqrtf(sum / Float(samples.count))
        guard rms > 0.006 else { return "" }  // essentially silence → ignore

        var options = DecodingOptions()
        options.task = .transcribe
        let lang = Settings.shared.language
        options.language = lang.isEmpty ? nil : lang
        // Deterministic decode with fallback only when a chunk fails quality checks.
        options.temperature = 0.0
        options.temperatureFallbackCount = 5
        // Dictation: no timestamps, no word-level timing → cleaner, faster.
        options.withoutTimestamps = true
        options.wordTimestamps = false
        options.skipSpecialTokens = true
        options.suppressBlank = true
        // Anti-hallucination trio.
        options.compressionRatioThreshold = 2.4
        options.logProbThreshold = -1.0
        options.noSpeechThreshold = 0.6

        // Custom vocabulary / initial prompt — biases decoding toward your jargon.
        let prompt = Settings.shared.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty, let tokenizer = whisperKit.tokenizer {
            let tokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.promptTokens = tokens
            options.usePrefillPrompt = true
        }

        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)

        // Context-aware no-speech rejection: trust Whisper's own per-segment
        // confidence rather than blocklisting words. If you actually say "hmm",
        // the audio carries real speech energy (low noSpeechProb) and it's kept;
        // a hallucinated "hmm" over silence scores as no-speech and is dropped.
        let segments = results.flatMap { $0.segments }
        let hasRealSpeech = segments.contains { $0.noSpeechProb < 0.6 && $0.avgLogprob > -1.5 }
        if !segments.isEmpty && !hasRealSpeech { return "" }

        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Only the unmistakable video-outro phrases Whisper invents are dropped
        // unconditionally — these are never intentional dictation.
        let normalized = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?-…"))
        if Self.outroHallucinations.contains(normalized) { return "" }
        return text
    }

    private static let outroHallucinations: Set<String> = [
        "thank you for watching", "thanks for watching", "please subscribe",
        "thank you for watching!", "thanks for watching!",
    ]
}

enum TranscriberError: Error {
    case notLoaded
}
