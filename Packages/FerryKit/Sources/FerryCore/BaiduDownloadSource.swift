import BaiduKit
import DownloadKit
import Foundation
import os

/// 用百度网盘的下载链接下载文件。`DownloadRequest.context` 是文件的网盘路径。
public final class BaiduDownloadSource: DownloadSource {
    private struct State {
        var client: BaiduClient?
        /// 每个文件下载已获取下载链接的次数。
        var attempts: [String: Int] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// 登录、退出或凭据变化时调用。之后获取的下载链接使用新的客户端。
    public func setClient(_ client: BaiduClient?) {
        state.withLock { $0.client = client }
    }

    /// 同一文件下载第 n 次（从 0 开始）获取链接时，选用第 n 个 dlink 主机（超出时用最后一个）。
    /// 引擎在链接失效后才再次获取，所以每次换一个主机。
    public func resolve(_ request: DownloadRequest) async throws -> ResolvedURL {
        let (client, attempt) = state.withLock { state in
            let attempt = state.attempts[request.id, default: 0]
            state.attempts[request.id] = attempt + 1
            return (state.client, attempt)
        }
        guard let client else { throw PermanentLinkError(description: "未登录百度网盘。") }
        do {
            let link = try await client.downloadLink(for: Self.remotePath(from: request.context), preference: attempt)
            return ResolvedURL(url: link.url, headers: link.headers)
        } catch let error as BaiduError {
            let description = error.errorDescription ?? error.localizedDescription
            if Self.isPermanent(error) {
                throw PermanentLinkError(description: description)
            }
            throw LinkError(description: description)
        }
    }

    /// 重试也不会成功的错误：登录失效、文件不存在或无权访问、需要安全验证。
    static func isPermanent(_ error: BaiduError) -> Bool {
        switch error {
        case .loginExpired, .loginStateMissing, .securityVerification, .captchaRequired, .verificationTriggered,
             .fileNotFound, .accessDenied, .invalidNameOrAccessDenied:
            true
        default:
            false
        }
    }

    public static func context(forRemotePath path: String) -> Data { Data(path.utf8) }

    public static func remotePath(from context: Data) -> String { String(decoding: context, as: UTF8.self) }
}

/// 引擎用 `errorDescription` 记录获取链接失败的原因。
struct LinkError: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
}

/// 引擎遇到它时不再重试，文件下载直接失败。
struct PermanentLinkError: PermanentDownloadSourceError, LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
}
