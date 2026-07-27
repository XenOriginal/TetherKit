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

    /// XPC 调用的超时（秒）。
    ///
    /// 取 30 秒是因为最慢的一次调用是 DHCP 配置：库内部最多等 10 秒租约，
    /// 加上 USB 握手与网卡创建，留 3 倍余量。
    public static let requestTimeout: TimeInterval = 30
}
