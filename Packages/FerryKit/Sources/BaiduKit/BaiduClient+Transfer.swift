import Foundation

extension BaiduClient {
    /// 把勾选的分享条目转存到 `directory`，保留它们在分享中的相对目录。目录不存在时自动创建。
    public func transfer(_ session: ShareSession, entries: [ShareEntry], to directory: String) async throws {
        let planner = TransferPlanner(
            makeDirectory: { try await self.createDirectory($0) },
            listChildren: { try await self.listShare(session, directory: $0) },
            transferBatch: { try await self.transferBatch(session, entries: $0, to: $1) }
        )
        try await planner.transfer(entries, to: directory)
    }

    func transferBatch(_ session: ShareSession, entries: [ShareEntry], to directory: String) async throws {
        let url = URLEncoding.url("\(Host.pan)/share/transfer", [
            ("app_id", Host.panAppID), ("channel", "chunlei"), ("clienttype", "0"), ("web", "1"),
            ("shareid", String(session.shareID)), ("from", String(session.shareUK)), ("bdstoken", session.bdstoken),
        ])
        let fsIDs = "[" + entries.map { String($0.fsID) }.joined(separator: ",") + "]"
        let request = BaiduRequest.form(
            [("fsidlist", fsIDs), ("path", directory)],
            url: url, endpoint: .shareTransfer, cookies: cookies(adding: session.cookies),
            headers: ["Referer": session.link.url.absoluteString]
        )
        let (json, _) = try await json(request)
        try Self.checkTransfer(json)
    }

    static func checkTransfer(_ json: JSON) throws {
        let errno = json["errno"].int ?? 0
        switch errno {
        case 0:
            return
        case 12:
            // 12 是总称，具体原因看数量上限字段和 info[0].errno。
            let info = json["info"][0]
            if let count = json["target_file_nums"].int, let limit = json["target_file_nums_limit"].int, count > limit {
                throw BaiduError.transferLimitExceeded(count: count, limit: limit)
            }
            let itemErrno = info["errno"].int ?? errno
            if itemErrno == -30 {
                throw BaiduError.transferConflict(name: Path.lastComponent(info["path"].string ?? ""))
            }
            throw BaiduError.transferFailed(code: itemErrno)
        case 4:
            throw BaiduError.transferDuplicate
        default:
            throw BaiduError(code: errno, message: json["show_msg"].string, endpoint: .shareTransfer)
        }
    }
}
