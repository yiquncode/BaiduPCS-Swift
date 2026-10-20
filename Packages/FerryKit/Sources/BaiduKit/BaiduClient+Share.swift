import Foundation

/// 列分享子目录的方法。两种方法都来自参考实现以外的项目，没有实测，所以按顺序尝试。
enum ShareDirectoryMethod: CaseIterable {
    /// `/share/list` 带 `dir`（BaiduPCS-Py）。
    case shareList
    /// `/share/wxlist`（AList），直接带提取码，不依赖 BDCLND。
    case wxList
}

extension BaiduClient {
    /// 打开分享：访问分享页 → 校验提取码（服务端设置 BDCLND）→ 再次访问分享页刷新 bdstoken 等字段。
    /// `password` 优先于链接中的提取码。
    public func openShare(_ link: ShareLink, password: String?) async throws -> ShareSession {
        var password = password?.trimmingCharacters(in: .whitespacesAndNewlines)
        if password?.isEmpty ?? true { password = link.password }
        if let given = password {
            guard let valid = ShareLink.validPassword(given) else { throw BaiduError.invalidPasswordFormat }
            password = valid
        }

        var cookies: [Credential.Cookie] = []
        let first = try await fetchSharePage(link, referer: "\(Host.pan)/disk/home", sessionCookies: cookies)
        cookies = cookies.merging(first.cookies)

        guard let password else {
            // 带提取码的分享会重定向到 /share/init（用 NetdiskUA 时是 /wap/init）。
            // 没有提取码时跳过校验，直接用第一次的字段。
            if first.redirectedToInit { throw BaiduError.passwordRequired }
            return ShareSession(link: link, password: nil, shareID: first.page.shareID, shareUK: first.page.shareUK,
                                bdstoken: first.page.bdstoken, cookies: cookies)
        }

        cookies = cookies.merging(try await verify(link, password: password, page: first.page, sessionCookies: cookies))

        let second = try await fetchSharePage(link, referer: "\(Host.pan)/share/init?surl=\(link.surl)", sessionCookies: cookies)
        cookies = cookies.merging(second.cookies)
        return ShareSession(link: link, password: password, shareID: second.page.shareID, shareUK: second.page.shareUK,
                            bdstoken: second.page.bdstoken, cookies: cookies)
    }

    /// 列出分享中的一层目录。`directory` 为 `nil` 时列根目录。自动翻页。
    public func listShare(_ session: ShareSession, directory: ShareEntry? = nil) async throws -> [ShareEntry] {
        guard let directory else { return try await listShareRoot(session) }

        var firstError: Error?
        for method in ShareDirectoryMethod.allCases {
            do {
                return try await listShareDirectory(session, directory: directory, method: method)
            } catch let error as BaiduError {
                if case .network = error { throw error }
                firstError = firstError ?? error
            }
        }
        throw firstError ?? BaiduError.invalidResponse
    }

    // MARK: - 分享页与提取码

    private func fetchSharePage(_ link: ShareLink, referer: String, sessionCookies: [Credential.Cookie])
        async throws -> (page: SharePage, cookies: [Credential.Cookie], redirectedToInit: Bool) {
        // 分享页必须用 NetdiskUA：浏览器 UA 会拿到不含 loginstate 的登录页。
        let request = BaiduRequest(url: link.url, endpoint: .sharePage, cookies: cookies(adding: sessionCookies),
                                   headers: ["Referer": referer])
        let (data, response) = try await send(request)
        if response.statusCode == 404 { throw BaiduError.shareNotFound }
        let html = String(decoding: data, as: UTF8.self)
        let page = try SharePage.parse(html: html, url: response.url)
        let redirected = response.url?.path.hasSuffix("/init") ?? false
        return (page, .from(response: response), redirected)
    }

    private func verify(_ link: ShareLink, password: String, page: SharePage, sessionCookies: [Credential.Cookie])
        async throws -> [Credential.Cookie] {
        let url = URLEncoding.url("\(Host.pan)/share/verify", [
            ("shareid", String(page.shareID)),
            ("time", String(Int64(Date().timeIntervalSince1970 * 1000))),
            ("clienttype", "1"),
            ("uk", String(page.shareUK)),
        ])
        let request = BaiduRequest.form(
            [("pwd", password), ("vcode", "null"), ("vcode_str", "null"), ("bdstoken", page.bdstoken)],
            url: url, endpoint: .shareVerify, cookies: cookies(adding: sessionCookies),
            contentType: "application/x-www-form-urlencoded; charset=UTF-8",
            headers: ["Referer": link.url.absoluteString]
        )
        let (json, response) = try await json(request)
        if let errno = json["errno"].int, errno != 0 {
            throw BaiduError(code: errno, endpoint: .shareVerify)
        }

        // BDCLND 优先取自 Set-Cookie；没有时用 randsk。randsk 已经是编码后的值，不再编码。
        var cookies = [Credential.Cookie].from(response: response)
        if !cookies.contains(where: { $0.name == "BDCLND" }), let randsk = json["randsk"].string, !randsk.isEmpty {
            cookies.append(Credential.Cookie(name: "BDCLND", value: randsk))
        }
        return cookies
    }

    // MARK: - 列目录

    private static let sharePageSize = 100

    /// 与参考实现一致，只请求一次，不发送 page 和 num。实测服务端忽略根目录的 page。
    private func listShareRoot(_ session: ShareSession) async throws -> [ShareEntry] {
        let url = URLEncoding.url("\(Host.pan)/share/list", [
            ("bdstoken", session.bdstoken), ("root", "1"), ("web", "5"), ("app_id", Host.panAppID),
            ("shorturl", session.link.surl), ("channel", "chunlei"),
        ])
        let request = BaiduRequest(url: url, endpoint: .shareList, cookies: cookies(adding: session.cookies))
        // 没有校验提取码就列需要提取码的分享时，服务端返回 -9 或 9019。
        let json = try await panJSON(request) { errno in
            session.password == nil && [-9, 9019].contains(errno) ? .passwordRequired : nil
        }
        return Self.entries(json["list"], in: "")
    }

    func listShareDirectory(_ session: ShareSession, directory: ShareEntry, method: ShareDirectoryMethod) async throws -> [ShareEntry] {
        let relative = directory.relativePath
        switch method {
        case .shareList:
            return try await paginate(pageSize: Self.sharePageSize) { page in
                let url = URLEncoding.url("\(Host.pan)/share/list", [
                    ("channel", "chunlei"), ("clienttype", "0"), ("web", "1"),
                    ("page", String(page)), ("num", String(Self.sharePageSize)),
                    ("dir", directory.path), ("t", String(Double.random(in: 0..<1))),
                    ("uk", String(session.shareUK)), ("shareid", String(session.shareID)),
                    ("desc", "1"), ("order", "other"), ("bdstoken", "null"), ("showempty", "0"),
                ])
                let json = try await panJSON(BaiduRequest(url: url, endpoint: .shareList, cookies: cookies(adding: session.cookies)))
                return (Self.entries(json["list"], in: relative), nil)
            }
        case .wxList:
            let pageSize = 1000
            return try await paginate(pageSize: pageSize) { page in
                let url = URLEncoding.url("\(Host.pan)/share/wxlist", [
                    ("channel", "weixin"), ("version", "2.2.2"), ("clienttype", "25"), ("web", "1"),
                ])
                // 这个接口只要 BDUSS，靠提取码访问，不用 BDCLND。
                let request = BaiduRequest.form(
                    [("shorturl", session.link.surl), ("pwd", session.password ?? ""), ("root", "0"),
                     ("dir", directory.path), ("page", String(page)), ("num", String(pageSize)), ("order", "time")],
                    url: url, endpoint: .shareWXList,
                    cookies: [Credential.Cookie(name: "BDUSS", value: credential.bduss)]
                )
                let json = try await panJSON(request)
                return (Self.entries(json["data"]["list"], in: relative), json["data"]["has_more"].bool)
            }
        }
    }

    /// 翻页直到：本页为空、本页不足一页（或 `hasMore` 为假）、出现已见过的条目。
    private func paginate(pageSize: Int, fetch: (Int) async throws -> (entries: [ShareEntry], hasMore: Bool?)) async throws -> [ShareEntry] {
        var result: [ShareEntry] = []
        var seen = Set<Int64>()
        var page = 1
        while true {
            let (entries, hasMore) = try await fetch(page)
            let fresh = entries.filter { seen.insert($0.fsID).inserted }
            result += fresh
            if entries.isEmpty || fresh.count < entries.count { break }
            if let hasMore { if !hasMore { break } } else if entries.count < pageSize { break }
            page += 1
        }
        return result
    }

    static func entries(_ list: JSON, in relativeDirectory: String) -> [ShareEntry] {
        list.array.compactMap { item in
            guard let fsID = item["fs_id"].int64 else { return nil }
            let path = item["path"].string ?? ""
            let name = item["server_filename"].string ?? Path.lastComponent(path)
            return ShareEntry(fsID: fsID, name: name, path: path.isEmpty ? "/" + name : path,
                              isDirectory: item["isdir"].bool ?? false, size: item["size"].int64 ?? 0,
                              relativeDirectory: relativeDirectory)
        }
    }
}
