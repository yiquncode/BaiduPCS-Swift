import DownloadKit
import os

/// 获取下载链接前，先让 `JobCoordinator` 检查文件下载所属的任务：任务属于另一个百度账号时不获取链接，
/// 文件下载直接失败（不重试）。下载引擎只在链接失效时才再获取，所以换账号前已开始的下载在链接失效前继续。
///
/// 下载引擎要先于 `JobCoordinator` 创建，所以创建 `JobCoordinator` 后再调用 `connect(_:)`。
public final class AccountCheckedSource: DownloadSource {
    private struct State {
        weak var coordinator: JobCoordinator?
    }

    private let base: any DownloadSource
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(_ base: any DownloadSource) {
        self.base = base
    }

    public func connect(_ coordinator: JobCoordinator) {
        state.withLock { $0.coordinator = coordinator }
    }

    /// 获取前后各检查一次。获取期间换了账号时，`base` 可能已经用新账号获取了链接，后一次检查丢掉它。
    public func resolve(_ request: DownloadRequest) async throws -> ResolvedURL {
        let coordinator = state.withLock { $0.coordinator }
        try await coordinator?.checkAccount(ofDownload: request.id)
        let resolved = try await base.resolve(request)
        try await coordinator?.checkAccount(ofDownload: request.id)
        return resolved
    }
}
