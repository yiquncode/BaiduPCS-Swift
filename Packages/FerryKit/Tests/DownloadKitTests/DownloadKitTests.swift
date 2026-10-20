import Testing
@testable import DownloadKit

@Test func moduleLoads() {
    #expect(String(describing: DownloadKit.self) == "DownloadKit")
}
