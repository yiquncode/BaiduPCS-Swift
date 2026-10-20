import Foundation
import Testing
@testable import BaiduKit

/// 模拟的分享：每个文件算 1 个，目录算它全部子文件的数量。
private actor FakeShare {
    let limit: Int
    let children: [Int64: [ShareEntry]]
    private(set) var log: [String] = []

    init(limit: Int, children: [Int64: [ShareEntry]] = [:]) {
        self.limit = limit
        self.children = children
    }

    func fileCount(_ entry: ShareEntry) -> Int {
        guard entry.isDirectory else { return 1 }
        return (children[entry.fsID] ?? []).reduce(0) { $0 + fileCount($1) }
    }

    func makeDirectory(_ path: String) { log.append("mkdir \(path)") }

    func list(_ entry: ShareEntry) -> [ShareEntry] {
        log.append("list \(entry.name)")
        return children[entry.fsID] ?? []
    }

    func transfer(_ entries: [ShareEntry], to path: String) throws {
        let count = entries.reduce(0) { $0 + fileCount($1) }
        guard count <= limit else { throw BaiduError.transferLimitExceeded(count: count, limit: limit) }
        log.append("transfer \(path) \(entries.map(\.name).joined(separator: ","))")
    }

    nonisolated var planner: TransferPlanner {
        TransferPlanner(
            makeDirectory: { await self.makeDirectory($0) },
            listChildren: { await self.list($0) },
            transferBatch: { try await self.transfer($0, to: $1) }
        )
    }
}

private func file(_ id: Int64, _ name: String, in directory: String = "") -> ShareEntry {
    ShareEntry(fsID: id, name: name, path: "/s/\(directory)/\(name)", isDirectory: false, size: 1, relativeDirectory: directory)
}

private func folder(_ id: Int64, _ name: String, in directory: String = "") -> ShareEntry {
    ShareEntry(fsID: id, name: name, path: "/s/\(directory)/\(name)", isDirectory: true, size: 0, relativeDirectory: directory)
}

struct TransferPlannerTests {
    @Test func transfersEachRelativeDirectoryInOneBatch() async throws {
        let share = FakeShare(limit: 100)
        try await share.planner.transfer([
            file(1, "a"), file(2, "b", in: "x/y"), file(3, "c"), file(4, "d", in: "x/y"), file(5, "e", in: "x"),
        ], to: "/Ferry/job")
        #expect(await share.log == [
            "mkdir /Ferry/job",
            "transfer /Ferry/job a,c",
            "mkdir /Ferry/job/x",
            "mkdir /Ferry/job/x/y",
            "transfer /Ferry/job/x/y b,d",
            "transfer /Ferry/job/x e",
        ])
    }

    @Test func splitsBatchByLimitThenInHalves() async throws {
        let share = FakeShare(limit: 2)
        try await share.planner.transfer((1...5).map { file($0, "f\($0)") }, to: "/T")
        #expect(await share.log == [
            "mkdir /T",
            "transfer /T f1,f2",
            "transfer /T f3,f4",
            "transfer /T f5",
        ])
    }

    @Test func recursesIntoDirectoryOverLimit() async throws {
        // big 含 3 个文件和一个含 2 个文件的子目录，共 5 个，超过上限 3。
        let big = folder(10, "big")
        let sub = folder(20, "sub", in: "big")
        let share = FakeShare(limit: 3, children: [
            10: [file(11, "a", in: "big"), file(12, "b", in: "big"), file(13, "c", in: "big"), sub],
            20: [file(21, "d", in: "big/sub"), file(22, "e", in: "big/sub")],
        ])
        try await share.planner.transfer([big, file(1, "small")], to: "/T")
        #expect(await share.log == [
            "mkdir /T",
            "mkdir /T/big",
            "list big",
            "transfer /T/big a,b,c",
            "transfer /T/big sub",
            "transfer /T small",
        ])
    }

    @Test func singleFileOverLimitFails() async {
        let share = FakeShare(limit: 0)
        await #expect(throws: BaiduError.transferLimitExceeded(count: 1, limit: 0)) {
            try await share.planner.transfer([file(1, "a")], to: "/T")
        }
    }

    @Test func dropsEntriesInsideSelectedDirectories() {
        let entries = [folder(1, "x"), file(2, "a", in: "x"), file(3, "b", in: "x/y"), file(4, "c", in: "xy"), file(5, "d")]
        #expect(TransferPlanner.removingNested(entries).map(\.fsID) == [1, 4, 5])
    }
}

extension StubbedNetworkTests {
    @Suite struct TransferTests {
        static let entries = [
            ShareEntry(fsID: 1, name: "a.zip", path: "/sharer/a.zip", isDirectory: false, size: 1),
            ShareEntry(fsID: 2, name: "b.zip", path: "/sharer/b.zip", isDirectory: false, size: 1),
            ShareEntry(fsID: 3, name: "c.zip", path: "/sharer/c.zip", isDirectory: false, size: 1),
            ShareEntry(fsID: 4, name: "d.zip", path: "/sharer/dir/sub/d.zip", isDirectory: false, size: 1, relativeDirectory: "dir/sub"),
        ]

        @Test func transferCreatesDirectoriesAndSplitsOverLimit() async throws {
            let client = Fixture.client { request in
                switch request.path {
                case "/rest/2.0/pcs/file":
                    return .json(#"{"fs_id":1,"path":"x"}"#)
                case "/share/transfer":
                    let ids = request.form["fsidlist"] ?? ""
                    if ids.split(separator: ",").count > 2 {
                        return .json(#"{"errno":12,"target_file_nums":3,"target_file_nums_limit":2,"info":[{"errno":0,"path":"/x"}]}"#)
                    }
                    return .json(#"{"errno":0,"info":[{"errno":0,"path":"/Ferry/job/a.zip","fsid":99}]}"#)
                default:
                    return .notFound
                }
            }
            try await client.transfer(Fixture.session(), entries: Self.entries, to: "/Ferry/job")

            let mkdirs = Stub.shared.requests(path: "/rest/2.0/pcs/file").map { $0.query["path"] }
            #expect(mkdirs == ["/Ferry/job", "/Ferry/job/dir", "/Ferry/job/dir/sub"])

            let transfers = Stub.shared.requests(path: "/share/transfer")
            #expect(transfers.map { $0.form["fsidlist"] } == ["[1,2,3]", "[1,2]", "[3]", "[4]"])
            #expect(transfers.map { $0.form["path"] } == ["/Ferry/job", "/Ferry/job", "/Ferry/job", "/Ferry/job/dir/sub"])

            let first = try #require(transfers.first)
            #expect(first.method == "POST")
            #expect(first.header("User-Agent") == UserAgent.chromeWin76)
            #expect(first.header("Referer") == "https://pan.baidu.com/s/1qYZEsSc")
            #expect(first.query["shareid"] == "3003")
            #expect(first.query["from"] == "2002")
            #expect(first.query["bdstoken"] == "bbbb2222")
            #expect(first.cookies["BDCLND"] == "clnd")
            #expect(first.cookies["STOKEN"] == "test_stoken")
        }

        @Test func transferReportsConflict() async {
            let client = Fixture.client { request in
                request.path == "/share/transfer"
                    ? .json(#"{"errno":12,"info":[{"errno":-30,"path":"/Ferry/job/a.zip"}],"target_file_nums":1,"target_file_nums_limit":500}"#)
                    : .json("{}")
            }
            await #expect(throws: BaiduError.transferConflict(name: "a.zip")) {
                try await client.transfer(Fixture.session(), entries: [Self.entries[0]], to: "/Ferry/job")
            }
        }

        @Test func transferReportsDuplicateAndUnknownErrors() throws {
            #expect(throws: BaiduError.transferDuplicate) { try BaiduClient.checkTransfer(JSON(["errno": 4])) }
            #expect(throws: BaiduError.transferFailed(code: -32)) {
                try BaiduClient.checkTransfer(JSON(["errno": 12, "info": [["errno": -32]]]))
            }
            #expect(throws: BaiduError.loginExpired) { try BaiduClient.checkTransfer(JSON(["errno": -6])) }
            try BaiduClient.checkTransfer(JSON(["errno": 0]))
        }
    }
}
