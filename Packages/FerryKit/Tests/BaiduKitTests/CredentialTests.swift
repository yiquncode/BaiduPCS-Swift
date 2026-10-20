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

    @Test func mergingReplacesValuesInPlace() {
        let base = [Credential.Cookie(name: "A", value: "1"), .init(name: "BDCLND", value: "old")]
        let merged = base.merging([.init(name: "BDCLND", value: "new"), .init(name: "C", value: "3")])
        #expect(merged.headerValue == "A=1; BDCLND=new; C=3")
    }
}
