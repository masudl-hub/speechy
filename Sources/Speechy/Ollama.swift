import Foundation

/// Small client for the local Ollama server — used to list installed cleanup
/// models and pull new ones on demand from the menu.
enum Ollama {
    static let base = "http://127.0.0.1:11434"

    /// Names of models currently installed (e.g. "qwen2.5:7b-instruct").
    static func installedModels() async -> Set<String> {
        guard let url = URL(string: "\(base)/api/tags") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let models = json["models"] as? [[String: Any]]
            else { return [] }
            return Set(models.compactMap { $0["name"] as? String })
        } catch {
            return []
        }
    }

    /// Pull a model. Long-running; resolves when the download completes (or fails).
    static func pull(_ model: String) async {
        guard let url = URL(string: "\(base)/api/pull") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": model, "stream": false])
        request.timeoutInterval = 3600
        _ = try? await URLSession.shared.data(for: request)
    }
}
