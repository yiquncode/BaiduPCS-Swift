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
    private static let service = Bundle.main.bundleIdentifier ?? "Ferry"
    private static let account = "baidu-login"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> StoredLogin? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredLogin.self, from: data)
    }

    static func save(_ login: StoredLogin) throws {
        let data = try JSONEncoder().encode(login)
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

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法把登录信息保存到钥匙串（\(status)）。"])
        }
    }
}
