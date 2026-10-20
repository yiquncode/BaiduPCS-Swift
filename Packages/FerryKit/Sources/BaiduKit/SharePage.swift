import Foundation

/// 从分享页 HTML 中取出的字段。
struct SharePage: Equatable {
    var bdstoken: String
    var shareID: Int64
    var shareUK: Int64
    var uk: Int64?

    /// 页面有两种结构：旧页 `locals.mset({...});`，新页 `try{ {...} }catch`。
    /// 片段不一定是合法 JSON，所以逐字段用正则提取，不依赖结尾的 `);`。
    static func parse(html: String) throws -> SharePage {
        if html.contains("error-404") { throw BaiduError.shareNotFound }
        if html.contains("platform-non-found") { throw BaiduError.shareExpired }

        // `.` 不匹配换行，与参考实现一致：取第一个包含 loginstate 的 `{...}` 片段。
        guard let fragment = html.firstMatch(of: #/\{.+?loginstate.+?\}/#).map({ String($0.output) }) else {
            throw BaiduError.loginStateMissing
        }

        // 片段在第一个 `}` 处截断，可能不含全部字段，所以找不到时再搜整页。
        func field(_ pattern: Regex<(Substring, Substring)>) -> String? {
            for text in [fragment, html] {
                if let match = text.firstMatch(of: pattern) { return String(match.output.1) }
            }
            return nil
        }

        guard let bdstoken = field(#/"bdstoken"\s*:\s*"([0-9a-f]+)"/#) else { throw BaiduError.loginStateMissing }
        guard let shareID = field(#/"shareid"\s*:\s*"?(\d+)/#).flatMap({ Int64($0) }),
              let shareUK = field(#/"share_uk"\s*:\s*"?(\d+)/#).flatMap({ Int64($0) })
        else { throw BaiduError.invalidResponse }
        let uk = field(#/"uk"\s*:\s*"?(\d+)/#).flatMap { Int64($0) }
        return SharePage(bdstoken: bdstoken, shareID: shareID, shareUK: shareUK, uk: uk)
    }
}
