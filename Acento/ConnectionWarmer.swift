import Foundation

/// Opens the HTTPS connections a dictation will need while the user is still speaking,
/// so the transcription and AI requests skip DNS, TCP and TLS setup. The requests share
/// `URLSession.shared`, whose connection pool the real API calls reuse.
enum ConnectionWarmer {
    private static var lastWarmed: [String: TimeInterval] = [:]
    private static let interval: TimeInterval = 20

    static func origin(for model: SpeechModel) -> String? {
        switch model {
        case .groq: "https://api.groq.com"
        case .openAI: "https://api.openai.com"
        case .gemini: "https://generativelanguage.googleapis.com"
        case .openRouter: "https://openrouter.ai"
        default: nil
        }
    }

    static func origin(for provider: AITextProvider) -> String {
        switch provider {
        case .cerebras: "https://api.cerebras.ai"
        case .openAI: "https://api.openai.com"
        case .gemini: "https://generativelanguage.googleapis.com"
        case .openRouter: "https://openrouter.ai"
        }
    }

    static func warm(_ origins: [String], now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        for origin in Set(origins) {
            if let last = lastWarmed[origin], now - last < interval { continue }
            guard let url = URL(string: origin) else { continue }
            lastWarmed[origin] = now
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            request.httpMethod = "HEAD"
            Task.detached(priority: .utility) { _ = try? await URLSession.shared.data(for: request) }
        }
    }
}
