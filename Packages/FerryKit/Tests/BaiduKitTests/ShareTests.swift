import Foundation
import Testing
@testable import BaiduKit

extension StubbedNetworkTests {
    @Suite struct ShareTests {
        /// 带提取码的分享：第一次访问重定向到 /share/init，校验后第二次访问返回新的 bdstoken。
        static func passwordShareHandler(verify: StubResponse) -> StubHandler {
            { request in
                switch request.path {
                case "/s/1qYZEsSc":
                    if request.header("Referer")?.contains("/share/init") == true {
                        return .html(Fixture.sharePage(bdstoken: "bbbb2222"), url: Fixture.initURL)
                    }
                    return .html(Fixture.sharePage(bdstoken: "aaaa1111"), url: Fixture.initURL)
                case "/share/verify":
                    return verify
                case "/share/list":
                    return .json(Fixture.listJSON([(1, "a.zip", "/sharer/a.zip", false, 10)]))
                default:
                    return .notFound
                }
            }
        }

        @Test func openShareCarriesBDCLNDFromSetCookie() async throws {
            let client = Fixture.client(Self.passwordShareHandler(verify: .json(
                #"{"errno":0,"randsk":"from-randsk"}"#,
                headers: ["Set-Cookie": "BDCLND=from%2Fcookie; expires=Thu, 01-Jan-2099 00:00:00 GMT; path=/; domain=.baidu.com"])))

            let session = try await client.openShare(Fixture.linkWithPassword, password: nil)
            #expect(session.password == "ab12")
            #expect(session.shareID == 3003)
            #expect(session.shareUK == 2002)
            #expect(session.bdstoken == "bbbb2222")
            #expect(session.cookies.first { $0.name == "BDCLND" }?.value == "from%2Fcookie")

            let pages = Stub.shared.requests(path: "/s/1qYZEsSc")
            try #require(pages.count == 2)
            #expect(pages[0].header("User-Agent") == UserAgent.netdisk)
            #expect(pages[0].header("Referer") == "https://pan.baidu.com/disk/home")
            #expect(pages[0].cookies["BDCLND"] == nil)
            #expect(pages[0].cookies["STOKEN"] == "test_stoken")
            #expect(pages[1].header("Referer") == "https://pan.baidu.com/share/init?surl=qYZEsSc")
            #expect(pages[1].cookies["BDCLND"] == "from%2Fcookie")
            #expect(pages[1].cookies["BDUSS"] == "test_bduss")

            let verify = try #require(Stub.shared.requests(path: "/share/verify").first)
            #expect(verify.method == "POST")
            #expect(verify.header("User-Agent") == UserAgent.chromeMac63)
            #expect(verify.header("Referer") == "https://pan.baidu.com/s/1qYZEsSc")
            #expect(verify.query["shareid"] == "3003")
            #expect(verify.query["uk"] == "2002")
            #expect(verify.query["clienttype"] == "1")
            #expect(verify.form == ["pwd": "ab12", "vcode": "null", "vcode_str": "null", "bdstoken": "aaaa1111"])

            _ = try await client.listShare(session)
            let list = try #require(Stub.shared.requests(path: "/share/list").first)
            #expect(list.header("User-Agent") == UserAgent.chromeMac63)
            #expect(list.cookies["BDCLND"] == "from%2Fcookie")
        }

        @Test func openShareFallsBackToRandsk() async throws {
            let client = Fixture.client(Self.passwordShareHandler(verify: .json(#"{"errno":0,"randsk":"rand%2Bsk"}"#)))
            let session = try await client.openShare(Fixture.link, password: "ab12")
            #expect(session.cookies.first { $0.name == "BDCLND" }?.value == "rand%2Bsk")
            #expect(Stub.shared.requests(path: "/s/1qYZEsSc").last?.cookies["BDCLND"] == "rand%2Bsk")
        }

        @Test func explicitPasswordWinsOverLink() async throws {
            let client = Fixture.client(Self.passwordShareHandler(verify: .json(#"{"errno":0,"randsk":"r"}"#)))
            let session = try await client.openShare(Fixture.linkWithPassword, password: " cd34 ")
            #expect(session.password == "cd34")
            #expect(Stub.shared.requests(path: "/share/verify").first?.form["pwd"] == "cd34")
        }

        @Test func wrongPassword() async {
            let client = Fixture.client(Self.passwordShareHandler(verify: .json(#"{"errno":-9}"#)))
            await #expect(throws: BaiduError.wrongPassword) {
                try await client.openShare(Fixture.linkWithPassword, password: nil)
            }
        }

        @Test func captchaRequired() async {
            let client = Fixture.client(Self.passwordShareHandler(verify: .json(#"{"errno":-62}"#)))
            await #expect(throws: BaiduError.captchaRequired) {
                try await client.openShare(Fixture.linkWithPassword, password: nil)
            }
        }

        @Test func malformedPassword() async {
            let client = Fixture.client { _ in .notFound }
            await #expect(throws: BaiduError.invalidPasswordFormat) {
                try await client.openShare(Fixture.link, password: "abc")
            }
            #expect(Stub.shared.requests.isEmpty)
        }

        @Test func expiredShare() async {
            let client = Fixture.client { _ in .html(#"<div class="platform-non-found">分享已失效</div>"#) }
            await #expect(throws: BaiduError.shareExpired) {
                try await client.openShare(Fixture.linkWithPassword, password: nil)
            }
        }

        @Test func missingShareRedirectsToWapError() async {
            let client = Fixture.client { _ in .html(ProbePage.wapError(loggedIn: true), url: ProbePage.wapErrorURL) }
            await #expect(throws: BaiduError.shareNotFound) {
                try await client.openShare(Fixture.link, password: nil)
            }
        }

        @Test func missingLoginState() async {
            let client = Fixture.client { _ in .html("<html>请登录</html>") }
            await #expect(throws: BaiduError.loginStateMissing) {
                try await client.openShare(Fixture.link, password: nil)
            }
        }

        @Test func shareWithoutPasswordSkipsVerify() async throws {
            let client = Fixture.client { request in
                request.path == "/s/1qYZEsSc" ? .html(Fixture.sharePage()) : .notFound
            }
            let session = try await client.openShare(Fixture.link, password: nil)
            #expect(session.password == nil)
            #expect(session.bdstoken == "aaaa1111")
            #expect(Stub.shared.requests.count == 1)
        }

        @Test(arguments: [Fixture.initURL, URL(string: "https://pan.baidu.com/wap/init?surl=qYZEsSc")!])
        func passwordRequiredWhenRedirectedToInit(_ url: URL) async {
            let client = Fixture.client { _ in .html(Fixture.sharePage(), url: url) }
            await #expect(throws: BaiduError.passwordRequired) {
                try await client.openShare(Fixture.link, password: nil)
            }
        }

        @Test(arguments: [-9, 9019])
        func rootListingWithoutPasswordReportsPasswordRequired(_ errno: Int) async {
            let client = Fixture.client { _ in .json(#"{"errno":\#(errno)}"#) }
            await #expect(throws: BaiduError.passwordRequired) {
                try await client.listShare(Fixture.session(password: nil, cookies: []))
            }
        }

        @Test func rootListingWithPasswordKeepsErrors() async {
            let client = Fixture.client { _ in .json(#"{"errno":-9}"#) }
            await #expect(throws: BaiduError.wrongOrExpiredPassword) {
                try await client.listShare(Fixture.session())
            }
            Stub.shared.install { _ in .json(#"{"errno":9019}"#) }
            await #expect(throws: BaiduError.verificationTriggered) {
                try await client.listShare(Fixture.session())
            }
        }

        // MARK: - 列目录

        static func entries(_ range: ClosedRange<Int64>, in directory: String = "/sharer") -> [(fsID: Int64, name: String, path: String, isDir: Bool, size: Int64)] {
            range.map { ($0, "f\($0).bin", "\(directory)/f\($0).bin", false, $0) }
        }

        @Test func rootListingPagesUntilShortPage() async throws {
            let client = Fixture.client { request in
                switch request.query["page"] {
                case "1": .json(Fixture.listJSON(Self.entries(1...100)))
                case "2": .json(Fixture.listJSON(Self.entries(101...103)))
                default: .json(#"{"errno":0,"list":[]}"#)
                }
            }
            let entries = try await client.listShare(Fixture.session())
            #expect(entries.count == 103)
            #expect(entries.allSatisfy { $0.relativeDirectory.isEmpty })

            let requests = Stub.shared.requests(path: "/share/list")
            #expect(requests.map { $0.query["page"] } == ["1", "2"])
            #expect(requests[0].query["root"] == "1")
            #expect(requests[0].query["shorturl"] == "qYZEsSc")
            #expect(requests[0].query["bdstoken"] == "bbbb2222")
            #expect(requests[0].query["num"] == "100")
        }

        @Test func rootListingStopsWhenServerIgnoresPaging() async throws {
            let client = Fixture.client { _ in .json(Fixture.listJSON(Self.entries(1...100))) }
            let entries = try await client.listShare(Fixture.session())
            #expect(entries.count == 100)
            #expect(Stub.shared.requests.count == 2)
        }

        @Test func rootListingReportsVerification() async {
            let client = Fixture.client { _ in .json(#"{"errno":8001}"#) }
            await #expect(throws: BaiduError.verificationTriggered) {
                try await client.listShare(Fixture.session())
            }
        }

        static let folder = ShareEntry(fsID: 9, name: "folder", path: "/sharer/folder", isDirectory: true, size: 0, relativeDirectory: "top")

        @Test func subdirectoryUsesShareListWithDir() async throws {
            let client = Fixture.client { _ in
                .json(Fixture.listJSON([(10, "a.txt", "/sharer/folder/a.txt", false, 5), (11, "sub", "/sharer/folder/sub", true, 0)]))
            }
            let entries = try await client.listShare(Fixture.session(), directory: Self.folder)
            #expect(entries.map(\.relativePath) == ["top/folder/a.txt", "top/folder/sub"])
            #expect(entries[1].isDirectory)

            let request = try #require(Stub.shared.requests.first)
            #expect(request.path == "/share/list")
            #expect(request.query["dir"] == "/sharer/folder")
            #expect(request.query["shareid"] == "3003")
            #expect(request.query["uk"] == "2002")
            #expect(request.query["root"] == nil)
            #expect(request.cookies["BDCLND"] == "clnd")
        }

        @Test func subdirectoryFallsBackToWXList() async throws {
            let client = Fixture.client { request in
                switch request.path {
                case "/share/list":
                    return .json(#"{"errno":2}"#)
                case "/share/wxlist":
                    let page = request.form["page"] == "1"
                        ? Fixture.listJSON([(10, "a.txt", "/sharer/folder/a.txt", false, 5)], key: "list")
                        : #"{"errno":0,"list":[]}"#
                    // wxlist 的列表在 data 下。
                    let body = page.replacingOccurrences(of: #"{"errno":0,"list":"#, with: #"{"errno":0,"data":{"has_more":false,"list":"#) + "}"
                    return .json(body)
                default:
                    return .notFound
                }
            }
            let entries = try await client.listShare(Fixture.session(), directory: Self.folder)
            #expect(entries.map(\.relativePath) == ["top/folder/a.txt"])

            let wx = try #require(Stub.shared.requests(path: "/share/wxlist").first)
            #expect(wx.method == "POST")
            #expect(wx.header("User-Agent") == "netdisk")
            #expect(wx.header("Cookie") == "BDUSS=test_bduss")
            #expect(wx.query["clienttype"] == "25")
            #expect(wx.form["shorturl"] == "qYZEsSc")
            #expect(wx.form["pwd"] == "ab12")
            #expect(wx.form["root"] == "0")
            #expect(wx.form["dir"] == "/sharer/folder")
            #expect(Stub.shared.requests(path: "/share/wxlist").count == 1)
        }

        @Test func subdirectoryReportsFirstErrorWhenBothMethodsFail() async {
            let client = Fixture.client { request in
                request.path == "/share/list" ? .json(#"{"errno":8001}"#) : .json(#"{"errno":-1}"#)
            }
            await #expect(throws: BaiduError.verificationTriggered) {
                try await client.listShare(Fixture.session(), directory: Self.folder)
            }
        }
    }
}
