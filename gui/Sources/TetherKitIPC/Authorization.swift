import Foundation
import Security

/// 授权凭据的取得（App 侧）与复核（helper 侧）。
///
/// ★ 两侧刻意放在同一个文件里 ★
///   它们的差别只有一个标志位（`.interactionAllowed`），而那一位放错就是一个
///   安全漏洞。写在一起，改一边时另一边就在眼前。
///
/// ★ 一句必须记住的话：授权 ≠ root ★
///   `AuthorizationCopyRights` 成功**不改变进程的任何东西** —— uid、euid 一个
///   都没动。它产出的只是一张「用户在某时刻通过密码/指纹确认过」的凭据。
///   权限本身必须另有来源（这里是 launchd 以 root 拉起的 helper）。
///
///   所以顺序不能反：不是「先弹指纹拿到 root，再去建网卡」，而是「先有常驻的
///   root helper，每次操作弹指纹拿凭据交给它复核」。

/// 一次授权的持有者。
///
/// ★ 它存在的唯一理由：外部形式**不是凭据本身，只是一个引用** ★
///
///   `AuthorizationMakeExternalForm` 产出的 32 字节里没有任何权利信息，它只是
///   指向 securityd 里那份授权的一把钥匙。只要 App 这边把 AuthorizationRef 释放
///   掉（尤其是带 `.destroyRights` 释放），securityd 里的东西就没了 ——
///   helper 随后 `AuthorizationCreateFromExternalForm` 会失败，
///   报 `errAuthorizationDenied (-60005)`。
///
///   所以 AuthorizationRef 必须**活到 XPC 往返结束之后**。用一个类来持有它，
///   让 ARC 去管这件事，比在每个调用点手写「记得最后再 free」可靠得多。
///
/// ★ 为什么敢标 @unchecked Sendable ★
///   HelperInstaller 要把令牌递到后台队列（AEWP 会阻塞在授权框上，不能占主
///   线程）。这里没有可变状态 —— 两个存储属性都是 let；AuthorizationRef 本身
///   按 Authorization Services 的文档是线程安全的（真正的状态在 securityd
///   进程里，跨进程调用天然串行化）；deinit 由 ARC 保证只跑一次。
public final class AuthorizationToken: @unchecked Sendable {
    /// 可以跨进程传给 helper 的 32 字节外部形式。
    public let externalForm: Data

    private let authorization: AuthorizationRef

    init(authorization: AuthorizationRef, externalForm: Data) {
        self.authorization = authorization
        self.externalForm = externalForm
    }

    /// 把底层的 AuthorizationRef 短暂借给需要它本体的 API（目前只有
    /// `AuthorizationExecuteWithPrivileges` 一处 —— 它要的是 ref，不是外部形式）。
    ///
    /// 做成作用域借用而不是直接暴露属性：ref 的生命周期归本类管，谁把它存到
    /// 闭包外面，令牌一释放就是悬垂引用 —— 那种错误编译器查不出来。
    public func withReference<T>(_ body: (AuthorizationRef) throws -> T) rethrows -> T {
        try body(authorization)
    }

    deinit {
        // 带 .destroyRights：凭据归 App 所有，用完就销毁，不在进程里留一张
        // 长期有效的通行证。（helper 那边复核时**不能**带这个标志，
        // 否则会把这边的授权一起作废 —— 见 AuthorizationVerifier。）
        AuthorizationFree(authorization, [.destroyRights])
    }
}

/// App 侧：向用户请求授权，拿到可以跨进程传递的凭据。
public enum AuthorizationBroker {
    public enum Failure: LocalizedError {
        case userCancelled
        case denied(OSStatus)
        case internalFailure(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .userCancelled:
                return L(.authorizationCancelled)
            case .denied(let status):
                return L(.authorizationDenied, Int(status))
            case .internalFailure(let status):
                return L(.authorizationSessionFailed, Int(status))
            }
        }
    }

    /// 尝试获取授权，优先静默（不弹框），仅在必要时才弹出系统授权框。
    ///
    /// ★ 为什么分两趟 ★
    ///   macOS 的 securityd 会在登录会话内缓存近期成功的管理员认证。
    ///   对 `system.privilege.admin` 这条权利，缓存的典型窗口是 5 分钟（可被
    ///   系统管理员通过 /etc/authorization 改动）。如果用户在本会话中最近输入过
    ///   密码（无论是给 TetherKit、sudo 还是其他工具），不带 .interactionAllowed
    ///   的 AuthorizationCopyRights 可以直接命中缓存、不弹任何 UI。
    ///
    ///   这就是为什么「每次连接都弹密码框」的根本原因不是安全策略太严，
    ///   而是我们的代码**每次都带 .interactionAllowed** —— 这个标志的意思是
    ///   「必须弹框交互」，securityd 即使有缓存也会照弹不误。
    ///
    /// ★ 调用方必须让令牌活到 XPC 往返结束之后。★
    ///
    /// - Parameter right: 要取得的权利名，默认为 HelperConstants 定义的管理员权利。
    /// - Parameter prompt: 弹框时显示的说明文字。静默成功时不使用。
    /// - Parameter allowInteraction: 是否允许弹框。传 false 可用于「仅在有缓存时
    ///   才继续」的场景（如自动应用）。
    /// - Parameter password: 明文管理员密码（来自钥匙串）。传入时**不弹任何 UI**，
    ///   用这组凭据静默取得授权；错误（密码错、被锁）一律抛 `.denied`，交给调用方
    ///   决定是清掉失效的钥匙串项还是回退到交互式授权。
    ///
    /// 必须在主线程调用 —— 它可能呈现 UI。
    public static func requestAuthorization(
        right: String = HelperConstants.privilegedRightName,
        prompt: String? = nil,
        allowInteraction: Bool = true,
        password: String? = nil
    ) throws -> AuthorizationToken {
        // 密码路径：用明文密码（来自钥匙串）静默取得授权，绝不弹 UI。
        if let password {
            if let token = tryPasswordAuthorization(right: right, password: password) {
                return token
            }
            throw Failure.denied(errAuthorizationDenied)
        }

        // 第一趟：静默尝试。不弹框，只查 securityd 的会话级缓存。
        if let token = trySilentAuthorization(right: right) {
            return token
        }

        // 第二趟：缓存未命中，需要用户交互（或调用方明确禁止交互）。
        guard allowInteraction else {
            throw Failure.denied(errAuthorizationInteractionNotAllowed)
        }

        return try requestInteractiveAuthorization(right: right, prompt: prompt)
    }

    /// 不带 .interactionAllowed 的静默授权尝试。
    ///
    /// 成功条件：securityd 在当前登录会话中持有该权利的有效缓存凭证。
    /// 典型场景：用户最近 5 分钟内（默认窗口）在任意地方输入过管理员密码。
    ///
    /// 返回 nil 而不是抛错：缓存未命中是正常情况，不应被视为错误。
    private static func trySilentAuthorization(right: String) -> AuthorizationToken? {
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else { return nil }
        var handedOff = false
        defer {
            if !handedOff { AuthorizationFree(authorization, [.destroyRights]) }
        }

        let copyStatus = copyRights(authorization, right: right, prompt: nil,
                                     interactionAllowed: false)
        guard copyStatus == errAuthorizationSuccess else { return nil }

        var external = AuthorizationExternalForm()
        let externalStatus = AuthorizationMakeExternalForm(authorization, &external)
        guard externalStatus == errAuthorizationSuccess else { return nil }

        handedOff = true
        return AuthorizationToken(authorization: authorization,
                                  externalForm: withUnsafeBytes(of: &external) { Data($0) })
    }

    /// 用明文密码（来自钥匙串）静默取得授权，不弹任何 UI。
    ///
    /// 原理：把用户名 + 密码放进 `AuthorizationEnvironment`，传给
    /// `AuthorizationCopyRights` 并**不**带 `.interactionAllowed`。Security 服务器
    /// 会用这组凭据认证 `system.privilege.admin`：密码正确则静默成功，错误则返回
    /// 失败（随后由调用方清掉钥匙串里那条失效的密码）。
    ///
    /// 这是「把密码存进钥匙串、启动时自动加载」方案的关键一环：用户只在第一次
    /// （或密码改了之后）亲手输一次密码，之后每次启动都走这条静默路径。
    private static func tryPasswordAuthorization(right: String, password: String) -> AuthorizationToken? {
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else { return nil }
        var handedOff = false
        defer {
            if !handedOff { AuthorizationFree(authorization, [.destroyRights]) }
        }

        let copyStatus = copyRightsWithPassword(authorization, right: right, password: password,
                                                interactionAllowed: false)
        guard copyStatus == errAuthorizationSuccess else { return nil }

        var external = AuthorizationExternalForm()
        let externalStatus = AuthorizationMakeExternalForm(authorization, &external)
        guard externalStatus == errAuthorizationSuccess else { return nil }

        handedOff = true
        return AuthorizationToken(authorization: authorization,
                                  externalForm: withUnsafeBytes(of: &external) { Data($0) })
    }

    /// 带「用户名 + 密码」环境项的授权请求。钥匙串里的密码走这一条。
    private static func copyRightsWithPassword(_ authorization: AuthorizationRef,
                                               right: String,
                                               password: String,
                                               interactionAllowed: Bool) -> OSStatus {
        var name = Array(right.utf8CString)
        let username = NSUserName()

        return name.withUnsafeMutableBufferPointer { nameBuffer in
            var rightItem = AuthorizationItem(name: nameBuffer.baseAddress!, valueLength: 0,
                                             value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &rightItem) { rightPointer in
                var rights = AuthorizationRights(count: 1, items: rightPointer)

                var flags: AuthorizationFlags = [.extendRights, .preAuthorize]
                if interactionAllowed {
                    flags.insert(.interactionAllowed)
                }

                var usernameKey = Array(kAuthorizationEnvironmentUsername.utf8CString)
                var usernameValue = Array(username.utf8)
                var passwordKey = Array(kAuthorizationEnvironmentPassword.utf8CString)
                var passwordValue = Array(password.utf8)

                return usernameKey.withUnsafeMutableBufferPointer { uk in
                    usernameValue.withUnsafeMutableBufferPointer { uv in
                        passwordKey.withUnsafeMutableBufferPointer { pk in
                            passwordValue.withUnsafeMutableBufferPointer { pv in
                                let usernameItem = AuthorizationItem(
                                    name: uk.baseAddress!, valueLength: uv.count,
                                    value: uv.baseAddress, flags: 0)
                                let passwordItem = AuthorizationItem(
                                    name: pk.baseAddress!, valueLength: pv.count,
                                    value: pv.baseAddress, flags: 0)
                                var envItems = [usernameItem, passwordItem]
                                // count 提到闭包外取，避免和 withUnsafeMutableBufferPointer
                                // 的独占访问冲突。
                                let envCount = UInt32(envItems.count)
                                return envItems.withUnsafeMutableBufferPointer { envBuffer in
                                    var environment = AuthorizationEnvironment(
                                        count: envCount,
                                        items: envBuffer.baseAddress!)
                                    return AuthorizationCopyRights(authorization, &rights, &environment,
                                                                 flags, nil)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 带交互（弹框）的授权请求。仅在静默尝试失败后才走到这里。
    private static func requestInteractiveAuthorization(
        right: String,
        prompt: String?
    ) throws -> AuthorizationToken {
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else {
            throw Failure.internalFailure(createStatus)
        }
        var handedOff = false
        defer {
            if !handedOff { AuthorizationFree(authorization, [.destroyRights]) }
        }

        let copyStatus = copyRights(authorization, right: right, prompt: prompt,
                                     interactionAllowed: true)
        guard copyStatus == errAuthorizationSuccess else {
            throw copyStatus == errAuthorizationCanceled
                ? Failure.userCancelled
                : Failure.denied(copyStatus)
        }

        var external = AuthorizationExternalForm()
        let externalStatus = AuthorizationMakeExternalForm(authorization, &external)
        guard externalStatus == errAuthorizationSuccess else {
            throw Failure.internalFailure(externalStatus)
        }

        handedOff = true
        return AuthorizationToken(authorization: authorization,
                                  externalForm: withUnsafeBytes(of: &external) { Data($0) })
    }

    /// 请求权利，控制是否弹框。
    ///
    /// 单独抽出来是因为环境项的构造要嵌好几层 `withUnsafe*` —— 那些缓冲必须活
    /// 到 `AuthorizationCopyRights` 返回之后，写在主流程里很容易被后来的人
    /// 「顺手整理」成悬垂指针。
    ///
    /// - Parameters:
    ///   - authorization: 要取得权利的 AuthorizationRef。
    ///   - right: 权利名（如 system.privilege.admin）。
    ///   - prompt: 授权框里的说明文字。nil 时不传环境变量（框里只有默认文案）。
    ///   - interactionAllowed: 是否允许弹框。false = 纯静默查询 securityd 缓存。
    private static func copyRights(_ authorization: AuthorizationRef,
                                   right: String,
                                   prompt: String?,
                                   interactionAllowed: Bool) -> OSStatus {
        var name = Array(right.utf8CString)
        var promptKey = Array(kAuthorizationEnvironmentPrompt.utf8CString)
        var promptValue = Array(prompt?.utf8 ?? "".utf8)

        return name.withUnsafeMutableBufferPointer { nameBuffer in
            var rightItem = AuthorizationItem(name: nameBuffer.baseAddress!, valueLength: 0,
                                              value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &rightItem) { rightPointer in
                var rights = AuthorizationRights(count: 1, items: rightPointer)

                var flags: AuthorizationFlags = [.extendRights, .preAuthorize]
                if interactionAllowed {
                    flags.insert(.interactionAllowed)
                }

                guard prompt != nil else {
                    return AuthorizationCopyRights(authorization, &rights, nil, flags, nil)
                }
                return promptKey.withUnsafeMutableBufferPointer { keyBuffer in
                    promptValue.withUnsafeMutableBufferPointer { valueBuffer in
                        var promptItem = AuthorizationItem(
                            name: keyBuffer.baseAddress!,
                            valueLength: valueBuffer.count,
                            value: valueBuffer.baseAddress,
                            flags: 0)
                        return withUnsafeMutablePointer(to: &promptItem) { promptPointer in
                            var environment = AuthorizationEnvironment(count: 1,
                                                                       items: promptPointer)
                            return AuthorizationCopyRights(authorization, &rights, &environment,
                                                           flags, nil)
                        }
                    }
                }
            }
        }
    }
}

/// helper 侧：复核调用方递过来的凭据。
public enum AuthorizationVerifier {
    public enum Failure: LocalizedError {
        case malformedCredential
        case restoreFailed(OSStatus)
        case rightNotHeld(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .malformedCredential:
                return L(.authorizationBlobMalformed)
            case .restoreFailed(let status):
                return L(.authorizationRestoreFailed, Int(status))
            case .rightNotHeld(let status):
                return L(.authorizationRightMissing, Int(status))
            }
        }
    }

    /// 校验凭据里确实已经包含指定权利。不包含就抛错。
    ///
    /// ★ 三条必须照做的细节 ★
    ///
    ///   1. **绝不能带 `.interactionAllowed`。** daemon 没有 UI 会话；真让它能
    ///      弹框，等于任何能连上 Mach 服务的进程都能随意触发系统授权弹框骚扰
    ///      用户。这一步只查「这份凭据里已经有这项权利了吗」，不获取新权利。
    ///
    ///   2. **`AuthorizationFree` 不能带 `.destroyRights`。** 凭据归 App 所有，
    ///      helper 只是借来核对；带上会把 App 那边的授权一起作废。
    ///
    ///   3. 复核是**每次特权调用**都要做的。helper 的 root 来自 launchd，
    ///      跟用户按没按指纹毫无关系 —— 它一启动就是 root，任何能连上 Mach
    ///      服务的进程都能发请求。所以「谁在调用」只能由 helper 自己回答。
    public static func verify(externalForm data: Data,
                              right: String = HelperConstants.privilegedRightName) throws {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else {
            throw Failure.malformedCredential
        }

        var external = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &external) { destination in
            data.copyBytes(to: destination.bindMemory(to: UInt8.self))
        }

        var authorization: AuthorizationRef?
        let restoreStatus = AuthorizationCreateFromExternalForm(&external, &authorization)
        guard restoreStatus == errAuthorizationSuccess, let authorization else {
            throw Failure.restoreFailed(restoreStatus)
        }
        // 注意：**不带** .destroyRights，见上面第 2 条。
        defer { AuthorizationFree(authorization, []) }

        var name = Array(right.utf8CString)
        let checkStatus: OSStatus = name.withUnsafeMutableBufferPointer { buffer in
            var item = AuthorizationItem(name: buffer.baseAddress!, valueLength: 0,
                                         value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                // 只有 .extendRights，**没有** .interactionAllowed，见上面第 1 条。
                return AuthorizationCopyRights(authorization, &rights, nil, [.extendRights], nil)
            }
        }
        guard checkStatus == errAuthorizationSuccess else {
            throw Failure.rightNotHeld(checkStatus)
        }
    }
}
