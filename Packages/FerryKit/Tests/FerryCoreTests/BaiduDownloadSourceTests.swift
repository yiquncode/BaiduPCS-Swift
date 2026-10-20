import BaiduKit
import DownloadKit
import Foundation
import os
import Testing
@testable import FerryCore

/// 用固定 JSON 回答 `locatedownload`。贴吧接口返回错误，客户端改用默认 uid。
final class LocateStub: URLProtocol, @unchecked Sendable {
    /// `locatedownload` 的响应体。
    static let body = OSAllocatedUnfairLock(initialState: "")

    static func makeSession() -> URLSession {
        let configuration = BaiduClient.defaultConfiguration()
        configuration.protocolClasses = [LocateStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let isLocate = url.query?.contains("method=locatedownload") == true
        let text = isLocate ? Self.body.withLock { $0 } : #"{"error_code": "1", "error_msg": "stub"}"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `LocateStub` 的响应是全局的，所以这些测试依次执行。
@Suite(.serialized) struct BaiduDownloadSourceTests {
    private func makeSource() throws -> BaiduDownloadSource {
        let credential = try Credential.parse("BDUSS=bduss; STOKEN=stoken")
        let source = BaiduDownloadSource()
        source.setClient(BaiduClient(credential: credential, session: LocateStub.makeSession()))
        return source
    }

    private func request(_ id: String) -> DownloadRequest {
        DownloadRequest(id: id, destination: URL(filePath: "/tmp/a.bin"),
                        context: BaiduDownloadSource.context(forRemotePath: "/Ferry/ABCD/a.bin"))
    }

    @Test func triesNextHostEachTime() async throws {
        LocateStub.body.withLock {
            $0 = #"{"urls": [{"url": "http://h0.test/f", "encrypt": 0}, {"url": "http://h1.test/f", "encrypt": 0}, {"url": "http://h2.test/f", "encrypt": 0}]}"#
        }
        let source = try makeSource()
        var hosts: [String?] = []
        for _ in 0..<4 {
            hosts.append(try await source.resolve(request("a")).url.host())
        }
        #expect(hosts == ["h0.test", "h1.test", "h2.test", "h2.test"])
        // 每个文件下载单独计数。
        #expect(try await source.resolve(request("b")).url.host() == "h0.test")
    }

    @Test func permanentErrorsStopRetries() async throws {
        LocateStub.body.withLock { $0 = #"{"error_code": 31066, "error_msg": "file does not exist"}"# }
        let source = try makeSource()
        do {
            _ = try await source.resolve(request("a"))
            Issue.record("expected an error")
        } catch {
            #expect(error is any PermanentDownloadSourceError)
            #expect((error as? LocalizedError)?.errorDescription == BaiduError.fileNotFound.errorDescription)
        }

        let loggedOut = BaiduDownloadSource()
        await #expect(throws: PermanentLinkError.self) { try await loggedOut.resolve(request("a")) }
    }

    @Test func classifiesErrors() {
        #expect(BaiduDownloadSource.isPermanent(.loginExpired))
        #expect(BaiduDownloadSource.isPermanent(.securityVerification))
        #expect(BaiduDownloadSource.isPermanent(.invalidNameOrAccessDenied))
        #expect(!BaiduDownloadSource.isPermanent(.network("timeout")))
        #expect(!BaiduDownloadSource.isPermanent(.tryLater))
        #expect(!BaiduDownloadSource.isPermanent(.server(code: 1, message: nil)))
    }
}
