import Foundation

/// 从分享页 HTML 中取出的字段。
struct SharePage: Equatable {
    var bdstoken: String
    var shareID: Int64
    var shareUK: Int64
    var uk: Int64?

    /// 页面有两种结构：旧页 `locals.mset({...});`，新页 `try{ {...} }catch`。
    /// 片段不一定是合法 JSON，所以逐字段用正则提取，不依赖结尾的 `);`。
    /// `url` 是重定向后的最终地址。
    static func parse(html: String, url: URL? = nil) throws -> SharePage {
        if html.contains("error-404") { throw BaiduError.shareNotFound }
        if html.contains("platform-non-found") { throw BaiduError.shareExpired }
        // 用 NetdiskUA 访问不存在的分享时，服务端重定向到 /wap/error?errortype=0。这个页面没有上面两个标记。
        if let url, url.path == "/wap/error" {
            let errorType = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "errortype" }?.value.flatMap { Int($0) }
            throw shareError(errorType: errorType)
        }

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

        // 正常的分享页是 `"errortype":-1,"errno":0`。
        if let errorType = field(#/"errortype"\s*:\s*(-?\d+)/#).flatMap({ Int($0) }), errorType != -1 {
            throw shareError(errorType: errorType)
        }

        guard let bdstoken = field(#/"bdstoken"\s*:\s*"([0-9a-f]+)"/#) else { throw BaiduError.loginStateMissing }
        guard let shareID = field(#/"shareid"\s*:\s*"?(\d+)/#).flatMap({ Int64($0) }),
              let shareUK = field(#/"share_uk"\s*:\s*"?(\d+)/#).flatMap({ Int64($0) })
        else { throw BaiduError.invalidResponse }
        let uk = field(#/"uk"\s*:\s*"?(\d+)/#).flatMap { Int64($0) }
        return SharePage(bdstoken: bdstoken, shareID: shareID, shareUK: shareUK, uk: uk)
    }

    /// 只实测过 `errortype=0`（短链不存在）。其他值无法区分是不存在还是已失效。
    static func shareError(errorType: Int?) -> BaiduError {
        errorType == 0 ? .shareNotFound : .shareUnavailable
    }
}
