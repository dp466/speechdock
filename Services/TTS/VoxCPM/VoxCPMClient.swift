import Foundation

/// Errors from the local engine. `.backendUnavailable` / `.notReady` signal that the app should fall
/// back to macOS Native TTS (never to a cloud provider).
enum VoxCPMError: LocalizedError {
    case backendUnavailable(String)   // cannot connect / no token yet
    case notReady(String)             // engine reachable but still loading or crashed
    case http(Int, String)
    case decoding(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .backendUnavailable(let m): return "VoxCPM engine unavailable: \(m)"
        case .notReady(let m): return "VoxCPM engine not ready: \(m)"
        case .http(let code, let m): return "VoxCPM engine error (HTTP \(code)): \(m)"
        case .decoding(let m): return "VoxCPM response error: \(m)"
        case .invalidResponse: return "VoxCPM engine returned an invalid response"
        }
    }

    /// Whether this error should trigger macOS-Native fallback.
    var shouldFallBackToNative: Bool {
        switch self {
        case .backendUnavailable, .notReady: return true
        case .http, .decoding, .invalidResponse: return false
        }
    }
}

/// Model presence/download snapshot from `GET /v1/model/status`.
struct VoxCPMModelStatus: Decodable, Equatable {
    let modelId: String
    let downloaded: Bool
    let state: String       // unknown | not_downloaded | downloading | ready | error
    let sizeBytes: Int
    let numFiles: Int
    let error: String?

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case downloaded, state
        case sizeBytes = "size_bytes"
        case numFiles = "num_files"
        case error
    }

    var isDownloading: Bool { state == "downloading" }
    var sizeGB: Double { Double(sizeBytes) / 1_000_000_000 }
}

/// Health snapshot from `GET /health`.
struct VoxCPMHealth: Decodable {
    let status: String
    let ready: Bool
    let model: String
    let device: String?
    let sampleRate: Int?
    let detail: String?
    let version: String?

    enum CodingKeys: String, CodingKey {
        case status, ready, model, device, detail, version
        case sampleRate = "sample_rate"
    }
}

/// Thin async HTTP client for the loopback engine. All `/v1` calls carry the session token.
struct VoxCPMClient {
    let baseURL: URL
    let tokenProvider: () -> String?
    let session: URLSession

    init(baseURL: URL, tokenProvider: @escaping () -> String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
    }

    // MARK: - Requests

    private func makeRequest(path: String, method: String = "GET", body: Data? = nil,
                             authenticated: Bool = true, timeout: TimeInterval = 30) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw VoxCPMError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let token = tokenProvider() else {
                throw VoxCPMError.backendUnavailable("no session token found (is the engine running?)")
            }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw VoxCPMError.invalidResponse }
            return (data, http)
        } catch let error as VoxCPMError {
            throw error
        } catch {
            // Connection refused / timeout / host down → treat as backend unavailable (fall back).
            throw VoxCPMError.backendUnavailable(error.localizedDescription)
        }
    }

    // MARK: - Endpoints

    /// `GET /health` — unauthenticated. Returns nil-safe health; throws only on connection failure.
    func health() async throws -> VoxCPMHealth {
        let req = try makeRequest(path: "health", authenticated: false, timeout: 5)
        let (data, http) = try await send(req)
        guard http.statusCode == 200 else {
            throw VoxCPMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(VoxCPMHealth.self, from: data)
        } catch {
            throw VoxCPMError.decoding(error.localizedDescription)
        }
    }

    /// `GET /v1/model/status`.
    func modelStatus() async throws -> VoxCPMModelStatus {
        try await decode(VoxCPMModelStatus.self, path: "v1/model/status")
    }

    /// `POST /v1/model/download` — starts a background download; returns the current status.
    func startModelDownload() async throws -> VoxCPMModelStatus {
        try await decode(VoxCPMModelStatus.self, path: "v1/model/download", method: "POST", body: Data("{}".utf8))
    }

    private func decode<T: Decodable>(_ type: T.Type, path: String, method: String = "GET",
                                      body: Data? = nil) async throws -> T {
        let req = try makeRequest(path: path, method: method, body: body)
        let (data, http) = try await send(req)
        try Self.throwIfError(http, data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw VoxCPMError.decoding(error.localizedDescription)
        }
    }

    /// `GET /v1/voices`.
    func listVoices() async throws -> [VoxCPMVoiceProfile] {
        let req = try makeRequest(path: "v1/voices")
        let (data, http) = try await send(req)
        try Self.throwIfError(http, data)
        struct Wrapper: Decodable { let data: [VoxCPMVoiceProfile] }
        do {
            return try JSONDecoder().decode(Wrapper.self, from: data).data
        } catch {
            throw VoxCPMError.decoding(error.localizedDescription)
        }
    }

    /// `POST /v1/voices/import` → the created profile. Reference audio is sent base64 (kept on-Mac).
    func importVoice(displayName: String, language: String, kind: String,
                     audioData: Data?, filename: String?, transcript: String?,
                     control: String?, notes: String?, consentConfirmed: Bool) async throws -> VoxCPMVoiceProfile {
        var payload: [String: Any] = [
            "displayName": displayName,
            "language": language,
            "kind": kind,
            "consentConfirmed": consentConfirmed,
        ]
        if let audioData { payload["referenceAudioBase64"] = audioData.base64EncodedString() }
        if let filename { payload["filename"] = filename }
        if let transcript, !transcript.isEmpty { payload["optionalReferenceTranscript"] = transcript }
        if let control, !control.isEmpty { payload["control"] = control }
        if let notes, !notes.isEmpty { payload["notes"] = notes }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = try makeRequest(path: "v1/voices/import", method: "POST", body: body, timeout: 60)
        let (data, http) = try await send(req)
        try Self.throwIfError(http, data)
        do {
            return try JSONDecoder().decode(VoxCPMVoiceProfile.self, from: data)
        } catch {
            throw VoxCPMError.decoding(error.localizedDescription)
        }
    }

    /// `DELETE /v1/voices/{id}`.
    func deleteVoice(id: String) async throws {
        let req = try makeRequest(path: "v1/voices/\(id)", method: "DELETE")
        let (data, http) = try await send(req)
        try Self.throwIfError(http, data)
    }

    /// `POST /v1/audio/speech` → WAV bytes.
    func synthesize(text: String, model: String, options: VoxCPMGenerationOptions) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: options.requestBody(input: text, model: model))
        let req = try makeRequest(path: "v1/audio/speech", method: "POST", body: body, timeout: 120)
        let (data, http) = try await send(req)
        if http.statusCode == 503 {
            throw VoxCPMError.notReady(String(data: data, encoding: .utf8) ?? "engine still loading")
        }
        try Self.throwIfError(http, data)
        guard !data.isEmpty else { throw VoxCPMError.invalidResponse }
        return data
    }

    private static func throwIfError(_ http: HTTPURLResponse, _ data: Data) throws {
        guard http.statusCode != 200 && http.statusCode != 201 && http.statusCode != 204 else { return }
        let message = String(data: data, encoding: .utf8) ?? ""
        if http.statusCode == 503 { throw VoxCPMError.notReady(message) }
        throw VoxCPMError.http(http.statusCode, message)
    }
}
