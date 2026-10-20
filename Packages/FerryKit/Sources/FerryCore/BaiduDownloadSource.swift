import BaiduKit
import DownloadKit
import Foundation
import Synchronization

/// 用百度网盘的下载链接下载文件。`DownloadRequest.context` 是文件的网盘路径。
public final class BaiduDownloadSource: DownloadSource {
    private let client = Mutex<BaiduClient?>(nil)

    public init() {}

    /// 登录、退出或凭据变化时调用。之后获取的下载链接使用新的客户端。
    public func setClient(_ client: BaiduClient?) {
        self.client.withLock { $0 = client }
    }

    public func resolve(_ request: DownloadRequest) async throws -> ResolvedURL {
        guard let client = client.withLock({ $0 }) else { throw ResolveError(description: "未登录百度网盘。") }
        do {
            let link = try await client.downloadLink(for: Self.remotePath(from: request.context))
            return ResolvedURL(url: link.url, headers: link.headers)
        } catch let error as BaiduError {
            throw ResolveError(description: error.localizedDescription)
        }
    }

    public static func context(forRemotePath path: String) -> Data { Data(path.utf8) }

    public static func remotePath(from context: Data) -> String { String(decoding: context, as: UTF8.self) }
}

/// 引擎用 `String(describing:)` 记录获取链接失败的原因，所以把中文说明放在 `description` 中。
struct ResolveError: Error, CustomStringConvertible {
    let description: String
}
