import Foundation
import os
import Testing
@testable import DownloadKit

/// 桩服务器记录的一个请求。
struct LoggedRequest: Sendable {
    var url: URL
    var headers: [String: String]
    /// `Range: bytes=first-last`；last 为 nil 表示读到文件末尾。
    var range: (first: Int64, last: Int64?)?

    var token: String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value
    }
}

enum Fault: Sendable {
    case status(Int, body: String = "")
    case disconnect(afterBytes: Int)
    case wrongContentRange
    case shortBody
    case okWithBody(String)
    case redirect(to: URL)
    /// 不发送响应，直接以这个错误结束请求。
    case fail(URLError.Code)
}

/// 内存中的文件服务器。每个实例用自己的 host，所以并行运行的测试互不干扰。
final class StubServer: Sendable {
    typealias FaultRule = @Sendable (_ request: LoggedRequest, _ index: Int) -> Fault?

    let host = "\(UUID().uuidString.lowercased()).test"

    private struct State {
        var files: [String: Data] = [:]
        var supportsRanges = true
        var expiredTokens: Set<String> = []
        var stallRule: (@Sendable (LoggedRequest) -> Int?)?
        var faultRule: FaultRule?
        var log: [LoggedRequest] = []
        var activeByPath: [String: Int] = [:]
        var maxActive = 0
        var maxActiveFiles = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {
        StubProtocol.register(self, host: host)
    }

    func url(_ path: String) -> URL { URL(string: "https://\(host)\(path)")! }

    func addAlias(_ host: String) { StubProtocol.register(self, host: host) }
    func setFile(_ path: String, _ data: Data) { state.withLock { $0.files[path] = data } }
    func setSupportsRanges(_ value: Bool) { state.withLock { $0.supportsRanges = value } }
    func expire(token: String) { state.withLock { _ = $0.expiredTokens.insert(token) } }
    /// 每个请求发送这么多字节后停住，直到设为 nil 或请求被取消。
    func setStall(after bytes: Int?) {
        if let bytes {
            setStallRule { _ in bytes }
        } else {
            setStallRule(nil)
        }
    }
    /// 按请求决定停住的位置。
    func setStallRule(_ rule: (@Sendable (LoggedRequest) -> Int?)?) { state.withLock { $0.stallRule = rule } }
    func setFaultRule(_ rule: FaultRule?) { state.withLock { $0.faultRule = rule } }
    func clearLog() { state.withLock { $0.log = [] } }

    var log: [LoggedRequest] { state.withLock { $0.log } }
    var activeRequests: Int { state.withLock { $0.activeByPath.values.reduce(0, +) } }
    var maxActive: Int { state.withLock { $0.maxActive } }
    var maxActiveFiles: Int { state.withLock { $0.maxActiveFiles } }

    func serve(_ request: URLRequest, on connection: StubProtocol) {
        let url = request.url!
        let headers = request.allHTTPHeaderFields ?? [:]
        let logged = LoggedRequest(url: url, headers: headers, range: headers["Range"].flatMap(Self.parseRange))
        let path = url.path
        let (index, rule, file, supportsRanges, isExpired) = state.withLock { state in
            state.log.append(logged)
            state.activeByPath[path, default: 0] += 1
            state.maxActive = max(state.maxActive, state.activeByPath.values.reduce(0, +))
            state.maxActiveFiles = max(state.maxActiveFiles, state.activeByPath.values.count { $0 > 0 })
            return (
                state.log.count - 1,
                state.faultRule,
                state.files[path],
                state.supportsRanges,
                logged.token.map { state.expiredTokens.contains($0) } ?? false
            )
        }
        defer { state.withLock { $0.activeByPath[path, default: 0] -= 1 } }
        let fault = rule?(logged, index)
        let client = connection.client!

        func respond(_ status: Int, _ headers: [String: String] = [:], body: Data = Data()) {
            var headers = headers
            headers["Content-Length"] = headers["Content-Length"] ?? String(body.count)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(connection, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client.urlProtocol(connection, didLoad: body) }
            client.urlProtocolDidFinishLoading(connection)
        }

        if isExpired {
            return respond(403, body: Data(#"{"error_code":31326,"error_msg":"link expired"}"#.utf8))
        }
        switch fault {
        case .status(let status, let body):
            return respond(status, body: Data(body.utf8))
        case .okWithBody(let body):
            return respond(200, body: Data(body.utf8))
        case .fail(let code):
            return client.urlProtocol(connection, didFailWithError: URLError(code))
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            // 新请求不带任何请求头，模拟跨主机重定向时丢失自定义请求头。
            client.urlProtocol(connection, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        default:
            break
        }
        guard let file else { return respond(404) }

        let total = Int64(file.count)
        var status = 200
        var body = file
        var responseHeaders: [String: String] = [:]
        if let range = logged.range, supportsRanges {
            let last = min(range.last ?? total - 1, total - 1)
            guard range.first <= last else { return respond(416) }
            body = Data(file[Int(range.first)...Int(last)])
            status = 206
            let first = if case .wrongContentRange = fault { range.first + 1 } else { range.first }
            responseHeaders["Content-Range"] = "bytes \(first)-\(last)/\(total)"
        }
        responseHeaders["Content-Length"] = String(body.count)
        if case .shortBody = fault {
            body = body.prefix(body.count / 2)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: responseHeaders)!
        client.urlProtocol(connection, didReceive: response, cacheStoragePolicy: .notAllowed)

        let disconnectAfter: Int? = if case .disconnect(let bytes) = fault { bytes } else { nil }
        var sent = 0
        while sent < body.count {
            if connection.isStopped { return }
            let stall = state.withLock { $0.stallRule }?(logged)
            if let stall, sent >= stall {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            var end = min(sent + 64 << 10, body.count)
            for limit in [stall, disconnectAfter].compactMap({ $0 }) where limit > sent {
                end = min(end, limit)
            }
            client.urlProtocol(connection, didLoad: body.subdata(in: sent..<end))
            sent = end
            if let disconnectAfter, sent >= disconnectAfter {
                // URLSession 收到失败时会丢掉还没交给代理的数据，所以先等数据交付。
                while (connection.task?.countOfBytesReceived ?? 0) < Int64(sent), !connection.isStopped {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return client.urlProtocol(connection, didFailWithError: URLError(.networkConnectionLost))
            }
        }
        if connection.isStopped { return }
        client.urlProtocolDidFinishLoading(connection)
    }

    private static func parseRange(_ header: String) -> (first: Int64, last: Int64?)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = Int64(bounds[0]) else { return nil }
        return (first, Int64(bounds[1]))
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = OSAllocatedUnfairLock<[String: StubServer]>(initialState: [:])
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    static func register(_ server: StubServer, host: String) {
        servers.withLock { $0[host] = server }
    }

    static func makeSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }

    /// `name` 不为 nil 时，这个会话的请求带 `X-Session: name` 头，用来区分请求来自哪个会话。
    static func makeConfiguration(name: String? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpMaximumConnectionsPerHost = 64
        if let name {
            configuration.httpAdditionalHeaders = ["X-Session": name]
        }
        return configuration
    }

    var isStopped: Bool { stopped.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        guard let host = request.url?.host(), let server = Self.servers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        DispatchQueue.global().async { server.serve(request, on: self) }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}

/// 把 `context` 当作文件路径，返回带令牌的下载链接。令牌按 `tokens` 的顺序依次使用。
final class StubSource: DownloadSource {
    private let host: String
    private let tokens: [String]
    private let count = OSAllocatedUnfairLock(initialState: 0)

    init(host: String, tokens: [String] = ["t1"]) {
        self.host = host
        self.tokens = tokens
    }

    var resolveCount: Int { count.withLock { $0 } }

    func resolve(_ request: DownloadRequest) async throws -> ResolvedURL {
        let number = count.withLock { count in
            count += 1
            return count
        }
        let token = tokens[min(number, tokens.count) - 1]
        let path = String(decoding: request.context, as: UTF8.self)
        return ResolvedURL(
            url: URL(string: "https://\(host)\(path)?token=\(token)")!,
            headers: ["Cookie": "BDUSS=test", "User-Agent": "FerryTests"]
        )
    }
}

/// 一个测试用的临时目录、桩服务器和下载源。
final class Fixture: Sendable {
    let directory: URL
    let server = StubServer()
    let source: StubSource
    let session = StubProtocol.makeSession()
    private let sizes = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    init(tokens: [String] = ["t1"]) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadKitTests-\(UUID().uuidString)")
        source = StubSource(host: server.host, tokens: tokens)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var stateDirectory: URL { directory.appendingPathComponent("state") }
    var downloadsDirectory: URL { directory.appendingPathComponent("downloads") }

    @discardableResult
    func addFile(_ name: String, size: Int) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, size) }
        server.setFile("/\(name)", data)
        sizes.withLock { $0[name] = size }
        return data
    }

    func request(_ name: String, knownSize: Bool = true) -> DownloadRequest {
        DownloadRequest(
            id: name,
            destination: downloadsDirectory.appendingPathComponent(name),
            expectedSize: knownSize ? sizes.withLock { $0[name] }.map(Int64.init) : nil,
            context: Data("/\(name)".utf8)
        )
    }

    func makeEngine(_ configuration: DownloadConfiguration = .test()) -> DownloadEngine {
        DownloadEngine(stateDirectory: stateDirectory, source: source, configuration: configuration, session: session)
    }

    func savedRecords() throws -> [DownloadRecord] {
        try StateStore(directory: stateDirectory).loadAll()
    }

    func contents(_ name: String) -> Data? {
        try? Data(contentsOf: downloadsDirectory.appendingPathComponent(name))
    }
}

extension DownloadConfiguration {
    static func test(files: Int = 2, connections: Int = 4, retries: Int = 3, throttleMultiplier: Int = 1) -> Self {
        DownloadConfiguration(
            maxConcurrentFiles: files,
            segmentsPerFile: connections,
            segmentSize: .fixed(256 << 10),
            maxRetries: retries,
            retryBaseDelay: .milliseconds(1),
            retryMaxDelay: .milliseconds(4),
            throttleBackoffMultiplier: throttleMultiplier,
            progressInterval: .milliseconds(20),
            checkpointInterval: .milliseconds(20)
        )
    }
}

struct TimeoutError: Error {}

/// 轮询直到条件成立。
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(10),
    _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for \(description)")
            throw TimeoutError()
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

extension DownloadEngine {
    nonisolated func waitForCompletion(of id: String) async throws -> URL {
        var location: URL?
        try await waitUntil("\(id) to complete") {
            switch await snapshot(id: id)?.state {
            case .completed(let url):
                location = url
                return true
            case .failed(let failure):
                Issue.record("\(id) failed: \(failure)")
                throw TimeoutError()
            default:
                return false
            }
        }
        return location!
    }
}
