import Foundation
import Testing
@testable import BaiduKit

/// 按实测的 NetdiskUA 分享页改写的样本。数值和名字都换成了测试值。
enum ProbePage {
    /// 正常的分享页（已登录）。
    static func share(errorType: Int = -1) -> String {
        """
        <!doctype html><html><head><title>百度网盘分享</title><script>window.locals = {};
                try{ window.locals = {"csrf":"test-csrf","master_auto_transfer":0,"auto_transfer":0,"share_uk":"2002","shareid":3003,"followFlag":-1,"access_list_flag":true,"Elink_info":{"isElink":0,"eflag_disable":false},"Clink_info":null,"sharetype":0,"view_visited":0,"view_limit":0,"errortype":\(errorType),"errno":0,"abroad_config":{"country":"JP","domain":{"pan.baidu.com":"drive.baidu.com"}},"linkusername":"测试**用户","shareUserErrno":0,"self":0,"uk":1001,"username":"tester","isVip":0,"VIPType":1,"bdstoken":"0a1b2c3d","loginstate":1,"photo":""}; }catch(ex){console.log(ex);};</script></head><body><div id="app"></div></body></html>
        """
    }

    /// 不存在的分享重定向到的 /wap/error 页。片段中没有 shareid、share_uk 和 errortype。
    static func wapError(loggedIn: Bool) -> String {
        let login = loggedIn ? #""bdstoken":"0a1b2c3d","loginstate":1"# : #""bdstoken":"","loginstate":0"#
        return """
        <!doctype html><html><head><title>百度网盘分享</title><script>window.locals = {};
                try{ window.locals = {"csrf":"test-csrf","uk":0,"username":"","isVip":0,"VIPType":1,\(login),"photo":""}; }catch(ex){console.log(ex);};</script></head><body><div id="app"></div></body></html>
        """
    }

    static let wapErrorURL = URL(string: "https://pan.baidu.com/wap/error?errortype=0&surl=zzzzzzzz")!
}

struct SharePageTests {
    @Test func parsesOldPageStructure() throws {
        let html = """
        <html><script>window.yunData = {};
        locals.mset({"loginstate":1,"bdstoken":"0a1b2c3d","uk":1001,"share_uk":"2002","shareid":3003,"title":"x"});
        </script></html>
        """
        #expect(try SharePage.parse(html: html) == SharePage(bdstoken: "0a1b2c3d", shareID: 3003, shareUK: 2002, uk: 1001))
    }

    @Test func parsesNewPageStructureWithoutClosingParenthesis() throws {
        let html = """
        <script>try{ {"shareid":"3003","share_uk":2002,"loginstate":1,"bdstoken":"0a1b2c3d","uk":"1001","self":0} }catch(e){}</script>
        """
        #expect(try SharePage.parse(html: html) == SharePage(bdstoken: "0a1b2c3d", shareID: 3003, shareUK: 2002, uk: 1001))
    }

    @Test func fallsBackToWholePageWhenFragmentIsTruncated() throws {
        // 片段在 file_list 中的第一个 `}` 处截断，shareid 在它后面。
        let html = """
        <script>locals.mset({"loginstate":1,"bdstoken":"beef","file_list":[{"fs_id":1}],"share_uk":2002,"shareid":3003});</script>
        """
        let page = try SharePage.parse(html: html)
        #expect(page.shareID == 3003)
        #expect(page.shareUK == 2002)
        #expect(page.uk == nil)
    }

    @Test func parsesProbedSharePage() throws {
        let url = URL(string: "https://pan.baidu.com/s/1qYZEsSc")!
        #expect(try SharePage.parse(html: ProbePage.share(), url: url) == SharePage(bdstoken: "0a1b2c3d", shareID: 3003, shareUK: 2002, uk: 1001))
    }

    @Test(arguments: [false, true])
    func detectsWapErrorRedirect(loggedIn: Bool) {
        #expect(throws: BaiduError.shareNotFound) {
            try SharePage.parse(html: ProbePage.wapError(loggedIn: loggedIn), url: ProbePage.wapErrorURL)
        }
        let other = URL(string: "https://pan.baidu.com/wap/error?errortype=9&surl=zzzzzzzz")!
        #expect(throws: BaiduError.shareUnavailable) {
            try SharePage.parse(html: ProbePage.wapError(loggedIn: loggedIn), url: other)
        }
        let missing = URL(string: "https://pan.baidu.com/wap/error")!
        #expect(throws: BaiduError.shareUnavailable) {
            try SharePage.parse(html: ProbePage.wapError(loggedIn: loggedIn), url: missing)
        }
    }

    @Test func detectsErrorTypeInFragment() {
        #expect(throws: BaiduError.shareNotFound) { try SharePage.parse(html: ProbePage.share(errorType: 0)) }
        #expect(throws: BaiduError.shareUnavailable) { try SharePage.parse(html: ProbePage.share(errorType: 4)) }
    }

    @Test func detectsMissingPage() {
        #expect(throws: BaiduError.shareNotFound) { try SharePage.parse(html: #"<div class="error-404">"#) }
    }

    @Test func detectsExpiredShare() {
        #expect(throws: BaiduError.shareExpired) { try SharePage.parse(html: #"<div id="platform-non-found">"#) }
    }

    @Test func detectsMissingLoginState() {
        #expect(throws: BaiduError.loginStateMissing) { try SharePage.parse(html: "<html><title>登录</title></html>") }
        // loginstate 与对象跨行时 `.` 不匹配换行，与参考实现一致。
        #expect(throws: BaiduError.loginStateMissing) { try SharePage.parse(html: "{\n\"loginstate\":0\n}") }
    }

    @Test func requiresBDStoken() {
        let html = #"locals.mset({"loginstate":0,"bdstoken":null,"share_uk":2002,"shareid":3003});"#
        #expect(throws: BaiduError.loginStateMissing) { try SharePage.parse(html: html) }
    }
}
