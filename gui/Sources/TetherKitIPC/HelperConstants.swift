import Foundation

/// App 与 helper 之间约定死的一组常量。
///
/// 单独成文件是为了让「改一个名字要同步改哪些地方」这件事只有一个答案 ——
/// 这些字符串同时出现在 LaunchDaemon 的 plist、安装脚本和两端代码里，
/// 任何一处不同步的表现都是「连不上 helper」，且没有任何有用的报错。
public enum HelperConstants {
    /// Mach 服务名。必须与 /Library/LaunchDaemons/*.plist 里的 MachServices 键一致。
    public static let machServiceName = "com.tetherkit.helper"

    /// helper 可执行文件的安装路径。
    ///
    /// /Library/PrivilegedHelperTools 是 Apple 给特权 helper 的约定位置，
    /// 只有 root 可写。
    public static let helperExecutablePath = "/Library/PrivilegedHelperTools/com.tetherkit.helper"

    /// LaunchDaemon 配置文件路径。
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/com.tetherkit.helper.plist"

    /// 特权操作所要求的授权权利。
    ///
    /// ★ 为什么用系统内置的 system.privilege.admin，而不是自定义权利 ★
    ///   自定义权利要先用 AuthorizationRightSet 写进策略数据库，而那本身就需要
    ///   管理员权限 —— 于是就有了「安装授权需要授权」的先有鸡还是先有蛋问题。
    ///   system.privilege.admin 的规则是 authenticate-admin，弹的正是我们想要的
    ///   密码 / Touch ID 框，语义也贴切：「这是一次需要管理员身份的操作」。
    public static let privilegedRightName = "system.privilege.admin"

    /// XPC 接口的修订号。**每次改动 TetherKitHelperProtocol 都要加一。**
    ///
    /// 为什么需要它：helper 是装在系统目录里的，升级 App 时如果忘了重装 helper，
    /// 两端的方法签名就对不上 —— 表现是调用卡住或者直接崩，完全看不出是版本问题。
    /// 有了这个号，App 一连上就能发现不匹配并明确告诉用户「请重新安装特权组件」。
    ///
    /// 修订历史：
    ///   1 —— 初版
    ///   2 —— 特权方法的应答从 (String?) 改成 (String?, Bool)，区分授权失败
    ///   3 —— 新增 setLanguage，让 helper 的提示与库日志跟随界面语言
    ///   4 —— 新增 applyNetworkV6 / queryNetworkV6，支持 IPv6 取址与 DNS
    public static let protocolRevision = 4

    /// 把修订号编进版本串。
    ///
    /// 刻意复用现成的 `helperVersion` 方法而不是新增一个 —— 新增方法本身就是
    /// 一次协议变更，旧 helper 根本没有它，那就又回到了「对不上还查不出来」。
    /// 用旧 helper 也一定会应答的这个方法，才能可靠地识别出旧 helper。
    public static func encodeVersion(_ version: String) -> String {
        "\(protocolRevision)|\(version)"
    }

    /// 解析版本串。旧 helper 返回的串里没有分隔符，此时修订号记作 0。
    public static func decodeVersion(_ encoded: String) -> (revision: Int, version: String) {
        guard let separator = encoded.firstIndex(of: "|"),
              let revision = Int(encoded[encoded.startIndex..<separator]) else {
            return (0, encoded)
        }
        return (revision, String(encoded[encoded.index(after: separator)...]))
    }

    /// 从库的版本串里取出语义化版本号：
    /// `"TetherKit 0.1.4 (C++23, macOS 13.3+)"` → `"0.1.4"`。
    ///
    /// ★ 为什么不直接比整串 ★
    ///   串里除了版本号还带着 C++ 标准与最低 macOS 版本 —— 那是**构建配置**，
    ///   不是版本。拿整串当判据的话，换个编译选项重建一次就会冒出一个
    ///   「组件该更新了」的假警报，而用户点下去什么也不会变。
    ///
    /// 取不到（串里没有带点的数字）时退回整串：宁可误报也不要漏报 —— 漏报
    /// 意味着用户一直在跑升级前的那份库，且毫不知情。
    public static func semanticVersion(of text: String) -> String {
        // 至少要有一个点，否则 "C++23" 这种也会被当成版本号。
        guard let range = text.range(of: "[0-9]+(\\.[0-9]+)+", options: .regularExpression) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[range])
    }

    /// XPC 调用的超时（秒）。
    ///
    /// 取 30 秒是因为最慢的一次调用是 DHCP 配置：库内部最多等 10 秒租约，
    /// 加上 USB 握手与网卡创建，留 3 倍余量。
    public static let requestTimeout: TimeInterval = 30
}
