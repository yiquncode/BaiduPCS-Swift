import Foundation
import Synchronization
import Testing
@testable import DownloadKit

private let kilobyte = 1 << 10
private let megabyte = 1 << 20

@Suite struct DownloadEngineTests {
    @Test func downloadsSegmentsInParallelAndMatchesSource() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("movie.mp4", size: 3 * megabyte)
        let engine = fixture.makeEngine()
        let events = engine.events()
        let collector = Task {
            var states: [DownloadState] = []
            for await case .stateChanged(let snapshot) in events {
                states.append(snapshot.state)
                if case .completed = snapshot.state { break }
            }
            return states
        }

        try await engine.enqueue(fixture.request("movie.mp4"))
        let location = try await engine.waitForCompletion(of: "movie.mp4")

        #expect(location == fixture.downloadsDirectory.appendingPathComponent("movie.mp4"))
        #expect(fixture.contents("movie.mp4") == data)
        #expect(!FileManager.default.fileExists(atPath: location.appendingPathExtension("ferrydownload").path))
        #expect(try fixture.savedRecords().isEmpty)

        let log = fixture.server.log
        #expect(log.count == 12)
        #expect(log.allSatisfy { $0.headers["Cookie"] == "BDUSS=test" && $0.headers["User-Agent"] == "FerryTests" })
        #expect(log.allSatisfy { $0.headers["Accept-Encoding"] == "identity" })
        let ranges = log.compactMap(\.range).map { $0.first...$0.last! }.sorted { $0.lowerBound < $1.lowerBound }
        #expect(ranges.count == 12)
        #expect(ranges.first?.lowerBound == 0 && ranges.last?.upperBound == Int64(data.count - 1))
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound + 1 == $1.lowerBound })
        #expect(fixture.server.maxActive <= 4)
        #expect(fixture.source.resolveCount == 1)

        let states = await collector.value
        #expect(states.first == .queued)
        #expect(states.contains(.running))
        #expect(states.last == .completed(location))
    }

    @Test func probesSizeWhenUnknown() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte + 123)
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin", knownSize: false))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        #expect(await engine.snapshot(id: "a.bin")?.totalBytes == Int64(data.count))
        let log = fixture.server.log
        #expect(log.first?.headers["Range"] == "bytes=0-0")
        #expect(log.count == 1 + 5)
    }

    @Test func respectsConcurrencyLimits() async throws {
        let fixture = Fixture()
        let names = (0..<5).map { "file\($0).bin" }
        let files = names.map { fixture.addFile($0, size: megabyte) }
        fixture.server.setStall(after: 64 * kilobyte)
        let engine = fixture.makeEngine(.test(files: 2, connections: 3))

        for name in names {
            try await engine.enqueue(fixture.request(name))
        }
        try await waitUntil("6 active requests") { fixture.server.activeRequests == 6 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.server.maxActive == 6)
        #expect(fixture.server.maxActiveFiles == 2)
        #expect(await engine.snapshots().map(\.state) == [.running, .running, .queued, .queued, .queued])

        var configuration = DownloadConfiguration.test(files: 3, connections: 3)
        await engine.updateConfiguration(configuration)
        try await waitUntil("9 active requests") { fixture.server.activeRequests == 9 }
        #expect(await engine.snapshots().map(\.state) == [.running, .running, .running, .queued, .queued])

        configuration.maxConcurrentFiles = 2
        await engine.updateConfiguration(configuration)
        fixture.server.setStall(after: nil)
        for (name, data) in zip(names, files) {
            _ = try await engine.waitForCompletion(of: name)
            #expect(fixture.contents(name) == data)
        }
        #expect(fixture.server.maxActive == 9)
        #expect(fixture.server.maxActiveFiles == 3)
    }

    @Test func raisingConnectionsAppliesToRunningDownload() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 2 * megabyte)
        fixture.server.setStall(after: 64 * kilobyte)
        let engine = fixture.makeEngine(.test(connections: 1))

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("1 active request") { fixture.server.activeRequests == 1 }

        await engine.updateConfiguration(.test(connections: 3))
        // 放行第一个分片。它完成后，下载要领取更多分片，用满 3 个连接。
        fixture.server.setStallRule { $0.range?.first == 0 ? nil : 64 * kilobyte }
        try await waitUntil("3 active requests") { fixture.server.activeRequests == 3 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.server.maxActive == 3)

        fixture.server.setStall(after: nil)
        _ = try await engine.waitForCompletion(of: "a.bin")
        #expect(fixture.contents("a.bin") == data)
    }

    @Test func retriesTransientErrors() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte)
        fixture.server.setFaultRule { _, index in
            switch index {
            case 0: .disconnect(afterBytes: 100 * kilobyte)
            case 1: .status(500)
            case 2: .status(503)
            default: nil
            }
        }
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        let log = fixture.server.log
        let interrupted = try #require(log.first?.range?.first)
        #expect(log.contains { $0.range?.first == interrupted + Int64(100 * kilobyte) })
        #expect(fixture.source.resolveCount == 1)
    }

    @Test func refreshesExpiredLink() async throws {
        let fixture = Fixture(tokens: ["old", "new"])
        let data = fixture.addFile("a.bin", size: megabyte)
        fixture.server.expire(token: "old")
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        #expect(fixture.source.resolveCount == 2)
        let log = fixture.server.log
        #expect(log.count { $0.token == "new" } == 4)
        #expect(log.allSatisfy { $0.headers["Cookie"] == "BDUSS=test" })
    }

    @Test func throttledResponsesBackOffLonger() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 100 * kilobyte)
        fixture.server.setFaultRule { _, index in index == 0 ? .status(429) : nil }
        let engine = fixture.makeEngine(.test(throttleMultiplier: 100))

        let start = ContinuousClock.now
        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(ContinuousClock.now - start >= .milliseconds(100))
        #expect(fixture.contents("a.bin") == data)
        #expect(fixture.source.resolveCount == 1)
    }

    @Test func failsAfterRetryLimitAndResumesFromCheckpoint() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte)
        let failing = Atomic(true)
        fixture.server.setFaultRule { request, _ in
            guard failing.load(ordering: .relaxed), let first = request.range?.first else { return nil }
            return first % Int64(256 * kilobyte) == 0
                ? .disconnect(afterBytes: 100 * kilobyte)
                : .status(500, body: #"{"error_code":2,"error_msg":"busy"}"#)
        }
        let engine = fixture.makeEngine(.test(connections: 2, retries: 2))

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("failure") {
            if case .failed = await engine.snapshot(id: "a.bin")?.state { true } else { false }
        }

        let snapshot = try #require(await engine.snapshot(id: "a.bin"))
        guard case .failed(.httpStatus(500, let message)) = snapshot.state else {
            Issue.record("unexpected state \(snapshot.state)")
            return
        }
        #expect(message.contains("error_code"))
        let saved = try #require(try fixture.savedRecords().first)
        #expect(saved.receivedBytes == snapshot.receivedBytes)
        #expect(saved.receivedBytes >= Int64(100 * kilobyte))

        failing.store(false, ordering: .relaxed)
        fixture.server.clearLog()
        await engine.resume(id: "a.bin")
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        expectOnlyMissingBytesRequested(fixture.server.log, after: saved)
    }

    @Test func pauseAndResume() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 2 * megabyte)
        fixture.server.setStall(after: 128 * kilobyte)
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("4 × 128 KB received") {
            await engine.snapshot(id: "a.bin")?.receivedBytes == Int64(512 * kilobyte)
        }
        await engine.pause(id: "a.bin")

        #expect(await engine.snapshot(id: "a.bin")?.state == .paused)
        let saved = try #require(try fixture.savedRecords().first)
        #expect(saved.isPaused)
        #expect(saved.receivedBytes == Int64(512 * kilobyte))
        try await waitUntil("requests to stop") { fixture.server.activeRequests == 0 }

        fixture.server.setStall(after: nil)
        fixture.server.clearLog()
        await engine.resume(id: "a.bin")
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        expectOnlyMissingBytesRequested(fixture.server.log, after: saved)
    }

    @Test func restoreInNewEngineContinuesFromSavedProgress() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 2 * megabyte)
        let other = fixture.addFile("b.bin", size: 300 * kilobyte)
        fixture.server.setStall(after: 128 * kilobyte)
        let first = fixture.makeEngine(.test(files: 1))

        try await first.enqueue(fixture.request("a.bin"))
        try await first.enqueue(fixture.request("b.bin"))
        await first.pause(id: "b.bin")
        try await waitUntil("4 × 128 KB received") {
            await first.snapshot(id: "a.bin")?.receivedBytes == Int64(512 * kilobyte)
        }
        await first.shutdown()

        let saved = try #require(try fixture.savedRecords().first { $0.request.id == "a.bin" })
        #expect(saved.receivedBytes == Int64(512 * kilobyte))
        #expect(!saved.isPaused)

        fixture.server.setStall(after: nil)
        fixture.server.clearLog()
        let second = fixture.makeEngine(.test(files: 1))
        let restored = try await second.restore()

        #expect(restored.map(\.id) == ["a.bin", "b.bin"])
        #expect(restored.map(\.state) == [.queued, .paused])
        #expect(restored.first?.receivedBytes == Int64(512 * kilobyte))
        _ = try await second.waitForCompletion(of: "a.bin")
        #expect(fixture.contents("a.bin") == data)
        expectOnlyMissingBytesRequested(fixture.server.log, after: saved)

        await second.resume(id: "b.bin")
        _ = try await second.waitForCompletion(of: "b.bin")
        #expect(fixture.contents("b.bin") == other)
    }

    @Test func savesProgressPeriodicallyAndCancelRemovesFiles() async throws {
        let fixture = Fixture()
        fixture.addFile("a.bin", size: megabyte)
        fixture.server.setStall(after: 128 * kilobyte)
        let engine = fixture.makeEngine(.test(connections: 1))
        let events = engine.events()

        let request = fixture.request("a.bin")
        try await engine.enqueue(request)
        try await waitUntil("checkpoint with 128 KB") {
            try fixture.savedRecords().first?.receivedBytes == Int64(128 * kilobyte)
        }
        #expect(FileManager.default.fileExists(atPath: request.temporaryURL.path))

        await engine.cancel(id: "a.bin")

        #expect(await engine.snapshot(id: "a.bin") == nil)
        #expect(!FileManager.default.fileExists(atPath: request.temporaryURL.path))
        #expect(!FileManager.default.fileExists(atPath: request.destination.path))
        #expect(try fixture.savedRecords().isEmpty)
        for await event in events {
            if event == .removed(id: "a.bin") { break }
        }
    }

    @Test func doesNotOverwriteExistingFiles() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 300 * kilobyte)
        let existing = Data("old".utf8)
        try FileManager.default.createDirectory(at: fixture.downloadsDirectory, withIntermediateDirectories: true)
        try existing.write(to: fixture.downloadsDirectory.appendingPathComponent("a.bin"))
        try existing.write(to: fixture.downloadsDirectory.appendingPathComponent("a (1).bin"))
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        let location = try await engine.waitForCompletion(of: "a.bin")

        #expect(location.lastPathComponent == "a (2).bin")
        #expect(fixture.contents("a (2).bin") == data)
        #expect(fixture.contents("a.bin") == existing)
        #expect(fixture.contents("a (1).bin") == existing)
    }

    @Test(arguments: [true, false])
    func fallsBackToSingleConnectionWithoutRangeSupport(knownSize: Bool) async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte)
        fixture.server.setSupportsRanges(false)
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin", knownSize: knownSize))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        let log = fixture.server.log
        #expect(log.last?.headers["Range"] == nil)
        #expect(log.count { $0.headers["Range"] == nil } == 1)
        if !knownSize {
            #expect(log.count == 2)
        }
    }

    @Test func rejectsMalformedResponses() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte)
        fixture.server.setFaultRule { _, index in
            switch index {
            case 0: .wrongContentRange
            case 1: .shortBody
            case 2: .okWithBody("<html>error</html>")
            default: nil
            }
        }
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        #expect(fixture.server.log.allSatisfy { $0.range != nil })
    }

    @Test func reportsServerErrorMessage() async throws {
        let fixture = Fixture(tokens: ["old"])
        fixture.addFile("a.bin", size: 100 * kilobyte)
        fixture.server.expire(token: "old")
        let engine = fixture.makeEngine(.test(retries: 1))

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("failure") {
            if case .failed = await engine.snapshot(id: "a.bin")?.state { true } else { false }
        }

        let state = await engine.snapshot(id: "a.bin")?.state
        #expect(state == .failed(.httpStatus(403, message: #"{"error_code":31326,"error_msg":"link expired"}"#)))
        #expect(fixture.source.resolveCount == 2)
    }

    @Test func emptyFileCompletesWithoutRequests() async throws {
        let fixture = Fixture()
        fixture.addFile("empty.txt", size: 0)
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("empty.txt"))
        _ = try await engine.waitForCompletion(of: "empty.txt")

        #expect(fixture.contents("empty.txt") == Data())
        #expect(fixture.server.log.isEmpty)
        #expect(fixture.source.resolveCount == 0)
    }

    @Test func redirectKeepsRequestHeaders() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 100 * kilobyte)
        let cdnHost = "cdn-\(fixture.server.host)"
        fixture.server.addAlias(cdnHost)
        fixture.server.setFaultRule { _, index in
            index == 0 ? .redirect(to: URL(string: "https://\(cdnHost)/a.bin")!) : nil
        }
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        let redirected = try #require(fixture.server.log.last)
        #expect(redirected.url.host() == cdnHost)
        #expect(redirected.headers["Cookie"] == "BDUSS=test")
        #expect(redirected.headers["Range"] == "bytes=0-\(data.count - 1)")
    }
}

/// 续传后的请求只覆盖保存时还缺的字节，每个字节只请求一次。
private func expectOnlyMissingBytesRequested(
    _ log: [LoggedRequest],
    after saved: DownloadRecord,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let received = (saved.segments ?? []).map { $0.start..<$0.offset }
    var requested: Int64 = 0
    for request in log {
        guard let range = request.range, let last = range.last else {
            Issue.record("request without a bounded range", sourceLocation: sourceLocation)
            continue
        }
        requested += last - range.first + 1
        let bytes = range.first..<(last + 1)
        #expect(!received.contains { $0.overlaps(bytes) }, sourceLocation: sourceLocation)
    }
    #expect(requested == saved.totalBytes! - saved.receivedBytes, sourceLocation: sourceLocation)
}
