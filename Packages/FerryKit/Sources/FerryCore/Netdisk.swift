import BaiduKit

/// `JobCoordinator` 用到的网盘操作。`BaiduClient` 实现它；测试用假实现。
public protocol Netdisk: Sendable {
    func openShare(_ link: ShareLink, password: String?) async throws -> ShareSession
    func createDirectory(_ path: String) async throws
    func transfer(_ session: ShareSession, entries: [ShareEntry], to directory: String) async throws
    func listFilesRecursively(_ path: String) async throws -> [RemoteFile]
    func delete(paths: [String]) async throws
}

extension BaiduClient: Netdisk {}
