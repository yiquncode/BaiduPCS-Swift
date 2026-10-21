import BaiduKit
import DownloadKit
import Foundation
import os
import Testing
@testable import FerryCore

/// 内存中的假网盘。分享内容按相对路径保存；转存把它们复制到网盘路径下。自己网盘中的文件按网盘路径保存。
final class FakeNetdisk: Netdisk {
    enum Operation: Equatable {
        case openShare
        case createDirectory(String)
        case transfer(String)
        case list(String)
        case listDirectory(String)
        case delete([String])
    }

    private struct State {
        var share: [String: Data] = [:]
        /// 分享中没有文件的目录（相对路径）。
        var emptyDirectories: Set<String> = []
        var disk: [String: Data] = [:]
        /// 下一次列目录返回这个结果，模拟转存后列表还没更新或返回了意外的路径。
        var nextListing: [RemoteFile]?
        var operations: [Operation] = []
        var transferFailures = 0
        var listFailures = 0
        var deleteFailures = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameter disk: 自己网盘中原来就有的文件，键是网盘路径。
    init(share: [String: Data], emptyDirectories: Set<String> = [], disk: [String: Data] = [:]) {
        state.withLock {
            $0.share = share
            $0.emptyDirectories = emptyDirectories
            $0.disk = disk
        }
    }

    var operations: [Operation] { state.withLock { $0.operations } }
    func data(at path: String) -> Data? { state.withLock { $0.disk[path] } }
    func remotePaths() -> [String] { state.withLock { $0.disk.keys.sorted() } }

    /// 下一次转存复制一个条目后失败，模拟转存到一半中断。
    func failNextTransfer() { state.withLock { $0.transferFailures += 1 } }
    func failNextDelete() { state.withLock { $0.deleteFailures += 1 } }
    /// 下一次递归列出失败。
    func failNextList() { state.withLock { $0.listFailures += 1 } }
    /// 收到的删除操作。网盘任务的测试要求它一直为空。
    var deletes: [[String]] {
        operations.compactMap { if case .delete(let paths) = $0 { paths } else { nil } }
    }
    func setNextListing(_ files: [RemoteFile]) { state.withLock { $0.nextListing = files } }

    func openShare(_ link: ShareLink, password: String?) async throws -> ShareSession {
        state.withLock { $0.operations.append(.openShare) }
        return Self.session
    }

    func createDirectory(_ path: String) async throws {
        state.withLock { $0.operations.append(.createDirectory(path)) }
    }

    func transfer(_ session: ShareSession, entries: [ShareEntry], to directory: String) async throws {
        try state.withLock { state in
            state.operations.append(.transfer(directory))
            let shouldFail = state.transferFailures > 0
            state.transferFailures = max(0, state.transferFailures - 1)
            for entry in entries {
                let matches = state.share.filter { $0.key == entry.relativePath || $0.key.hasPrefix(entry.relativePath + "/") }
                for (path, data) in matches {
                    let target = directory + "/" + path
                    // 真实接口遇到同名条目时返回 -30。
                    guard state.disk[target] == nil else { throw BaiduError.transferConflict(name: entry.name) }
                    state.disk[target] = data
                }
                if shouldFail { throw BaiduError.network("connection lost") }
            }
        }
    }

    func listShare(_ session: ShareSession, directory: ShareEntry?) async throws -> [ShareEntry] {
        let prefix = directory.map { $0.relativePath + "/" } ?? ""
        return entries(under: prefix)
    }

    func listDirectory(_ path: String) async throws -> [NetdiskEntry] {
        state.withLock { state in
            state.operations.append(.listDirectory(path))
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let names = Set(state.disk.keys.filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count).split(separator: "/")[0]) })
            return names.sorted().map { name in
                let child = prefix + name
                let data = state.disk[child]
                return NetdiskEntry(fsID: Int64(child.hashValue), name: name, path: child, isDirectory: data == nil,
                                    size: Int64(data?.count ?? 0))
            }
        }
    }

    func listFilesRecursively(_ path: String) async throws -> [RemoteFile] {
        try state.withLock { state in
            state.operations.append(.list(path))
            if state.listFailures > 0 {
                state.listFailures -= 1
                throw BaiduError.network("connection lost")
            }
            if let listing = state.nextListing {
                state.nextListing = nil
                return listing
            }
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return state.disk.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
                .enumerated().map { RemoteFile(path: $1.key, size: Int64($1.value.count), fsID: Int64($0)) }
        }
    }

    func delete(paths: [String]) async throws {
        try state.withLock { state in
            state.operations.append(.delete(paths))
            if state.deleteFailures > 0 {
                state.deleteFailures -= 1
                throw BaiduError.tryLater
            }
            for path in paths {
                state.disk = state.disk.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
            }
        }
    }

    static let link = ShareLink.parse("https://pan.baidu.com/s/1qYZEsSc")!
    static let session = ShareSession(link: link, password: nil, shareID: 1, shareUK: 2, bdstoken: "token", cookies: [])

    /// 分享根目录中的条目。
    func rootEntries() -> [ShareEntry] {
        entries(under: "")
    }

    /// `prefix` 为空或以 `/` 结尾的相对目录。
    private func entries(under prefix: String) -> [ShareEntry] {
        let (share, emptyDirectories) = state.withLock { ($0.share, $0.emptyDirectories) }
        let paths = Array(share.keys) + Array(emptyDirectories)
        let names = Set(paths.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count).split(separator: "/")[0]) })
        let directory = String(prefix.dropLast())
        return names.sorted().enumerated().map { index, name in
            let path = prefix + name
            let isDirectory = share[path] == nil
            return ShareEntry(fsID: Int64(path.hashValue), name: name, path: "/share/" + path, isDirectory: isDirectory,
                              size: Int64(share[path]?.count ?? 0), relativeDirectory: directory)
        }
    }
}

/// 按网盘路径提供文件内容的 HTTP 桩。每个实例用自己的 host，并行测试互不干扰。
final class FileServer: Sendable {
    let host = "\(UUID().uuidString.lowercased()).test"
    private let netdisk: FakeNetdisk
    private let state = OSAllocatedUnfairLock<(log: [String], stalled: Bool, failing: Set<String>, stalling: Set<String>)>(initialState: ([], false, [], []))

    init(netdisk: FakeNetdisk) {
        self.netdisk = netdisk
        FileProtocol.register(self, host: host)
    }

    var log: [String] { state.withLock { $0.log } }
    func requests(for path: String) -> Int { log.count { $0 == path } }
    /// 停住所有响应，直到设为 false 或请求被取消。
    func setStalled(_ stalled: Bool) { state.withLock { $0.stalled = stalled } }
    /// 只停住以这些后缀结尾的路径。
    func setStalling(_ suffixes: Set<String>) { state.withLock { $0.stalling = suffixes } }
    /// 以这些后缀结尾的路径返回 500。
    func setFailing(_ suffixes: Set<String>) { state.withLock { $0.failing = suffixes } }

    func url(for remotePath: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = remotePath
        return components.url!
    }

    func serve(_ request: URLRequest, on connection: FileProtocol) {
        let url = request.url!
        let path = url.path(percentEncoded: false)
        let isFailing = state.withLock { state in
            state.log.append(path)
            return state.failing.contains { path.hasSuffix($0) }
        }
        let client = connection.client!
        func respond(_ status: Int, headers: [String: String] = [:], body: Data = Data()) {
            var headers = headers
            headers["Content-Length"] = String(body.count)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(connection, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client.urlProtocol(connection, didLoad: body) }
            client.urlProtocolDidFinishLoading(connection)
        }
        if isFailing { return respond(500) }
        guard let file = netdisk.data(at: path) else { return respond(404) }

        var body = file
        var status = 200
        var headers: [String: String] = [:]
        if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes="), !file.isEmpty {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let first = Int(bounds[0]) ?? 0
            let last = min(Int(bounds[1]) ?? file.count - 1, file.count - 1)
            body = file.subdata(in: first..<last + 1)
            status = 206
            headers["Content-Range"] = "bytes \(first)-\(last)/\(file.count)"
        }
        headers["Content-Length"] = String(body.count)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client.urlProtocol(connection, didReceive: response, cacheStoragePolicy: .notAllowed)
        // 先发一部分，停住时留下可以续传的进度。
        let half = body.count / 2
        if half > 0 { client.urlProtocol(connection, didLoad: body.prefix(half)) }
        while state.withLock({ $0.stalled || $0.stalling.contains { path.hasSuffix($0) } }) {
            if connection.isStopped { return }
            Thread.sleep(forTimeInterval: 0.002)
        }
        if connection.isStopped { return }
        if body.count > half { client.urlProtocol(connection, didLoad: body.subdata(in: half..<body.count)) }
        client.urlProtocolDidFinishLoading(connection)
    }
}

final class FileProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = OSAllocatedUnfairLock<[String: FileServer]>(initialState: [:])
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    static func register(_ server: FileServer, host: String) {
        servers.withLock { $0[host] = server }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FileProtocol.self]
        return URLSession(configuration: configuration)
    }

    var isStopped: Bool { stopped.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        guard let host = request.url?.host(), let server = Self.servers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        DispatchQueue.global().async { server.serve(request, on: self) }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}

/// 把 `context` 中的网盘路径映射到桩服务器。
struct FileServerSource: DownloadSource {
    let server: FileServer

    func resolve(_ request: DownloadRequest) async throws -> ResolvedURL {
        ResolvedURL(url: server.url(for: BaiduDownloadSource.remotePath(from: request.context)))
    }
}

/// 一个测试的临时目录、假网盘和桩服务器。
@MainActor
final class Fixture {
    let directory: URL
    let netdisk: FakeNetdisk
    let server: FileServer
    let session = FileProtocol.makeSession()

    init(share: [String: Data] = [:], emptyDirectories: Set<String> = [], disk: [String: Data] = [:]) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FerryCoreTests-\(UUID().uuidString)")
        netdisk = FakeNetdisk(share: share, emptyDirectories: emptyDirectories, disk: disk)
        server = FileServer(netdisk: netdisk)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("downloads"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var downloads: URL { directory.appendingPathComponent("downloads") }
    /// 代替系统的废纸篓。
    var trash: URL { directory.appendingPathComponent("trash") }

    /// 把项目移到 `trash` 中。测试不使用系统的废纸篓。
    static func trashItem(into trash: URL) -> @Sendable (URL) throws -> Void {
        { url in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)"))
        }
    }

    /// 已转存、文件列表已保存，但还没开始下载的任务。
    func makeTransferredJob() async throws -> Job {
        let entries = netdisk.rootEntries()
        var job = Job(link: FakeNetdisk.link, password: nil, entries: entries, transferFolder: "/Ferry")
        try await netdisk.transfer(FakeNetdisk.session, entries: entries, to: job.remoteDirectory)
        job.files = try await netdisk.listFilesRecursively(job.remoteDirectory).map { file in
            JobFile(remotePath: file.path, relativePath: RemotePath.relativePath(of: file.path, in: job.remoteDirectory)!, size: file.size)
        }
        job.phase = .downloading
        return job
    }
    var store: JobStore { JobStore(fileURL: directory.appendingPathComponent("jobs.json")) }

    static let accountUK: Int64 = 1

    static let configuration = DownloadConfiguration(
        maxConcurrentFiles: 4,
        segmentSize: .fixed(1 << 20),
        maxRetries: 0,
        retryBaseDelay: .milliseconds(1),
        retryMaxDelay: .milliseconds(2),
        progressInterval: .milliseconds(20),
        checkpointInterval: .milliseconds(20)
    )

    func makeEngine() -> DownloadEngine {
        DownloadEngine(stateDirectory: stateDirectory, source: FileServerSource(server: server),
                       configuration: Self.configuration, session: session)
    }

    func makeCoordinator(settings: FerrySettings = FerrySettings(cleanupAfterDownload: false, maxConcurrentFiles: 4), downloadFolder: URL? = nil,
                         folderAccess: any DownloadFolderAccess = SecurityScopedFolderAccess()) -> JobCoordinator {
        let coordinator = JobCoordinator(engine: makeEngine(), store: store, settings: settings,
                                         downloadFolder: DownloadFolder(url: downloadFolder ?? downloads),
                                         folderAccess: folderAccess, trashItem: Self.trashItem(into: trash),
                                         baseConfiguration: Self.configuration)
        coordinator.netdisk = netdisk
        coordinator.accountUK = Self.accountUK
        // 每个测试的每个事件都检查增量维护的计数。
        coordinator.tallyMismatchHandler = { Issue.record(Comment(rawValue: $0)) }
        return coordinator
    }

    var stateDirectory: URL { directory.appendingPathComponent("state") }

    /// 下载引擎状态目录中的文件名。
    func stateFiles() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: stateDirectory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: stateDirectory.path))
    }

    func contents(_ relativePath: String) -> Data? {
        try? Data(contentsOf: downloads.appending(path: relativePath))
    }
}

func randomData(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
    return data
}

/// 记录打开和关闭的下载目录。`failing` 中的路径无法打开。
final class FakeFolderAccess: DownloadFolderAccess {
    private let state = OSAllocatedUnfairLock<(opened: [String], closed: [String], failing: Set<String>)>(initialState: ([], [], []))

    var opened: [String] { state.withLock { $0.opened } }
    var closed: [String] { state.withLock { $0.closed } }
    func setFailing(_ paths: Set<String>) { state.withLock { $0.failing = paths } }

    func open(_ folder: DownloadFolder) throws -> OpenedFolder {
        try state.withLock { state in
            guard !state.failing.contains(folder.url.path) else { throw DownloadFolderError.inaccessible(folder.url) }
            state.opened.append(folder.url.path)
            return OpenedFolder(url: folder.url, isSecurityScoped: true)
        }
    }

    func close(_ folder: OpenedFolder) {
        state.withLock { $0.closed.append(folder.url.path) }
    }
}

struct TimeoutError: Error {}

@MainActor
func waitUntil(_ description: String, timeout: Duration = .seconds(10), _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for \(description)")
            throw TimeoutError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

extension JobCoordinator {
    func job(_ id: Job.ID) -> Job? { jobs.first { $0.id == id } }

    func waitForPhase(_ phase: Job.Phase, of id: Job.ID) async throws {
        try await waitUntil("phase \(phase)") { job(id)?.phase == phase }
    }
}
