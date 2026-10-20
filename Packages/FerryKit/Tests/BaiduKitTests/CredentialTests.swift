import Foundation
import Testing
@testable import BaiduKit

struct CredentialTests {
    @Test func parsesCookiesInOrder() throws {
        let credential = try Credential.parse("BAIDUID=abc:FG=1; BDUSS=bduss-value; STOKEN=stoken-value; PANPSC=x")
        #expect(credential.bduss == "bduss-value")
        #expect(credential.stoken == "stoken-value")
        #expect(credential.cookies.map(\.name) == ["BAIDUID", "BDUSS", "STOKEN", "PANPSC"])
        // 值中的 `=` 只按第一个分割。
        #expect(credential.cookies[0].value == "abc:FG=1")
    }

    @Test func stripsWhitespaceAndQuotes() throws {
        let credential = try Credential.parse("  STOKEN = s ;\n RT=\"z=1&dm=baidu.com\" ;BDUSS= b  ")
        #expect(credential.bduss == "b")
        #expect(credential.stoken == "s")
        #expect(credential.cookies.first { $0.name == "RT" }?.value == "z=1&dm=baidu.com")
    }

    @Test func acceptsBDUSSAtEndWithoutSemicolon() throws {
        let credential = try Credential.parse("STOKEN=s; BDUSS=last")
        #expect(credential.bduss == "last")
    }

    @Test func acceptsCopiedHeaderLine() throws {
        let credential = try Credential.parse("Cookie: BDUSS=b; STOKEN=s")
        #expect(credential.bduss == "b")
    }

    @Test func dropsSegmentsWithoutEqualsAndKeepsLastDuplicate() throws {
        let credential = try Credential.parse("garbage; BDUSS=old; STOKEN=s; BDUSS=new")
        #expect(credential.bduss == "new")
        #expect(credential.cookies.map(\.name) == ["BDUSS", "STOKEN"])
    }

    @Test func rejectsMissingBDUSS() {
        #expect(throws: BaiduError.missingBDUSS) { try Credential.parse("STOKEN=s; BAIDUID=x") }
        #expect(throws: BaiduError.missingBDUSS) { try Credential.parse("BDUSS=; STOKEN=s") }
        #expect(throws: BaiduError.missingBDUSS) { try Credential.parse("") }
    }

    @Test func rejectsMissingSTOKEN() {
        #expect(throws: BaiduError.missingSTOKEN) { try Credential.parse("BDUSS=b") }
        #expect(BaiduError.missingSTOKEN.errorDescription?.contains("pan.baidu.com") == true)
    }

    @Test func expiredSetCookieDeletesCookie() {
        let url = URL(string: "https://pan.baidu.com/s/1qYZEsSc")!
        func response(_ setCookie: String) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Set-Cookie": setCookie])!
        }
        var session = SessionCookies()
        session.apply(response(
            "PANPSC=; expires=Fri, 01-Apr-1900 00:00:00 GMT; path=/; domain=pan.baidu.com; HttpOnly;, "
                + "csrfToken=abc; path=/; secure, "
                + "BAIDUID=X:FG=1; expires=Thu, 01-Jan-2099 00:00:00 GMT; path=/; domain=.baidu.com"))
        #expect(session.cookies.headerValue == "csrfToken=abc; BAIDUID=X:FG=1")
        #expect(session.deleted == ["PANPSC"])

        // 之后再设置同名 Cookie 时，它不再算删除；删除会话中设置过的 Cookie 时，把它移除。
        session.apply(response("PANPSC=new; path=/, csrfToken=; expires=Fri, 01-Apr-1900 00:00:00 GMT; path=/"))
        #expect(session.cookies.headerValue == "BAIDUID=X:FG=1; PANPSC=new")
        #expect(session.deleted == ["csrfToken"])
    }

    @Test func mergingReplacesValuesInPlace() {
        let base = [Credential.Cookie(name: "A", value: "1"), .init(name: "BDCLND", value: "old")]
        let merged = base.merging([.init(name: "BDCLND", value: "new"), .init(name: "C", value: "3")])
        #expect(merged.headerValue == "A=1; BDCLND=new; C=3")
    }

    // MARK: - 网页登录

    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func cookie(_ name: String, _ value: String, domain: String, path: String = "/",
                               secure: Bool = false, expires: Date? = nil, created: Double? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        if let created { properties[HTTPCookiePropertyKey("Created")] = created }
        return HTTPCookie(properties: properties)!
    }

    @Test func webCookiesPreferNetdiskSTOKENOverPassport() throws {
        let credential = try Credential.parse([
            Self.cookie("STOKEN", "passport-stoken", domain: ".passport.baidu.com"),
            Self.cookie("STOKEN", "passport-host-stoken", domain: "passport.baidu.com"),
            Self.cookie("BDUSS", "fake-bduss", domain: ".baidu.com"),
            Self.cookie("STOKEN", "pan-stoken", domain: ".pan.baidu.com"),
            Self.cookie("PTOKEN", "passport-only", domain: "passport.baidu.com"),
        ], now: Self.now)
        #expect(credential.bduss == "fake-bduss")
        #expect(credential.stoken == "pan-stoken")
        #expect(credential.cookies.map(\.name) == ["BDUSS", "STOKEN"])
    }

    @Test func webCookiesAcceptHostOnlyNetdiskSTOKEN() throws {
        let credential = try Credential.parse([
            Self.cookie("BDUSS", "fake-bduss", domain: ".baidu.com", secure: true),
            Self.cookie("STOKEN", "pan-stoken", domain: "pan.baidu.com"),
        ], now: Self.now)
        #expect(credential.stoken == "pan-stoken")
    }

    @Test func webCookiesWithoutNetdiskSTOKEN() {
        #expect(throws: BaiduError.missingSTOKEN) {
            try Credential.parse([
                Self.cookie("BDUSS", "fake-bduss", domain: ".baidu.com"),
                Self.cookie("STOKEN", "passport-stoken", domain: "passport.baidu.com"),
            ], now: Self.now)
        }
        #expect(throws: BaiduError.missingBDUSS) {
            try Credential.parse([Self.cookie("STOKEN", "pan-stoken", domain: ".pan.baidu.com")], now: Self.now)
        }
    }

    @Test func webCookiesExcludeOtherDomains() throws {
        let credential = try Credential.parse([
            Self.cookie("BDUSS", "fake-bduss", domain: ".baidu.com"),
            Self.cookie("STOKEN", "pan-stoken", domain: ".pan.baidu.com"),
            Self.cookie("pcsett", "pcs", domain: ".pcs.baidu.com"),
            Self.cookie("SUFFIX", "x", domain: ".an.baidu.com"),
            Self.cookie("ROOT", "x", domain: "baidu.com"),
            Self.cookie("OTHER", "x", domain: ".example.com"),
            Self.cookie("SUB", "x", domain: "www.pan.baidu.com"),
        ], now: Self.now)
        #expect(credential.cookies.map(\.name) == ["BDUSS", "STOKEN"])
    }

    @Test func webCookiesExcludeExpiredAndOtherPaths() {
        #expect(throws: BaiduError.missingSTOKEN) {
            try Credential.parse([
                Self.cookie("BDUSS", "fake-bduss", domain: ".baidu.com", expires: Self.now.addingTimeInterval(3600)),
                Self.cookie("STOKEN", "expired", domain: ".pan.baidu.com", expires: Self.now.addingTimeInterval(-1)),
                Self.cookie("STOKEN", "other-path", domain: ".pan.baidu.com", path: "/disk"),
            ], now: Self.now)
        }
    }

    @Test func secureCookiesMatchHTTPSOnly() {
        let cookie = Self.cookie("BDUSS", "fake-bduss", domain: ".baidu.com", secure: true)
        #expect(cookie.isSent(to: URL(string: "https://pan.baidu.com/")!, at: Self.now))
        #expect(!cookie.isSent(to: URL(string: "http://pan.baidu.com/")!, at: Self.now))
    }

    @Test func pathMatchFollowsRFC6265() {
        let url = URL(string: "https://pan.baidu.com/disk/main")!
        #expect(Self.cookie("A", "x", domain: "pan.baidu.com", path: "/disk").isSent(to: url, at: Self.now))
        #expect(Self.cookie("A", "x", domain: "pan.baidu.com", path: "/disk/").isSent(to: url, at: Self.now))
        #expect(!Self.cookie("A", "x", domain: "pan.baidu.com", path: "/dis").isSent(to: url, at: Self.now))
        #expect(!Self.cookie("A", "x", domain: "pan.baidu.com", path: "/disk/main/x").isSent(to: url, at: Self.now))
    }

    /// 同名 Cookie 按浏览器的发送顺序只保留一个：路径长的优先，其次先创建的优先。
    @Test func duplicateWebCookiesKeepTheFirstSent() {
        let url = URL(string: "https://pan.baidu.com/disk/main")!
        let byPath = Credential.cookies([
            Self.cookie("STOKEN", "root", domain: ".baidu.com", created: 1),
            Self.cookie("STOKEN", "disk", domain: "pan.baidu.com", path: "/disk", created: 2),
        ], sentTo: url, at: Self.now)
        #expect(byPath == [.init(name: "STOKEN", value: "disk")])

        let byCreation = Credential.cookies([
            Self.cookie("STOKEN", "newer", domain: ".pan.baidu.com", created: 20),
            Self.cookie("STOKEN", "older", domain: ".baidu.com", created: 10),
        ], sentTo: url, at: Self.now)
        #expect(byCreation == [.init(name: "STOKEN", value: "older")])
    }

    @Test func webCookiesStripQuotes() throws {
        let credential = try Credential.parse([
            Self.cookie("BDUSS", "fake-bduss", domain: ".baidu.com"),
            Self.cookie("STOKEN", "pan-stoken", domain: ".pan.baidu.com"),
            Self.cookie("RT", "\"z=1&dm=baidu.com\"", domain: ".baidu.com"),
        ], now: Self.now)
        #expect(credential.cookies.map(\.name) == ["BDUSS", "STOKEN", "RT"])
        #expect(credential.cookies.last?.value == "z=1&dm=baidu.com")
    }
}
