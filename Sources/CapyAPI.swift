import Foundation

// MARK: - Network discipline

/// The single network host this feature talks to. The base URL is a constant; a different endpoint can be injected
/// only in DEBUG builds through the CAPY_API_BASE_URL environment variable (integration experiments), never in a
/// release. No other Capy-related network call exists in the application, and the API key travels exclusively in the
/// Authorization header of requests built here — it is never logged, never persisted outside the Keychain and never
/// embedded in error messages.
enum CapyAPI {
    static let productionBaseURL = URL(string: "https://api.capy.ai/api/v1")!
    static let baseURL: URL = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["CAPY_API_BASE_URL"], let url = URL(string: override) { return url }
        #endif
        return productionBaseURL
    }()
    /// Model ids the picker offers — the current generation on the Capy platform. The API takes any model id
    /// string, so this list is curation, not a limit.
    static let knownModels = [
        "anthropic/claude-fable-5", "anthropic/claude-opus-5", "anthropic/claude-sonnet-5", "anthropic/claude-haiku-4-5",
        "openai/gpt-5.6-sol", "openai/gpt-5.6-terra", "openai/gpt-5.6-luna", "openai/gpt-5.5", "openai/gpt-5.3-codex",
        "google/gemini-3.1-pro-preview", "google/gemini-3-flash-preview",
        "xai/grok-4.5", "deepseek/deepseek-v4-pro", "moonshotai/kimi-k3", "zai/glm-5.2",
    ]
    static let defaultModel = "anthropic/claude-opus-5"
    /// The picker's rows: the curated list, plus the currently stored id when it is not in the list (saved by an
    /// older version, or set by hand) — an unknown selection stays visible and selectable, never silently blank.
    static func pickerModels(current: String) -> [String] {
        knownModels.contains(current) ? knownModels : [current] + knownModels
    }
    /// Reasoning modes from the API schema, plus "default" meaning the field is omitted and the platform decides.
    static let reasoningModes = ["default", "none", "minimal", "low", "medium", "high", "xhigh", "max"]
}

/// The one seam between the client and the real network: production uses URLSession, tests inject a fake and never
/// touch the network.
protocol CapyHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct CapyURLSessionTransport: CapyHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CapyAPIError.network("the response was not an HTTP response") }
        return (data, http)
    }
}

// MARK: - Named failures

/// Every way a Capy API call can fail, each named with what happened and what the user can do. There are no silent
/// retries anywhere: a failure surfaces immediately and repeating the call is always the user's explicit click.
enum CapyAPIError: LocalizedError, Equatable {
    /// HTTP 401 — the key is missing, revoked or expired; Capy deliberately answers all three identically.
    case keyRejected
    /// HTTP 402 — a paid feature or balance limit blocked the request.
    case paymentRequired(detail: String)
    /// HTTP 429 — the API rate limit; slow down and retry by hand.
    case rateLimited(detail: String)
    /// HTTP 404 — the project or thread does not exist or is not reachable from this key's organization.
    case notFound(detail: String)
    /// HTTP 5xx — a server-side failure; nothing on this side is wrong and an explicit retry is reasonable.
    case serverError(status: Int, detail: String)
    /// Any other unexpected HTTP status.
    case unexpectedStatus(status: Int, detail: String)
    /// The body did not decode as the documented shape.
    case malformedResponse(String)
    /// The request never produced an HTTP response (offline, DNS, TLS…).
    case network(String)
    /// The Capy thread itself ended in the `error` status.
    case threadFailed
    /// The named polling ceiling was reached before the thread settled; polling stopped and only an explicit user
    /// action resumes it.
    case pollTimeout(minutes: Int)

    var errorDescription: String? {
        switch self {
        case .keyRejected: "Capy rejected the API key (HTTP 401): it is missing, revoked or expired. Check the key in Settings → AI."
        case .paymentRequired(let detail): "Capy reports a billing limit (HTTP 402\(detail.isEmpty ? "" : ": \(detail)")). Resolve billing at capy.ai, then retry."
        case .rateLimited(let detail): "Capy's API rate limit answered this request (HTTP 429\(detail.isEmpty ? "" : ": \(detail)")). Wait a moment, then retry."
        case .notFound(let detail): "Capy answered 404\(detail.isEmpty ? "" : " (\(detail))"): the project or thread does not exist or is not reachable with this key. Check the project id in Settings → AI."
        case .serverError(let status, let detail): "Capy answered HTTP \(status)\(detail.isEmpty ? "" : " (\(detail))") — a server-side failure. Nothing was lost on this side; retry when ready."
        case .unexpectedStatus(let status, let detail): "Capy answered an unexpected HTTP \(status)\(detail.isEmpty ? "" : " (\(detail))")."
        case .malformedResponse(let reason): "Capy's response could not be decoded: \(reason)."
        case .network(let reason): "The request to Capy did not complete: \(reason)."
        case .threadFailed: "The Capy thread ended in the error status — the run failed on Capy's side. Start a new analysis or retry."
        case .pollTimeout(let minutes): "The Capy thread did not settle within \(minutes) minutes, so polling stopped at its named ceiling. Press Continue Polling to keep waiting."
        }
    }

    /// Maps an HTTP failure to its named case, extracting the API's own `message` (falling back to `_tag`) so the
    /// user sees Capy's explanation, never a bare status code. The response body never contains the API key, so
    /// quoting it is safe.
    static func from(status: Int, data: Data) -> CapyAPIError {
        struct Body: Decodable {
            var _tag: String?
            var message: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let detail = body?.message ?? body?._tag ?? ""
        switch status {
        case 401: return .keyRejected
        case 402: return .paymentRequired(detail: detail)
        case 429: return .rateLimited(detail: detail)
        case 404: return .notFound(detail: detail)
        case 500...599: return .serverError(status: status, detail: detail)
        default: return .unexpectedStatus(status: status, detail: detail)
        }
    }
}

// MARK: - Wire models (the documented subset the app consumes)

struct CapyModelSelection: Codable, Sendable, Equatable {
    var modelId: String
    var reasoningMode: String?
}

struct CapyThread: Codable, Sendable, Equatable {
    var id: String
    var status: String
    var title: String?
}

/// Thread statuses in which the agent is no longer working and polling must stop.
enum CapyThreadStatus {
    static let settled: Set<String> = ["pending_user", "ready_for_review", "idle", "error", "archived"]
}

struct CapyMessage: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var source: String // "user" / "assistant" / "tool"
    var tool: String?
    var text: String
    var createdAt: String
}

struct CapyMessagePage: Codable, Sendable, Equatable {
    var items: [CapyMessage]
    var cursor: String?
}

// MARK: - Client

/// Thin, injectable client for the four Capy API calls this application makes: verify access, create a thread, read
/// a thread and its transcript, send a message. Every method throws a named `CapyAPIError`; nothing retries on its own.
struct CapyAPIClient: Sendable {
    let apiKey: String
    var baseURL: URL = CapyAPI.baseURL
    var transport: any CapyHTTPTransport = CapyURLSessionTransport()

    /// The cheapest authenticated read: list one thread of the project. HTTP 200 proves both the key and the
    /// project id; the named errors distinguish a rejected key from a wrong project id.
    func checkAccess(projectID: String) async throws {
        _ = try await get(path: "threads", query: [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "limit", value: "1")])
    }

    func createThread(requestID: String, projectID: String, message: String, model: CapyModelSelection?) async throws -> CapyThread {
        struct Request: Encodable {
            var requestId: String
            var projectId: String
            var message: String
            var model: CapyModelSelection?
        }
        let data = try await post(path: "threads", body: Request(requestId: requestID, projectId: projectID, message: message, model: model))
        return try decode(CapyThread.self, from: data)
    }

    func thread(id: String) async throws -> CapyThread {
        try decode(CapyThread.self, from: try await get(path: "threads/\(id)"))
    }

    func messages(threadID: String, after: String? = nil) async throws -> CapyMessagePage {
        var query: [URLQueryItem] = []
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        return try decode(CapyMessagePage.self, from: try await get(path: "threads/\(threadID)/messages", query: query))
    }

    /// The whole transcript, following `cursor` pages to the end.
    func fullTranscript(threadID: String) async throws -> [CapyMessage] {
        var all: [CapyMessage] = []
        var after: String? = nil
        repeat {
            let page = try await messages(threadID: threadID, after: after)
            all += page.items
            after = page.cursor
        } while after != nil
        return all
    }

    func sendMessage(threadID: String, text: String) async throws {
        struct Request: Encodable { var text: String }
        _ = try await post(path: "threads/\(threadID)/message", body: Request(text: text))
    }

    // MARK: request plumbing

    private func request(path: String, query: [URLQueryItem]) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let final = components?.url else { throw CapyAPIError.network("could not build the request URL for \(path)") }
        var request = URLRequest(url: final)
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func get(path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await perform(request(path: path, query: query))
    }

    private func post<Body: Encodable>(path: String, body: Body) async throws -> Data {
        var request = try request(path: path, query: [])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) }
        catch let error as CapyAPIError { throw error }
        catch { throw CapyAPIError.network(error.localizedDescription) }
        guard (200...299).contains(response.statusCode) else { throw CapyAPIError.from(status: response.statusCode, data: data) }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw CapyAPIError.malformedResponse(error.localizedDescription) }
    }
}
