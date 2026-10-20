import Foundation

extension BaiduClient {
    /// 校验凭据：bdstoken 非空表示 Cookie 对网盘有效；再取 uk；最后用贴吧接口取 uid 和用户名。
    /// 贴吧接口失败不阻止登录。
    public func validate() async throws -> Account {
        let bdstoken = try await fetchBDStoken()
        let info = try await fetchUserInfo()
        let tieba = try? await tiebaLogin()
        uidLookup = Task { tieba?.uid }

        let username = [tieba?.name, info.name].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return Account(username: username, uk: info.uk, uid: tieba?.uid, bdstoken: bdstoken)
    }

    func fetchBDStoken() async throws -> String {
        // `fields` 是 URL 编码的 JSON 数组。参考实现的 app_id 是乱码，这里用正确的值。
        let url = URLEncoding.url("\(Host.pan)/api/gettemplatevariable", [
            ("clienttype", "0"), ("app_id", Host.panAppID), ("fields", #"["bdstoken"]"#),
        ])
        let json = try await panJSON(BaiduRequest(url: url, endpoint: .templateVariable, cookies: cookies()))
        guard let bdstoken = json["result"]["bdstoken"].string, !bdstoken.isEmpty else { throw BaiduError.loginExpired }
        return bdstoken
    }

    func fetchUserInfo() async throws -> (uk: Int64, name: String?) {
        let url = URLEncoding.url("\(Host.pan)/api/user/getinfo", [("need_selfinfo", "1")])
        let json = try await panJSON(BaiduRequest(url: url, endpoint: .userInfo, cookies: cookies()))
        let records = json["records"].array
        guard records.count == 1, let uk = records[0]["uk"].int64 else { throw BaiduError.loginExpired }
        // 用户名字段没有出现在参考实现中，只作为贴吧接口不可用时的备选。
        let name = ["baidu_name", "netdisk_name", "uname"].lazy
            .compactMap { records[0][$0].string }
            .first { !$0.isEmpty }
        return (uk, name)
    }

    /// 贴吧客户端登录接口。它是取得百度 uid 的唯一来源。
    func tiebaLogin() async throws -> (uid: UInt64, name: String) {
        let now = Int64(Date().timeIntervalSince1970)
        let request = BaiduRequest.form(
            TiebaLogin.form(bduss: credential.bduss, now: now),
            url: URLEncoding.url("\(Host.tieba)/c/s/login", rawQuery: ""),
            endpoint: .tiebaLogin,
            cookies: [Credential.Cookie(name: "ka", value: "open")],
            headers: ["net": "1", "client_logid": "\(now)416"]
        )
        let (json, _) = try await json(request)
        let code = json["error_code"].string ?? ""
        guard code == "0" else {
            throw BaiduError.server(code: Int(code) ?? -1, message: json["error_msg"].string)
        }
        guard let uid = json["user"]["id"].uint64 else { throw BaiduError.invalidResponse }
        return (uid, json["user"]["name"].string ?? "")
    }

    func resolveUID() async -> UInt64 {
        if uidLookup == nil {
            uidLookup = Task { try? await self.tiebaLogin().uid }
        }
        return await uidLookup?.value ?? Self.fallbackUID
    }
}
