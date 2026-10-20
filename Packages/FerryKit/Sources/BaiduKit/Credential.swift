import Foundation

/// 登录信息：从用户粘贴的 Cookie 字符串或网页登录的 Cookie 中取出。
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
    /// 登录时取得的全部 Cookie，同名只保留一个。每个请求都带上它们。
    public let cookies: [Cookie]

    /// 网页登录只取会发给这个地址的 Cookie。
    static let panURL = URL(string: "https://pan.baidu.com/")!

    /// 按 `;` 分段，每段按第一个 `=` 分成名字和值，去掉空白和值两端的双引号。
    /// 不用 `BDUSS=(.+?);` 这样的正则：BDUSS 在末尾且没有分号时会匹配失败。
    /// 同名 Cookie 保留最后一个值，位置是第一次出现的位置。
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
            let value = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            cookies = cookies.merging([Cookie(name: name, value: unquoted(value))])
        }
        return try Credential(validating: cookies)
    }

    /// 网页登录：从网页的 Cookie 中选出浏览器会发给 `https://pan.baidu.com/` 的 Cookie，再取出凭据。
    /// passport.baidu.com 的 STOKEN 不会发给网盘，所以不会被选中。
    public static func parse(_ cookies: [HTTPCookie], now: Date = .now) throws -> Credential {
        try Credential(validating: Self.cookies(cookies, sentTo: panURL, at: now))
    }

    /// 按 RFC 6265 5.4 选出会发给 `url` 的 Cookie，并按浏览器的发送顺序排列：路径长的在前，路径一样长时先创建的在前。
    /// 同名 Cookie 有多个时只保留第一个，即浏览器在 `Cookie` 头中最先发送的那个。服务端读到的通常是它。
    static func cookies(_ cookies: [HTTPCookie], sentTo url: URL, at now: Date) -> [Cookie] {
        let sent = cookies.enumerated()
            .filter { !$0.element.name.isEmpty && $0.element.isSent(to: url, at: now) }
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element, rhs.element)
                if left.path.count != right.path.count { return left.path.count > right.path.count }
                if let leftCreated = left.created, let rightCreated = right.created, leftCreated != rightCreated {
                    return leftCreated < rightCreated
                }
                return lhs.offset < rhs.offset
            }
        var result: [Cookie] = []
        for (_, cookie) in sent where !result.contains(where: { $0.name == cookie.name }) {
            result.append(Cookie(name: cookie.name, value: unquoted(cookie.value)))
        }
        return result
    }

    /// 百度的部分 Cookie（例如 `RT`）的值带双引号。
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}

extension Credential {
    fileprivate init(validating cookies: [Cookie]) throws {
        func value(_ name: String) -> String? {
            cookies.first { $0.name == name }.map(\.value).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let bduss = value("BDUSS") else { throw BaiduError.missingBDUSS }
        guard let stoken = value("STOKEN") else { throw BaiduError.missingSTOKEN }
        self.init(bduss: bduss, stoken: stoken, cookies: cookies)
    }
}

extension HTTPCookie {
    /// RFC 6265 5.4：没有过期，域名和路径都匹配，并且 secure Cookie 只发给 https 时，浏览器才把 Cookie 发给 `url`。
    /// `domain` 以 `.` 开头的是 domain Cookie（`Set-Cookie` 带 `Domain`），也发给子域名；其余的是 host-only Cookie，只发给这个主机。
    func isSent(to url: URL, at now: Date) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if let expiresDate, expiresDate <= now { return false }
        if isSecure, url.scheme?.lowercased() != "https" { return false }

        let domain = domain.lowercased()
        let domainMatches = if domain.hasPrefix(".") {
            host == domain.dropFirst() || host.hasSuffix(domain)
        } else {
            host == domain
        }

        let requestPath = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
        let cookiePath = path.isEmpty ? "/" : path
        let pathMatches = requestPath == cookiePath
            || (requestPath.hasPrefix(cookiePath)
                && (cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).hasPrefix("/")))

        return domainMatches && pathMatches
    }

    /// Cookie 的创建时间。CFNetwork 和 WebKit 把它放在 `properties` 的 `Created` 中（自 2001 年起的秒数）。
    fileprivate var created: Double? {
        (properties?[HTTPCookiePropertyKey("Created")] as? NSNumber)?.doubleValue
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
