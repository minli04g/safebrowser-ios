import Foundation
import WebKit

enum NativeMessageAPIError: LocalizedError {
    case invalidServerConfiguration
    case unauthorized
    case server(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidServerConfiguration:
            return "The server address is unavailable."
        case .unauthorized:
            return "Sign in from Manage to use Messages."
        case .server:
            return "The message server is temporarily unavailable."
        case .invalidResponse:
            return "The message server returned an invalid response."
        }
    }
}

final class NativeMessageAPI {
    let baseURL: URL
    private let cookieStore: WKHTTPCookieStore
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init?(cookieStore: WKHTTPCookieStore, session: URLSession = .shared) {
        guard let serverURL = NativeServerConfiguration.serverURL else { return nil }
        self.baseURL = serverURL
        self.cookieStore = cookieStore
        self.session = session
    }

    func listConversations() async throws -> [NativeMessageConversation] {
        let response: NativeConversationsResponse = try await request(path: "/v1/messages/conversations")
        return response.conversations
    }

    func listMessages(conversationId: String, before: String? = nil) async throws -> NativeMessagesResponse {
        var path = "/v1/messages/conversations/\(encodePath(conversationId))/messages"
        if let before, !before.isEmpty {
            path += "?before=\(encodeQuery(before))"
        }
        return try await request(path: path)
    }

    func sendMessage(conversationId: String, text: String, mentions: [NativeMessageActor]) async throws -> NativeMessageRecord {
        let body = NativeSendMessageBody(text: text, mentions: mentions.isEmpty ? nil : mentions)
        let response: NativeSendMessageResponse = try await request(
            path: "/v1/messages/conversations/\(encodePath(conversationId))/messages",
            method: "POST",
            body: try encoder.encode(body)
        )
        return response.message
    }

    func markSeen(conversationId: String, messageId: String?) async throws {
        let body = NativeSeenMessageBody(messageId: messageId)
        let _: NativeSeenMessageResponse = try await request(
            path: "/v1/messages/conversations/\(encodePath(conversationId))/seen",
            method: "POST",
            body: try encoder.encode(body)
        )
    }

    func sendVoiceMessage(
        conversationId: String,
        data: Data,
        durationMs: Int,
        mimeType: String = "audio/mp4"
    ) async throws -> NativeMessageRecord {
        let response: NativeSendVoiceMessageResponse = try await request(
            path: "/v1/messages/conversations/\(encodePath(conversationId))/voice",
            method: "POST",
            body: data,
            headers: [
                "Content-Type": "application/octet-stream",
                "X-Voice-Duration-Ms": String(durationMs),
                "X-Voice-Mime-Type": mimeType
            ]
        )
        return response.message
    }

    func voiceData(conversationId: String, messageId: String) async throws -> Data {
        try await requestData(
            path: "/v1/messages/conversations/\(encodePath(conversationId))/voice/\(encodePath(messageId))"
        )
    }

    func makeParentWebSocket() async throws -> URLSessionWebSocketTask {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/v1/parent-ws"
        guard let url = components?.url else { throw NativeMessageAPIError.invalidServerConfiguration }
        var request = URLRequest(url: url)
        applyCookies(await cookies(), to: &request)
        return session.webSocketTask(with: request)
    }

    func absoluteURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private func request<T: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        let data = try await requestData(path: path, method: method, body: body, headers: headers)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw NativeMessageAPIError.invalidResponse
        }
    }

    private func requestData(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw NativeMessageAPIError.invalidServerConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil && headers["Content-Type"] == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        applyCookies(await cookies(), to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeMessageAPIError.invalidResponse }
        if http.statusCode == 401 { throw NativeMessageAPIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw NativeMessageAPIError.server(http.statusCode) }
        return data
    }

    private func cookies() async -> [HTTPCookie] {
        let all = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        guard let host = baseURL.host else { return [] }
        return all.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix(".\(domain)")
        }
    }

    private func applyCookies(_ cookies: [HTTPCookie], to request: inout URLRequest) {
        let headers = HTTPCookie.requestHeaderFields(with: cookies)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    }

    private func encodePath(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func encodeQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

enum NativeServerConfiguration {
    static var serverURL: URL? {
        guard
            let configURL = Bundle.main.url(forResource: "capacitor.config", withExtension: "json"),
            let data = try? Data(contentsOf: configURL),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let server = object["server"] as? [String: Any],
            let rawURL = server["url"] as? String
        else {
            return URL(string: "https://lovemin.fancytech.top:21000/")
        }
        return URL(string: rawURL)
    }
}
