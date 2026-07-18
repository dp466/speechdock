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
