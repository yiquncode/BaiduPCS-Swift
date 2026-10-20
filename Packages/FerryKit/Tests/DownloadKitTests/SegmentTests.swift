import Foundation
import Testing
@testable import DownloadKit

@Suite struct SegmentTests {
    @Test func automaticSegmentSize() {
        let kilobyte: Int64 = 1 << 10
        let megabyte: Int64 = 1 << 20
        let cases: [(fileSize: Int64, expected: Int64)] = [
            (1, 256 * kilobyte),
            (5 * megabyte - 1, 256 * kilobyte),
            (5 * megabyte, 512 * kilobyte),
            (10 * megabyte, megabyte),
            (15 * megabyte, 4 * megabyte),
            (1 << 40, 4 * megabyte),
        ]
        for (fileSize, expected) in cases {
            #expect(SegmentSize.automatic.bytes(forFileSize: fileSize) == expected)
        }
    }

    @Test func planCoversFileWithoutGaps() {
        let segments = Segment.plan(totalBytes: 1000, acceptsRanges: nil, size: .fixed(300))
        #expect(segments.map(\.start) == [0, 300, 600, 900])
        #expect(segments.map(\.end) == [300, 600, 900, 1000])
    }

    @Test func planUsesOneOpenSegmentWithoutRanges() {
        #expect(Segment.plan(totalBytes: 1000, acceptsRanges: false, size: .fixed(300)) == [Segment(start: 0, end: 1000)])
        #expect(Segment.plan(totalBytes: nil, acceptsRanges: nil, size: .automatic) == [Segment(start: 0, end: nil)])
        #expect(Segment.plan(totalBytes: 0, acceptsRanges: nil, size: .automatic).isEmpty)
    }

    @Test func parsesContentRange() {
        let range = ContentRange("bytes 0-99/1000")
        #expect(range?.first == 0 && range?.last == 99 && range?.total == 1000)
        #expect(ContentRange("bytes 100-199/*")?.total == nil)
        #expect(ContentRange("bytes 100-99/1000") == nil)
        #expect(ContentRange("bytes 0-99/50") == nil)
        #expect(ContentRange("items 0-99/1000") == nil)
        #expect(ContentRange("bytes */1000") == nil)
    }

    @Test func stateFileNamesAreDistinctOnCaseInsensitiveVolumes() {
        let store = StateStore(directory: URL(filePath: "/tmp"))
        #expect(store.fileURL(for: "a").lastPathComponent.lowercased() != store.fileURL(for: "A").lastPathComponent.lowercased())
    }
}
