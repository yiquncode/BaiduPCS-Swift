/// User-Agent 字符串。百度按 UA 区分客户端，UA 不对时会返回登录页或 `user is not authorized`。
enum UserAgent {
    static let netdisk = "netdisk;P2SP;3.0.0.8;netdisk;11.12.3;ANG-AN00;android-android;10.0;JSbridge4.4.0;jointBridge;1.1.0;"
    static let chromeMac63 = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/63.0.3239.132 Safari/537.36"
    static let chromeWin76 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/76.0.3809.100 Safari/537.36"
    static let tieba = "bdtb for Android 6.9.2.1"
    static let wxList = "netdisk"

    /// 参考实现对这些接口不发送 UA。URLSession 不能去掉 UA，`nil` 表示使用 URLSession 的默认 UA。
    /// 实测被拒绝时，改成 `netdisk`。
    static let unspecified: String? = nil
}

/// Ferry 调用的百度接口。每个接口的 UA 沿用参考实现，不要统一成一个。
enum Endpoint: Sendable {
    case sharePage
    case shareVerify
    case shareList
    case shareWXList
    case shareTransfer
    case templateVariable
    case userInfo
    case fileList
    case pcsFile
    case locateDownload
    case pcsDownload
    case downloadLink
    case tiebaLogin

    var userAgent: String? {
        switch self {
        case .sharePage, .fileList: UserAgent.netdisk
        // 参考实现对 PCS download 地址不发送 UA。URLSession 不能发送空 UA，所以下载相关的接口统一用 NetdiskUA。
        case .locateDownload, .downloadLink, .pcsDownload: UserAgent.netdisk
        case .shareVerify, .shareList: UserAgent.chromeMac63
        case .shareTransfer: UserAgent.chromeWin76
        case .shareWXList: UserAgent.wxList
        case .tiebaLogin: UserAgent.tieba
        case .templateVariable, .userInfo, .pcsFile: UserAgent.unspecified
        }
    }
}

enum Host {
    static let pan = "https://pan.baidu.com"
    static let pcs = "https://pcs.baidu.com"
    /// 应用开启了 ATS，参考实现的 http 地址会被拦截。
    static let tieba = "https://tieba.baidu.com"

    static let panAppID = "250528"
    static let pcsAppID = "266719"
}
