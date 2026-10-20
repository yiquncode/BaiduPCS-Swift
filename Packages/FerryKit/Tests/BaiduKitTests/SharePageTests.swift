import Testing
@testable import BaiduKit

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
