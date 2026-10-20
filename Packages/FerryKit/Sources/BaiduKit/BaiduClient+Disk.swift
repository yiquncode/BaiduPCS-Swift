import Foundation

extension BaiduClient {
    // MARK: - 目录与文件

    /// 建目录。目录已存在时视为成功。
    public func createDirectory(_ path: String) async throws {
        let url = URLEncoding.url("\(Host.pcs)/rest/2.0/pcs/file", [
            ("app_id", Host.pcsAppID), ("method", "mkdir"), ("path", path),
        ])
        do {
            _ = try await pcsJSON(BaiduRequest(method: "POST", url: url, endpoint: .pcsFile, cookies: cookies()))
        } catch BaiduError.alreadyExists {
            return
        }
    }

    private static let listPageSize = 1000

    /// 递归列出目录下的全部文件（不含目录）。
    public func listFilesRecursively(_ path: String) async throws -> [RemoteFile] {
        var files: [RemoteFile] = []
        var directories = [path]
        var seen = Set<Int64>()

        while !directories.isEmpty {
            let directory = directories.removeFirst()
            var page = 1
            while true {
                let url = URLEncoding.url("\(Host.pan)/api/list", [
                    ("dir", directory), ("order", "name"), ("desc", "0"), ("clienttype", "0"),
                    ("num", String(Self.listPageSize)), ("page", String(page)),
                ])
                let json = try await panJSON(BaiduRequest(url: url, endpoint: .fileList, cookies: cookies()))
                let list = json["list"].array
                var repeated = false
                for item in list {
                    guard let fsID = item["fs_id"].int64, let itemPath = item["path"].string else { continue }
                    // 服务端忽略分页参数时会重复返回同一页，出现已见过的条目就停止。
                    guard seen.insert(fsID).inserted else { repeated = true; continue }
                    if item["isdir"].bool ?? false {
                        directories.append(itemPath)
                    } else {
                        files.append(RemoteFile(path: itemPath, size: item["size"].int64 ?? 0, fsID: fsID))
                    }
                }
                if list.count < Self.listPageSize || repeated { break }
                page += 1
            }
        }
        return files
    }

    /// 删除文件或目录，删除的内容进入回收站。路径不存在时视为成功。
    public func delete(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        var form = MultipartForm()
        form.add(name: "param", value: try Self.pathListJSON(paths))
        let url = URLEncoding.url("\(Host.pcs)/rest/2.0/pcs/file", [("app_id", Host.pcsAppID), ("method", "delete")])
        let request = BaiduRequest(method: "POST", url: url, endpoint: .pcsFile, cookies: cookies(),
                                   headers: ["Content-Type": form.contentType], body: form.finalized())
        do {
            _ = try await pcsJSON(request)
        } catch BaiduError.fileNotFound {
            return
        }
    }

    static func pathListJSON(_ paths: [String]) throws -> String {
        struct Item: Encodable { let path: String }
        struct List: Encodable { let list: [Item] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(List(list: paths.map(Item.init))), as: UTF8.self)
    }

    // MARK: - 下载链接

    /// 取文件的下载地址。先用 `locatedownload`，失败时退回 PCS `download` 地址。
    /// `preference` 是优先选用的 dlink 序号。下载后大小不符时，下次可以加 1。
    public func downloadLink(for path: String, preference: Int = 0) async throws -> DownloadLink {
        do {
            return try await locateDownload(path, preference: preference)
        } catch let error as BaiduError {
            switch error {
            case .fileNotFound, .loginExpired, .network: throw error
            default: return pcsDownloadLink(path)
            }
        }
    }

    func locateDownload(_ path: String, preference: Int) async throws -> DownloadLink {
        let uid = await resolveUID()
        let sign = LocateDownloadSign(bduss: credential.bduss, uid: uid, time: Int64(Date().timeIntervalSince1970))
        // 参考实现原样发送 `|`。Foundation 的 URL 不能包含 `|`，所以编码为 `%7C`，服务端解码后得到相同的值。
        let query = LocateDownloadSign.query(path: path, sign: sign).replacingOccurrences(of: "|", with: "%7C")
        let url = URLEncoding.url("\(Host.pcs)/rest/2.0/pcs/file", rawQuery: query)
        let json = try await pcsJSON(BaiduRequest(method: "POST", url: url, endpoint: .locateDownload, cookies: cookies()))

        let candidates = json["urls"].array
            .filter { ($0["encrypt"].int ?? 0) == 0 }
            .compactMap { $0["url"].string.flatMap(URL.init(string:)) }
        guard let url = Self.selectDownloadURL(candidates, preference: preference) else { throw BaiduError.noDownloadLink }
        return DownloadLink(url: url, headers: downloadHeaders(endpoint: .downloadLink), source: .locate)
    }

    /// 改用 https，取第 `preference` 个（超出时取最后一个）。
    /// `nb.cache` 开头的主机没有有效证书，URLSession 会拒绝，所以后面还有地址时跳过它们。
    static func selectDownloadURL(_ urls: [URL], preference: Int) -> URL? {
        guard !urls.isEmpty else { return nil }
        var index = min(max(preference, 0), urls.count - 1)
        while urls[index].host()?.hasPrefix("nb.cache") == true, index + 1 < urls.count {
            index += 1
        }
        var components = URLComponents(url: urls[index], resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? urls[index]
    }

    func pcsDownloadLink(_ path: String) -> DownloadLink {
        let url = URLEncoding.url("\(Host.pcs)/rest/2.0/pcs/file", [
            ("app_id", Host.pcsAppID), ("method", "download"), ("path", path),
        ])
        return DownloadLink(url: url, headers: downloadHeaders(endpoint: .pcsDownload), source: .pcs)
    }

    private func downloadHeaders(endpoint: Endpoint) -> [String: String] {
        var headers = ["Cookie": cookies().headerValue]
        if let userAgent = endpoint.userAgent { headers["User-Agent"] = userAgent }
        return headers
    }
}
