import Foundation

/// 用户提交的分享链接。
///
/// 两种格式等价：`/s/{短链}` 和 `/share/init?surl={surl}`，其中短链 = `"1" + surl`。
public struct ShareLink: Sendable, Hashable, Codable {
    /// 不带开头 `1` 的 surl。
    public let surl: String
    /// 链接或分享文字中带的提取码。
    public let password: String?

    public init?(surl: String, password: String? = nil) {
        let shortCode = "1" + surl
        guard shortCode.count <= 23, shortCode.wholeMatch(of: #/1[0-9A-Za-z_-]+/#) != nil else { return nil }
        self.surl = surl
        self.password = password.flatMap(Self.validPassword)
    }

    /// 分享页路径中的短链，例如 `1abc`。
    public var shortCode: String { "1" + surl }

    public var url: URL { URLEncoding.url("\(Host.pan)/s/\(shortCode)", rawQuery: "") }

    /// 从链接或整段分享文字中取出分享链接。提取码依次取自 `pwd` 参数和文字中的“提取码”。
    public static func parse(_ text: String) -> ShareLink? {
        guard let match = text.firstMatch(of: #/(?i:https?://)?pan\.baidu\.com/[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]*/#),
              let components = URLComponents(string: match.output.hasPrefix("pan.") ? "https://" + match.output : String(match.output))
        else { return nil }

        let query = components.queryItems ?? []
        func queryValue(_ name: String) -> String? { query.first { $0.name == name }?.value }

        let surl: String
        let path = components.path
        if path.hasPrefix("/s/") {
            let shortCode = path.dropFirst(3).split(separator: "/").first.map(String.init) ?? ""
            guard shortCode.hasPrefix("1") else { return nil }
            surl = String(shortCode.dropFirst())
        } else if path.hasSuffix("/share/init"), let value = queryValue("surl") {
            surl = value
        } else {
            return nil
        }

        let textPassword = text.firstMatch(of: #/(?:提取码|密码)\s*[:：]?\s*([0-9A-Za-z]{4})(?![0-9A-Za-z])/#).map { String($0.output.1) }
        let password = queryValue("pwd").flatMap(validPassword) ?? textPassword
        return ShareLink(surl: surl, password: password)
    }

    /// 提取码是 4 位字母或数字。
    static func validPassword(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.wholeMatch(of: #/[0-9A-Za-z]{4}/#) != nil ? trimmed : nil
    }
}
