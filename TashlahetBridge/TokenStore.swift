import Foundation
import Security

protocol TokenStoring {
    func loadToken() throws -> String
    func saveToken(_ token: String) throws
}

enum TokenStoreError: Error {
    case invalidData
    case keychain(OSStatus)
}

struct KeychainTokenStore: TokenStoring {
    private let service = "com.briguy.tashlahetbridge.translation-auth"
    private let account = "translation-backend-bearer-token"

    func loadToken() throws -> String {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw TokenStoreError.keychain(status) }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw TokenStoreError.invalidData
        }
        return try TranslationConfiguration.normalizedAuthToken(token) ?? ""
    }

    func saveToken(_ token: String) throws {
        let normalized = try TranslationConfiguration.normalizedAuthToken(token) ?? ""
        if normalized.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TokenStoreError.keychain(status)
            }
            return
        }

        let value = Data(normalized.utf8)
        let attributes: [CFString: Any] = [
            kSecValueData: value,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData] = value
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw TokenStoreError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw TokenStoreError.keychain(updateStatus)
        }
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}
