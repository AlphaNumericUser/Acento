import Foundation

enum CloudTranscriber {
    static func transcribe(_ url: URL, provider: SpeechModel, key: String, autoDetectLanguage: Bool) async throws -> String {
        let audio = try Data(contentsOf: url)
        switch WAVSpeechCheck.evaluate(audio) {
        case .tooShort: throw SpeechFailure("The recording is too short to transcribe.")
        case .silent: throw SpeechFailure("No speech was detected. The recording was kept for retry.")
        case .speech, .unknown: break
        }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let languageName = Locale.current.localizedString(forLanguageCode: language) ?? language
        let prompt = autoDetectLanguage
            ? "Transcribe the spoken audio verbatim in its original language. Return only the transcript, without commentary or formatting."
            : "Transcribe the spoken audio verbatim in \(languageName) (\(language)). Do not translate it. Return only the transcript, without commentary or formatting."
        switch provider {
        case .groq:
            return try await transcribeWithGroq(audio, key: key, language: autoDetectLanguage ? nil : language)
        case .openAI:
            guard audio.count < 25_000_000 else { throw SpeechFailure("OpenAI accepts recordings under 25 MB. Try a shorter dictation.") }
            let boundary = "Speech-\(UUID().uuidString)"
            var body = Data()
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n".utf8))
            if !autoDetectLanguage {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n".utf8))
            }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            body.append(audio)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let response = try await send(request, provider: provider)
            return (response["text"] as? String) ?? ""
        case .gemini:
            guard audio.count < 14_000_000 else { throw SpeechFailure("Gemini's inline audio limit is 20 MB including base64 encoding. Try a shorter dictation.") }
            var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")!)
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["contents": [["parts": [
                ["text": prompt],
                ["inline_data": ["mime_type": "audio/wav", "data": audio.base64EncodedString()]]
            ]]]])
            let response = try await send(request, provider: provider)
            let candidates = response["candidates"] as? [[String: Any]] ?? []
            let content = candidates.first?["content"] as? [String: Any] ?? [:]
            let parts = content["parts"] as? [[String: Any]] ?? []
            return parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        case .openRouter:
            guard audio.count < 14_000_000 else { throw SpeechFailure("The audio exceeds the inline request size. Try a shorter dictation.") }
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "google/gemini-2.5-flash",
                "messages": [["role": "user", "content": [
                    ["type": "text", "text": prompt],
                    ["type": "input_audio", "input_audio": ["data": audio.base64EncodedString(), "format": "wav"]]
                ]]]
            ])
            let response = try await send(request, provider: provider)
            let choices = response["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any] ?? [:]
            return message["content"] as? String ?? ""
        default:
            throw SpeechFailure("Unknown API provider.")
        }
    }

    private static func transcribeWithGroq(_ audio: Data, key: String, language: String?) async throws -> String {
        guard audio.count < 25_000_000 else { throw SpeechFailure("Groq accepts recordings under 25 MB. Try a shorter dictation.") }
        let boundary = "Speech-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", GroqTranscriptionModel.current.rawValue)
        field("response_format", "json")
        field("temperature", "0")
        if let language { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let response = try await send(request, provider: .groq)
        return (response["text"] as? String) ?? ""
    }

    /// Sends a request with the same error handling for every API provider: rate limits (HTTP 429) are
    /// retried after 1, 2 and 4 seconds; anything else becomes a clear message. No other model takes over.
    private static func send(_ request: URLRequest, provider: SpeechModel) async throws -> [String: Any] {
        let name = provider.title
        var attempt = 0
        while true {
            do {
                return try await send(request)
            } catch let error as ProviderHTTPError {
                switch error.status {
                case 429 where attempt < 3:
                    try await Task.sleep(for: .seconds(1 << attempt))
                    attempt += 1
                case 429: throw SpeechFailure(L10n.format("%@'s rate limit was reached. Try again in a moment.", name))
                case 401, 403: throw SpeechFailure(L10n.format("%@ rejected the API key. Check it in Models → API.", name))
                case 413: throw SpeechFailure(L10n.format("The recording is too large for %@. Try a shorter dictation.", name))
                case 500...599: throw SpeechFailure(L10n.format("%@ is having problems right now. Try again in a moment.", name))
                default: throw error
                }
            } catch let error as URLError where NetworkMonitor.connectivityCodes.contains(error.code) {
                throw OfflineFailure(provider: name)
            }
        }
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpeechFailure("No response from the provider.") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200...299).contains(http.statusCode) else {
            let apiError = json["error"] as? [String: Any]
            let detail = (apiError?["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ProviderHTTPError(status: http.statusCode, detail: detail)
        }
        return json
    }
}

struct ProviderHTTPError: LocalizedError {
    let status: Int
    let detail: String
    var errorDescription: String? { L10n.format("Provider error (%ld): %@", status, detail) }
}
