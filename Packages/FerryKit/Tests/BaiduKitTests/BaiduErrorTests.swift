import Testing
@testable import BaiduKit

struct BaiduErrorTests {
    @Test func minus7MeansExpiredShareOnlyInShareEndpoints() {
        for endpoint in [Endpoint.sharePage, .shareVerify, .shareList, .shareWXList] {
            #expect(BaiduError(code: -7, endpoint: endpoint) == .shareExpired)
        }
        for endpoint in [Endpoint.shareTransfer, .fileList, .pcsFile, .locateDownload] {
            #expect(BaiduError(code: -7, endpoint: endpoint) == .invalidNameOrAccessDenied)
        }
    }

    @Test func minus9DependsOnEndpoint() {
        #expect(BaiduError(code: -9, endpoint: .shareVerify) == .wrongPassword)
        #expect(BaiduError(code: -9, endpoint: .shareList) == .wrongOrExpiredPassword)
        #expect(BaiduError(code: -9, endpoint: .shareWXList) == .wrongOrExpiredPassword)
        #expect(BaiduError(code: -9, endpoint: .fileList) == .fileNotFound)
    }

    @Test func verificationCodes() {
        #expect(BaiduError(code: 9019, endpoint: .shareList) == .verificationTriggered)
        #expect(BaiduError(code: 8001, endpoint: .shareList) == .verificationTriggered)
    }
}
