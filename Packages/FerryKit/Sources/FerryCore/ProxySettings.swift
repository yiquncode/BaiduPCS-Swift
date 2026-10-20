import Foundation
import Network

/// 代理设置。密码存在应用的 Keychain 中，由调用方传入。
public struct ProxySettings: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable {
        /// 使用系统设置。
        case system
        case socks5
    }

    public var mode: Mode
    public var host: String
    /// nil 表示没有填写。
    public var port: Int?
    public var username: String

    public init(mode: Mode = .system, host: String = "", port: Int? = nil, username: String = "") {
        self.mode = mode
        self.host = host
        self.port = port
        self.username = username
    }

    /// 缺少或无法解码的字段用默认值。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        let defaults = ProxySettings()
        mode = value(.mode) ?? defaults.mode
        host = value(.host) ?? defaults.host
        port = value(.port)
        username = value(.username) ?? defaults.username
    }

    public static let portRange = 1...65535

    /// SOCKS5 设置不完整的原因，给设置页显示。使用系统设置或设置完整时返回 nil。
    public func problem(password: String) -> String? {
        guard mode == .socks5 else { return nil }
        if trimmedHost.isEmpty { return "请填写代理服务器。" }
        guard let port else { return "请填写代理端口。" }
        if !Self.portRange.contains(port) { return "端口需要在 1–65535 之间。" }
        if username.isEmpty != password.isEmpty { return "用户名和密码需要同时填写。" }
        return nil
    }

    /// 给 `URLSessionConfiguration` 和 `WKWebsiteDataStore` 使用的代理配置。使用系统设置或设置不完整时返回空数组。
    public func proxyConfigurations(password: String) -> [ProxyConfiguration] {
        guard mode == .socks5, problem(password: password) == nil,
              let port, let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return [] }
        let configuration = ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(trimmedHost), port: endpointPort))
        if !username.isEmpty {
            configuration.applyCredential(username: username, password: password)
        }
        return [configuration]
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
