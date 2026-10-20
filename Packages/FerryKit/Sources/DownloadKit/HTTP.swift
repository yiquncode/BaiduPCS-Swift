import Foundation
import Synchronization

/// 一次请求或一次文件操作失败的原因。重试策略按它决定怎样处理。
enum FetchError: Error {
    case network(URLError.Code)
    case http(status: Int, body: String)
    case invalidResponse(String)
    /// 服务器对 Range 请求返回了整个文件。
    case rangeIgnored
    case resolve(String)
    case disk(String)

    init(_ error: any Error) {
        switch error {
        case let error as FetchError: self = error
        case let error as URLError: self = .network(error.code)
        default: self = .network(.unknown)
        }
    }

    var isRetryable: Bool {
        switch self {
        case .disk, .rangeIgnored: false
        default: true
        }
    }

    /// 这些情况多半是下载链接过期或失效，要重新获取链接。
    var invalidatesLink: Bool {
        switch self {
        case .http(let status, _): [403, 404, 410, 416].contains(status)
        case .invalidResponse: true
        default: false
        }
    }

    var isThrottled: Bool {
        if case .http(let status, _) = self { [429, 509].contains(status) } else { false }
    }

    var failure: DownloadFailure {
        switch self {
        case .network(let code): .network(code)
        case .http(let status, let body): .httpStatus(status, message: body)
        case .invalidResponse(let reason): .invalidResponse(reason)
        case .rangeIgnored: .invalidResponse("server ignored the Range header")
        case .resolve(let reason): .resolveFailed(reason)
        case .disk(let reason): .fileSystem(reason)
        }
    }
}

/// `Content-Range: bytes first-last/total`。
struct ContentRange: Equatable {
    var first: Int64
    var last: Int64
    /// 服务器写 `*` 时为 nil。
    var total: Int64?

    init?(_ header: String) {
        let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1)
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard rangeAndTotal.count == 2, bounds.count == 2,
              let first = Int64(bounds[0]), let last = Int64(bounds[1]), first <= last
        else { return nil }
        self.first = first
        self.last = last
        if rangeAndTotal[1] == "*" {
            total = nil
        } else if let total = Int64(rangeAndTotal[1]), total > last {
            self.total = total
        } else {
            return nil
        }
    }
}

/// 运行一个 data task，响应体按数据块交给 `onData`（不逐字节迭代）。
///
/// 非 2xx 响应不交给调用方，而是读取响应体的开头作为错误信息，抛出 `FetchError.http`。
final class DataTaskRunner: NSObject, URLSessionDataDelegate, Sendable {
    /// 2xx 响应到达时调用。返回 false 表示只要响应头，不接收响应体。
    typealias ResponseHandler = @Sendable (HTTPURLResponse) throws -> Bool
    typealias DataHandler = @Sendable (Data) throws -> Void

    private static let errorBodyLimit = 4096

    private struct State {
        var continuation: CheckedContinuation<HTTPURLResponse, any Error>?
        var response: HTTPURLResponse?
        var error: (any Error)?
        var errorBody: Data?
        var stoppedAfterResponse = false
    }

    private let headers: [String: String]
    private let onResponse: ResponseHandler
    private let onData: DataHandler
    private let state = Mutex(State())

    private init(headers: [String: String], onResponse: @escaping ResponseHandler, onData: @escaping DataHandler) {
        self.headers = headers
        self.onResponse = onResponse
        self.onData = onData
    }

    @discardableResult
    static func run(
        _ request: URLRequest,
        session: URLSession,
        onResponse: @escaping ResponseHandler = { _ in true },
        onData: @escaping DataHandler = { _ in }
    ) async throws -> HTTPURLResponse {
        try Task.checkCancellation()
        let runner = DataTaskRunner(headers: request.allHTTPHeaderFields ?? [:], onResponse: onResponse, onData: onData)
        let task = session.dataTask(with: request)
        task.delegate = runner
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                runner.state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // 跨主机重定向时 URLSession 会丢掉部分自定义请求头（例如 Cookie），这里补上。
        var request = request
        for (field, value) in headers where request.value(forHTTPHeaderField: field) == nil {
            request.setValue(value, forHTTPHeaderField: field)
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            state.withLock { $0.error = FetchError.invalidResponse("not an HTTP response") }
            return completionHandler(.cancel)
        }
        state.withLock { $0.response = response }
        guard (200..<300).contains(response.statusCode) else {
            state.withLock { $0.errorBody = Data() }
            return completionHandler(.allow)
        }
        do {
            if try onResponse(response) { return completionHandler(.allow) }
            state.withLock { $0.stoppedAfterResponse = true }
        } catch {
            state.withLock { $0.error = error }
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        enum Next { case deliver, stop, ignore }
        let next = state.withLock { state -> Next in
            if state.error != nil { return .ignore }
            guard var body = state.errorBody else { return .deliver }
            body.append(data.prefix(Self.errorBodyLimit - body.count))
            state.errorBody = body
            return body.count >= Self.errorBodyLimit ? .stop : .ignore
        }
        switch next {
        case .ignore:
            return
        case .stop:
            dataTask.cancel()
        case .deliver:
            do {
                try onData(data)
            } catch {
                state.withLock { $0.error = error }
                dataTask.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let state = state.withLock { state in
            defer { state.continuation = nil }
            return state
        }
        guard let continuation = state.continuation else { return }
        if let recorded = state.error {
            continuation.resume(throwing: recorded)
        } else if let response = state.response, let body = state.errorBody {
            let message = String(decoding: body, as: UTF8.self)
            continuation.resume(throwing: FetchError.http(status: response.statusCode, body: message))
        } else if let response = state.response, state.stoppedAfterResponse || error == nil {
            continuation.resume(returning: response)
        } else {
            continuation.resume(throwing: FetchError(error ?? URLError(.badServerResponse)))
        }
    }
}
