import Foundation
import os
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

        let request = fixture.request("movie.mp4")
        try await engine.enqueue(request)
        let location = try await engine.waitForCompletion(of: "movie.mp4")

        #expect(location == fixture.downloadsDirectory.appendingPathComponent("movie.mp4"))
        #expect(fixture.contents("movie.mp4") == data)
        #expect(!FileManager.default.fileExists(atPath: request.temporaryURL.path))
        #expect(try fixture.savedRecords().map(\.completedURL) == [location])

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

    @Test(arguments: [
        URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
        .serverCertificateHasUnknownRoot, .clientCertificateRejected, .secureConnectionFailed,
        .cannotConnectToHost, .cannotFindHost,
    ])
    func connectionErrorRefreshesLink(_ code: URLError.Code) async throws {
        let fixture = Fixture(tokens: ["old", "new"])
        let data = fixture.addFile("a.bin", size: 100 * kilobyte)
        fixture.server.setFaultRule { request, _ in request.token == "old" ? .fail(code) : nil }
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        #expect(fixture.source.resolveCount == 2)
        #expect(fixture.server.log.map(\.token) == ["old", "new"])
    }

    @Test func connectionLossKeepsLink() async throws {
        let fixture = Fixture(tokens: ["old", "new"])
        let data = fixture.addFile("a.bin", size: 100 * kilobyte)
        fixture.server.setFaultRule { _, index in index == 0 ? .fail(.networkConnectionLost) : nil }
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        #expect(fixture.source.resolveCount == 1)
        #expect(fixture.server.log.map(\.token) == ["old", "old"])
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
        let failing = OSAllocatedUnfairLock(initialState: true)
        fixture.server.setFaultRule { request, _ in
            guard failing.withLock({ $0 }), let first = request.range?.first else { return nil }
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

        failing.withLock { $0 = false }
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

    @Test func replacingSessionContinuesFromCheckpointOnNewSession() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 2 * megabyte)
        // 旧会话的请求停在 128 KB。新会话的请求先停在开头，取得换会话时保存的进度后再放行。
        let released = OSAllocatedUnfairLock(initialState: false)
        fixture.server.setStallRule { request in
            guard request.headers["X-Session"] == "new" else { return 128 * kilobyte }
            return released.withLock { $0 } ? nil : 0
        }
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

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("4 × 128 KB received") {
            await engine.snapshot(id: "a.bin")?.receivedBytes == Int64(512 * kilobyte)
        }
        let oldRequests = fixture.server.log.count
        await engine.replaceSession(configuration: StubProtocol.makeConfiguration(name: "new"))

        #expect(await engine.snapshot(id: "a.bin")?.state == .running)
        let saved = try #require(try fixture.savedRecords().first)
        #expect(saved.receivedBytes == Int64(512 * kilobyte))
        released.withLock { $0 = true }
        let location = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        let log = fixture.server.log
        #expect(log.prefix(oldRequests).allSatisfy { $0.headers["X-Session"] == nil })
        let newRequests = Array(log.dropFirst(oldRequests))
        #expect(!newRequests.isEmpty)
        #expect(newRequests.allSatisfy { $0.headers["X-Session"] == "new" })
        expectOnlyMissingBytesRequested(newRequests, after: saved)

        let states = await collector.value
        #expect(states.first == .queued)
        #expect(states.dropFirst().dropLast().allSatisfy { $0 == .running })
        #expect(states.last == .completed(location))
    }

    @Test func replacingSessionAfterShutdownStartsNothing() async throws {
        let fixture = Fixture()
        fixture.addFile("a.bin", size: megabyte)
        fixture.server.setStall(after: 128 * kilobyte)
        let engine = fixture.makeEngine(.test(connections: 1))

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("1 active request") { fixture.server.activeRequests == 1 }
        await engine.shutdown()
        fixture.server.clearLog()
        await engine.replaceSession(configuration: StubProtocol.makeConfiguration(name: "new"))

        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.snapshot(id: "a.bin")?.state == .queued)
        #expect(fixture.server.log.isEmpty)
    }

    @Test func shutdownDuringSessionReplacementStartsNothing() async throws {
        let fixture = Fixture()
        fixture.addFile("a.bin", size: megabyte)
        fixture.addFile("b.bin", size: megabyte)
        let source = GatedSource(fixture.source, gating: ["a.bin", "b.bin"])
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source, configuration: .test(), session: fixture.session)

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("a.bin to wait for its link") { source.hasEntered("a.bin") }
        let replaced = Task { await engine.replaceSession(configuration: StubProtocol.makeConfiguration(name: "new")) }
        try await waitUntil("replaceSession to cancel a.bin") { source.wasCancelled("a.bin") }
        // b.bin 在新会话上开始。它被取消，说明 shutdown 已经开始。
        try await engine.enqueue(fixture.request("b.bin"))
        try await waitUntil("b.bin to wait for its link") { source.hasEntered("b.bin") }
        let shutDown = Task { await engine.shutdown() }
        try await waitUntil("shutdown to cancel b.bin") { source.wasCancelled("b.bin") }
        source.open()
        await replaced.value
        await shutDown.value

        #expect(await engine.snapshot(id: "a.bin")?.state == .queued)
        #expect(await engine.snapshot(id: "b.bin")?.state == .queued)
        #expect(fixture.server.log.isEmpty)
        #expect(try fixture.savedRecords().allSatisfy { !$0.isPaused })
    }

    @Test func pauseDuringSessionReplacementStaysPaused() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: megabyte)
        let source = GatedSource(fixture.source, gating: ["a.bin"])
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source, configuration: .test(), session: fixture.session)

        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("a.bin to wait for its link") { source.hasEntered("a.bin") }
        let replaced = Task { await engine.replaceSession(configuration: StubProtocol.makeConfiguration(name: "new")) }
        try await waitUntil("replaceSession to cancel a.bin") { source.wasCancelled("a.bin") }
        let paused = Task { await engine.pause(id: "a.bin") }
        try await waitUntil("a.bin to be paused") { await engine.snapshot(id: "a.bin")?.state == .paused }
        source.open()
        await replaced.value
        await paused.value

        #expect(await engine.snapshot(id: "a.bin")?.state == .paused)
        let saved = try #require(try fixture.savedRecords().first)
        #expect(saved.isPaused)
        #expect(fixture.server.log.isEmpty)

        await engine.resume(id: "a.bin")
        _ = try await engine.waitForCompletion(of: "a.bin")
        #expect(fixture.contents("a.bin") == data)
        #expect(fixture.server.log.allSatisfy { $0.headers["X-Session"] == "new" })
    }

    @Test func cancelDuringSessionReplacementEndsBeforeReplacementReturns() async throws {
        let fixture = Fixture()
        fixture.addFile("a.bin", size: megabyte)
        let data = fixture.addFile("b.bin", size: megabyte)
        fixture.server.setStallRule { $0.headers["X-Session"] == nil ? 128 * kilobyte : nil }
        let source = GatedSource(fixture.source, gating: ["a.bin"])
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source, configuration: .test(), session: fixture.session)

        try await engine.enqueue(fixture.request("a.bin"))
        try await engine.enqueue(fixture.request("b.bin"))
        try await waitUntil("a.bin to wait for its link and b.bin to stall") {
            source.hasEntered("a.bin") && fixture.server.activeRequests == 4
        }
        // cancel(id:) 已经把 a.bin 移出队列，还在等它的传输任务结束。
        let cancelled = Task { await engine.cancel(id: "a.bin") }
        try await waitUntil("a.bin to be removed") { await engine.snapshot(id: "a.bin") == nil }
        let replaced = Task {
            await engine.replaceSession(configuration: StubProtocol.makeConfiguration(name: "new"))
            return source.isOpen
        }
        // b.bin 已经在新会话上重新开始，换会话只剩 a.bin 的传输任务要等。
        try await waitUntil("b.bin to restart on the new session") {
            fixture.server.log.contains { $0.headers["X-Session"] == "new" }
        }
        source.open()

        #expect(await replaced.value, "replaceSession returned before the transfer of a.bin ended")
        await cancelled.value
        _ = try await engine.waitForCompletion(of: "b.bin")
        #expect(fixture.contents("b.bin") == data)
        #expect(!fixture.server.log.contains { $0.url.path == "/a.bin" })
        #expect(try fixture.savedRecords().map(\.request.id) == ["b.bin"])
        #expect(!FileManager.default.fileExists(atPath: fixture.request("a.bin").temporaryURL.path))
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

    @Test func completedRecordIsKeptUntilCancel() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 300 * kilobyte)
        let first = fixture.makeEngine()
        try await first.enqueue(fixture.request("a.bin"))
        let location = try await first.waitForCompletion(of: "a.bin")
        await first.shutdown()
        #expect(try fixture.savedRecords().map(\.completedURL) == [location])

        // 应用在保存最终路径前退出：新的引擎把它恢复为 completed，不再下载。
        fixture.server.clearLog()
        let second = fixture.makeEngine()
        let restored = try await second.restore()
        #expect(restored.map(\.state) == [.completed(location)])
        try await Task.sleep(for: .milliseconds(50))
        #expect(await second.snapshot(id: "a.bin")?.state == .completed(location))
        #expect(fixture.server.log.isEmpty)
        #expect(fixture.source.resolveCount == 1)

        await second.cancel(id: "a.bin")
        #expect(await second.snapshot(id: "a.bin") == nil)
        #expect(try fixture.savedRecords().isEmpty)
        #expect(fixture.contents("a.bin") == data)
        #expect(try await fixture.makeEngine().restore().isEmpty)
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

    @Test func sameDestinationUsesSeparateTemporaryFiles() async throws {
        let fixture = Fixture()
        let first = fixture.addFile("one.bin", size: megabyte)
        let second = fixture.addFile("two.bin", size: megabyte)
        fixture.server.setStall(after: 64 * kilobyte)
        let engine = fixture.makeEngine(.test(files: 2, connections: 2))
        let destination = fixture.downloadsDirectory.appendingPathComponent("same.bin")
        var one = fixture.request("one.bin")
        one.destination = destination
        var two = fixture.request("two.bin")
        two.destination = destination
        #expect(one.temporaryURL != two.temporaryURL)
        #expect(one.temporaryURL.deletingLastPathComponent().path == fixture.downloadsDirectory.path)

        try await engine.enqueue(one)
        try await engine.enqueue(two)
        try await waitUntil("both files downloading") { fixture.server.activeRequests == 4 }
        fixture.server.setStall(after: nil)
        let locations = [
            try await engine.waitForCompletion(of: "one.bin"),
            try await engine.waitForCompletion(of: "two.bin"),
        ]

        #expect(Set(locations.map(\.lastPathComponent)) == ["same.bin", "same (1).bin"])
        #expect(try Data(contentsOf: locations[0]) == first)
        #expect(try Data(contentsOf: locations[1]) == second)
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

    @Test func permanentResolveErrorFailsWithoutRetry() async throws {
        let (state, resolveCount) = try await resolveFailure(PermanentError(), retries: 3)
        #expect(state == .failed(.resolveFailed("登录已失效。")))
        #expect(resolveCount == 1)
    }

    @Test func resolveErrorsAreRetriedAndReportTheirDescription() async throws {
        let (state, resolveCount) = try await resolveFailure(TransientError(), retries: 2)
        #expect(state == .failed(.resolveFailed("暂时取不到链接。")))
        #expect(resolveCount == 3)

        let plain = PlainError()
        let (plainState, _) = try await resolveFailure(plain, retries: 0)
        #expect(plainState == .failed(.resolveFailed(plain.localizedDescription)))
    }

    /// 用总是失败的下载源下载一个文件，返回最终状态和调用下载源的次数。
    private func resolveFailure(_ error: any Error & Sendable, retries: Int) async throws -> (DownloadState?, Int) {
        let fixture = Fixture()
        fixture.addFile("a.bin", size: 100 * kilobyte)
        let source = ThrowingSource(error)
        let engine = DownloadEngine(stateDirectory: fixture.stateDirectory, source: source,
                                    configuration: .test(retries: retries), session: fixture.session)
        try await engine.enqueue(fixture.request("a.bin"))
        try await waitUntil("failure") {
            if case .failed = await engine.snapshot(id: "a.bin")?.state { true } else { false }
        }
        #expect(fixture.server.log.isEmpty)
        return (await engine.snapshot(id: "a.bin")?.state, source.resolveCount)
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

    @Test func crossHostRedirectKeepsHeadersExceptCookie() async throws {
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
        #expect(redirected.headers["Cookie"] == nil)
        #expect(redirected.headers["User-Agent"] == "FerryTests")
        #expect(redirected.headers["Range"] == "bytes=0-\(data.count - 1)")
    }

    @Test func sameHostRedirectKeepsCookie() async throws {
        let fixture = Fixture()
        let data = fixture.addFile("a.bin", size: 100 * kilobyte)
        fixture.server.setFaultRule { _, index in
            index == 0 ? .redirect(to: fixture.server.url("/a.bin?moved=1")) : nil
        }
        let engine = fixture.makeEngine()

        try await engine.enqueue(fixture.request("a.bin"))
        _ = try await engine.waitForCompletion(of: "a.bin")

        #expect(fixture.contents("a.bin") == data)
        let redirected = try #require(fixture.server.log.last)
        #expect(redirected.url.query() == "moved=1")
        #expect(redirected.headers["Cookie"] == "BDUSS=test")
        #expect(redirected.headers["Range"] == "bytes=0-\(data.count - 1)")
    }
}

private struct PermanentError: PermanentDownloadSourceError, LocalizedError {
    var errorDescription: String? { "登录已失效。" }
}

private struct TransientError: LocalizedError {
    var errorDescription: String? { "暂时取不到链接。" }
}

private struct PlainError: Error {}

/// 每次都抛出同一个错误的下载源。
private final class ThrowingSource: DownloadSource {
    private let error: any Error & Sendable
    private let count = OSAllocatedUnfairLock(initialState: 0)

    init(_ error: any Error & Sendable) {
        self.error = error
    }

    var resolveCount: Int { count.withLock { $0 } }

    func resolve(_ request: DownloadRequest) async throws -> ResolvedURL {
        count.withLock { $0 += 1 }
        throw error
    }
}

/// 指定的文件下载取链接时停住，直到 `open()`。停住时不响应取消，所以传输任务被取消后要等 `open()` 才结束。
private final class GatedSource: DownloadSource {
    private struct State {
        var isOpen = false
        var entered: Set<String> = []
        var cancelled: Set<String> = []
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let base: StubSource
    private let gated: Set<String>
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ base: StubSource, gating gated: Set<String>) {
        self.base = base
        self.gated = gated
    }

    var isOpen: Bool { state.withLock { $0.isOpen } }
    func hasEntered(_ id: String) -> Bool { state.withLock { $0.entered.contains(id) } }
    func wasCancelled(_ id: String) -> Bool { state.withLock { $0.cancelled.contains(id) } }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func resolve(_ request: DownloadRequest) async throws -> ResolvedURL {
        let id = request.id
        if gated.contains(id) {
            state.withLock { _ = $0.entered.insert(id) }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let isOpen = state.withLock { state in
                        if !state.isOpen { state.waiters.append(continuation) }
                        return state.isOpen
                    }
                    if isOpen { continuation.resume() }
                }
            } onCancel: {
                state.withLock { _ = $0.cancelled.insert(id) }
            }
        }
        return try await base.resolve(request)
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
