import Foundation

/// 百度网盘协议客户端。所有网络请求都经过它。它负责 Cookie、User-Agent 和错误码到 `BaiduError` 的转换。
public actor BaiduClient {
    public let credential: Credential
    let session: URLSession
    /// `locatedownload` 签名要用的百度 uid。只查一次，查不到时用 `fallbackUID`。
    var uidLookup: Task<UInt64?, Never>?

    /// 参考实现的“强制登录”模式在贴吧接口不可用时用这个 uid，服务端可能不严格校验它。
    static let fallbackUID: UInt64 = 24

    /// `session` 用于测试注入。注入的 session 应基于 `defaultConfiguration()`。
    public init(credential: Credential, session: URLSession? = nil) {
        self.credential = credential
        self.session = session ?? URLSession(configuration: Self.defaultConfiguration())
    }

    /// Cookie 由客户端自己管理：系统的 Cookie 存储会按域名过滤，dlink 主机和同名 Cookie 都处理不了。
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 50
        return configuration
    }
}

// MARK: - 请求层

struct BaiduRequest {
    var method = "GET"
    var url: URL
    var endpoint: Endpoint
    var cookies: [Credential.Cookie]
    var headers: [String: String] = [:]
    var body: Data?

    static func form(_ items: [(String, String)], url: URL, endpoint: Endpoint, cookies: [Credential.Cookie],
                     contentType: String = "application/x-www-form-urlencoded", headers: [String: String] = [:]) -> BaiduRequest {
        var headers = headers
        headers["Content-Type"] = contentType
        return BaiduRequest(method: "POST", url: url, endpoint: endpoint, cookies: cookies,
                            headers: headers, body: URLEncoding.form(items))
    }
}

extension BaiduClient {
    /// 用户的全部 Cookie 加上会话中新增的 Cookie，同名取最新。会话中删除的 Cookie 不发送。
    func cookies(adding session: SessionCookies = SessionCookies()) -> [Credential.Cookie] {
        credential.cookies.merging(session.cookies).filter { !session.deleted.contains($0.name) }
    }

    func send(_ request: BaiduRequest) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        if let userAgent = request.endpoint.userAgent {
            urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if !request.cookies.isEmpty {
            urlRequest.setValue(request.cookies.headerValue, forHTTPHeaderField: "Cookie")
        }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw BaiduError.invalidResponse }
            return (data, http)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw BaiduError.network(error.localizedDescription)
        }
    }

    /// 解析 JSON，不检查错误码。PCS 出错时 HTTP 状态常为 4xx，响应体仍是错误 JSON，所以先解析再看状态。
    func json(_ request: BaiduRequest) async throws -> (JSON, HTTPURLResponse) {
        let (data, response) = try await send(request)
        guard let json = try? JSON(data: data) else {
            if response.statusCode >= 400 { throw BaiduError.httpStatus(response.statusCode) }
            throw BaiduError.invalidResponse
        }
        return (json, response)
    }

    /// 网盘接口：`errno` 非 0 时抛错。`mapError` 返回非 nil 时用它代替默认的错误。
    func panJSON(_ request: BaiduRequest, mapError: (Int) -> BaiduError? = { _ in nil }) async throws -> JSON {
        let (json, response) = try await json(request)
        if let errno = json["errno"].int, errno != 0 {
            throw mapError(errno)
                ?? BaiduError(code: errno, message: json["show_msg"].string ?? json["errmsg"].string, endpoint: request.endpoint)
        }
        if response.statusCode >= 400 { throw BaiduError.httpStatus(response.statusCode) }
        return json
    }

    /// PCS 接口：`error_code` 非 0 时抛错。
    func pcsJSON(_ request: BaiduRequest) async throws -> JSON {
        let (json, response) = try await json(request)
        if let code = json["error_code"].int, code != 0 {
            throw BaiduError(code: code, message: json["error_msg"].string, endpoint: request.endpoint)
        }
        if response.statusCode >= 400 { throw BaiduError.httpStatus(response.statusCode) }
        return json
    }
}
