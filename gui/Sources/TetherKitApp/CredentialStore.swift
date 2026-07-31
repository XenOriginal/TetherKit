import Foundation
import Security

/// 管理员密码的加密持久化。
///
/// ★ 用系统钥匙串，而不是自己加密 ★
///   自己写 AES 再加一层密钥管理，等于制造第二个需要保护的东西。macOS 的
///   登录钥匙串本身已经由用户登录密码加密存储 —— 用户登录后钥匙串自动解密，
///   TetherKit 读到的就是明文密码（只在内存里短暂存在）；用户登出或锁屏后
///   钥匙串重新上锁，磁盘上仍是密文。这比任何「应用自管加密」都更可信，
///   因为密钥就在用户脑子里，不在磁盘上。
///
/// ★ 存的是什么 ★
///   只是「当前登录用户的管理员密码」，用来在启动时静默取得 `system.privilege.admin`
///   权利，免去每次打开 App 弹系统授权框。它不是 root 密码、不是 ssh key，
///   作用域仅限本机本用户的授权缓存。
///
/// ★ 何时写入 ★
///   仅在用户**亲手在 TetherKit 自己的输入框里输过一次正确密码**之后才写入。
///   密码从不在系统授权框里被读取（那个框的返回值里根本没有密码），
///   所以从系统框永远取不到可落盘的凭据 —— 这正是为什么需要一个 TetherKit 自己的
///   输入框来首采密码。
public enum CredentialStore {
    private static let service = "com.tetherkit.credential"
    private static let account = "adminPassword"

    /// 把密码写入登录钥匙串。重复写入会先删旧的。
    ///
    /// 失败（比如钥匙串被锁、权限不足）时返回 false；调用方应重新向用户收集。
    @discardableResult
    public static func save(_ password: String) -> Bool {
        let data = Data(password.utf8)
        // 先删可能已存在的项，避免 duplicate item 错误。
        SecItemDelete(baseQuery() as CFDictionary)
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            // 仅在本机解锁时可用、且不进 iCloud 同步 —— 最大限度收窄泄露面。
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel: "TetherKit administrator password",
            kSecAttrDescription: "Used to silently obtain admin authorization at launch",
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// 读回密码；钥匙串里没有、被锁、或解码失败都返回 nil。
    public static func load() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    /// 删除已存密码（例如用户改了管理员密码导致之前存的那条失效）。
    public static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: account]
    }
}
