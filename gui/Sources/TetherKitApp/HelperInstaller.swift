import Foundation
import Security
import TetherKitIPC

/// 把 .app 内嵌的特权组件载荷安装成 LaunchDaemon，或把装好的卸干净 ——
/// 「一键安装 / 卸载」按钮背后的全部机制。真正的步骤在载荷里的
/// install-helper.sh / uninstall-helper.sh，这里只负责两件事：找到、以 root 跑。
///
/// ★ 为什么是 AuthorizationExecuteWithPrivileges（AEWP）★
///
///   目标只有一个：以 root 跑一遍安装脚本。系统里能做这件事的口子：
///
///   * SMJobBless / SMAppService —— 靠代码签名 DR 双向绑定，源码分发下每台
///     机器的 cdhash 都不同，走不通（docs/GUI-SPIKE.md 第 3.3 节）；
///   * osascript "with administrator privileges" —— 能用，但它自建授权会话，
///     与 App 缓存的 AuthorizationRef（5 分钟窗口）完全接不上，必然多弹框；
///   * AEWP —— 参数就是 AuthorizationRef：缓存令牌还有效就一次框都不弹，
///     权利缺失时由它按 system.privilege.admin 弹标准授权框。与现有信任
///     模型（AuthorizationRef 复核，见 Authorization.swift）无缝衔接。
///
///   AEWP 自 10.7 起标记废弃，但 macOS 26 上实测符号仍可解析、它的 setuid
///   执行载体 /usr/libexec/security_authtrampoline 也仍在。这里用 dlsym 在
///   运行时解析而不是直接链接：将来系统真把它移除时，用户看到的是本页降级成
///   「请用终端安装」，而不是 App 在 dyld 绑定阶段直接起不来。
///
/// ★ 为什么 AEWP 的对象是 helper 二进制而不是安装脚本 ★
///
///   AEWP 给子进程的凭据是 euid=0 / ruid=普通用户，而 bash 在 euid ≠ ruid
///   且未带 -p 时会把 euid 降回 ruid —— 直接 AEWP 脚本，脚本开头的 root 检查
///   必然失败（真机踩过）。所以这里拉起的是载荷里 helper 二进制的 --install
///   模式：它先 setuid(0) 把凭据归一化成与 sudo 完全相同的真 root，把 stderr
///   并进 stdout（AEWP 的管道只接 stdout），再 exec 同目录的 install-helper.sh。
///   见 TetherKitHelper/InstallerMode.swift。
///
/// ★ 为什么成败不看退出码 ★
///
///   AEWP 既不给子进程 pid 也不给退出码，只有一根连到子进程 stdout 的管道。
///   所以这里只把「脚本跑完了」和「它说了什么」交出去；真正的成败由调用方
///   （AppModel）用一次真实的 XPC 往返判定 —— 「能连上匹配版本的 helper」
///   本来就比任何退出码都更接近事实。输出只在失败时给用户看原因。
enum HelperInstaller {
    /// 要执行的维护动作，对应 helper 二进制的命令行参数与载荷里的脚本。
    enum Action {
        case install
        case uninstall

        var flag: String {
            switch self {
            case .install: return "--install"
            case .uninstall: return "--uninstall"
            }
        }
    }

    enum Failure: LocalizedError {
        /// 找不到内嵌载荷。典型场景：`swift run` 直接跑的裸可执行文件 ——
        /// 只有 build-gui.sh 组装出的 .app 才带 Contents/Library/HelperTools。
        case payloadMissing
        /// 运行时解析不到 AEWP（未来某个 macOS 移除了它）。
        case executorUnavailable
        /// AEWP 返回错误（用户取消已单独成 case）。
        case launchFailed(OSStatus)
        case userCancelled

        var errorDescription: String? {
            switch self {
            case .payloadMissing:
                return "这份 TetherKit 不带安装载荷（可能是开发构建）。"
                    + "请在终端执行：sudo ./gui/Scripts/install-helper.sh"
            case .executorUnavailable:
                return "当前系统不再提供 App 内安装所需的接口。"
                    + "请在终端执行：sudo ./gui/Scripts/install-helper.sh"
            case .launchFailed(let status):
                return "无法启动安装/卸载程序（\(status)）"
            case .userCancelled:
                return "已取消授权"
            }
        }
    }

    /// 内嵌载荷目录（平铺放着 helper 二进制、dylib、plist 与安装脚本）。
    /// 不是从组装好的 .app 里跑起来时为 nil。
    static var payloadDirectory: URL? {
        let directory = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/HelperTools", isDirectory: true)
        // 二进制（AEWP 的执行对象）与两个脚本（真正的安装/卸载逻辑）缺一不可。
        let required = [helperBinaryName, installScriptName, uninstallScriptName]
            .map { directory.appendingPathComponent($0).path }
        let complete = required.allSatisfy { FileManager.default.isExecutableFile(atPath: $0) }
        return complete ? directory : nil
    }

    /// 进入安装流程前的快速自检：载荷在不在、AEWP 还在不在。
    ///
    /// 单独暴露是为了让调用方在**弹授权框之前**就发现装不了 —— 把用户的密码
    /// 要来了再说「装不了」是最差的次序。
    static func preflightError() -> Failure? {
        if payloadDirectory == nil { return .payloadMissing }
        if loadExecutor() == nil { return .executorUnavailable }
        return nil
    }

    /// 以 root 执行载荷里的安装 / 卸载脚本，返回其全部输出（stdout 与 stderr
    /// 合流）。
    ///
    /// 会阻塞在「可能弹出的授权框」与「脚本执行」上，所以整体挪到后台队列；
    /// 返回即代表脚本已经跑完（管道读到 EOF），**不代表动作成功** —— 见类型
    /// 注释里「为什么成败不看退出码」。
    static func run(_ action: Action, with token: AuthorizationToken) async throws -> String {
        guard let payload = payloadDirectory else { throw Failure.payloadMissing }
        guard let execute = loadExecutor() else { throw Failure.executorUnavailable }
        let installer = payload.appendingPathComponent(helperBinaryName).path

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    // 令牌必须活到 AEWP 返回、脚本跑完之后 —— 授权在它手里。
                    try withExtendedLifetime(token) {
                        try run(execute, token: token, installer: installer,
                                flag: action.flag)
                    }
                })
            }
        }
    }

    // MARK: - 实现

    private static let installScriptName = "install-helper.sh"
    private static let uninstallScriptName = "uninstall-helper.sh"
    /// 载荷里 helper 二进制的文件名，与 LaunchDaemon 的 Label 同名。
    private static let helperBinaryName = HelperConstants.machServiceName

    /// AEWP 的 C 原型。倒数第二个参数是 `char *const *`（NULL 结尾的 argv，
    /// 不含 argv[0] —— trampoline 会把工具路径填成 argv[0]）。
    private typealias ExecuteFunction = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        UInt32,
        UnsafePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private static func loadExecutor() -> ExecuteFunction? {
        // RTLD_DEFAULT：Security.framework 已经由本进程链接，符号一定在全局
        // 命名空间里（若还存在的话）。Darwin 模块没把这个常量导出给 Swift，
        // 只能按 dlfcn.h 里的定义写死 -2。
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "AuthorizationExecuteWithPrivileges") else { return nil }
        return unsafeBitCast(symbol, to: ExecuteFunction.self)
    }

    private static func run(_ execute: ExecuteFunction,
                            token: AuthorizationToken,
                            installer: String,
                            flag: String) throws -> String {
        // 执行对象是 helper 二进制的安装/卸载模式，不是脚本 —— 原因见类型
        // 注释。stderr 合流也由那边做（dup2），这里只管拉起与收输出。
        var pipe: UnsafeMutablePointer<FILE>?
        let status = token.withReference { reference in
            withArgv([flag]) { argv in
                execute(reference, installer, 0 /* kAuthorizationFlagDefaults */,
                        argv, &pipe)
            }
        }

        switch status {
        case errAuthorizationSuccess:
            break
        case errAuthorizationCanceled:
            throw Failure.userCancelled
        default:
            throw Failure.launchFailed(status)
        }

        guard let pipe else { return "" }
        defer { fclose(pipe) }

        // 直接读底层 fd 到 EOF —— EOF 即子进程结束（LaunchDaemon 的 stdio 由
        // launchd 按 plist 里的 StandardOutPath 单独给，不会继承这根管道，
        // 所以不存在「孙进程拖着管道不放」的悬挂）。
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let descriptor = fileno(pipe)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                output.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno != EINTR {
                break
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// 把 Swift 字符串数组变成 NULL 结尾的 C argv，喂给 body。
    private static func withArgv<T>(
        _ arguments: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        return argv.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
