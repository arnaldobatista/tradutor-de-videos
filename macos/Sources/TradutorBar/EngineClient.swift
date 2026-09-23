import Foundation

enum EngineError: LocalizedError {
    case http(status: Int, detail: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let status, let detail): return detail ?? "HTTP \(status)"
        case .invalidResponse: return "Resposta inválida do motor"
        }
    }
}

/// Cliente HTTP do motor. Nunca envia o header `Origin`: o motor responde 403 a qualquer origem que não
/// seja a extensão, e aceita requisições sem origem (que é o caso de um app nativo).
struct EngineClient: Sendable {
    let port: Int
    private let session: URLSession

    init(port: Int) {
        self.port = port
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        // Um proxy HTTP configurado no sistema não pode entrar no caminho até o 127.0.0.1.
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config)
    }

    func health() async -> Bool {
        let health: Health? = try? await send("GET", "health")
        return health?.ok == true
    }

    func status() async throws -> EngineStatus {
        try await send("GET", "status")
    }

    func updateSetting<Value: Encodable & Sendable>(_ key: String, _ value: Value) async throws -> EngineSettings {
        try await send("PUT", "settings", body: JSONEncoder().encode([key: value]))
    }

    func cancelJob(id: String) async throws {
        let _: JobCancelled = try await send("DELETE", "jobs/\(id)")
    }

    func clearCache() async throws -> Int64 {
        // Apagar gigabytes de cache pode passar bem do timeout padrão.
        let cleared: CacheCleared = try await send("POST", "cache/clear", timeout: 120)
        return cleared.freedBytes
    }

    /// WAV curto com a voz falando uma frase. A primeira chamada de cada voz sintetiza na hora (1–3 s).
    func voiceSample(id: String) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(port)/voices/\(id)/sample") else { throw EngineError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            throw EngineError.invalidResponse
        }
        return data
    }

    private func send<Response: Decodable>(
        _ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval? = nil
    ) async throws -> Response {
        // Sempre 127.0.0.1: o motor valida o header Host e só escuta em IPv4 ("localhost" pode virar ::1).
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(path)") else { throw EngineError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EngineError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
            throw EngineError.http(status: http.statusCode, detail: detail)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }

    private struct ErrorBody: Decodable {
        let detail: String?
    }
}
