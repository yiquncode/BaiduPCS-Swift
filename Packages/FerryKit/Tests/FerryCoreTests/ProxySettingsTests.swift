import Foundation
import Network
import Testing
@testable import FerryCore

@Suite struct ProxySettingsTests {
    private let complete = ProxySettings(mode: .socks5, host: " 127.0.0.1 ", port: 1080)

    @Test func readsSettingsWithoutProxy() throws {
        let bookmark = Data([1, 2, 3])
        let json = """
        {"downloadDirectoryBookmark": "\(bookmark.base64EncodedString())", "transferFolder": "/Downloads",
         "cleanupAfterDownload": true, "maxConcurrentFiles": 2, "connectionsPerFile": 8}
        """
        let settings = try JSONDecoder().decode(FerrySettings.self, from: Data(json.utf8))
        #expect(settings.proxy == ProxySettings())
        #expect(settings.proxy.mode == .system)
        #expect(settings == FerrySettings(downloadDirectoryBookmark: bookmark, transferFolder: "/Downloads", cleanupAfterDownload: true,
                                          maxConcurrentFiles: 2, connectionsPerFile: 8))
    }

    @Test func invalidProxyKeepsOtherSettings() throws {
        let json = """
        {"transferFolder": "/Downloads", "maxConcurrentFiles": 3, "proxy": "socks5://127.0.0.1"}
        """
        let settings = try JSONDecoder().decode(FerrySettings.self, from: Data(json.utf8))
        #expect(settings.proxy == ProxySettings())
        #expect(settings.transferFolder == "/Downloads")
        #expect(settings.maxConcurrentFiles == 3)

        let partial = """
        {"maxConcurrentFiles": 3, "proxy": {"mode": "http", "host": "proxy.local", "port": "1080", "username": 7}}
        """
        let decoded = try JSONDecoder().decode(FerrySettings.self, from: Data(partial.utf8))
        #expect(decoded.proxy == ProxySettings(host: "proxy.local"))
        #expect(decoded.maxConcurrentFiles == 3)
    }

    @Test func roundTripsProxy() throws {
        let settings = FerrySettings(proxy: ProxySettings(mode: .socks5, host: "proxy.local", port: 1080, username: "ferry"))
        #expect(try JSONDecoder().decode(FerrySettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func reportsIncompleteSocks5() {
        #expect(ProxySettings().problem(password: "") == nil)
        #expect(ProxySettings(host: "", port: nil).problem(password: "secret") == nil)

        #expect(complete.problem(password: "") == nil)
        #expect(ProxySettings(mode: .socks5, host: "proxy.local", port: 1, username: "ferry").problem(password: "secret") == nil)
        #expect(ProxySettings(mode: .socks5, host: "proxy.local", port: 65535).problem(password: "") == nil)

        #expect(ProxySettings(mode: .socks5).problem(password: "") == "请填写代理服务器。")
        #expect(ProxySettings(mode: .socks5, host: "  \n", port: 1080).problem(password: "") == "请填写代理服务器。")
        #expect(ProxySettings(mode: .socks5, host: "proxy.local").problem(password: "") == "请填写代理端口。")
        for port in [0, -1, 65536] {
            #expect(ProxySettings(mode: .socks5, host: "proxy.local", port: port).problem(password: "") == "端口需要在 1–65535 之间。")
        }
        let credentialProblem = "用户名和密码需要同时填写。"
        #expect(ProxySettings(mode: .socks5, host: "proxy.local", port: 1080, username: "ferry").problem(password: "") == credentialProblem)
        #expect(complete.problem(password: "secret") == credentialProblem)
        // 先报告服务器，再报告端口和凭据。
        #expect(ProxySettings(mode: .socks5, port: 0, username: "ferry").problem(password: "") == "请填写代理服务器。")
    }

    @Test func buildsConfigurationOnlyForCompleteSocks5() {
        #expect(ProxySettings().proxyConfigurations(password: "").isEmpty)
        #expect(ProxySettings(host: "proxy.local", port: 1080).proxyConfigurations(password: "").isEmpty)
        #expect(ProxySettings(mode: .socks5, host: "proxy.local").proxyConfigurations(password: "").isEmpty)
        #expect(ProxySettings(mode: .socks5, host: "proxy.local", port: 70000).proxyConfigurations(password: "").isEmpty)
        #expect(complete.proxyConfigurations(password: "secret").isEmpty)

        let configurations = complete.proxyConfigurations(password: "")
        #expect(configurations.count == 1)
        // ProxyConfiguration 只公开 debugDescription。只检查其中有去掉空白的服务器和端口。
        let description = configurations.first?.debugDescription ?? ""
        #expect(description.contains("127.0.0.1"))
        #expect(description.contains("1080"))
        #expect(!description.contains(" 127.0.0.1 "))
        let withCredential = ProxySettings(mode: .socks5, host: "proxy.local", port: 1080, username: "ferry")
        #expect(withCredential.proxyConfigurations(password: "secret").count == 1)
    }
}
