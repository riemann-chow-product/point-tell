import Foundation
import Security

/// API Key 的存储。
///
/// 为什么不是「只用钥匙串」：
/// 本项目用 ad-hoc 签名（`codesign --sign -`），每次重新构建 cdhash 都会变。
/// 钥匙串条目的 ACL 绑定在创建它的那份签名上，于是「重新构建 → 读不了自己刚存的 key」，
/// 而且读失败时系统会弹授权框——那是个模态窗口，会把主线程卡死（连设置窗口都打不开）。
///
/// 所以这里的策略是：
///   1. 先关掉钥匙串的用户交互（`SecKeychainSetUserInteractionAllowed(false)`），
///      让权限不足时**立刻失败**而不是弹窗卡住；
///   2. 写入后立刻读回验证，能读回才算存好；
///   3. 钥匙串不可用时，退到 `~/Library/Application Support/PointTell/api-key.json`
///      （权限 0600，只有当前用户可读），保证配置不会静默丢失。
///
/// 正式签名（有 Team ID）的构建不会走到第 3 步，key 只存在钥匙串里。
enum Keychain {

    /// nil 表示存好了；非 nil 是给用户看的原因
    @discardableResult
    static func set(_ value: String, account: String) -> String? {
        silenceUI()

        if value.isEmpty {
            SecItemDelete(baseQuery(account: account) as CFDictionary)
            removeFromFile(account: account)
            PTLog.write("keychain: cleared \(account)")
            return nil
        }

        let status = writeKeychain(value, account: account)

        // 写完立刻读回：能读回才算真的可用（ACL 不匹配时 add 会成功但读不到）
        if status == errSecSuccess, readKeychain(account: account) == value {
            // 同时留一份 0600 文件镜像。
            // 原因：钥匙串条目的 ACL 绑定在「创建它的那份签名」上，换签名（ad-hoc → 证书、
            // 换证书、甚至某些系统升级）之后条目就读不出来了，表现为「设置里明明存过，却 401」。
            // 镜像让 key 不会因为签名变化而丢失。
            mirrorToFile(value, account: account)
            PTLog.write("keychain: stored \(account) in keychain (len=\(value.count)) + file mirror")
            return nil
        }

        PTLog.write("keychain: keychain unusable for \(account) (status=\(status) \(describe(status))), falling back to file")

        if writeFile(value, account: account) {
            return nil
        }
        return "API Key 存不进钥匙串，也写不了本地文件（\(describe(status))）"
    }

    static func get(account: String) -> String {
        silenceUI()
        if let v = readKeychain(account: account), !v.isEmpty {
            PTLog.write("keychain: read \(account) from keychain (len=\(v.count))")
            return v
        }
        let fallback = readFile(account: account)
        PTLog.write("keychain: keychain read MISS for \(account) → file fallback len=\(fallback.count)")
        return fallback
    }

    /// 当前 key 存在哪里，设置窗口里可以显示
    static func storageDescription(account: String) -> String {
        silenceUI()
        let inKeychain = !(readKeychain(account: account) ?? "").isEmpty
        let inFile = !readFile(account: account).isEmpty
        if inKeychain && inFile { return "钥匙串 + 本地文件（0600）" }
        if inKeychain { return "钥匙串" }
        if inFile { return "本地文件（0600）" }
        return "未保存"
    }

    // MARK: - 钥匙串

    private static func baseQuery(account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppInfo.keychainService,
            kSecAttrAccount as String: account
        ]
    }

    private static func writeKeychain(_ value: String, account: String) -> OSStatus {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var add = baseQuery(account: account)
        add[kSecValueData as String] = value.data(using: .utf8) ?? Data()
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // 旧签名留下的条目删不掉，按 service 全量清一次再试
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: AppInfo.keychainService] as CFDictionary)
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }

    private static func readKeychain(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            PTLog.write("keychain: SecItemCopyMatching(\(account)) = \(status) \(describe(status))")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// 关键：禁止钥匙串弹窗。否则权限不足时会挂一个模态框，主线程直接停住。
    private static func silenceUI() {
        SecKeychainSetUserInteractionAllowed(false)
    }

    // MARK: - 本地文件兜底（0600）

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("PointTell", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        return dir.appendingPathComponent("api-key.json")
    }

    private static func readFile(account: String) -> String {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let value = dict[account] else { return "" }
        return value
    }

    private static func writeFile(_ value: String, account: String) -> Bool {
        var dict: [String: String] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            dict = existing
        }
        dict[account] = value
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) else {
            return false
        }
        let url = fileURL
        let ok = FileManager.default.createFile(atPath: url.path, contents: data,
                                                attributes: [.posixPermissions: 0o600])
        // 文件已存在时 createFile 不覆盖内容，需要显式写
        if ok || FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        }
        return false
    }

    /// 钥匙串存好之后再镜像一份文件。失败不影响主流程（key 已在钥匙串里）。
    private static func mirrorToFile(_ value: String, account: String) {
        if !writeFile(value, account: account) {
            PTLog.write("keychain: file mirror failed for \(account)")
        }
    }

    private static func removeFromFile(account: String) {
        guard let data = try? Data(contentsOf: fileURL),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        dict.removeValue(forKey: account)
        if dict.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        if let out = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? out.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - 错误码

    static func describe(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess: return "成功"
        case errSecItemNotFound: return "条目不存在"
        case errSecDuplicateItem: return "条目重复"
        case errSecAuthFailed: return "钥匙串拒绝访问（签名变化后常见）"
        case errSecInteractionNotAllowed: return "钥匙串被锁定或不允许交互"
        case errSecMissingEntitlement: return "缺少钥匙串权限"
        case errSecNotAvailable: return "钥匙串不可用"
        default:
            if let msg = SecCopyErrorMessageString(status, nil) as String? { return msg }
            return "错误码 \(status)"
        }
    }
}
