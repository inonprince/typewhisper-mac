import Foundation
import SwiftUI
import os
import TypeWhisperPluginSDK

// MARK: - Supported Languages

private let sonioxSupportedLanguages = [
    "af", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs",
    "cy", "da", "de", "el", "en", "es", "et", "fa", "fi", "fr",
    "gl", "gu", "ha", "he", "hi", "hr", "hu", "hy", "id", "is",
    "it", "ja", "ka", "kk", "km", "kn", "ko", "lo", "lt", "lv",
    "mk", "ml", "mn", "mr", "ms", "my", "ne", "nl", "no", "pa",
    "pl", "pt", "ro", "ru", "sk", "sl", "so", "sq", "sr", "sv",
    "sw", "ta", "te", "th", "tr", "uk", "ur", "uz", "vi", "zh",
]

private let sonioxControlTokens: Set<String> = ["<end>", "<fin>"]

private func sonioxTranscriptTokenText(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return sonioxControlTokens.contains(trimmed) ? nil : text
}

private func sanitizeSonioxTranscript(_ text: String) -> String {
    sonioxControlTokens
        .reduce(text) { partial, controlToken in
            partial.replacingOccurrences(of: controlToken, with: "")
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct SonioxRealtimePreviewConfiguration: Equatable {
    let apiKey: String
    let modelId: String
    let language: String?
    let translate: Bool
}

private actor SonioxRealtimePreviewCoordinator {
    private let logger = Logger(subsystem: "com.typewhisper.soniox", category: "RealtimePreview")
    private let sampleRate = 16000
    private let chunkSize = 3840
    private let firstBufferMaxSamples = 32000
    private let maxPendingBytes = 16000 * 2 * 6
    private let idleCloseDelay: Duration = .seconds(8)

    private var configuration: SonioxRealtimePreviewConfiguration?
    private var wsTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    private var idleCloseTask: Task<Void, Never>?
    private var onProgress: (@Sendable (String) -> Bool)?

    private var pendingPCM = Data()
    private var lastSnapshot: [Float]?
    private var lastAppendDate: Date?
    private var idleGeneration = 0

    private var finals: [String] = []
    private var interim = ""
    private var detectedLanguage: String?
    private var error: String?

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        modelId: String,
        apiKey: String,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        let nextConfiguration = SonioxRealtimePreviewConfiguration(
            apiKey: apiKey,
            modelId: modelId,
            language: language,
            translate: translate
        )

        if let error {
            await closeSession(sendEnd: false)
            throw PluginTranscriptionError.apiError(error)
        }

        if configuration != nextConfiguration || wsTask == nil {
            try await startSession(configuration: nextConfiguration)
        }

        self.onProgress = onProgress

        let samples = newSamples(from: audio.samples)
        if !samples.isEmpty {
            pendingPCM.append(SonioxPlugin.floatToPCM16(samples))
            trimPendingPCMIfNeeded()
        }

        scheduleIdleClose()

        return PluginTranscriptionResult(
            text: bestCurrentText(),
            detectedLanguage: detectedLanguage ?? language
        )
    }

    func close() async {
        idleCloseTask?.cancel()
        idleCloseTask = nil
        await closeSession(sendEnd: true)
    }

    private func startSession(configuration: SonioxRealtimePreviewConfiguration) async throws {
        idleCloseTask?.cancel()
        idleCloseTask = nil
        await closeSession(sendEnd: false)

        guard let url = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket") else {
            throw PluginTranscriptionError.apiError("Invalid Soniox WebSocket URL")
        }

        let wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask.resume()

        let configString = try Self.configString(for: configuration)
        try await wsTask.send(.string(configString))

        self.configuration = configuration
        self.wsTask = wsTask
        self.pendingPCM = Data()
        self.lastSnapshot = nil
        self.lastAppendDate = nil
        self.finals = []
        self.interim = ""
        self.detectedLanguage = nil
        self.error = nil

        receiveTask = Task { await self.receiveLoop() }
        senderTask = Task { await self.sendLoop() }
    }

    private static func configString(for configuration: SonioxRealtimePreviewConfiguration) throws -> String {
        var config: [String: Any] = [
            "api_key": configuration.apiKey,
            "model": configuration.modelId,
            "audio_format": "pcm_s16le",
            "sample_rate": 16000,
            "num_channels": 1,
            "enable_endpoint_detection": true,
        ]

        if let language = configuration.language, !language.isEmpty {
            config["language_hints"] = [language]
        }

        if configuration.translate {
            config["translation"] = [
                "type": "one_way",
                "target_language": "en",
            ]
        }

        let configData = try JSONSerialization.data(withJSONObject: config)
        guard let configString = String(data: configData, encoding: .utf8) else {
            throw PluginTranscriptionError.apiError("Failed to encode config")
        }
        return configString
    }

    private func sendLoop() async {
        while !Task.isCancelled {
            guard let wsTask else { return }

            guard let chunk = popNextChunk() else {
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }

            do {
                try await wsTask.send(.data(chunk))
                let bytesPerSecond = Double(sampleRate * 2)
                let chunkDuration = Double(chunk.count) / bytesPerSecond
                try await Task.sleep(for: .seconds(chunkDuration))
            } catch {
                self.error = error.localizedDescription
                logger.error("Soniox preview send error: \(error.localizedDescription)")
                return
            }
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let wsTask else { return }

            do {
                let message = try await wsTask.receive()
                guard case .string(let text) = message else { continue }
                try await processReceivedText(text)
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                    logger.error("Soniox preview receive error: \(error.localizedDescription)")
                }
                return
            }
        }
    }

    private func processReceivedText(_ text: String) async throws {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let isFinished = json["finished"] as? Bool == true

        if let errorObj = json["error"] as? [String: Any] {
            let msg = errorObj["message"] as? String ?? "Unknown Soniox error"
            logger.error("Soniox error: \(msg)")
            self.error = msg
            return
        }
        if let errorCode = json["error_code"] {
            let msg = json["error_message"] as? String ?? "Unknown Soniox error"
            logger.error("Soniox error \(String(describing: errorCode)): \(msg)")
            self.error = msg
            return
        }

        if let tokens = json["tokens"] as? [[String: Any]] {
            var finalText: [String] = []
            var interimText: [String] = []
            var tokenLanguage: String?

            for token in tokens {
                guard let tokenStr = token["text"] as? String else { continue }
                guard let transcriptTokenText = sonioxTranscriptTokenText(tokenStr) else { continue }

                if configuration?.translate == true {
                    let status = token["translation_status"] as? String
                    if status == "original" { continue }
                }

                let isFinal = token["is_final"] as? Bool ?? false
                if let lang = token["language"] as? String, !lang.isEmpty {
                    tokenLanguage = lang
                }

                if isFinal {
                    finalText.append(transcriptTokenText)
                } else {
                    interimText.append(transcriptTokenText)
                }
            }

            addFinal(finalText.joined(), language: tokenLanguage)
            setInterim(interimText.joined(), language: tokenLanguage)

            let currentText = bestCurrentText()
            if !currentText.isEmpty, onProgress?(currentText) == false {
                await closeSession(sendEnd: false)
                return
            }
        }

        if isFinished {
            await closeSession(sendEnd: false)
        }
    }

    private func addFinal(_ text: String, language: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            finals.append(trimmed)
            interim = ""
        }
        if let language, !language.isEmpty {
            detectedLanguage = language
        }
    }

    private func setInterim(_ text: String, language: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        interim = trimmed
        if let language, !language.isEmpty {
            detectedLanguage = language
        }
    }

    private func bestCurrentText() -> String {
        var parts = finals
        if !interim.isEmpty {
            parts.append(interim)
        }
        return parts.joined(separator: " ")
    }

    private func newSamples(from samples: [Float]) -> [Float] {
        let now = Date()
        defer {
            lastSnapshot = samples
            lastAppendDate = now
        }

        guard !samples.isEmpty else { return [] }
        guard let lastSnapshot, let lastAppendDate else {
            return Array(samples.suffix(min(samples.count, firstBufferMaxSamples)))
        }

        if samples == lastSnapshot {
            return []
        }

        if samples.count > lastSnapshot.count,
           samples.prefix(lastSnapshot.count).elementsEqual(lastSnapshot) {
            return Array(samples.suffix(samples.count - lastSnapshot.count))
        }

        let elapsed = max(0, now.timeIntervalSince(lastAppendDate))
        let estimatedNewSamples = min(samples.count, Int(elapsed * Double(sampleRate)))
        guard estimatedNewSamples > 0 else { return [] }
        return Array(samples.suffix(estimatedNewSamples))
    }

    private func popNextChunk() -> Data? {
        guard !pendingPCM.isEmpty else { return nil }

        let count = min(chunkSize, pendingPCM.count)
        let chunk = Data(pendingPCM.prefix(count))
        pendingPCM.removeFirst(count)
        return chunk
    }

    private func trimPendingPCMIfNeeded() {
        guard pendingPCM.count > maxPendingBytes else { return }
        pendingPCM.removeFirst(pendingPCM.count - maxPendingBytes)
    }

    private func scheduleIdleClose() {
        idleGeneration += 1
        let generation = idleGeneration

        idleCloseTask?.cancel()
        idleCloseTask = Task {
            try? await Task.sleep(for: idleCloseDelay)
            await self.closeIfIdle(generation: generation)
        }
    }

    private func closeIfIdle(generation: Int) async {
        guard generation == idleGeneration else { return }
        await closeSession(sendEnd: true)
    }

    private func closeSession(sendEnd: Bool) async {
        let wsTask = self.wsTask

        senderTask?.cancel()
        receiveTask?.cancel()
        senderTask = nil
        receiveTask = nil

        if sendEnd, let wsTask {
            try? await wsTask.send(.string(""))
        }
        wsTask?.cancel(with: .normalClosure, reason: nil)

        configuration = nil
        self.wsTask = nil
        onProgress = nil
        pendingPCM = Data()
        lastSnapshot = nil
        lastAppendDate = nil
        finals = []
        interim = ""
        detectedLanguage = nil
        error = nil
    }
}

// MARK: - Plugin Entry Point

@objc(SonioxPlugin)
final class SonioxPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.soniox"
    static let pluginName = "Soniox"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?

    private let logger = Logger(subsystem: "com.typewhisper.soniox", category: "Plugin")
    private let realtimePreview = SonioxRealtimePreviewCoordinator()

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            ?? transcriptionModels.first?.id
    }

    func deactivate() {
        Task { await realtimePreview.close() }
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "soniox" }
    var providerDisplayName: String { "Soniox" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    var transcriptionModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "stt-rt-v4", displayName: "STT RT v4"),
            PluginModelInfo(id: "stt-rt-preview", displayName: "STT RT Preview"),
        ]
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
        Task { await realtimePreview.close() }
    }

    var supportsTranslation: Bool { true }
    var supportsStreaming: Bool { true }

    var supportedLanguages: [String] { sonioxSupportedLanguages }

    // MARK: - Transcription (REST Fallback)

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }

        await realtimePreview.close()
        return try await transcribeREST(audio: audio, language: language, translate: translate, apiKey: apiKey)
    }

    // MARK: - Transcription (WebSocket Streaming)

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        do {
            return try await transcribeWebSocket(
                audio: audio, language: language, translate: translate,
                modelId: modelId, apiKey: apiKey, onProgress: onProgress
            )
        } catch {
            logger.warning("WebSocket streaming failed, falling back to REST: \(error.localizedDescription)")
            return try await transcribeREST(audio: audio, language: language, translate: translate, apiKey: apiKey)
        }
    }

    // MARK: - WebSocket Implementation

    private func transcribeWebSocket(
        audio: AudioData,
        language: String?,
        translate: Bool,
        modelId: String,
        apiKey: String,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        try await realtimePreview.transcribe(
            audio: audio,
            language: language,
            translate: translate,
            modelId: modelId,
            apiKey: apiKey,
            onProgress: onProgress
        )
    }

    // MARK: - REST Implementation (4-Step Async)

    private func transcribeREST(
        audio: AudioData,
        language: String?,
        translate: Bool,
        apiKey: String
    ) async throws -> PluginTranscriptionResult {
        let fileId = try await uploadFile(wavData: audio.wavData, apiKey: apiKey)
        let transcriptionId = try await createTranscription(
            fileId: fileId, language: language, translate: translate, apiKey: apiKey
        )
        try await pollUntilCompleted(id: transcriptionId, apiKey: apiKey)
        return try await fetchTranscript(id: transcriptionId, apiKey: apiKey, language: language)
    }

    private func uploadFile(wavData: Data, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.soniox.com/v1/files") else {
            throw PluginTranscriptionError.apiError("Invalid upload URL")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200, 201: break
        case 401: throw PluginTranscriptionError.invalidApiKey
        case 413: throw PluginTranscriptionError.fileTooLarge
        case 429: throw PluginTranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Upload failed HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileId = json["id"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid upload response")
        }

        return fileId
    }

    private func createTranscription(
        fileId: String,
        language: String?,
        translate: Bool,
        apiKey: String
    ) async throws -> String {
        guard let url = URL(string: "https://api.soniox.com/v1/transcriptions") else {
            throw PluginTranscriptionError.apiError("Invalid transcriptions URL")
        }

        var body: [String: Any] = [
            "file_id": fileId,
            "model": "stt-async-v4",
        ]

        if let language, !language.isEmpty {
            body["language_hints"] = [language]
        }

        if translate {
            body["translation"] = [
                "type": "one_way",
                "target_language": "en",
            ]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200, 201: break
        case 401: throw PluginTranscriptionError.invalidApiKey
        case 429: throw PluginTranscriptionError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Create transcription failed HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw PluginTranscriptionError.apiError("Invalid transcription creation response")
        }

        return id
    }

    private func pollUntilCompleted(id: String, apiKey: String) async throws {
        guard let url = URL(string: "https://api.soniox.com/v1/transcriptions/\(id)") else {
            throw PluginTranscriptionError.apiError("Invalid poll URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        for _ in 0..<300 {
            try await Task.sleep(for: .seconds(1))

            let (data, response) = try await PluginHTTPClient.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                continue
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else {
                continue
            }

            switch status {
            case "completed":
                return
            case "error", "failed":
                // Try multiple error field formats
                let errorMsg: String
                if let errStr = json["error"] as? String {
                    errorMsg = errStr
                } else if let errObj = json["error"] as? [String: Any], let msg = errObj["message"] as? String {
                    errorMsg = msg
                } else if let errMsg = json["error_message"] as? String {
                    errorMsg = errMsg
                } else {
                    // Log full response for debugging
                    let responseStr = String(data: data, encoding: .utf8) ?? ""
                    logger.error("Soniox transcription failed, full response: \(responseStr)")
                    errorMsg = "Transcription failed (status: \(status))"
                }
                throw PluginTranscriptionError.apiError(errorMsg)
            default:
                continue
            }
        }

        throw PluginTranscriptionError.apiError("Transcription timed out after 5 minutes")
    }

    private func fetchTranscript(id: String, apiKey: String, language: String?) async throws -> PluginTranscriptionResult {
        guard let url = URL(string: "https://api.soniox.com/v1/transcriptions/\(id)/transcript") else {
            throw PluginTranscriptionError.apiError("Invalid transcript URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.apiError("No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginTranscriptionError.apiError("Fetch transcript failed HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginTranscriptionError.apiError("Invalid transcript response")
        }

        // Extract full text from tokens or top-level text field
        let text: String
        if let tokens = json["tokens"] as? [[String: Any]] {
            text = tokens.compactMap { ($0["text"] as? String).flatMap(sonioxTranscriptTokenText) }.joined()
        } else {
            text = sanitizeSonioxTranscript(json["text"] as? String ?? "")
        }

        return PluginTranscriptionResult(text: text, detectedLanguage: language)
    }

    // MARK: - Audio Conversion

    fileprivate static func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0)
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - API Key Validation

    fileprivate func validateApiKey(_ key: String) async -> Bool {
        guard let url = URL(string: "https://api.soniox.com/v1/files") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(SonioxSettingsView(plugin: self))
    }

    // MARK: - Internal Methods for Settings

    fileprivate func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[SonioxPlugin] Failed to store API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    fileprivate func removeApiKey() {
        _apiKey = nil
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: "")
            } catch {
                print("[SonioxPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }
}

// MARK: - Settings View

private struct SonioxSettingsView: View {
    let plugin: SonioxPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    private let bundle = Bundle(for: SonioxPlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // API Key Section
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key", bundle: bundle)
                    .font(.headline)

                HStack(spacing: 8) {
                    if showApiKey {
                        TextField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)

                    if plugin.isConfigured {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            apiKeyInput = ""
                            validationResult = nil
                            plugin.removeApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    } else {
                        Button(String(localized: "Save", bundle: bundle)) {
                            saveApiKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if isValidating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating...", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let result = validationResult {
                    HStack(spacing: 4) {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result ? .green : .red)
                        Text(result ? String(localized: "Valid API Key", bundle: bundle) : String(localized: "Invalid API Key", bundle: bundle))
                            .font(.caption)
                            .foregroundStyle(result ? .green : .red)
                    }
                }
            }

            if plugin.isConfigured {
                Divider()

                // Model Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model", bundle: bundle)
                        .font(.headline)

                    Picker("Model", selection: $selectedModel) {
                        ForEach(plugin.transcriptionModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectModel(selectedModel)
                    }
                }
            }

            Text("API keys are stored securely in the Keychain", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            if let key = plugin._apiKey, !key.isEmpty {
                apiKeyInput = key
            }
            selectedModel = plugin.selectedModelId ?? plugin.transcriptionModels.first?.id ?? ""
        }
    }

    private func saveApiKey() {
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        plugin.setApiKey(trimmedKey)

        isValidating = true
        validationResult = nil
        Task {
            let isValid = await plugin.validateApiKey(trimmedKey)
            await MainActor.run {
                isValidating = false
                validationResult = isValid
            }
        }
    }
}
