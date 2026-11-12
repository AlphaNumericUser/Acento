import Foundation

// Keep these settings-only checks away from saved recordings and credentials.
enum RecordingStorage {
    static func delete(_ filename: String?) {}
    static func folder(_ name: String) throws -> URL { FileManager.default.temporaryDirectory }
}
enum CredentialStore {
    static func get(_ account: String) -> String? { nil }
}
struct SpeechFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main
struct AIProviderSettingsChecks {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        let legacy = Data(#"{"provider":"cerebras","model":"gpt-oss-120b","reasoningEffort":"low","temperature":0.37,"enabled":false,"includeAppName":false,"systemPrompt":"My custom prompt","contextualPromptVersion":1}"#.utf8)
        var settings = try JSONDecoder().decode(AIProcessingSettings.self, from: legacy)
        let cerebras = settings.parameters(for: .cerebras)
        expect(cerebras == AIProviderParameters(model: "gpt-oss-120b", reasoningEffort: "low"), "Migrate existing active provider and ignore its legacy temperature")
        let prompt = settings.systemPrompt
        let beforeCancel = try JSONEncoder().encode(settings)
        var draft = settings.parameters(for: .openAI)
        draft.model = "gpt-4o"
        expect(settings.provider == .cerebras && settings.model == "gpt-oss-120b", "Editing another provider must not activate or change it")
        let afterCancel = try JSONDecoder().decode(AIProcessingSettings.self, from: beforeCancel)
        expect(afterCancel.parameters(for: .openAI).model == "gpt-4.1-mini", "Discarded draft leaves saved settings untouched")
        settings.use(.openAI, parameters: draft)
        expect(settings.provider == .openAI && settings.model == "gpt-4o", "Save and use applies the edited provider atomically")
        expect(settings.parameters(for: .cerebras) == cerebras, "Switching preserves the previous provider")
        let expected: [AITextProvider: AIProviderParameters] = [
            .cerebras: cerebras, .openAI: draft,
            .gemini: AIProviderParameters(model: "gemini-2.5-flash", reasoningEffort: "medium"),
            .openRouter: AIProviderParameters(model: "google/gemini-2.5-flash", reasoningEffort: "none")
        ]
        for provider in AITextProvider.allCases { settings.use(provider, parameters: expected[provider]!) }
        settings = try JSONDecoder().decode(AIProcessingSettings.self, from: JSONEncoder().encode(settings))
        for provider in AITextProvider.allCases {
            expect(settings.parameters(for: provider) == expected[provider], "Each provider survives a persistence round trip: \(provider)")
            settings.use(provider, parameters: settings.parameters(for: provider))
            expect(settings.model == expected[provider]!.model && settings.reasoningEffort == expected[provider]!.reasoningEffort,
                   "Reopening and saving restores that provider's own parameters")
        }
        expect(!settings.enabled && !settings.includeAppName && settings.systemPrompt == prompt, "Provider saves preserve global preferences and custom instructions")
        let normalized = AIProviderParameters(model: "unknown", reasoningEffort: "high").validated(for: .openAI)
        expect(normalized.model == "unknown" && normalized.reasoningEffort == "none", "Keep live-listed models and drop unsupported reasoning")
        expect(AIProviderParameters(model: " ").validated(for: .openAI).model == "gpt-4.1-mini", "Empty model falls back to the provider default")
        let gpt5 = AIProviderParameters(model: "gpt-5-mini", reasoningEffort: "none").validated(for: .openAI)
        expect(gpt5.reasoningEffort == "low" && !AITextModelCapabilities.supportsTemperature(.openAI, model: "gpt-5-mini"), "OpenAI reasoning models get effort and fixed temperature")
        expect(AITextModelCapabilities.reasoningOptions(.openAI, model: "gpt-6.1-sol") == ["low", "medium", "high"]
               && AITextModelCapabilities.reasoningOptions(.openAI, model: "o5-mini").count == 3
               && AITextModelCapabilities.reasoningOptions(.openAI, model: "gpt-4.1").isEmpty
               && AITextModelCapabilities.reasoningOptions(.openAI, model: "gpt-6-chat-latest").isEmpty, "Newer OpenAI generations get reasoning effort")
        expect(AITextModelCapabilities.reasoningOptions(.gemini, model: "gemini-2.5-flash").first == "none"
               && AITextModelCapabilities.reasoningOptions(.gemini, model: "gemini-2.5-pro") == ["low", "medium", "high"], "Gemini thinking options per model")
        let openAIList = AITextModelCatalog.parse(.openAI, json: ["data": ["gpt-5-mini", "gpt-4o-mini-tts", "gpt-4.1-2025-04-14", "whisper-1", "o3-pro", "gpt-4.1"].map { ["id": $0] }])
        expect(openAIList.map(\.id) == ["gpt-4.1", "gpt-5-mini"], "OpenAI list keeps chat models only: \(openAIList.map(\.id))")
        let geminiList = AITextModelCatalog.parse(.gemini, json: ["models": [
            ["name": "models/gemini-2.5-flash", "supportedGenerationMethods": ["generateContent"]],
            ["name": "models/gemini-embedding-001", "supportedGenerationMethods": ["embedContent"]],
            ["name": "models/gemini-2.5-flash-preview-tts", "supportedGenerationMethods": ["generateContent"]]]])
        expect(geminiList.map(\.id) == ["gemini-2.5-flash"], "Gemini list keeps text generation models")
        let routerList = AITextModelCatalog.parse(.openRouter, json: ["data": [
            ["id": "a/think", "architecture": ["input_modalities": ["text"], "output_modalities": ["text"]], "supported_parameters": ["reasoning"]],
            ["id": "b/image", "architecture": ["input_modalities": ["text"], "output_modalities": ["image", "text"]]]]])
        AITextModelCache.save(routerList, for: .openRouter)
        expect(routerList.map(\.id) == ["a/think"] && AITextModelCapabilities.reasoningOptions(.openRouter, model: "a/think").contains("high"), "OpenRouter reasoning comes from published capabilities")
        AITextModelCache.save([], for: .openRouter)
        let reasoning = AIProviderParameters(model: "gpt-oss-120b", reasoningEffort: "none").validated(for: .cerebras)
        expect(reasoning.reasoningEffort == "low", "GPT OSS requires a supported reasoning effort")
        print("Passed \(checks) provider settings, migration, draft isolation, and persistence checks.")
    }
}
