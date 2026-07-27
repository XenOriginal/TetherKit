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

/// App 侧：向用户请求授权，拿到可以跨进程传递的凭据。
public enum AuthorizationBroker {
    public enum Failure: LocalizedError {
        case userCancelled
        case denied(OSStatus)
        case internalFailure(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .userCancelled:
                return "已取消授权"
            case .denied(let status):
                return "授权未通过（\(status)）"
            case .internalFailure(let status):
                return "无法创建授权会话（\(status)）"
            }
        }
    }

    /// 弹出系统授权框（密码 / Touch ID），成功后返回凭据的外部形式。
    ///
    /// 必须在主线程调用 —— 它会呈现 UI。
    public static func requestAuthorization(
        right: String = HelperConstants.privilegedRightName
    ) throws -> Data {
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else {
            throw Failure.internalFailure(createStatus)
        }
        // App 这一侧持有凭据，用完要连同权利一起销毁 —— 不留一张长期有效的
        // 「通行证」在进程里。
        defer { AuthorizationFree(authorization, [.destroyRights]) }

        var name = Array(right.utf8CString)
        let copyStatus: OSStatus = name.withUnsafeMutableBufferPointer { buffer in
            var item = AuthorizationItem(name: buffer.baseAddress!, valueLength: 0,
                                         value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                // App 侧**要**带 .interactionAllowed —— 弹框正是我们要的。
                return AuthorizationCopyRights(authorization, &rights, nil,
                                               [.extendRights, .interactionAllowed, .preAuthorize],
                                               nil)
            }
        }
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
        return withUnsafeBytes(of: &external) { Data($0) }
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
                return "授权凭据格式不正确"
            case .restoreFailed(let status):
                return "无法还原授权凭据（\(status)）"
            case .rightNotHeld(let status):
                return "调用方没有执行该操作所需的授权（\(status)）"
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
