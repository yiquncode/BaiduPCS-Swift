import Foundation
import Testing
@testable import BaiduKit

struct DownloadURLSelectionTests {
    let urls = ["http://a.example/1", "http://nb.cache.example/2", "http://nb.cache2.example/3", "http://d.example/4"]
        .map { URL(string: $0)! }

    @Test func picksPreferredAndForcesHTTPS() {
        #expect(BaiduClient.selectDownloadURL(urls, preference: 0)?.absoluteString == "https://a.example/1")
    }

    @Test func skipsNBCacheHosts() {
        #expect(BaiduClient.selectDownloadURL(urls, preference: 1)?.absoluteString == "https://d.example/4")
    }

    @Test func clampsPreferenceToLastURL() {
        #expect(BaiduClient.selectDownloadURL(urls, preference: 99)?.absoluteString == "https://d.example/4")
    }

    @Test func keepsNBCacheWhenItIsTheLastChoice() {
        let only = [URL(string: "http://nb.cache.example/x")!]
        #expect(BaiduClient.selectDownloadURL(only, preference: 0)?.host() == "nb.cache.example")
        #expect(BaiduClient.selectDownloadURL([], preference: 0) == nil)
    }
}

extension StubbedNetworkTests {
    @Suite struct DiskTests {
        @Test func createDirectoryTreatsExistingAsSuccess() async throws {
            let client = Fixture.client { _ in .json(#"{"error_code":31061,"error_msg":"file already exists"}"#, status: 400) }
            try await client.createDirectory("/Ferry/job 1")

            let request = try #require(Stub.shared.requests.first)
            #expect(request.method == "POST")
            #expect(request.url.host() == "pcs.baidu.com")
            #expect(request.query["method"] == "mkdir")
            #expect(request.query["app_id"] == "266719")
            #expect(request.query["path"] == "/Ferry/job 1")
            #expect(request.header("User-Agent") == nil)
            #expect(request.cookies["BDUSS"] == "test_bduss")
        }

        @Test func createDirectoryReportsInvalidName() async {
            let client = Fixture.client { _ in .json(#"{"error_code":31062}"#, status: 400) }
            await #expect(throws: BaiduError.invalidFileName) { try await client.createDirectory("/Ferry/a:b") }
        }

        @Test func listsFilesRecursivelyWithPaging() async throws {
            let client = Fixture.client { request in
                switch (request.query["dir"], request.query["page"]) {
                case ("/Ferry/job", "1"):
                    var items = (1...999).map { (fsID: Int64($0), name: "f\($0)", path: "/Ferry/job/f\($0)", isDir: false, size: Int64($0)) }
                    items.append((5000, "sub", "/Ferry/job/sub", true, 0))
                    return .json(Fixture.listJSON(items))
                case ("/Ferry/job", "2"):
                    return .json(Fixture.listJSON([(1000, "last", "/Ferry/job/last", false, 7)]))
                case ("/Ferry/job/sub", "1"):
                    return .json(Fixture.listJSON([(6000, "deep", "/Ferry/job/sub/deep", false, 42)]))
                default:
                    return .json(#"{"errno":0,"list":[]}"#)
                }
            }
            let files = try await client.listFilesRecursively("/Ferry/job")
            #expect(files.count == 1001)
            #expect(files.contains(RemoteFile(path: "/Ferry/job/sub/deep", size: 42, fsID: 6000)))
            #expect(!files.contains { $0.path == "/Ferry/job/sub" })

            let requests = Stub.shared.requests
            #expect(requests.count == 3)
            #expect(requests.allSatisfy { $0.path == "/api/list" && $0.header("User-Agent") == UserAgent.netdisk })
            #expect(requests[0].query["num"] == "1000")
        }

        @Test func listingStopsOnRepeatedEntries() async throws {
            let client = Fixture.client { _ in
                .json(Fixture.listJSON((1...1000).map { (Int64($0), "f\($0)", "/d/f\($0)", false, 1) }))
            }
            let files = try await client.listFilesRecursively("/d")
            #expect(files.count == 1000)
            #expect(Stub.shared.requests.count == 2)
        }

        @Test func deleteSendsMultipartPathList() async throws {
            let client = Fixture.client { _ in .json(#"{"request_id":1}"#) }
            try await client.delete(paths: ["/Ferry/job", "/Ferry/a b"])

            let request = try #require(Stub.shared.requests.first)
            #expect(request.method == "POST")
            #expect(request.query["method"] == "delete")
            #expect(request.header("User-Agent") == nil)
            #expect(request.header("Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            let body = String(decoding: request.body, as: UTF8.self)
            #expect(body.contains(#"name="param""#))
            #expect(body.contains(#"{"list":[{"path":"/Ferry/job"},{"path":"/Ferry/a b"}]}"#))
        }

        @Test func deleteIgnoresMissingFiles() async throws {
            let client = Fixture.client { _ in .json(#"{"error_code":31066,"error_msg":"file does not exist"}"#, status: 404) }
            try await client.delete(paths: ["/Ferry/gone"])
        }

        static let locateResponse = """
        {"urls":[
          {"url":"http://encrypted.example/f","encrypt":1},
          {"url":"http://nb.cache.example/f","encrypt":0},
          {"url":"http://d.pcs.baidu.com/file/abc?fid=1","encrypt":0}
        ]}
        """

        @Test func downloadLinkUsesLocateDownload() async throws {
            let client = Fixture.client { request in
                switch request.path {
                case "/rest/2.0/pcs/file": .json(Self.locateResponse)
                case "/c/s/login": .json(#"{"error_code":"1"}"#)
                default: .notFound
                }
            }
            let link = try await client.downloadLink(for: "/Ferry/job/a.zip")
            #expect(link.source == .locate)
            #expect(link.url.absoluteString == "https://d.pcs.baidu.com/file/abc?fid=1")
            #expect(link.headers["User-Agent"] == UserAgent.netdisk)
            #expect(link.headers["Cookie"]?.contains("BDUSS=test_bduss") == true)
            #expect(link.headers["Cookie"]?.contains("STOKEN=test_stoken") == true)

            let locate = try #require(Stub.shared.requests(path: "/rest/2.0/pcs/file").first)
            #expect(locate.method == "POST")
            #expect(locate.header("User-Agent") == UserAgent.netdisk)
            #expect(locate.url.absoluteString.contains("&path=%2FFerry%2Fjob%2Fa.zip&"))
            #expect(locate.url.absoluteString.contains("&devuid=66AE65D3C5D483FC4431FC43670A4673%7C0&"))
            let query = locate.query
            #expect(query["method"] == "locatedownload")
            #expect(query["app_id"] == "250528")
            #expect(query["path"] == "/Ferry/job/a.zip")
            let devUID = LocateDownloadSign.devUID(bduss: "test_bduss")
            #expect(query["devuid"] == devUID)
            #expect(query["cuid"] == devUID)
            // 贴吧接口失败时用 uid 24 签名。
            let time = try #require(query["time"].flatMap { Int64($0) })
            #expect(query["rand"] == LocateDownloadSign(bduss: "test_bduss", uid: 24, time: time).rand)
        }

        @Test func downloadLinkUsesUIDFromValidate() async throws {
            let client = Fixture.client { request in
                switch request.path {
                case "/api/gettemplatevariable": .json(#"{"errno":0,"result":{"bdstoken":"ab"}}"#)
                case "/api/user/getinfo": .json(#"{"errno":0,"records":[{"uk":1}]}"#)
                case "/c/s/login": .json(#"{"error_code":"0","user":{"id":"10086","name":"n"}}"#)
                case "/rest/2.0/pcs/file": .json(Self.locateResponse)
                default: .notFound
                }
            }
            _ = try await client.validate()
            _ = try await client.downloadLink(for: "/a")
            #expect(Stub.shared.requests(path: "/c/s/login").count == 1)
            let query = try #require(Stub.shared.requests(path: "/rest/2.0/pcs/file").first?.query)
            let time = try #require(query["time"].flatMap { Int64($0) })
            #expect(query["rand"] == LocateDownloadSign(bduss: "test_bduss", uid: 10086, time: time).rand)
        }

        @Test(arguments: [
            #"{"error_code":31626,"error_msg":"user is not authorized"}"#,
            #"{"error_code":31326,"error_msg":"user is not authorized, hitcode:122"}"#,
            #"{"urls":[{"url":"http://x.example/f","encrypt":1}]}"#,
        ])
        func downloadLinkFallsBackToPCSDownload(_ response: String) async throws {
            let client = Fixture.client { request in
                request.path == "/c/s/login" ? .json(#"{"error_code":"1"}"#) : .json(response, status: 200)
            }
            let link = try await client.downloadLink(for: "/Ferry/a b.zip")
            #expect(link.source == .pcs)
            let components = try #require(URLComponents(url: link.url, resolvingAgainstBaseURL: false))
            #expect(components.host == "pcs.baidu.com")
            #expect(components.queryItems?.first { $0.name == "method" }?.value == "download")
            #expect(components.queryItems?.first { $0.name == "app_id" }?.value == "266719")
            #expect(components.queryItems?.first { $0.name == "path" }?.value == "/Ferry/a b.zip")
            #expect(link.headers["User-Agent"] == nil)
            #expect(link.headers["Cookie"]?.contains("BDUSS=test_bduss") == true)
        }

        @Test func downloadLinkDoesNotFallBackForMissingFile() async {
            let client = Fixture.client { request in
                request.path == "/c/s/login" ? .json(#"{"error_code":"1"}"#) : .json(#"{"error_code":31066}"#, status: 404)
            }
            await #expect(throws: BaiduError.fileNotFound) { try await client.downloadLink(for: "/gone") }
        }
    }
}
