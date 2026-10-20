import Foundation
import Testing
@testable import BaiduKit

/// 实网只读冒烟测试。需要两个环境变量：
/// `FERRY_LIVE_COOKIE_FILE`（Cookie 字符串所在文件）和 `FERRY_LIVE_SHARE`（分享链接或分享文字）。
/// 只做 validate → openShare → 列根目录和第一个子目录，不转存、不删除。
struct LiveSmokeTests {
    static let environment = ProcessInfo.processInfo.environment
    static let isEnabled = environment["FERRY_LIVE_COOKIE_FILE"] != nil && environment["FERRY_LIVE_SHARE"] != nil

    @Test(.enabled(if: isEnabled, "需要 FERRY_LIVE_COOKIE_FILE 和 FERRY_LIVE_SHARE"))
    func readOnlyShareFlow() async throws {
        let cookieFile = try #require(Self.environment["FERRY_LIVE_COOKIE_FILE"])
        let shareText = try #require(Self.environment["FERRY_LIVE_SHARE"])
        let cookie = try String(contentsOfFile: (cookieFile as NSString).expandingTildeInPath, encoding: .utf8)

        let client = BaiduClient(credential: try Credential.parse(cookie))
        let account = try await client.validate()
        print("账号：\(account.username) uk=\(account.uk) uid=\(account.uid.map(String.init) ?? "不可得")")

        let link = try #require(ShareLink.parse(shareText))
        let session = try await client.openShare(link, password: nil)
        print("分享：shareid=\(session.shareID) share_uk=\(session.shareUK) cookies=\(session.cookies.map(\.name))")

        let root = try await client.listShare(session)
        print("根目录 \(root.count) 项：")
        for entry in root { print("  \(entry.isDirectory ? "[目录]" : "      ") \(entry.relativePath) \(entry.size)") }

        if let directory = root.first(where: \.isDirectory) {
            let children = try await client.listShare(session, directory: directory)
            print("\(directory.relativePath) 中 \(children.count) 项：")
            for entry in children { print("  \(entry.isDirectory ? "[目录]" : "      ") \(entry.relativePath) \(entry.size)") }
        }
    }
}
