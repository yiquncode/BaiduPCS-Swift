import Foundation
import Testing
@testable import BaiduKit

struct ShareLinkTests {
    @Test func parsesShortLink() throws {
        let link = try #require(ShareLink.parse("https://pan.baidu.com/s/1qYZEsSc"))
        #expect(link.surl == "qYZEsSc")
        #expect(link.shortCode == "1qYZEsSc")
        #expect(link.password == nil)
        #expect(link.url.absoluteString == "https://pan.baidu.com/s/1qYZEsSc")
    }

    @Test func parsesShortLinkWithPassword() throws {
        let link = try #require(ShareLink.parse("https://pan.baidu.com/s/1qYZEsSc?pwd=ab12"))
        #expect(link.surl == "qYZEsSc")
        #expect(link.password == "ab12")
    }

    @Test func parsesInitLink() throws {
        let link = try #require(ShareLink.parse("https://pan.baidu.com/share/init?surl=qYZEsSc&pwd=ab12"))
        #expect(link.surl == "qYZEsSc")
        #expect(link.password == "ab12")
    }

    @Test func parsesSharingText() throws {
        let text = "通过网盘分享的文件：资料.zip\n链接: https://pan.baidu.com/s/1qYZEsSc?pwd=ab12 提取码: ab12 \n--来自百度网盘超级会员v5的分享"
        let link = try #require(ShareLink.parse(text))
        #expect(link.surl == "qYZEsSc")
        #expect(link.password == "ab12")
    }

    @Test func takesPasswordFromTextWhenURLHasNone() throws {
        let link = try #require(ShareLink.parse("链接：pan.baidu.com/s/1qYZEsSc 提取码：x9Z1"))
        #expect(link.surl == "qYZEsSc")
        #expect(link.password == "x9Z1")
    }

    @Test func acceptsUnderscoreAndDash() throws {
        let link = try #require(ShareLink.parse("http://pan.baidu.com/s/1ab_c-D"))
        #expect(link.surl == "ab_c-D")
    }

    @Test func ignoresMalformedPassword() throws {
        let link = try #require(ShareLink.parse("https://pan.baidu.com/s/1qYZEsSc?pwd=abc"))
        #expect(link.password == nil)
    }

    @Test(arguments: [
        "",
        "hello",
        "https://pan.baidu.com/s/",
        "https://pan.baidu.com/s/qYZEsSc",
        "https://pan.baidu.com/s/1abcdefghijklmnopqrstuvwxyz",
        "https://pan.baidu.com/share/init?pwd=ab12",
        "https://pan.baidu.com/disk/home",
        "https://example.com/s/1qYZEsSc",
    ])
    func rejectsInvalidInput(_ text: String) {
        #expect(ShareLink.parse(text) == nil)
    }
}
