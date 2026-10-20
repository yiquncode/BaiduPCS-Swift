import Foundation

public enum BaiduError: LocalizedError, Equatable, Sendable {
    // 凭据
    case missingBDUSS
    case missingSTOKEN
    case loginExpired
    case loginStateMissing
    case securityVerification

    // 分享
    case invalidShareLink
    case invalidPasswordFormat
    case passwordRequired
    case wrongPassword
    case shareNotFound
    case shareExpired
    /// 分享页报告分享不可用，但无法区分不存在还是已失效。
    case shareUnavailable
    case shareBanned
    case captchaRequired
    case verificationTriggered

    // 转存
    case transferLimitExceeded(count: Int, limit: Int)
    case transferConflict(name: String)
    case transferDuplicate
    case transferFailed(code: Int)

    // 网盘与下载
    case fileNotFound
    case alreadyExists
    case invalidFileName
    case accessDenied
    case unauthorized
    case noDownloadLink
    case tooManyItems
    case tryLater

    // 通用
    case server(code: Int, message: String?)
    case httpStatus(Int)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingBDUSS:
            "Cookie 中缺少 BDUSS，无法登录。请在浏览器登录 pan.baidu.com，在开发者工具的“网络”面板中复制网盘主页第一条请求的 Cookie 请求头。"
        case .missingSTOKEN:
            "Cookie 中缺少 STOKEN，无法转存。请在浏览器登录 pan.baidu.com，在开发者工具的“网络”面板中复制网盘主页第一条请求的 Cookie 请求头。passport.baidu.com 的 STOKEN 不能用。"
        case .loginExpired:
            "登录已失效，请重新复制网盘的 Cookie 登录。"
        case .loginStateMissing:
            "分享页中没有登录信息。Cookie 可能缺少网盘的 STOKEN 或已过期，请重新复制网盘主页的 Cookie。"
        case .securityVerification:
            "百度要求账号安全验证，请先在浏览器中登录网盘完成验证。"
        case .invalidShareLink:
            "无法识别分享链接。支持 https://pan.baidu.com/s/1… 和 https://pan.baidu.com/share/init?surl=… 两种格式。"
        case .invalidPasswordFormat:
            "提取码应为 4 位字母或数字。"
        case .passwordRequired:
            "这个分享需要提取码。"
        case .wrongPassword:
            "提取码错误。"
        case .shareNotFound:
            "分享页面不存在，请检查链接是否完整。"
        case .shareExpired:
            "分享已失效，可能已被取消、删除或过期。"
        case .shareUnavailable:
            "分享不存在或已失效。"
        case .shareBanned:
            "这个分享因违规被禁用。"
        case .captchaRequired:
            "百度要求输入验证码。请稍后再试，或先在浏览器中打开这个分享。"
        case .verificationTriggered:
            "触发了百度的人机验证，请稍后再试。"
        case let .transferLimitExceeded(count, limit):
            "转存文件数 \(count) 超过单次上限 \(limit)。"
        case let .transferConflict(name):
            "转存目录中已有同名的文件或目录“\(name)”。"
        case .transferDuplicate:
            "转存失败：目标目录中的文件重复。"
        case let .transferFailed(code):
            "转存失败（错误码 \(code)）。"
        case .fileNotFound:
            "网盘中找不到这个文件或目录。"
        case .alreadyExists:
            "已存在同名的文件或目录。"
        case .invalidFileName:
            "文件名不合法。"
        case .accessDenied:
            "无权访问这个文件。"
        case .unauthorized:
            "百度拒绝了请求（user is not authorized），请稍后再试。"
        case .noDownloadLink:
            "没有取得下载链接。"
        case .tooManyItems:
            "一次操作的文件太多。"
        case .tryLater:
            "百度暂时无法处理请求，请稍后再试。"
        case let .server(code, message):
            if let message, !message.isEmpty {
                "百度返回错误（错误码 \(code)）：\(message)"
            } else {
                "百度返回错误（错误码 \(code)）。"
            }
        case let .httpStatus(status):
            "服务器返回 HTTP \(status)。"
        case .invalidResponse:
            "百度返回了无法识别的数据，接口可能已变化。"
        case let .network(message):
            "网络错误：\(message)"
        }
    }
}

extension BaiduError {
    /// 把网盘 `errno` 或 PCS `error_code` 转为错误。同一个码在不同接口中含义不同，所以带上接口。
    init(code: Int, message: String? = nil, endpoint: Endpoint) {
        switch (code, endpoint) {
        case (-9, .shareVerify), (-12, _): self = .wrongPassword
        case (-62, _), (-19, _): self = .captchaRequired
        case (8001, _): self = .verificationTriggered
        case (-7, _), (-21, _), (105, _): self = .shareExpired
        case (-1, _): self = .shareBanned
        case (-6, _), (-4, _), (3, _), (31041, _), (31042, _), (31045, _): self = .loginExpired
        case (132, _): self = .securityVerification
        case (-3, _), (-9, _), (31066, _), (31297, _): self = .fileNotFound
        case (-8, _), (-30, _), (31061, _): self = .alreadyExists
        case (31062, _): self = .invalidFileName
        case (31064, _): self = .accessDenied
        case (31044, _), (31326, _), (31626, _): self = .unauthorized
        case (-33, _): self = .tooManyItems
        case (2, _): self = .tryLater
        default: self = .server(code: code, message: message)
        }
    }
}
