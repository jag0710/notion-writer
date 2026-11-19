import Foundation
import Security

enum Keychain {
    static func query(_ databaseID: String) -> [String: Any] {
        let service = "io.github.jag0710.notion-writer"
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: databaseID]
    }
    static func read(_ databaseID: String) throws -> String? {
        var query = query(databaseID)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw failure(status, reading: true) }
        return text
    }
    static func save(_ token: String, databaseID: String) throws {
        let data = Data(token.utf8); let query = query(databaseID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let add = SecItemAdd(item as CFDictionary, nil)
            guard add == errSecSuccess else { throw failure(add) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    static func failure(_ status: OSStatus, reading: Bool = false) -> NSError {
        let detail = reading ? "保存済みの接続トークンを読み取れません。Macのキーチェーンを解除し、再度お試しください。解消しない場合は設定からAPIトークンを登録し直してください。下書きは保持しています。" : "接続トークンを保存できませんでした。キーチェーンの状態を確認してください。"
        return NSError(domain: "NotionWriter.Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychainにアクセスできません (\(status))。\n" + detail])
    }
}
