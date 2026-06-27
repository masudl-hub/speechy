import Foundation

/// One persisted transcript.
struct TranscriptEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let raw: String         // exactly what Whisper produced
    let cleaned: String     // post-cleanup text (== raw if cleanup off)
    let app: String         // frontmost app at capture time

    var display: String { cleaned.isEmpty ? raw : cleaned }
}

/// Append-only JSONL log of transcripts, pruned to a 24h window.
/// Every transcript is written here *before* we attempt to paste, so a failed
/// paste, crash, or app switch can never lose your words.
final class HistoryStore {
    static let shared = HistoryStore()

    private let retention: TimeInterval = 24 * 60 * 60
    private let queue = DispatchQueue(label: "com.speechy.history")
    private let fileURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speechy", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.jsonl")
        prune()
    }

    /// Append a transcript and prune anything older than 24h.
    @discardableResult
    func append(raw: String, cleaned: String, app: String) -> TranscriptEntry {
        let entry = TranscriptEntry(id: UUID(), timestamp: Date(), raw: raw, cleaned: cleaned, app: app)
        queue.sync {
            if let line = try? Self.encoder.encode(entry),
               var text = String(data: line, encoding: .utf8) {
                text += "\n"
                appendString(text)
            }
        }
        prune()
        return entry
    }

    /// Recent entries, newest first.
    func recent(limit: Int = 20) -> [TranscriptEntry] {
        queue.sync { loadAll() }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Internals

    private func prune() {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-retention)
            let kept = loadAll().filter { $0.timestamp >= cutoff }
            let joined = kept.compactMap { entry -> String? in
                guard let data = try? Self.encoder.encode(entry) else { return nil }
                return String(data: data, encoding: .utf8)
            }.joined(separator: "\n")
            let out = kept.isEmpty ? "" : joined + "\n"
            try? out.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        }
    }

    private func loadAll() -> [TranscriptEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? Self.decoder.decode(TranscriptEntry.self, from: d)
        }
    }

    private func appendString(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
