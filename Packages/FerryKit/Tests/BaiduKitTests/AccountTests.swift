import Foundation
import Testing
@testable import BaiduKit

extension StubbedNetworkTests {
    @Suite struct AccountTests {
        static func handler(tieba: StubResponse) -> StubHandler {
            { request in
                switch request.path {
                case "/api/gettemplatevariable":
                    .json(#"{"errno":0,"result":{"bdstoken":"0123abcd"}}"#)
                case "/api/user/getinfo":
                    .json(#"{"errno":0,"records":[{"uk":4242,"baidu_name":"pan_user"}]}"#)
                case "/c/s/login":
                    tieba
                default:
                    .notFound
                }
            }
        }

        @Test func validateCollectsAccount() async throws {
            let client = Fixture.client(Self.handler(
                tieba: .json(#"{"error_code":"0","user":{"id":"123456789","name":"tieba_user"}}"#)))
            let account = try await client.validate()
            #expect(account == Account(username: "tieba_user", uk: 4242, uid: 123456789, bdstoken: "0123abcd"))

            let template = try #require(Stub.shared.requests(path: "/api/gettemplatevariable").first)
            #expect(template.query["fields"] == #"["bdstoken"]"#)
            #expect(template.query["app_id"] == "250528")
            #expect(template.header("User-Agent") == nil)
            #expect(template.cookies["BDUSS"] == "test_bduss")
            #expect(template.cookies["RT"] == "z=1&dm=baidu.com")

            let getinfo = try #require(Stub.shared.requests(path: "/api/user/getinfo").first)
            #expect(getinfo.header("User-Agent") == nil)

            let tieba = try #require(Stub.shared.requests(path: "/c/s/login").first)
            #expect(tieba.url.scheme == "https")
            #expect(tieba.url.host() == "tieba.baidu.com")
            #expect(tieba.method == "POST")
            #expect(tieba.header("User-Agent") == "bdtb for Android 6.9.2.1")
            #expect(tieba.header("Cookie") == "ka=open")
            let form = tieba.form
            #expect(form["bdusstoken"] == "test_bduss|null")
            let unsigned = form.filter { $0.key != "sign" }.map { ($0.key, $0.value) }
            #expect(form["sign"] == TiebaLogin.sign(unsigned))
        }

        @Test func tiebaFailureDoesNotBlockLogin() async throws {
            let client = Fixture.client(Self.handler(
                tieba: .json(#"{"error_code":"1","error_msg":"用户未登录或登录失败"}"#)))
            let account = try await client.validate()
            #expect(account.uid == nil)
            #expect(account.username == "pan_user")
            #expect(account.uk == 4242)
        }

        @Test func expiredCookieFailsValidation() async {
            let client = Fixture.client { _ in .json(#"{"errno":-6}"#) }
            await #expect(throws: BaiduError.loginExpired) { try await client.validate() }
        }

        @Test func emptyBDStokenFailsValidation() async {
            let client = Fixture.client { _ in .json(#"{"errno":0,"result":{"bdstoken":""}}"#) }
            await #expect(throws: BaiduError.loginExpired) { try await client.validate() }
        }
    }
}
