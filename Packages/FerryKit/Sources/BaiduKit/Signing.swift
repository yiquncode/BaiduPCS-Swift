import CryptoKit
import Foundation

enum Hash {
    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha1(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// `locatedownload` 的签名（参考实现的 netdisksign）。
struct LocateDownloadSign: Equatable {
    private static let secret = "ebrcUYiuxaZv2XGu7KIYKxUrqfnOfpDF"

    let time: Int64
    let devUID: String
    let rand: String

    init(bduss: String, uid: UInt64, time: Int64, devUID: String? = nil) {
        let devUID = devUID ?? Self.devUID(bduss: bduss)
        self.time = time
        self.devUID = devUID
        rand = Hash.sha1(Hash.sha1(bduss) + String(uid) + Self.secret + String(time) + devUID)
    }

    static func devUID(bduss: String) -> String {
        Hash.md5(bduss).uppercased() + "|0"
    }

    /// 原样拼接，`|` 不编码。
    var queryTail: String {
        "time=\(time)&rand=\(rand)&devuid=\(devUID)&cuid=\(devUID)"
    }

    /// 完整的 query：固定参数按键名排序并编码，签名参数原样接在后面。
    static func query(path: String, sign: LocateDownloadSign) -> String {
        let items: [(String, String)] = [
            ("ant", "1"), ("apn_id", "1_0"), ("app_id", Host.panAppID), ("channel", "0"),
            ("check_blue", "1"), ("clienttype", "17"), ("es", "1"), ("esl", "1"),
            ("freeisp", "0"), ("method", "locatedownload"), ("path", path),
            ("queryfree", "0"), ("use", "0"), ("ver", "4.0"),
        ].sorted { $0.0 < $1.0 }
        return URLEncoding.query(items) + "&" + sign.queryTail
    }
}

/// 贴吧客户端登录接口的表单。
enum TiebaLogin {
    /// 参考实现从一个总是为空的表单键计算 model、imei 和 cuid，所以它对所有账号发送相同的值。这里直接固定。
    static let model = "HUAWEI MLA-AL10"
    static let phoneIMEI = "860983036542682"
    static let cuid = Hash.md5("_7.0.0.0_" + phoneIMEI + "_mini_ad_wandoujia").uppercased() + "|" + String(phoneIMEI.reversed())

    static func form(bduss: String, now: Int64) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("bdusstoken", bduss + "|null"),
            ("channel_id", ""),
            ("channel_uid", ""),
            ("stErrorNums", "0"),
            ("subapp_type", "mini"),
            ("timestamp", "\(now)922"),
            ("_client_type", "2"),
            ("_client_version", "7.0.0.0"),
            ("_phone_imei", phoneIMEI),
            ("from", "mini_ad_wandoujia"),
            ("model", model),
            ("cuid", cuid),
        ]
        fields.append(("sign", sign(fields)))
        return fields
    }

    /// 按键名排序，拼接 `key=value`（无分隔符），末尾加 `tiebaclient!!!`，取大写 MD5。
    static func sign(_ fields: [(String, String)]) -> String {
        let joined = fields.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined()
        return Hash.md5(joined + "tiebaclient!!!").uppercased()
    }
}
