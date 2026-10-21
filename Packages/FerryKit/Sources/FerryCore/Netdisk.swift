import BaiduKit

/// `JobCoordinator` 用到的网盘操作。`BaiduClient` 实现它；测试用假实现。
public protocol Netdisk: Sendable {
    func openShare(_ link: ShareLink, password: String?) async throws -> ShareSession
    func createDirectory(_ path: String) async throws
    /// 列出分享中的一层目录。
    func listShare(_ session: ShareSession, directory: ShareEntry?) async throws -> [ShareEntry]
    func transfer(_ session: ShareSession, entries: [ShareEntry], to directory: String) async throws
    /// 列出自己网盘中的一层目录。
    func listDirectory(_ path: String) async throws -> [NetdiskEntry]
    func listFilesRecursively(_ path: String) async throws -> [RemoteFile]
    /// 只用于分享任务的任务子目录。不对网盘任务的源文件调用。
    func delete(paths: [String]) async throws
}

extension BaiduClient: Netdisk {}
