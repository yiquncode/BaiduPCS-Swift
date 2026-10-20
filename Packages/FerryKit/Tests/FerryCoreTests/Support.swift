import BaiduKit
import DownloadKit
import Foundation
import Synchronization
import Testing
@testable import FerryCore

/// 内存中的假网盘。分享内容按相对路径保存；转存把它们复制到网盘路径下。
final class FakeNetdisk: Netdisk {
    enum Operation: Equatable {
        case openShare
        case createDirectory(String)
        case transfer(String)
        case list(String)
        case delete([String])
    }

    private struct State {
        var share: [String: Data] = [:]
        var disk: [String: Data] = [:]
        var operations: [Operation] = []
        var transferFailures = 0
        var deleteFailures = 0
    }

    private let state = Mutex(State())

    init(share: [String: Data]) {
        state.withLock { $0.share = share }
    }

    var operations: [Operation] { state.withLock { $0.operations } }
    func data(at path: String) -> Data? { state.withLock { $0.disk[path] } }
    func remotePaths() -> [String] { state.withLock { $0.disk.keys.sorted() } }

    /// 下一次转存复制一个条目后失败，模拟转存到一半中断。
    func failNextTransfer() { state.withLock { $0.transferFailures += 1 } }
    func failNextDelete() { state.withLock { $0.deleteFailures += 1 } }

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

    func listFilesRecursively(_ path: String) async throws -> [RemoteFile] {
        state.withLock { state in
            state.operations.append(.list(path))
            return state.disk.filter { $0.key.hasPrefix(path + "/") }.sorted { $0.key < $1.key }
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
        let names = Set(state.withLock { $0.share.keys }.map { String($0.split(separator: "/")[0]) })
        return names.sorted().enumerated().map { index, name in
            let isDirectory = state.withLock { $0.share[name] == nil }
            let size = Int64(state.withLock { $0.share[name]?.count ?? 0 })
            return ShareEntry(fsID: Int64(index + 100), name: name, path: "/share/" + name, isDirectory: isDirectory, size: size)
        }
    }
}

/// 按网盘路径提供文件内容的 HTTP 桩。每个实例用自己的 host，并行测试互不干扰。
final class FileServer: Sendable {
    let host = "\(UUID().uuidString.lowercased()).test"
    private let netdisk: FakeNetdisk
    private let state = Mutex<(log: [String], stalled: Bool, failing: Set<String>)>(([], false, []))

    init(netdisk: FakeNetdisk) {
        self.netdisk = netdisk
        FileProtocol.register(self, host: host)
    }

    var log: [String] { state.withLock { $0.log } }
    func requests(for path: String) -> Int { log.count { $0 == path } }
    /// 停住所有响应，直到设为 false 或请求被取消。
    func setStalled(_ stalled: Bool) { state.withLock { $0.stalled = stalled } }
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
        while state.withLock({ $0.stalled }) {
            if connection.isStopped { return }
            Thread.sleep(forTimeInterval: 0.002)
        }
        if connection.isStopped { return }
        if body.count > half { client.urlProtocol(connection, didLoad: body.subdata(in: half..<body.count)) }
        client.urlProtocolDidFinishLoading(connection)
    }
}

final class FileProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = Mutex<[String: FileServer]>([:])
    private let stopped = Atomic(false)

    static func register(_ server: FileServer, host: String) {
        servers.withLock { $0[host] = server }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FileProtocol.self]
        return URLSession(configuration: configuration)
    }

    var isStopped: Bool { stopped.load(ordering: .acquiring) }

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
        stopped.store(true, ordering: .releasing)
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

    init(share: [String: Data]) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FerryCoreTests-\(UUID().uuidString)")
        netdisk = FakeNetdisk(share: share)
        server = FileServer(netdisk: netdisk)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var downloads: URL { directory.appendingPathComponent("downloads") }
    var store: JobStore { JobStore(fileURL: directory.appendingPathComponent("jobs.json")) }

    static let configuration = DownloadConfiguration(
        maxConcurrentFiles: 4,
        segmentSize: .fixed(1 << 20),
        maxRetries: 0,
        retryBaseDelay: .milliseconds(1),
        retryMaxDelay: .milliseconds(2),
        progressInterval: .milliseconds(20),
        checkpointInterval: .milliseconds(20)
    )

    func makeCoordinator(settings: FerrySettings = FerrySettings(maxConcurrentFiles: 4)) -> JobCoordinator {
        let engine = DownloadEngine(stateDirectory: stateDirectory,
                                    source: FileServerSource(server: server), configuration: Self.configuration, session: session)
        let coordinator = JobCoordinator(engine: engine, store: store, settings: settings, downloadDirectory: downloads,
                                         baseConfiguration: Self.configuration)
        coordinator.netdisk = netdisk
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
