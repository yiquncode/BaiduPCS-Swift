import Foundation
import Testing
@testable import BaiduKit

/// 桩服务器收到的一个请求。
struct RecordedRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data

    var path: String { url.path }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var query: [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    var form: [String: String] {
        let text = String(decoding: body, as: UTF8.self)
        let pairs = text.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let decode = { (s: String) in s.removingPercentEncoding ?? s }
            return (decode(parts[0]), decode(parts.count > 1 ? parts[1] : ""))
        }
        return Dictionary(pairs, uniquingKeysWith: { $1 })
    }

    var cookies: [String: String] {
        let pairs = (header("Cookie") ?? "").components(separatedBy: "; ").compactMap { pair -> (String, String)? in
            guard let equals = pair.firstIndex(of: "=") else { return nil }
            return (String(pair[..<equals]), String(pair[pair.index(after: equals)...]))
        }
        return Dictionary(pairs, uniquingKeysWith: { $1 })
    }
}

struct StubResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    /// 模拟重定向后的最终地址。
    var url: URL?

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        var headers = headers
        headers["Content-Type"] = "application/json"
        return StubResponse(status: status, headers: headers, body: Data(text.utf8))
    }

    static func html(_ text: String, url: URL? = nil) -> StubResponse {
        StubResponse(headers: ["Content-Type": "text/html"], body: Data(text.utf8), url: url)
    }

    static let notFound = StubResponse(status: 404)
}

typealias StubHandler = @Sendable (RecordedRequest) -> StubResponse

/// 全局桩。使用它的测试都放在串行的 `StubbedNetworkTests` 中。
final class Stub: @unchecked Sendable {
    static let shared = Stub()
    private let lock = NSLock()
    private var handler: StubHandler = { _ in .notFound }
    private var recorded: [RecordedRequest] = []

    func install(_ handler: @escaping StubHandler) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    func respond(to request: RecordedRequest) -> StubResponse {
        lock.withLock {
            recorded.append(request)
            return handler(request)
        }
    }

    var requests: [RecordedRequest] { lock.withLock { recorded } }

    func requests(path: String) -> [RecordedRequest] { requests.filter { $0.path == path } }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        )
        let stub = Stub.shared.respond(to: recorded)
        let response = HTTPURLResponse(url: stub.url ?? recorded.url, statusCode: stub.status,
                                       httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

enum Fixture {
    static let cookieString = #"BDUSS=test_bduss; STOKEN=test_stoken; RT="z=1&dm=baidu.com""#
    static let credential = try! Credential.parse(cookieString)
    static let surl = "qYZEsSc"
    static let link = ShareLink.parse("https://pan.baidu.com/s/1qYZEsSc")!
    static let linkWithPassword = ShareLink.parse("https://pan.baidu.com/s/1qYZEsSc?pwd=ab12")!
    static let initURL = URL(string: "https://pan.baidu.com/share/init?surl=qYZEsSc")!

    static func client(credential: Credential = credential, _ handler: @escaping StubHandler) -> BaiduClient {
        Stub.shared.install(handler)
        let configuration = BaiduClient.defaultConfiguration()
        configuration.protocolClasses = [StubURLProtocol.self]
        return BaiduClient(credential: credential, session: URLSession(configuration: configuration))
    }

    static func sharePage(bdstoken: String = "aaaa1111", shareID: Int64 = 3003, shareUK: Int64 = 2002) -> String {
        """
        <html><body><script>
        try{ {"loginstate":1,"bdstoken":"\(bdstoken)","uk":1001,"share_uk":"\(shareUK)","shareid":\(shareID),"self":0} }catch(e){}
        </script></body></html>
        """
    }

    static func session(password: String? = "ab12", cookies: [Credential.Cookie] = [.init(name: "BDCLND", value: "clnd")]) -> ShareSession {
        ShareSession(link: password == nil ? link : linkWithPassword, password: password, shareID: 3003,
                     shareUK: 2002, bdstoken: "bbbb2222", cookies: cookies)
    }

    static func listJSON(_ items: [(fsID: Int64, name: String, path: String, isDir: Bool, size: Int64)], key: String = "list") -> String {
        let list = items.map {
            #"{"fs_id":\#($0.fsID),"server_filename":"\#($0.name)","path":"\#($0.path)","isdir":\#($0.isDir ? 1 : 0),"size":\#($0.size)}"#
        }.joined(separator: ",")
        return #"{"errno":0,"\#(key)":[\#(list)]}"#
    }
}

/// 所有使用全局桩的测试都嵌套在这个串行套件中。
@Suite(.serialized) struct StubbedNetworkTests {}
