import Foundation

/// 从用户粘贴的 Cookie 字符串中取出的登录信息。
public struct Credential: Codable, Sendable, Equatable {
    public struct Cookie: Codable, Sendable, Hashable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public let bduss: String
    public let stoken: String
    /// 用户粘贴的全部 Cookie，按原顺序，同名只保留最后一个。每个请求都带上它们。
    public let cookies: [Cookie]

    /// 按 `;` 分段，每段按第一个 `=` 分成名字和值，去掉空白和值两端的双引号。
    /// 不用 `BDUSS=(.+?);` 这样的正则：BDUSS 在末尾且没有分号时会匹配失败。
    public static func parse(_ cookieString: String) throws -> Credential {
        var text = cookieString.trimmingCharacters(in: .whitespacesAndNewlines)
        // 用户可能连同请求头名一起复制。
        if text.lowercased().hasPrefix("cookie:") {
            text = String(text.dropFirst("cookie:".count))
        }

        var cookies: [Cookie] = []
        for segment in text.split(separator: ";") {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let name = segment[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !name.isEmpty else { continue }
            cookies = cookies.merging([Cookie(name: name, value: value)])
        }

        func value(_ name: String) -> String? {
            cookies.first { $0.name == name }.map(\.value).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let bduss = value("BDUSS") else { throw BaiduError.missingBDUSS }
        guard let stoken = value("STOKEN") else { throw BaiduError.missingSTOKEN }
        return Credential(bduss: bduss, stoken: stoken, cookies: cookies)
    }
}

extension [Credential.Cookie] {
    /// 同名 Cookie 取 `newer` 中的值，位置保持不变；新名字追加在末尾。
    func merging(_ newer: [Credential.Cookie]) -> [Credential.Cookie] {
        var result = self
        for cookie in newer {
            if let index = result.firstIndex(where: { $0.name == cookie.name }) {
                result[index].value = cookie.value
            } else {
                result.append(cookie)
            }
        }
        return result
    }

    var headerValue: String {
        map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// 分享会话中服务端设置和删除的 Cookie。
struct SessionCookies: Equatable {
    var cookies: [Credential.Cookie] = []
    /// 服务端用已过期的 `Set-Cookie`（例如 `PANPSC=; expires=...1900...`）删除的 Cookie。之后的请求不再发送同名 Cookie。
    var deleted: Set<String> = []

    /// 按响应的 `Set-Cookie` 更新。
    mutating func apply(_ response: HTTPURLResponse) {
        guard let url = response.url,
              let header = response.value(forHTTPHeaderField: "Set-Cookie") else { return }
        let now = Date()
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url) {
            if let expires = cookie.expiresDate, expires <= now {
                remove(cookie.name)
            } else {
                set(Credential.Cookie(name: cookie.name, value: cookie.value))
            }
        }
    }

    mutating func set(_ cookie: Credential.Cookie) {
        cookies = cookies.merging([cookie])
        deleted.remove(cookie.name)
    }

    mutating func remove(_ name: String) {
        cookies.removeAll { $0.name == name }
        deleted.insert(name)
    }
}
