import Combine
import Foundation

/// Fetches each text provider's live model list so new models appear without app updates.
@MainActor
final class AITextModelCatalog: ObservableObject {
    static let shared = AITextModelCatalog()
    private static let maxAge: TimeInterval = 6 * 60 * 60

    @Published private(set) var loading: Set<AITextProvider> = []
    @Published private(set) var errors: [AITextProvider: String] = [:]
    @Published private(set) var revision = 0

    func models(for provider: AITextProvider) -> [String] { AITextModelCache.models(provider) }
    func lastUpdated(_ provider: AITextProvider) -> Date? { AITextModelCache.entry(provider)?.fetched }

    func refreshIfStale(_ provider: AITextProvider, key: String?) {
        if let fetched = lastUpdated(provider), Date().timeIntervalSince(fetched) < Self.maxAge { return }
        Task { await refresh(provider, key: key) }
    }

    func refresh(_ provider: AITextProvider, key: String?) async {
        let key = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loading.contains(provider), provider == .openRouter || !key.isEmpty else { return }
        loading.insert(provider)
        defer { loading.remove(provider) }
        do {
            let models = try await Self.fetch(provider, key: key)
            guard !models.isEmpty else { throw SpeechFailure("The provider returned no text models.") }
            let changed = models.map(\.id) != AITextModelCache.entry(provider)?.models.map(\.id)
            AITextModelCache.save(models, for: provider)
            errors[provider] = nil
            // Only re-render pickers when the list actually changed, so silent revalidation is invisible.
            if changed { revision += 1 }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            errors[provider] = L10n.format("Couldn't update the model list: %@", error.localizedDescription)
        }
    }

    nonisolated static func fetch(_ provider: AITextProvider, key: String) async throws -> [AITextModelInfo] {
        var request: URLRequest
        switch provider {
        case .cerebras:
            request = URLRequest(url: URL(string: "https://api.cerebras.ai/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .openRouter:
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200...299).contains(status) else {
            let detail = (json["error"] as? [String: Any])?["message"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            if status == 401 || status == 403 || detail.localizedCaseInsensitiveContains("API key not valid") {
                throw SpeechFailure(L10n.text("Invalid API key."))
            }
            throw SpeechFailure("HTTP \(status): \(detail)")
        }
        return parse(provider, json: json)
    }

    /// Keeps only chat/text models usable for editing and drops dated snapshots and specialized variants.
    nonisolated static func parse(_ provider: AITextProvider, json: [String: Any]) -> [AITextModelInfo] {
        var models: [AITextModelInfo]
        switch provider {
        case .cerebras:
            models = (json["data"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? String).map { AITextModelInfo(id: $0) } }
        case .openAI:
            let excluded = ["audio", "realtime", "tts", "transcribe", "image", "search", "embedding", "instruct",
                            "codex", "moderation", "computer-use", "deep-research", "-pro"]
            models = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                .filter { id in
                    (["gpt-", "chatgpt-"].contains { id.hasPrefix($0) } || id.range(of: #"^o\d"#, options: .regularExpression) != nil)
                        && !excluded.contains { id.contains($0) }
                        && id.range(of: #"-(\d{4}-\d{2}-\d{2}|\d{4})$"#, options: .regularExpression) == nil
                }
                .map { AITextModelInfo(id: $0) }
        case .gemini:
            let excluded = ["embedding", "tts", "image", "live", "audio", "native", "computer-use", "robotics", "aqa"]
            models = (json["models"] as? [[String: Any]] ?? []).compactMap { item -> AITextModelInfo? in
                guard let name = item["name"] as? String,
                      (item["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") else { return nil }
                let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
                guard id.hasPrefix("gemini"), !excluded.contains(where: id.contains) else { return nil }
                return AITextModelInfo(id: id)
            }
        case .openRouter:
            models = (json["data"] as? [[String: Any]] ?? []).compactMap { item -> AITextModelInfo? in
                guard let id = item["id"] as? String else { return nil }
                let architecture = item["architecture"] as? [String: Any] ?? [:]
                let input = architecture["input_modalities"] as? [String] ?? ["text"]
                let output = architecture["output_modalities"] as? [String] ?? ["text"]
                guard input.contains("text"), output == ["text"] else { return nil }
                let parameters = item["supported_parameters"] as? [String] ?? []
                return AITextModelInfo(id: id, reasoning: parameters.contains("reasoning"))
            }
        }
        var seen = Set<String>()
        return models
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
