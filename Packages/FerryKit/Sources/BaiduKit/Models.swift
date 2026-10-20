import Foundation

/// 用凭据校验后得到的用户信息。
public struct Account: Codable, Sendable, Equatable {
    public var username: String
    /// 网盘 uk。
    public var uk: Int64
    /// 百度 uid，`locatedownload` 签名要用。贴吧接口不可用时为 `nil`。
    public var uid: UInt64?
    public var bdstoken: String

    public init(username: String, uk: Int64, uid: UInt64?, bdstoken: String) {
        self.username = username
        self.uk = uk
        self.uid = uid
        self.bdstoken = bdstoken
    }
}

/// 提取码校验通过后的分享状态。列目录和转存都要用它。
public struct ShareSession: Sendable, Codable, Equatable {
    public var link: ShareLink
    /// 实际使用的提取码。无提取码的分享为 `nil`。
    public var password: String?
    public var shareID: Int64
    /// 分享者的 uk。
    public var shareUK: Int64
    /// 第二次访问分享页时取到的 bdstoken。转存要用它。
    public var bdstoken: String
    /// 会话中服务端新设置的 Cookie（例如 `BDCLND`）。请求时覆盖用户 Cookie 中的同名项。
    public var cookies: [Credential.Cookie]
    /// 会话中服务端删除的 Cookie 名。请求时不发送这些 Cookie，包括用户 Cookie 中的同名项。
    public var deletedCookies: Set<String>

    public init(link: ShareLink, password: String?, shareID: Int64, shareUK: Int64, bdstoken: String,
                cookies: [Credential.Cookie], deletedCookies: Set<String> = []) {
        self.link = link
        self.password = password
        self.shareID = shareID
        self.shareUK = shareUK
        self.bdstoken = bdstoken
        self.cookies = cookies
        self.deletedCookies = deletedCookies
    }

    var sessionCookies: SessionCookies { SessionCookies(cookies: cookies, deleted: deletedCookies) }
}

/// 分享中的一个文件或目录。
public struct ShareEntry: Sendable, Hashable, Codable, Identifiable {
    public var fsID: Int64
    public var name: String
    /// 条目在分享者网盘中的绝对路径。列子目录时作为 `dir` 参数。
    public var path: String
    public var isDirectory: Bool
    /// 字节数。目录为 0。
    public var size: Int64
    /// 条目所在目录相对于分享根目录的路径，例如 `a/b`。位于分享根目录时为空。
    public var relativeDirectory: String

    public var id: Int64 { fsID }

    /// 条目相对于分享根目录的路径，例如 `a/b/file.zip`。
    public var relativePath: String {
        relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
    }

    public init(fsID: Int64, name: String, path: String, isDirectory: Bool, size: Int64, relativeDirectory: String = "") {
        self.fsID = fsID
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.relativeDirectory = relativeDirectory
    }
}

/// 自己网盘中的一个文件。
public struct RemoteFile: Sendable, Hashable, Codable {
    public var path: String
    public var size: Int64
    public var fsID: Int64

    public init(path: String, size: Int64, fsID: Int64) {
        self.path = path
        self.size = size
        self.fsID = fsID
    }
}

/// 文件的下载地址和下载时必须带的请求头。
public struct DownloadLink: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// PCS `locatedownload` 返回的 dlink。
        case locate
        /// PCS `download` 地址，`locatedownload` 失败时使用。
        case pcs
    }

    public var url: URL
    /// 包含 `Cookie`，以及需要时的 `User-Agent`。dlink 主机不在 `.baidu.com` 下，所以 Cookie 必须显式设置。
    public var headers: [String: String]
    public var source: Source

    public init(url: URL, headers: [String: String], source: Source) {
        self.url = url
        self.headers = headers
        self.source = source
    }
}
