import BaiduKit
import Foundation
import Security

/// 登录信息。账号随凭据一起保存，启动时不用等校验就能显示用户名。
struct StoredLogin: Codable {
    var credential: Credential
    var account: Account
}

/// 把登录信息保存在 Keychain 中。
enum CredentialStore {
    private static let item = KeychainItem(account: "baidu-login", name: "登录信息")

    static func load() -> StoredLogin? {
        item.load().flatMap { try? JSONDecoder().decode(StoredLogin.self, from: $0) }
    }

    static func save(_ login: StoredLogin) throws {
        try item.save(JSONEncoder().encode(login))
    }

    static func delete() {
        item.delete()
    }
}

/// 把 SOCKS5 代理的密码保存在 Keychain 中。代理的其他设置在 `FerrySettings` 中。
enum ProxyPasswordStore {
    private static let item = KeychainItem(account: "socks-proxy", name: "代理密码")

    /// 没有保存密码时返回空字符串。
    static func load() -> String {
        item.load().flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// 密码为空时删除这一项。
    static func save(_ password: String) throws {
        if password.isEmpty {
            item.delete()
        } else {
            try item.save(Data(password.utf8))
        }
    }
}

/// Keychain 中的一项通用密码。service 是应用的 bundle id。
private struct KeychainItem {
    let account: String
    /// 保存失败时提示中的名称。
    let name: String

    private static let service = Bundle.main.bundleIdentifier ?? "Ferry"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func load() -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法把\(name)保存到钥匙串（\(status)）。"])
        }
    }
}
